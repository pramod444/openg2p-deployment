#!/usr/bin/env bash
# =============================================================================
# OpenG2P Backup — rancher-backup operator (resource-level export)
# =============================================================================
# What this captures: the Kubernetes resources that DO NOT come back from a
# fresh helmfile install — Secrets (incl. Helm release Secrets, runtime TLS),
# ConfigMaps, PV/PVCs, Namespaces, ServiceAccounts, and curated CR groups
# (Rancher, cert-manager, Prometheus, Istio, Keycloak, Logging).
#
# Output: encrypted tarball nightly to a PVC on NFS. The NFS restic backup
# captures the tarball — single point of dedup/encryption downstream.
#
# Upstream:
#   https://ranchermanager.docs.rancher.com/integrations-in-rancher/backup-restore-and-disaster-recovery
#   https://github.com/rancher/backup-restore-operator
# =============================================================================

set -euo pipefail

RANCHER_BACKUP_NS="cattle-resources-system"
RANCHER_BACKUP_PVC="openg2p-rancher-backup"
RANCHER_BACKUP_ENC_SECRET="openg2p-backup-encryption"

# ---------------------------------------------------------------------------
# rancher_install — runs on orchestrator. Drives compute node via SSH.
# ---------------------------------------------------------------------------
rancher_install() {
    local chart_version="$(cfg versions.rancher_backup_chart 7.0.0)"
    local resourceset_file="${BACKUPS_ROOT_DIR}/manifests/rancher-backup-resourceset.yaml"
    local schedule_file="${BACKUPS_ROOT_DIR}/manifests/rancher-backup-schedule.yaml"

    log_info "Pre-flight: validating ResourceSet GVKs against live cluster..."
    rancher_validate_resourceset || log_warn "ResourceSet has unknown GVKs — see warnings above. Proceeding."

    log_info "Pushing manifests to compute node..."
    ssh_run "compute" "install -d -m 0750 /tmp/openg2p-rancher-backup"
    ssh_push "compute" "$resourceset_file" "/tmp/openg2p-rancher-backup/resourceset.yaml"
    ssh_push "compute" "$schedule_file"    "/tmp/openg2p-rancher-backup/schedule.yaml"

    # Install operator + create the PVC (PVC backed by NFS, bound by NFS-CSI
    # default StorageClass). Encryption Secret holds the at-rest key for the
    # tarball. We reuse the restic passphrase here (single key custody point).
    local restic_pass_file
    restic_pass_file="$(ensure_passphrase_file restic_passphrase_file restic false)"
    local restic_pass; restic_pass="$(< "$restic_pass_file")"

    log_info "Installing rancher-backup operator (chart ${chart_version}) on compute..."
    ssh_run "compute" "set -euo pipefail
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        export PATH=\$PATH:/var/lib/rancher/rke2/bin

        kubectl create namespace ${RANCHER_BACKUP_NS} --dry-run=client -o yaml | kubectl apply -f -

        # Encryption Secret — the operator uses an aes-cbc/gcm key to encrypt
        # the tarball. Format per upstream docs: a single keys field with
        # base64-encoded 32-byte key.
        keyb64=\$(printf '%s' '${restic_pass}' | sha256sum | awk '{print \$1}' | xxd -r -p | base64 -w0)
        cat <<EOC | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${RANCHER_BACKUP_ENC_SECRET}
  namespace: ${RANCHER_BACKUP_NS}
type: Opaque
data:
  encryption-provider-config.yaml: |-
\$(echo -n \"apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: openg2p
              secret: \${keyb64}
      - identity: {}\" | base64 -w0 | sed 's/^/    /')
EOC

        # PVC — uses default StorageClass (nfs-csi from the production install).
        cat <<EOC | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${RANCHER_BACKUP_PVC}
  namespace: ${RANCHER_BACKUP_NS}
spec:
  accessModes: [\"ReadWriteOnce\"]
  resources:
    requests:
      storage: 50Gi
EOC

        # Helm chart install — assumes the cluster has the rancher-charts repo
        # already added by the production install (it does, for Rancher itself).
        helm repo update >/dev/null 2>&1 || true
        helm upgrade --install rancher-backup-crd rancher-charts/rancher-backup-crd \
            --namespace ${RANCHER_BACKUP_NS} --version ${chart_version} --wait
        helm upgrade --install rancher-backup rancher-charts/rancher-backup \
            --namespace ${RANCHER_BACKUP_NS} --version ${chart_version} --wait

        kubectl apply -f /tmp/openg2p-rancher-backup/resourceset.yaml
        kubectl apply -f /tmp/openg2p-rancher-backup/schedule.yaml"

    log_success "rancher-backup operator + ResourceSet + nightly Schedule installed."
}

# ---------------------------------------------------------------------------
# rancher_validate_resourceset — list api-resources, warn on unknown GVKs.
# ---------------------------------------------------------------------------
rancher_validate_resourceset() {
    local known
    known=$(ssh_run "compute" "kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml api-resources --no-headers 2>/dev/null | awk '{print \$NF}' | sort -u" 2>/dev/null) || {
        log_warn "Could not query api-resources from compute — skipping validation."
        return 0
    }

    local groups; mapfile -t groups < <(grep -E '^\s+- apiVersion:' "${BACKUPS_ROOT_DIR}/manifests/rancher-backup-resourceset.yaml" | sed -E 's/.*"([^"]+)".*/\1/' | awk -F/ '{print $1}' | sort -u)
    local unknown=0
    for g in "${groups[@]}"; do
        [[ -z "$g" ]] && continue
        # 'v1' (core) is always present; skip.
        [[ "$g" == "v1" ]] && continue
        if ! grep -qx "$g" <<<"$known"; then
            log_warn "ResourceSet references unknown API group on this cluster: ${g}"
            unknown=$((unknown + 1))
        fi
    done
    (( unknown > 0 )) && return 1 || return 0
}

# ---------------------------------------------------------------------------
# rancher_run — trigger an on-demand Backup CR (the schedule already runs
# nightly; this is for ad-hoc/before-upgrade backups).
# ---------------------------------------------------------------------------
rancher_run() {
    local started; started="$(ts_utc)"
    local rc=0

    local backup_name="openg2p-ondemand-$(date -u +%Y%m%d%H%M%S)"
    log_info "Triggering on-demand Backup: ${backup_name}"

    ssh_run "compute" "set -euo pipefail
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        cat <<EOC | kubectl apply -f -
apiVersion: resources.cattle.io/v1
kind: Backup
metadata:
  name: ${backup_name}
spec:
  resourceSetName: openg2p-resource-set
  encryptionConfigSecretName: ${RANCHER_BACKUP_ENC_SECRET}
  storageLocation:
    persistentVolumeClaim:
      claimName: ${RANCHER_BACKUP_PVC}
EOC
        # Wait up to 10 min for completion.
        for i in \$(seq 1 60); do
            phase=\$(kubectl get backup.resources.cattle.io ${backup_name} -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null)
            [[ \$phase == 'True' ]] && exit 0
            sleep 10
        done
        echo 'rancher-backup did not become Ready in 10 minutes' >&2
        kubectl describe backup.resources.cattle.io ${backup_name} >&2
        exit 1" || rc=$?

    local result="ok"; (( rc != 0 )) && result="fail"
    _status_write_component "rancher" "last_run" "$started" "$result" "$backup_name"
    return $rc
}

# ---------------------------------------------------------------------------
# rancher_verify — list backups + assert tarball integrity for the latest.
# ---------------------------------------------------------------------------
rancher_verify() {
    log_info "Verifying latest rancher-backup tarball..."
    ssh_run "compute" "set -euo pipefail
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        # Resolve the PVC mount on a worker node — tar -tzf via a debug pod.
        kubectl run rancher-backup-verify --rm -i --restart=Never \
            --image=busybox:1.36 \
            --overrides='{\"spec\":{\"containers\":[{\"name\":\"v\",\"image\":\"busybox:1.36\",\"stdin\":true,\"tty\":false,\"command\":[\"sh\",\"-c\",\"latest=\\\$(ls -1t /b/*.tar.gz 2>/dev/null | head -1); [ -n \\\"\\\$latest\\\" ] || { echo no-tarballs; exit 1; }; tar -tzf \\\$latest | head -20; echo OK\"],\"volumeMounts\":[{\"name\":\"b\",\"mountPath\":\"/b\"}]}],\"volumes\":[{\"name\":\"b\",\"persistentVolumeClaim\":{\"claimName\":\"${RANCHER_BACKUP_PVC}\"}}]}}' \
            --namespace=${RANCHER_BACKUP_NS}"
}

# ---------------------------------------------------------------------------
# rancher_list — show Backup CRs.
# ---------------------------------------------------------------------------
rancher_list() {
    ssh_run "compute" "kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
        get backup.resources.cattle.io -A"
}

# ---------------------------------------------------------------------------
# rancher_restore — apply a Restore CR pointing at a specific backup tarball.
# Args: <target='cluster'|namespace> <pit_unused> <dry_run>
# ---------------------------------------------------------------------------
rancher_restore() {
    local target="${1:-cluster}"
    local _pit="$2"
    local dry_run="$3"

    log_info "Discovering most recent Backup tarball..."
    local latest
    latest=$(ssh_run "compute" "kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
        get backup.resources.cattle.io -A -o jsonpath='{range .items[*]}{.status.filename}{\"\\n\"}{end}' \
        | sort | tail -1") || { log_error "Could not list backups" "" ""; return 1; }
    latest=$(echo "$latest" | tail -1)
    [[ -z "$latest" ]] && { log_error "No backup tarballs found" "" ""; return 1; }
    log_info "Latest tarball: ${latest}"

    if [[ "$dry_run" == "true" ]]; then
        log_info "[dry-run] would create Restore CR consuming ${latest}"
        return 0
    fi

    ssh_run "compute" "set -euo pipefail
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        cat <<EOC | kubectl apply -f -
apiVersion: resources.cattle.io/v1
kind: Restore
metadata:
  name: openg2p-restore-$(date -u +%Y%m%d%H%M%S)
spec:
  backupFilename: ${latest}
  encryptionConfigSecretName: ${RANCHER_BACKUP_ENC_SECRET}
  storageLocation:
    persistentVolumeClaim:
      claimName: ${RANCHER_BACKUP_PVC}
EOC"
    log_warn "Restore CR created. Watch progress:"
    log_warn "  kubectl get restore.resources.cattle.io -A -w"
}

# ---------------------------------------------------------------------------
# rancher_drill — verify tarball integrity only.
# ---------------------------------------------------------------------------
rancher_drill() {
    local started; started="$(ts_utc)"
    if rancher_verify; then
        _status_write_component "rancher" "last_drill" "$started" "ok" "tarball integrity"
        return 0
    else
        _status_write_component "rancher" "last_drill" "$started" "fail" "tarball integrity"
        return 1
    fi
}
