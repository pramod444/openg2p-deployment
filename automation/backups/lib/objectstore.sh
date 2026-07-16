#!/usr/bin/env bash
# =============================================================================
# OpenG2P Backup — object storage (MinIO/S3) via rclone + restic
# =============================================================================
# Reference: openg2p-backup-signoff (rclone RO mount + restic snapshot).
#
# Flow:
#   1. rclone mount remote:bucket → mount point (read-only, dir-cache warm)
#   2. restic backup that mount into backup_repo_root/objectstore-restic
#   3. forget/prune; leave mount up for subsequent runs (like signoff)
#
# Credentials on backup host:
#   /etc/openg2p-backup/rclone.conf              (mode 0600)
#   /etc/openg2p-backup/restic-objectstore.env   RESTIC_PASSWORD=...
# =============================================================================

set -euo pipefail

_objectstore_enabled() {
    local v
    v="$(cfg groups.objectstore false)"
    [[ "$v" == "true" || "$v" == "yes" || "$v" == "1" ]]
}

_objectstore_repo() {
    echo "$(cfg backup_repo_root /var/lib/openg2p-backup)/objectstore-restic"
}

_objectstore_mount() {
    echo "$(cfg objectstore.mount_point /mnt/openg2p-rclone)"
}

objectstore_install() {
    _objectstore_enabled || { log_info "groups.objectstore=false — skip install"; return 0; }
    log_info "=== Installing objectstore (rclone + restic) ==="

    run_on_backup "set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive
        if ! command -v rclone >/dev/null 2>&1; then
            curl -fsSL https://rclone.org/install.sh | bash
        fi
        if ! command -v restic >/dev/null 2>&1; then
            apt-get update -qq
            apt-get install -y -qq restic || true
        fi
        if ! command -v restic >/dev/null 2>&1; then
            ver=\$(curl -fsSL https://api.github.com/repos/restic/restic/releases/latest | jq -r .tag_name | sed 's/^v//')
            curl -fsSL \"https://github.com/restic/restic/releases/download/v\${ver}/restic_\${ver}_linux_amd64.bz2\" \\
                | bunzip2 > /usr/local/bin/restic
            chmod +x /usr/local/bin/restic
        fi
        install -d -m 0755 '$(_objectstore_mount)'
        install -d -m 0700 '$(_objectstore_repo)'
        install -d -m 0755 /etc/openg2p-backup
        apt-get install -y -qq fuse3 2>/dev/null || apt-get install -y -qq fuse || true
        grep -q '^user_allow_other' /etc/fuse.conf 2>/dev/null || echo 'user_allow_other' >> /etc/fuse.conf
    "

    local rclone_src
    rclone_src="$(cfg objectstore.rclone_conf "")"
    rclone_src="${rclone_src/#\~/$HOME}"
    if [[ -n "$rclone_src" && -f "$rclone_src" ]]; then
        push_file_as_root "backup" "$rclone_src" "/etc/openg2p-backup/rclone.conf" 0600
    else
        log_warn "objectstore.rclone_conf not set or missing — place /etc/openg2p-backup/rclone.conf manually"
    fi

    local pw_file
    pw_file="$(cfg objectstore.restic_password_file "")"
    pw_file="${pw_file/#\~/$HOME}"
    if [[ -n "$pw_file" && -f "$pw_file" ]]; then
        # Expect RESTIC_PASSWORD=... line; if file is bare passphrase, wrap it.
        local stage
        stage=$(mktemp -t openg2p-os-pass.XXXXXX)
        if grep -q '^RESTIC_PASSWORD=' "$pw_file" 2>/dev/null; then
            cp "$pw_file" "$stage"
        else
            printf 'RESTIC_PASSWORD=%s\n' "$(tr -d '\n' < "$pw_file")" > "$stage"
        fi
        push_file_as_root "backup" "$stage" "/etc/openg2p-backup/restic-objectstore.env" 0600
        rm -f "$stage"
    else
        log_warn "objectstore.restic_password_file missing — create /etc/openg2p-backup/restic-objectstore.env"
    fi

    run_on_backup "set -euo pipefail
        set -a; [[ -f /etc/openg2p-backup/restic-objectstore.env ]] && source /etc/openg2p-backup/restic-objectstore.env; set +a
        : \"\${RESTIC_PASSWORD:?RESTIC_PASSWORD required}\"
        export RESTIC_REPOSITORY='$(_objectstore_repo)'
        if ! restic snapshots >/dev/null 2>&1; then
            restic init
        fi
        restic snapshots || true
    "
    log_info "=== objectstore install done ==="
}

objectstore_run() {
    _objectstore_enabled || { log_info "groups.objectstore=false — skip run"; return 0; }
    log_info "=== objectstore backup run ==="
    local remote bucket mount tag keep_daily keep_weekly
    remote="$(cfg objectstore.rclone_remote minio)"
    bucket="$(cfg objectstore.bucket "")"
    mount="$(_objectstore_mount)"
    tag="$(cfg objectstore.restic_tag openg2p-objectstore)"
    keep_daily="$(cfg objectstore.keep_daily "$(cfg retention.keep_daily 7)")"
    keep_weekly="$(cfg objectstore.keep_weekly "$(cfg retention.keep_weekly 4)")"

    local result=fail
    if run_on_backup "set -euo pipefail
        set -a; source /etc/openg2p-backup/restic-objectstore.env; set +a
        export RCLONE_CONFIG=/etc/openg2p-backup/rclone.conf
        export RESTIC_REPOSITORY='$(_objectstore_repo)'
        export HOME=/root
        : \"\${RESTIC_PASSWORD:?}\"
        mount='${mount}'
        src='${remote}:${bucket}'
        install -d -m 0755 \"\$mount\"
        if ! mountpoint -q \"\$mount\"; then
            rclone mount \"\$src\" \"\$mount\" \\
                --config \"\$RCLONE_CONFIG\" \\
                --read-only \\
                --vfs-cache-mode off \\
                --dir-cache-time 96h \\
                --attr-timeout 5m \\
                --daemon \\
                --daemon-timeout 0 \\
                --log-file /var/log/openg2p-rclone-mount.log \\
                --log-level NOTICE
            for i in \$(seq 1 60); do
                mountpoint -q \"\$mount\" && break
                sleep 2
            done
        fi
        mountpoint -q \"\$mount\" || { echo 'rclone mount failed' >&2; exit 1; }
        # Warm dir cache (flat bucket layouts can stall restic readdir)
        ls -f \"\$mount\" >/dev/null 2>&1 || true
        restic backup \"\$mount\" --tag '${tag}' --one-file-system
        restic forget --tag '${tag}' --keep-daily ${keep_daily} --keep-weekly ${keep_weekly} --prune
    "; then
        result=ok
    fi

    local ts
    ts="$(ts_utc 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
    _status_write_component "objectstore" "last_run" "$ts" "$result" ""
    if [[ "$result" != "ok" ]]; then
        declare -F notify_failure >/dev/null 2>&1 && \
            notify_failure "objectstore" "rclone+restic backup failed" || true
        return 1
    fi
    log_info "=== objectstore backup ok ==="
}

objectstore_verify() {
    _objectstore_enabled || return 0
    log_info "=== objectstore verify ==="
    run_on_backup "set -euo pipefail
        set -a; source /etc/openg2p-backup/restic-objectstore.env; set +a
        export RESTIC_REPOSITORY='$(_objectstore_repo)'
        restic snapshots --tag '$(cfg objectstore.restic_tag openg2p-objectstore)' --latest 1
        restic check --read-data-subset=1%
    "
}

objectstore_list() {
    _objectstore_enabled || { echo "objectstore disabled"; return 0; }
    run_on_backup "set -euo pipefail
        set -a; source /etc/openg2p-backup/restic-objectstore.env; set +a
        export RESTIC_REPOSITORY='$(_objectstore_repo)'
        restic snapshots --tag '$(cfg objectstore.restic_tag openg2p-objectstore)'
    "
}

objectstore_restore() {
    _objectstore_enabled || { log_error "objectstore disabled"; return 1; }
    local snapshot="${1:-latest}" dest="${2:-}"
    [[ -n "$dest" ]] || dest="$(cfg backup_repo_root /var/lib/openg2p-backup)/restore/objectstore"
    log_info "Restoring objectstore snapshot ${snapshot} → ${dest}"
    run_on_backup "set -euo pipefail
        set -a; source /etc/openg2p-backup/restic-objectstore.env; set +a
        export RESTIC_REPOSITORY='$(_objectstore_repo)'
        install -d -m 0755 '${dest}'
        restic restore '${snapshot}' --target '${dest}' --tag '$(cfg objectstore.restic_tag openg2p-objectstore)'
    "
}

objectstore_drill() {
    _objectstore_enabled || return 0
    log_info "=== objectstore restore drill ==="
    local dest result=fail
    dest="$(cfg backup_repo_root /var/lib/openg2p-backup)/restore/objectstore-drill-$$"
    if objectstore_restore latest "$dest"; then
        if run_on_backup "set -euo pipefail
            [[ -n \$(find '${dest}' -type f 2>/dev/null | head -1) ]]
            rm -rf '${dest}'
        "; then
            result=ok
        fi
    fi
    local ts
    ts="$(ts_utc 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)"
    _status_write_component "objectstore" "last_drill" "$ts" "$result" ""
    [[ "$result" == "ok" ]]
}
