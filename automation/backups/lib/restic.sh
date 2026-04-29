#!/usr/bin/env bash
# =============================================================================
# OpenG2P Backup — restic helpers
# =============================================================================
# All restic ops happen ON the backup host. The orchestrator wraps these via
# ssh_run "backup" "<function-call>" — we keep the functions self-contained
# so they can also be invoked directly (e.g. from cron on the backup host).
#
# Repos:
#   ${repo_root}/restic/nfs       — NFS data
#   ${repo_root}/restic/configs   — RP and compute filesystem state
#
# Each repo has its own passphrase from the same key file (restic.pass) —
# we don't split passphrases per repo because rotation is hard enough already.
# =============================================================================

set -euo pipefail

# These are expected to be in the environment when restic_* funcs run on the
# backup host. The orchestrator sets them via ssh_run -E or by sourcing
# /etc/openg2p-backup/env on the backup host.
: "${RESTIC_REPO_ROOT:=/var/lib/openg2p-backup/restic}"
: "${RESTIC_PASSWORD_FILE:=/etc/openg2p-backup/restic.pass}"

# ---------------------------------------------------------------------------
# Repo init — idempotent.
# ---------------------------------------------------------------------------
restic_repo_init() {
    local repo_name="$1"   # e.g. "nfs" or "configs"
    local repo_path="${RESTIC_REPO_ROOT}/${repo_name}"

    mkdir -p "$repo_path"

    if RESTIC_REPOSITORY="$repo_path" \
       RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
       restic cat config &>/dev/null; then
        echo "[restic] repo '${repo_name}' already initialised at ${repo_path}"
        return 0
    fi

    echo "[restic] initialising repo '${repo_name}' at ${repo_path}"
    RESTIC_REPOSITORY="$repo_path" \
    RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
    restic init
}

# ---------------------------------------------------------------------------
# Backup — local path → restic repo.
# ---------------------------------------------------------------------------
# Args: <repo_name> <path> [tag1 tag2 ...]
# Excludes are read from /etc/openg2p-backup/restic-${repo_name}.exclude if
# present (one pattern per line).
restic_backup_path() {
    local repo_name="$1"; shift
    local source_path="$1"; shift
    local tags=("$@")

    local repo_path="${RESTIC_REPO_ROOT}/${repo_name}"
    local exclude_file="/etc/openg2p-backup/restic-${repo_name}.exclude"

    local args=(
        --tag "openg2p"
        --tag "$(date -u +%Y-%m-%d)"
    )
    for t in "${tags[@]}"; do args+=(--tag "$t"); done
    [[ -f "$exclude_file" ]] && args+=(--exclude-file "$exclude_file")

    echo "[restic] backup → ${repo_name}: ${source_path}"
    RESTIC_REPOSITORY="$repo_path" \
    RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
    restic backup "$source_path" "${args[@]}"
}

# ---------------------------------------------------------------------------
# Backup from a stream (stdin) — used for SSH-tar-over-pipe of remote dirs.
# ---------------------------------------------------------------------------
# Args: <repo_name> <stdin_filename_label> [tag1 tag2 ...]
restic_backup_stdin() {
    local repo_name="$1"; shift
    local label="$1"; shift
    local tags=("$@")

    local repo_path="${RESTIC_REPO_ROOT}/${repo_name}"

    local args=(
        --stdin
        --stdin-filename "$label"
        --tag "openg2p"
        --tag "$(date -u +%Y-%m-%d)"
    )
    for t in "${tags[@]}"; do args+=(--tag "$t"); done

    echo "[restic] backup (stream) → ${repo_name}: ${label}"
    RESTIC_REPOSITORY="$repo_path" \
    RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
    restic backup "${args[@]}"
}

# ---------------------------------------------------------------------------
# Forget + prune per retention policy.
# Reads keep_daily/keep_weekly/keep_monthly from env (set by orchestrator
# from backup-config.yaml).
# ---------------------------------------------------------------------------
restic_forget_prune() {
    local repo_name="$1"
    local repo_path="${RESTIC_REPO_ROOT}/${repo_name}"

    local keep_daily="${KEEP_DAILY:-7}"
    local keep_weekly="${KEEP_WEEKLY:-4}"
    local keep_monthly="${KEEP_MONTHLY:-6}"

    echo "[restic] forget+prune ${repo_name} (d=${keep_daily} w=${keep_weekly} m=${keep_monthly})"
    RESTIC_REPOSITORY="$repo_path" \
    RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
    restic forget \
        --keep-daily "$keep_daily" \
        --keep-weekly "$keep_weekly" \
        --keep-monthly "$keep_monthly" \
        --prune
}

# ---------------------------------------------------------------------------
# Integrity check — full structural + sampled data check.
# ---------------------------------------------------------------------------
restic_check() {
    local repo_name="$1"
    local subset="${2:-5%}"
    local repo_path="${RESTIC_REPO_ROOT}/${repo_name}"

    echo "[restic] check ${repo_name} (sampled ${subset})"
    RESTIC_REPOSITORY="$repo_path" \
    RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
    restic check --read-data-subset="$subset"
}

# ---------------------------------------------------------------------------
# Restore — repo → target directory.
# ---------------------------------------------------------------------------
# Args: <repo_name> <snapshot_id_or_'latest'> <target_dir> [include_path]
restic_restore() {
    local repo_name="$1"
    local snapshot="$2"
    local target_dir="$3"
    local include_path="${4:-}"

    local repo_path="${RESTIC_REPO_ROOT}/${repo_name}"

    mkdir -p "$target_dir"

    local args=(restore "$snapshot" --target "$target_dir")
    [[ -n "$include_path" ]] && args+=(--include "$include_path")

    echo "[restic] restore ${repo_name}@${snapshot} → ${target_dir} ${include_path:+(${include_path})}"
    RESTIC_REPOSITORY="$repo_path" \
    RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
    restic "${args[@]}"
}

# ---------------------------------------------------------------------------
# List snapshots — JSON output, used by `openg2p-backup.sh list`.
# ---------------------------------------------------------------------------
restic_snapshots() {
    local repo_name="$1"
    local repo_path="${RESTIC_REPO_ROOT}/${repo_name}"

    RESTIC_REPOSITORY="$repo_path" \
    RESTIC_PASSWORD_FILE="$RESTIC_PASSWORD_FILE" \
    restic snapshots --json
}
