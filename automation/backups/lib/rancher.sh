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
# Cadence is owned by the in-cluster Schedule CR (manifests/rancher-backup-
# schedule.yaml). The cron entry on the backup host is NOT used for nightly
# backups — that would double-trigger. `rancher_run` is for ad-hoc/before-
# upgrade invocation by the operator from the laptop.
#
# Upstream:
#   https://ranchermanager.docs.rancher.com/integrations-in-rancher/backup-restore-and-disaster-recovery
#   https://github.com/rancher/backup-restore-operator
# =============================================================================

set -euo pipefail

RANCHER_BACKUP_NS="cattle-resources-system"
RANCHER_BACKUP_RELEASE="rancher-backup"
RANCHER_BACKUP_ENC_SECRET="openg2p-backup-encryption"
RANCHER_CHARTS_REPO_URL="https://charts.rancher.io/"
# Stable name for BOTH the static NFS PersistentVolume and the operator's PVC.
RANCHER_BACKUP_PV="openg2p-rancher-backup-store"

# The backup-restore-operator stores tarballs to EITHER an S3 bucket OR a PVC
# mounted into the operator pod at /var/lib/backups (chart persistence.*). It
# has NO per-Backup "persistentVolumeClaim" storageLocation — Backup/Restore CRs
# simply OMIT storageLocation to use the operator's mounted PVC.
#
# IMPORTANT: with DYNAMIC persistence the chart names its PVC "<release>-
# <revision>" (see backupRestore.pvcName in the chart), so EVERY `helm upgrade`
# provisions a fresh, empty PVC, remounts it, and strands prior backups on the
# old volume. To keep a single, stable backup location we instead provision a
# STATIC NFS PV and bind the chart's PVC to it via persistence.volumeName (which
# also pins the PVC name), with persistence.storageClass="-" to turn OFF dynamic
# provisioning. The PVC still carries app.kubernetes.io/instance=<release>, so
# verify/restore resolve it by that label.

