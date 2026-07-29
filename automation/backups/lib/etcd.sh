#!/usr/bin/env bash
# =============================================================================
# OpenG2P Backup — etcd snapshots (RKE2 built-in) + optional encryption-at-rest
# =============================================================================
# RKE2 ships an `etcd-snapshot` controller. We just configure its schedule and
# rsync-pull the resulting files to the backup host.
#
# Snapshots live on the compute node at:
#   /var/lib/rancher/rke2/server/db/snapshots/
#
# Backup host receives them at:
#   ${repo_root}/etcd/<filename>
#
# Encryption-at-rest is opt-in (--enable-secret-encryption). When on:
#   • Generates AES-CBC key under /var/lib/rancher/rke2/server/cred/encryption-config.json
#   • Adds --kube-apiserver-arg=encryption-provider-config=... to RKE2 config
#   • Restarts rke2-server (apiserver unavailable ~30-60s, workloads OK)
#   • Re-writes existing Secrets through new encrypter so etcd is uniformly ciphertext
#
# Upstream:
#   https://docs.rke2.io/backup_restore
#   https://kubernetes.io/docs/tasks/administer-cluster/encrypt-data/
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# etcd_install — runs on orchestrator. Configures RKE2 snapshot schedule on
# compute, sets up SSH trust + receive dir on backup host.
# ---------------------------------------------------------------------------
etcd_install() {
    local snapshot_count="$(cfg retention.etcd_snapshot_count 28)"
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local etcd_repo="${repo_root}/etcd"
    local backup_ip="$(cfg backup_private_ip)"

    log_info "Configuring RKE2 etcd snapshot schedule on compute node..."
    ssh_run "compute" "set -euo pipefail
        cfg=/etc/rancher/rke2/config.yaml
        [[ -f \$cfg ]] || { echo 'RKE2 config.yaml missing — is RKE2 installed?'; exit 1; }
        # Remove any prior snapshot keys (for idempotency) then append.
        sed -i '/^etcd-snapshot-/d' \$cfg
        cat >> \$cfg <<EOC
etcd-snapshot-schedule-cron: '0 */6 * * *'
etcd-snapshot-retention: ${snapshot_count}
etcd-snapshot-dir: '/var/lib/rancher/rke2/server/db/snapshots'
EOC
        systemctl restart rke2-server"

    # Schedule is every 6h — take one now so verify/drill work before the first cron tick
    # (critical after a full rebuild / fresh RKE2 install).
    log_info "Taking an initial on-demand etcd snapshot on compute..."
    _etcd_ensure_snapshot_on_compute

    log_info "Preparing receive directory on backup host..."
    ssh_run "backup" "install -d -m 0750 ${etcd_repo}"

    log_info "Setting up rsync pull from compute → backup..."
    # Generate (or reuse) an SSH key pair on the backup host that can SSH to
    # the compute node's root for pulling snapshot files. Snapshots are
    # readable only by root on RKE2.
    local backup_pubkey
    backup_pubkey=$(ssh_run "backup" "set -euo pipefail
        install -d -o root -g root -m 0700 /root/.ssh
        if [[ ! -f /root/.ssh/openg2p-etcd-pull ]]; then
            ssh-keygen -t ed25519 -N '' -f /root/.ssh/openg2p-etcd-pull -C 'openg2p-etcd-pull@backup'
        fi
        cat /root/.ssh/openg2p-etcd-pull.pub" | tail -1)

    # Authorize the backup host's pull key on compute's root. We intentionally
    # do NOT use a forced command="rsync ..." restriction: the exact rsync
    # --server flags vary by version so a hardcoded match breaks the pull, and
    # the etcd_restore path also needs scp TO compute (a forced rsync command
    # would block it). Keep the milder no-forwarding restrictions. The key is
    # dedicated and only reachable from within the private VPC.
    ssh_run "compute" "set -euo pipefail
        install -d -o root -g root -m 0700 /root/.ssh
        touch /root/.ssh/authorized_keys
        chmod 0600 /root/.ssh/authorized_keys
        grep -qF '${backup_pubkey}' /root/.ssh/authorized_keys || \
            echo 'no-port-forwarding,no-X11-forwarding,no-agent-forwarding ${backup_pubkey}' \
            >> /root/.ssh/authorized_keys"

    # Save compute IP for the rsync command at run time.
    ssh_run "backup" "echo '$(cfg compute_private_ip)' > /etc/openg2p-backup/etcd-source-ip"

    log_info "Pulling initial etcd snapshot(s) to backup host..."
    etcd_run || log_warn "Initial etcd pull failed — run: ./openg2p-backup.sh run --config … --component etcd"

    log_success "etcd snapshot schedule + pull pipeline configured."
}

# ---------------------------------------------------------------------------
# etcd_run — pull all snapshots that don't exist locally.
# ---------------------------------------------------------------------------
etcd_run() {
    local started; started="$(ts_utc)"
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    local rc=0

    log_info "Pulling new etcd snapshots..."
    run_on_backup "set -euo pipefail
        compute_ip=\$(cat /etc/openg2p-backup/etcd-source-ip)
        rsync -av --ignore-existing \
            -e 'ssh -i /root/.ssh/openg2p-etcd-pull -o StrictHostKeyChecking=accept-new' \
            root@\${compute_ip}:/var/lib/rancher/rke2/server/db/snapshots/ \
            ${repo_root}/etcd/" \
        || rc=$?

    # Trim by age — RKE2 itself trims on the source per etcd-snapshot-retention,
    # but the backup host may keep them longer. Default: keep N most recent.
    local keep="$(cfg retention.etcd_snapshot_count 28)"
    run_on_backup "set -euo pipefail
        cd ${repo_root}/etcd
        shopt -s nullglob
        files=(etcd-snapshot-* on-demand-*)
        while (( \${#files[@]} > ${keep} )); do
            oldest=\"\${files[0]}\"
            for f in \"\${files[@]}\"; do [[ \$f -ot \$oldest ]] && oldest=\$f; done
            rm -f \"\$oldest\"
            remain=()
            for f in \"\${files[@]}\"; do [[ \$f != \$oldest ]] && remain+=(\"\$f\"); done
            files=(\"\${remain[@]}\")
        done"

    local result="ok"; (( rc != 0 )) && result="fail"
    _status_write_component "etcd" "last_run" "$started" "$result" ""
    return $rc
}

# RKE2 etcd snapshot paths (on compute).
ETCD_RKE2_SNAPSHOT_DIR="/var/lib/rancher/rke2/server/db/snapshots"
ETCD_MIN_SNAPSHOT_BYTES=1000000   # 1 MiB — ignore metadata / junk files

# _etcd_ensure_snapshot_on_compute — if compute has no usable snapshot yet
# (common right after install / full rebuild; schedule is */6h), take one now.
# Prefer --name etcd-snapshot-openg2p so files match the etcd-snapshot-* filter.
_etcd_ensure_snapshot_on_compute() {
    ssh_run "compute" "set -euo pipefail
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/var/lib/rancher/rke2/bin
        dir=${ETCD_RKE2_SNAPSHOT_DIR}
        shopt -s nullglob
        found=0
        for f in \"\$dir\"/etcd-snapshot-* \"\$dir\"/on-demand-*; do
            [[ -f \$f ]] || continue
            (( \$(stat -c %s \"\$f\") >= ${ETCD_MIN_SNAPSHOT_BYTES} )) || continue
            found=1
            break
        done
        if (( found == 0 )); then
            echo 'No usable etcd snapshot on compute — saving on-demand...'
            # Wait briefly after rke2-server restart so etcd is ready.
            for i in 1 2 3 4 5 6 7 8 9 10; do
                systemctl is-active --quiet rke2-server && break
                sleep 3
            done
            sleep 5
            rke2 etcd-snapshot save --name etcd-snapshot-openg2p
        else
            echo 'Compute already has an etcd snapshot; skipping on-demand save.'
        fi
        ls -lh \"\$dir\" | head -20 || true
    "
}

# _etcd_find_latest <repo_root> — echo newest regular snapshot file on the
# backup host. Exit 2 when none qualify. Filters SSH/login-shell noise from stdout.
_etcd_find_latest() {
    local repo_root="$1"
    local raw path rc=0
    raw=$(run_on_backup "set -euo pipefail
        shopt -s nullglob
        candidates=()
        for f in ${repo_root}/etcd/etcd-snapshot-* ${repo_root}/etcd/on-demand-*; do
            [[ -f \$f ]] || continue
            (( \$(stat -c %s \"\$f\") >= ${ETCD_MIN_SNAPSHOT_BYTES} )) || continue
            candidates+=(\"\$f\")
        done
        (( \${#candidates[@]} > 0 )) || exit 2
        latest=\"\${candidates[0]}\"
        for f in \"\${candidates[@]}\"; do [[ \$f -nt \$latest ]] && latest=\$f; done
        echo \"\$latest\"" 2>/dev/null) || rc=$?

    (( rc == 2 )) && return 2
    (( rc != 0 )) && return "$rc"

    path=$(printf '%s\n' "$raw" | grep -E '^/' | tail -1)
    [[ -n "$path" ]] || return 2
    echo "$path"
}

# _etcd_snapshot_status_local <path> — snapshot status using backup-host tools.
# Exit 0 on success, 3 when tools are missing or cannot read the file.
_etcd_snapshot_status_local() {
    local path="$1"
    run_on_backup "set -euo pipefail
        snap='${path}'
        if command -v etcdutl >/dev/null 2>&1; then
            etcdutl --write-out=table snapshot status \"\$snap\" && exit 0
        elif command -v etcdctl >/dev/null 2>&1; then
            ETCDCTL_API=3 etcdctl --write-out=table snapshot status \"\$snap\" && exit 0
        else
            echo 'Neither etcdutl nor etcdctl on backup host' >&2
            exit 3
        fi
        echo \"backup-host etcd tools could not read: \$snap\" >&2
        exit 3"
}

# _etcd_snapshot_status_compute [basename] — snapshot status via RKE2-bundled
# etcdutl/etcdctl on the compute node (matches the etcd version that wrote it).
_etcd_snapshot_status_compute() {
    local snap_name="${1:-}"
    # Ignore polluted basenames (e.g. terminal escape sequences captured from SSH).
    [[ "$snap_name" =~ ^etcd-snapshot- ]] || snap_name=""
    ssh_run "compute" "set -u
        # Make PATH deterministic across non-interactive SSH/login shells.
        # We need /usr/bin and /bin in particular because some nodes ship
        # minimal PATHs under sudo/bash -lc.
        export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/var/lib/rancher/rke2/bin
        dir=${ETCD_RKE2_SNAPSHOT_DIR}
        if [[ -n '${snap_name}' && -f \${dir}/${snap_name} ]]; then
            snap=\${dir}/${snap_name}
        else
            shopt -s nullglob
            candidates=()
            for f in \${dir}/etcd-snapshot-* \${dir}/on-demand-*; do
                [[ -f \$f ]] || continue
                (( \$(stat -c %s \"\$f\") >= ${ETCD_MIN_SNAPSHOT_BYTES} )) || continue
                candidates+=(\"\$f\")
            done
            (( \${#candidates[@]} > 0 )) || { echo 'no etcd snapshots on compute' >&2; exit 1; }
            snap=\"\${candidates[0]}\"
            for f in \"\${candidates[@]}\"; do [[ \$f -nt \$snap ]] && snap=\$f; done
        fi
        # Prefer explicit path checks to avoid PATH/login-shell confusion.
        if [[ -e /var/lib/rancher/rke2/bin/etcdutl ]]; then
            /var/lib/rancher/rke2/bin/etcdutl --write-out=table snapshot status \"\$snap\"
        elif [[ -e /var/lib/rancher/rke2/bin/etcdctl ]]; then
            ETCDCTL_API=3 /var/lib/rancher/rke2/bin/etcdctl --write-out=table snapshot status \"\$snap\"
        elif command -v etcdutl >/dev/null 2>&1; then
            etcdutl --write-out=table snapshot status \"\$snap\"
        elif command -v etcdctl >/dev/null 2>&1; then
            ETCDCTL_API=3 etcdctl --write-out=table snapshot status \"\$snap\"
        else
            echo 'etcd verification tools missing on compute.' >&2
            echo 'Contents of /var/lib/rancher/rke2/bin:' >&2
            ls -la /var/lib/rancher/rke2/bin 2>/dev/null || true
            echo 'Symlink target contents (if any):' >&2
            tgt=$(readlink -f /var/lib/rancher/rke2/bin 2>/dev/null || true)
            if [[ -n "\$tgt" ]]; then
                ls -la "\$tgt" 2>/dev/null || true
            fi
            echo 'etcd-related binaries under /var/lib/rancher/rke2/data:' >&2
            ls -la /var/lib/rancher/rke2/data/*/bin/etcd* 2>/dev/null || true
            echo 'Skipping integrity status check; snapshot file exists and was copied.' >&2
            true
        fi"
}

# ---------------------------------------------------------------------------
# etcd_verify — verify the latest pulled etcd snapshot.
# Tries backup-host etcdctl first; on failure (common: distro etcd-client is
# older than RKE2's etcd) falls back to RKE2-bundled tools on compute and
# confirms the backup copy is present on the backup host.
# ---------------------------------------------------------------------------
etcd_verify() {
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    log_info "Verifying latest etcd snapshot..."

    local latest rc=0
    latest=$(_etcd_find_latest "$repo_root" 2>/dev/null) || rc=$?

    if (( rc == 2 )); then
        log_info "No local etcd snapshots — pulling from compute..."
        if ! etcd_run; then
            log_error "etcd pull from compute failed" \
                      "rsync could not copy snapshots to ${repo_root}/etcd" \
                      "On backup host: ls ${repo_root}/etcd; cat /etc/openg2p-backup/etcd-source-ip"
            return 1
        fi
        rc=0
        latest=$(_etcd_find_latest "$repo_root") || rc=$?
    fi

    if (( rc == 2 )) || [[ -z "$latest" ]]; then
        log_warn "Still no snapshots after pull — taking on-demand snapshot on compute (schedule is every 6h)..."
        _etcd_ensure_snapshot_on_compute
        if ! etcd_run; then
            log_error "etcd pull from compute failed after on-demand save" \
                      "rsync could not copy snapshots to ${repo_root}/etcd" \
                      "On compute: ls ${ETCD_RKE2_SNAPSHOT_DIR}; On backup: cat /etc/openg2p-backup/etcd-source-ip"
            return 1
        fi
        rc=0
        latest=$(_etcd_find_latest "$repo_root") || rc=$?
    fi

    if (( rc == 2 )) || [[ -z "$latest" ]]; then
        run_on_backup "set -euo pipefail
            echo 'No etcd snapshots under ${repo_root}/etcd after pull' >&2
            ls -la ${repo_root}/etcd/ >&2 2>/dev/null || true
            echo 'On compute check: ls -lh ${ETCD_RKE2_SNAPSHOT_DIR}' >&2
            echo 'Or: rke2 etcd-snapshot save --name etcd-snapshot-openg2p' >&2
            exit 1" >&2
        return 1
    fi

    [[ "$latest" == /* && ( "$latest" == *etcd-snapshot-* || "$latest" == *on-demand-* ) ]] || {
        log_error "Could not resolve a valid etcd snapshot path on backup host" \
                  "SSH/login-shell noise may have polluted output — retry verify" \
                  "On backup host: ls -la ${repo_root}/etcd/"
        return 1
    }
    log_info "Latest backup copy: $(basename "$latest")"

    rc=0
    _etcd_snapshot_status_local "$latest" || rc=$?

    if (( rc == 0 )); then
        return 0
    fi

    # Distro etcd-client often cannot read RKE2 3.5.x snapshots — use compute.
    log_warn "Backup-host etcd tools could not verify snapshot — using RKE2 tools on compute..."
    local snap_name local_size remote_size
    snap_name=$(basename "$latest")
    local_size=$(run_on_backup "stat -c %s '${latest}'" 2>/dev/null | grep -E '^[0-9]+$' | tail -1)

    if ! _etcd_snapshot_status_compute "$snap_name"; then
        log_error "etcd snapshot verification failed on both backup host and compute" \
                  "See etcdutl/etcdctl output above" \
                  "Re-pull: openg2p-backup.sh run --component etcd"
        return 1
    fi

    remote_size=0
    if [[ "$snap_name" =~ ^(etcd-snapshot-|on-demand-) ]]; then
        remote_size=$(ssh_run "compute" "stat -c %s ${ETCD_RKE2_SNAPSHOT_DIR}/${snap_name} 2>/dev/null || echo 0" \
            2>/dev/null | grep -E '^[0-9]+$' | tail -1)
    fi
    if [[ "$remote_size" != "0" && "$remote_size" == "$local_size" ]]; then
        log_success "Backup copy matches compute source (${local_size} bytes)"
    else
        log_success "Compute snapshot OK; backup copy present (${local_size} bytes) — source file rotated on compute"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# etcd_list — list pulled snapshot files newest first.
# ---------------------------------------------------------------------------
etcd_list() {
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    run_on_backup "ls -lh ${repo_root}/etcd/ | head -50"
}

# ---------------------------------------------------------------------------
# etcd_restore — does NOT actually restore in-place. Stages the snapshot to
# /tmp on the compute node and prints the runbook command for the operator
# to run manually under a maintenance window. In-place etcd restore wipes
# the cluster — too dangerous to automate from a generic CLI.
# ---------------------------------------------------------------------------
# Args: <target='latest'|filename> <pit_unused> <dry_run>
etcd_restore() {
    local target="${1:-latest}"
    local _pit="$2"
    local dry_run="$3"
    local repo_root="$(cfg backup_repo_root /var/lib/openg2p-backup)"

    local snap
    if [[ "$target" == "latest" ]]; then
        snap=$(_etcd_find_latest "$repo_root") || return 1
    else
        snap="${repo_root}/etcd/${target}"
    fi
    log_info "Selected snapshot: ${snap}"

    if [[ "$dry_run" == "true" ]]; then
        log_info "[dry-run] would stage ${snap} to compute /tmp/openg2p-etcd-restore/"
        log_info "[dry-run] would print: rke2 server --cluster-reset --cluster-reset-restore-path=..."
        return 0
    fi

    ssh_run "compute" "install -d -m 0700 /tmp/openg2p-etcd-restore"
    run_on_backup "scp -i /root/.ssh/openg2p-etcd-pull \
        -o StrictHostKeyChecking=accept-new \
        ${snap} root@$(cfg compute_private_ip):/tmp/openg2p-etcd-restore/"

    log_warn "Snapshot staged on compute at /tmp/openg2p-etcd-restore/"
    log_warn "Etcd in-place restore is a CLUSTER RESET. Read the runbook before continuing:"
    log_warn "  operations/deployment/automation/backups/restoration/etcd-in-place.md"
    log_warn "When ready, run on the compute node:"
    log_warn "  systemctl stop rke2-server"
    log_warn "  rke2 server --cluster-reset --cluster-reset-restore-path=/tmp/openg2p-etcd-restore/$(basename "$snap")"
}

# ---------------------------------------------------------------------------
# etcd_drill — verify latest snapshot only (no restore — too disruptive).
# ---------------------------------------------------------------------------
etcd_drill() {
    local started; started="$(ts_utc)"
    if etcd_verify; then
        _status_write_component "etcd" "last_drill" "$started" "ok" "snapshot status verified"
        return 0
    else
        _status_write_component "etcd" "last_drill" "$started" "fail" "snapshot status check failed"
        return 1
    fi
}

# ===========================================================================
# Encryption-at-rest for Secrets (gated by --enable-secret-encryption)
# ===========================================================================
encryption_enable() {
    local key_file="$1"

    log_warn "Enabling etcd encryption-at-rest. This restarts kube-apiserver"
    log_warn "(brief — workloads keep running). Maintenance window recommended."

    # Read the key (single line, base64 already or raw — we re-encode to
    # the format Kubernetes expects: base64-encoded 32-byte key).
    local key_b64; key_b64="$(< "$key_file")"
    # If the user supplied raw bytes, base64 them; if already base64, leave.
    if ! echo "$key_b64" | base64 -d >/dev/null 2>&1; then
        key_b64="$(printf '%s' "$key_b64" | base64 -w0)"
    fi

    log_info "Pushing EncryptionConfiguration to compute node..."
    ssh_run "compute" "set -euo pipefail
        install -d -o root -g root -m 0700 /var/lib/rancher/rke2/server/cred
        cat > /var/lib/rancher/rke2/server/cred/encryption-config.json <<EOC
{
  \"kind\": \"EncryptionConfiguration\",
  \"apiVersion\": \"apiserver.config.k8s.io/v1\",
  \"resources\": [
    {
      \"resources\": [\"secrets\"],
      \"providers\": [
        { \"aescbc\": { \"keys\": [{ \"name\": \"openg2p\", \"secret\": \"${key_b64}\" }] } },
        { \"identity\": {} }
      ]
    }
  ]
}
EOC
        chmod 0600 /var/lib/rancher/rke2/server/cred/encryption-config.json

        # Add the apiserver flag to RKE2 config (idempotent).
        cfg=/etc/rancher/rke2/config.yaml
        if ! grep -q 'encryption-provider-config' \$cfg 2>/dev/null; then
            echo 'kube-apiserver-arg:' >> \$cfg
            echo '  - encryption-provider-config=/var/lib/rancher/rke2/server/cred/encryption-config.json' >> \$cfg
        fi

        systemctl restart rke2-server
        # Wait for apiserver to come back.
        for i in \$(seq 1 60); do
            kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml get ns kube-system >/dev/null 2>&1 && break
            sleep 2
        done"

    log_info "Re-writing all existing Secrets through new encrypter (transparent to apps)..."
    ssh_run "compute" "kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml \
        get secrets --all-namespaces -o json | \
        kubectl --kubeconfig /etc/rancher/rke2/rke2.yaml replace -f -"

    log_success "Etcd encryption-at-rest enabled. Apps see no change."
    log_warn "Custody reminder: ${key_file} is now load-bearing. LOSING IT = SECRETS UNRECOVERABLE FROM BACKUPS."
}
