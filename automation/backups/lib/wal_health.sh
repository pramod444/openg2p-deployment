#!/usr/bin/env bash
# =============================================================================
# OpenG2P Backup — independent WAL growth / archiver health probe
# =============================================================================
# Runs outside pgbackrest_run so a stuck archiver or WAL pileup is visible even
# when the nightly full backup hasn't fired yet (signoff pattern: frequent cron
# → metrics → Alertmanager).
#
# Probe targets the storage (PostgreSQL) node via SSH.
# =============================================================================

set -euo pipefail

# wal_health_run — emit metrics + optional email if thresholds exceeded.
# Exits non-zero only if the probe itself fails (cannot reach PG / parse stats).
wal_health_run() {
    log_info "=== WAL health probe ==="
    local pgdata size_bytes failed_count age_s out
    pgdata="$(cfg postgres.data_dir /var/lib/postgresql)"

    out="$(ssh_run "storage" "set -euo pipefail
        WAL=\"${pgdata}/pg_wal\"
        if [[ ! -d \"\$WAL\" ]]; then
            cand=\$(ls -d /var/lib/postgresql/*/main/pg_wal 2>/dev/null | head -1 || true)
            [[ -n \"\$cand\" ]] && WAL=\"\$cand\"
        fi
        size=0
        [[ -d \"\$WAL\" ]] && size=\$(du -sb \"\$WAL\" 2>/dev/null | awk '{print \$1}')
        failed=0
        age=0
        if command -v sudo >/dev/null && sudo -u postgres psql -Atqc \"SELECT 1\" >/dev/null 2>&1; then
            IFS='|' read -r failed age < <(sudo -u postgres psql -Atqc \"
                SELECT coalesce(failed_count,0)::text || '|' ||
                       coalesce(extract(epoch from (now() - last_archived_time))::bigint, 0)::text
                FROM pg_stat_archiver;
            \")
        fi
        echo \"SIZE=\${size}\"
        echo \"FAILED=\${failed}\"
        echo \"AGE=\${age}\"
    ")" || {
        log_error "WAL probe SSH/query failed on storage"
        if declare -F metrics_emit_wal >/dev/null 2>&1; then
            metrics_emit_wal 0 0 0 || true
        fi
        return 1
    }

    size_bytes="$(echo "$out" | sed -n 's/^SIZE=//p' | head -1)"
    failed_count="$(echo "$out" | sed -n 's/^FAILED=//p' | head -1)"
    age_s="$(echo "$out" | sed -n 's/^AGE=//p' | head -1)"
    size_bytes="${size_bytes:-0}"
    failed_count="${failed_count:-0}"
    age_s="${age_s:-0}"

    log_info "WAL size=${size_bytes}B archiver_failed=${failed_count} last_archive_age=${age_s}s"

    if declare -F metrics_emit_wal >/dev/null 2>&1; then
        metrics_emit_wal "$size_bytes" "$failed_count" "$age_s"
    fi

    local max_bytes max_age max_failed
    max_bytes="$(cfg monitoring.wal.max_size_bytes 10737418240)"
    max_age="$(cfg monitoring.wal.max_archive_age_seconds 3600)"
    max_failed="$(cfg monitoring.wal.max_failed_count 1)"
    if (( size_bytes > max_bytes )); then
        log_warn "WAL size ${size_bytes} exceeds threshold ${max_bytes}"
        declare -F notify_failure >/dev/null 2>&1 && \
            notify_failure "wal-health" "pg_wal size ${size_bytes} > ${max_bytes}" || true
    fi
    if (( failed_count >= max_failed && failed_count > 0 )); then
        log_warn "Archiver failed_count=${failed_count}"
        declare -F notify_failure >/dev/null 2>&1 && \
            notify_failure "wal-health" "pg_stat_archiver.failed_count=${failed_count}" || true
    fi
    if (( age_s > max_age && age_s > 0 )); then
        log_warn "Last archive age ${age_s}s exceeds ${max_age}s"
        declare -F notify_failure >/dev/null 2>&1 && \
            notify_failure "wal-health" "last archive age ${age_s}s > ${max_age}s" || true
    fi
    log_info "=== WAL health probe done ==="
}