# ---------------------------------------------------------------------------
# rancher_install — runs on orchestrator (laptop). Drives compute via SSH.
# ---------------------------------------------------------------------------
rancher_install() {
    # rancher-charts publishes rancher-backup with the Rancher chart-version
    # scheme <chartVersion>+up<appVersion> — there is NO plain "7.0.0" chart, so
    # helm --version must be given a real chart version (e.g. 107.1.5+up8.1.5),
    # NOT the operator app version. The pinned default targets Rancher 2.12.x /
    # k8s 1.31–1.33; override per-cluster via versions.rancher_backup_chart.
    local chart_version="$(cfg versions.rancher_backup_chart 107.1.5+up8.1.5)"
    local resourceset_file="${BACKUPS_ROOT_DIR}/manifests/rancher-backup-resourceset.yaml"
    local schedule_file="${BACKUPS_ROOT_DIR}/manifests/rancher-backup-schedule.yaml"
    # Operator-mounted backup PVC: bound to a STATIC NFS PV (stable name, no
    # per-revision rotation). We read the NFS server/share from the cluster's
    # existing StorageClass so the backup volume lives on the same restic-tracked
    # NFS export.
    local pvc_storage_class="$(cfg rancher.pvc_storage_class nfs-csi)"
    local pvc_size="$(cfg rancher.pvc_size 50Gi)"

    log_info "Pre-flight: validating ResourceSet GVKs against live cluster..."
    rancher_validate_resourceset || log_warn "ResourceSet has unknown GVKs — see warnings above. Proceeding."

    # Build the encryption Secret YAML locally — far less fragile than
    # building it through 3 layers of bash heredoc escaping on the remote.
    local restic_pass_file
    restic_pass_file="$(ensure_passphrase_file restic_passphrase_file restic false)"
    local restic_pass; restic_pass="$(< "$restic_pass_file")"

    # Derive a 32-byte AES key from the restic passphrase (sha256 → 32 bytes).
    local key_b64
    key_b64=$(printf '%s' "$restic_pass" | openssl dgst -sha256 -binary 2>/dev/null | base64 | tr -d '\n')

    # The Secret holds an EncryptionConfiguration document, base64'd into the
    # data field (per upstream operator docs).
    local enc_doc enc_doc_b64
    enc_doc=$(cat <<EOF
apiVersion: apiserver.config.k8s.io/v1
kind: EncryptionConfiguration
resources:
  - resources:
      - secrets
    providers:
      - aescbc:
          keys:
            - name: openg2p
              secret: ${key_b64}
      - identity: {}
EOF
)
    enc_doc_b64=$(printf '%s' "$enc_doc" | base64 | tr -d '\n')

    # Stage all manifests in a tmpdir, then push as one rsync.
    local stage; stage=$(mktemp -d -t openg2p-rancher-stage.XXXXXX)
    trap "rm -rf '$stage'" RETURN

    cp "$resourceset_file" "$stage/resourceset.yaml"
    cp "$schedule_file"    "$stage/schedule.yaml"

    cat > "$stage/encryption-secret.yaml" <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${RANCHER_BACKUP_ENC_SECRET}
  namespace: ${RANCHER_BACKUP_NS}
type: Opaque
data:
  encryption-provider-config.yaml: ${enc_doc_b64}
EOF

    cat > "$stage/namespace.yaml" <<EOF
apiVersion: v1
kind: Namespace
metadata:
  name: ${RANCHER_BACKUP_NS}
EOF

    log_info "Pushing manifests to compute node..."
    # Don't pre-create the dir via sudo — ssh_push makes it as the login user
    # and then chmods it; a root-owned dir would make that chmod fail. kubectl
    # apply (run via sudo below) can still read login-user-owned files.
    ssh_push "compute" "${stage}/" "/tmp/openg2p-rancher-backup/"

    # Determine the NFS server + base share from the cluster StorageClass so the
    # static backup PV lives on the same export the nfs restic job already tracks.
    log_info "Reading NFS server/share from StorageClass '${pvc_storage_class}'..."
    local nfs_info nfs_server nfs_share backup_path
    nfs_info=$(ssh_run "compute" "set -euo pipefail
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        s=\$(kubectl get sc ${pvc_storage_class} -o jsonpath='{.parameters.server}' 2>/dev/null || true)
        p=\$(kubectl get sc ${pvc_storage_class} -o jsonpath='{.parameters.share}' 2>/dev/null || true)
        echo \"\${s}|\${p}\"" | tail -1)
    nfs_server="${nfs_info%%|*}"
    nfs_share="${nfs_info#*|}"
    if [[ -z "$nfs_server" || -z "$nfs_share" ]]; then
        log_error "Could not read NFS server/share from StorageClass '${pvc_storage_class}'" \
                  "The static rancher-backup PV needs a concrete NFS server + path" \
                  "kubectl get sc ${pvc_storage_class} -o yaml"
        return 1
    fi
    backup_path="${nfs_share%/}/rancher-backup"
    log_info "rancher-backup will persist to ${nfs_server}:${backup_path}"

    # World-writable so the operator pod can write regardless of its runAsUser.
    log_info "Ensuring backup directory exists on storage node..."
    ssh_run "storage" "install -d -m 0777 '${backup_path}'"

    log_info "Installing rancher-backup operator (chart ${chart_version}) on compute..."
    ssh_run "compute" "set -euo pipefail
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        export PATH=\$PATH:/var/lib/rancher/rke2/bin

        # Ensure the rancher-charts repo is added (production install adds
        # rancher-stable for Rancher itself, not necessarily rancher-charts).
        if ! helm repo list 2>/dev/null | awk '{print \$1}' | grep -qx 'rancher-charts'; then
            helm repo add rancher-charts ${RANCHER_CHARTS_REPO_URL}
        fi
        helm repo update rancher-charts >/dev/null 2>&1 || helm repo update >/dev/null 2>&1 || true

        kubectl apply -f /tmp/openg2p-rancher-backup/namespace.yaml
        kubectl apply -f /tmp/openg2p-rancher-backup/encryption-secret.yaml

        # Static NFS PV with a STABLE name. The chart binds its PVC to this via
        # persistence.volumeName, so the PVC name — and thus the on-disk backup
        # location — never rotates across helm upgrades.
        cat <<EOP | kubectl apply -f -
apiVersion: v1
kind: PersistentVolume
metadata:
  name: ${RANCHER_BACKUP_PV}
  labels:
    app.kubernetes.io/managed-by: openg2p-backup
spec:
  capacity:
    storage: ${pvc_size}
  accessModes:
    - ReadWriteOnce
  persistentVolumeReclaimPolicy: Retain
  storageClassName: \"\"
  nfs:
    server: ${nfs_server}
    path: ${backup_path}
EOP

        helm upgrade --install rancher-backup-crd rancher-charts/rancher-backup-crd \
            --namespace ${RANCHER_BACKUP_NS} --version ${chart_version} --wait
        # persistence.enabled + volumeName binds the operator PVC to our static
        # PV (stable name); storageClass='-' disables dynamic provisioning so the
        # chart does NOT create a per-revision '<release>-<revision>' PVC. Backup
        # CRs omit storageLocation and thus write to /var/lib/backups → our PV.
        # (Do NOT also set s3.enabled — the chart fails if both are configured.)
        helm upgrade --install rancher-backup rancher-charts/rancher-backup \
            --namespace ${RANCHER_BACKUP_NS} --version ${chart_version} \
            --set persistence.enabled=true \
            --set persistence.storageClass=- \
            --set persistence.volumeName=${RANCHER_BACKUP_PV} \
            --set persistence.size=${pvc_size} \
            --wait

        kubectl apply -f /tmp/openg2p-rancher-backup/resourceset.yaml
        kubectl apply -f /tmp/openg2p-rancher-backup/schedule.yaml"

    log_success "rancher-backup operator + ResourceSet + nightly Schedule installed."
    log_info "Nightly cadence is driven by the in-cluster Schedule CR; the"
    log_info "backup-host cron file deliberately has NO rancher entry to avoid"
    log_info "double-triggering. Use 'openg2p-backup.sh run --component rancher'"
    log_info "for ad-hoc backups (e.g. pre-upgrade)."
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
# rancher_run — trigger an on-demand Backup CR. ONLY for operator-initiated
# ad-hoc backups (pre-upgrade snapshots, etc.). Nightly cadence is owned by
# the in-cluster Schedule CR — this is NOT called from cron.
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
EOC
        # Wait up to 10 min. The operator reports success/failure on the Ready
        # condition (status True/False + message). Break early on False rather
        # than blocking the full window, and always surface the operator's own
        # message + pod logs so the real cause isn't swallowed by the caller.
        ready='' msg=''
        for i in \$(seq 1 60); do
            ready=\$(kubectl get backup.resources.cattle.io ${backup_name} \
                -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null || true)
            msg=\$(kubectl get backup.resources.cattle.io ${backup_name} \
                -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].message}' 2>/dev/null || true)
            [[ \$ready == 'True' ]] && { echo \"rancher-backup Ready: \${msg:-ok}\"; exit 0; }
            [[ \$ready == 'False' ]] && break
            sleep 10
        done
        echo \"rancher-backup not Ready (status='\${ready:-<none>}'): \${msg:-<no message>}\" >&2
        echo '--- backup describe ---' >&2
        kubectl describe backup.resources.cattle.io ${backup_name} >&2 || true
        echo '--- operator logs (tail 60) ---' >&2
        kubectl -n ${RANCHER_BACKUP_NS} logs -l app.kubernetes.io/instance=${RANCHER_BACKUP_RELEASE} --tail=60 >&2 || true
        exit 1" || rc=$?

    # Authoritative success check. The remote login-shell wrapper can, on some
    # nodes, corrupt the SSH exit status with environmental noise (no-TTY curses
    # errors in the profile) even after the backup itself succeeded. So when the
    # transport reports failure, confirm against the operator's own Ready
    # condition before declaring the run failed. The value on stdout is what we
    # trust here, not this probe's own exit code.
    if (( rc != 0 )); then
        local ready
        ready="$(ssh_run "compute" "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
            kubectl get backup.resources.cattle.io ${backup_name} \
                -o jsonpath='{.status.conditions[?(@.type==\"Ready\")].status}' 2>/dev/null" \
            | tail -1)"
        if [[ "$ready" == "True" ]]; then
            log_info "Backup ${backup_name} is Ready (recovered from a non-fatal SSH exit code)."
            rc=0
        fi
    fi

    local result="ok"; (( rc != 0 )) && result="fail"
    _status_write_component "rancher" "last_run" "$started" "$result" "$backup_name"
    return $rc
}

# ---------------------------------------------------------------------------
# rancher_verify — confirm the latest tarball exists, is non-zero, and is
# a readable gzip.
#
# Approach: resolve the PVC's on-server NFS path from kubectl, then gzip -t
# the latest *.tar.gz over SSH to the storage node. Much simpler than spawning
# a debug pod with `kubectl run --overrides`.
# ---------------------------------------------------------------------------
rancher_verify() {
    log_info "Verifying latest rancher-backup tarball..."

    # Resolve the export ROOT (the on-server NFS path holding the tarballs).
    # Preferred: the stable static PV we provision (deterministic, immune to
    # leftover per-revision PVCs). Fallback: resolve via the operator's PVC label
    # for older dynamic/CSI layouts — nfs-csi PVs keep the base share in
    # .spec.csi.volumeAttributes.share; native NFS PVs use .spec.nfs.path.
    local root
    root=$(ssh_run "compute" "set -euo pipefail
        export KUBECONFIG=/etc/rancher/rke2/rke2.yaml
        p=\$(kubectl get pv ${RANCHER_BACKUP_PV} -o jsonpath='{.spec.nfs.path}' 2>/dev/null || true)
        if [[ -n \$p ]]; then echo \"\${p%/}\"; exit 0; fi
        pvc=\$(kubectl get pvc -n ${RANCHER_BACKUP_NS} \
            -l app.kubernetes.io/instance=${RANCHER_BACKUP_RELEASE} \
            -o jsonpath='{.items[0].metadata.name}')
        [[ -z \$pvc ]] && { echo 'no rancher-backup PVC found' >&2; exit 1; }
        vol=\$(kubectl get pvc -n ${RANCHER_BACKUP_NS} \$pvc -o jsonpath='{.spec.volumeName}')
        [[ -z \$vol ]] && { echo 'rancher-backup PVC not bound yet' >&2; exit 1; }
        share=\$(kubectl get pv \$vol -o jsonpath='{.spec.csi.volumeAttributes.share}')
        if [[ -n \$share ]]; then echo \"\${share%/}\"; else kubectl get pv \$vol -o jsonpath='{.spec.nfs.path}'; fi" \
        | tail -1)

    if [[ -z "$root" ]]; then
        log_error "Could not resolve the NFS export root for the rancher-backup PVC" \
                  "PVC may not be bound yet, or the PV's StorageClass isn't NFS-based" \
                  "kubectl -n ${RANCHER_BACKUP_NS} get pvc -l app.kubernetes.io/instance=${RANCHER_BACKUP_RELEASE} -o yaml"
        return 1
    fi
    log_info "rancher-backup NFS export root: ${root}"

    # The storage node sees the export on its local filesystem at the same path.
    # Glob both native layout (tarballs directly under the root) and CSI layout
    # (tarballs under per-PVC subdirs named <ns>-<release>-*). nullglob so empty
    # patterns vanish; pick newest by mtime without a pipe (avoids pipefail
    # aborting on a no-match glob and swallowing the diagnostic).
    ssh_run "storage" "set -euo pipefail
        shopt -s nullglob
        files=(${root}/*.tar.gz ${root}/${RANCHER_BACKUP_NS}-${RANCHER_BACKUP_RELEASE}-*/*.tar.gz)
        if (( \${#files[@]} == 0 )); then
            echo 'No rancher-backup tarballs found under ${root}' >&2
            echo '--- entries under ${root} (for debugging) ---' >&2
            ls -la ${root}/ >&2 2>/dev/null || echo '(export path not present on storage node)' >&2
            exit 1
        fi
        latest=\"\${files[0]}\"
        for f in \"\${files[@]}\"; do [[ \$f -nt \$latest ]] && latest=\$f; done
        size=\$(stat -c %s \"\$latest\")
        if (( size < 100 )); then
            echo \"rancher tarball suspiciously small: \$size bytes (\$latest)\" >&2
            exit 1
        fi
        echo \"Latest: \$latest (\$size bytes)\"
        # rancher-backup tarballs are encrypted when encryptionConfig is set, so
        # 'tar -tzf' won't list contents; confirm gzip integrity with 'gzip -t'.
        gzip -t \"\$latest\" && echo 'gzip integrity OK'"
}

# ---------------------------------------------------------------------------
# rancher_list — show Backup CRs.
# ---------------------------------------------------------------------------
rancher_list() {
    ssh_run "compute" "kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
        get backup.resources.cattle.io -A"
}

# ---------------------------------------------------------------------------
# rancher_restore — apply a Restore CR pointing at the most recent tarball.
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
  prune: false
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
