#!/usr/bin/env bash
# =============================================================================
# OpenG2P Backup — operator email notifications (no SSH required to read them)
# =============================================================================
# Pattern from openg2p-backup-signoff/scripts/send-mail.sh:
# body → env var, then Python smtplib (never heredoc-as-python-stdin).
#
# SMTP secrets: /etc/openg2p-backup/smtp.env on the backup host (mode 0600).
# Install copies from alerting.smtp_env_file on the laptop.
# =============================================================================

set -euo pipefail

_notify_enabled() {
    local v
    v="$(cfg alerting.email_enabled false)"
    [[ "$v" == "true" || "$v" == "yes" || "$v" == "1" ]]
}

# notify_send <subject>  — body on stdin
notify_send() {
    _notify_enabled || return 0
    local subject="$1"
    local body
    body="$(cat)"
    local b64 s64
    b64="$(printf '%s' "$body" | base64 | tr -d '\n')"
    s64="$(printf '%s' "$subject" | base64 | tr -d '\n')"
    run_on_backup "set -euo pipefail
        [[ -f /etc/openg2p-backup/smtp.env ]] || {
            echo '[notify] smtp.env missing — skip mail' >&2; exit 0
        }
        set -a; source /etc/openg2p-backup/smtp.env; set +a
        : \"\${SMTP_HOST:?}\" \"\${SMTP_PORT:?}\" \"\${SMTP_FROM:?}\" \"\${MAIL_TO:?}\"
        export SUBJECT=\$(echo '${s64}' | base64 -d)
        export BODY=\$(echo '${b64}' | base64 -d)
        python3 -c '
import os, smtplib, ssl, sys
from email.message import EmailMessage
m = EmailMessage()
m[\"Subject\"] = os.environ[\"SUBJECT\"]
m[\"From\"] = os.environ[\"SMTP_FROM\"]
m[\"To\"] = os.environ[\"MAIL_TO\"]
m.set_content(os.environ.get(\"BODY\", \"\"))
try:
    s = smtplib.SMTP(os.environ[\"SMTP_HOST\"], int(os.environ[\"SMTP_PORT\"]), timeout=25)
    if os.environ.get(\"SMTP_STARTTLS\", \"true\").lower() in (\"1\", \"true\", \"yes\"):
        s.starttls(context=ssl.create_default_context())
    user = os.environ.get(\"SMTP_USER\", \"\")
    if user:
        s.login(user, os.environ.get(\"SMTP_PASS\", \"\"))
    s.send_message(m)
    s.quit()
    print(\"MAIL_SENT\")
except Exception as e:
    sys.stderr.write(\"mail fail: %r\\n\" % (e,))
    sys.exit(1)
'
    " || log_warn "Email notify failed (non-fatal) — check /etc/openg2p-backup/smtp.env"
}

# notify_failure <component> <details>
notify_failure() {
    _notify_enabled || return 0
    local component="$1" details="${2:-}"
    local host
    host="$(cfg backup_private_ip backup-host)"
    notify_send "[OpenG2P Backup] FAILED — ${component} on ${host}" <<EOF
Component : ${component}
Host      : ${host}
When      : $(date -u +%Y-%m-%dT%H:%M:%SZ)
Details   : ${details}

Check:
  ./openg2p-backup.sh status --config backup-config.yaml
  /var/log/openg2p-backup.log on the backup host
EOF
}

# notify_daily_report — summarise .status.json for operators without SSH.
notify_daily_report() {
    _notify_enabled || return 0
    local host summary repo
    host="$(cfg backup_private_ip backup-host)"
    repo="$(cfg backup_repo_root /var/lib/openg2p-backup)"
    summary=$(run_on_backup "set -euo pipefail
        f='${repo}/.status.json'
        [[ -f \$f ]] || { echo 'No .status.json yet'; exit 0; }
        jq -r '
          \"OpenG2P backup daily report\",
          \"============================\",
          \"\",
          (.components // {} | to_entries[] |
            \"\\(.key): run=\\(.value.last_run_result // \"-\") at \\(.value.last_run // \"-\")\" +
            (if .value.last_drill then \" | drill=\\(.value.last_drill_result // \"-\") at \\(.value.last_drill)\" else \"\" end)
          )
        ' \"\$f\"
        echo \"\"
        echo \"Repo disk:\"
        df -h '${repo}' 2>/dev/null | tail -1 || true
    " 2>/dev/null || echo "Could not read backup status")

    local failed=0
    echo "$summary" | grep -q 'run=fail' && failed=1 || true
    local subject
    if (( failed )); then
        subject="[OpenG2P Backup] DAILY — HAS FAILURES — ${host}"
    else
        subject="[OpenG2P Backup] DAILY OK — ${host}"
    fi
    printf '%s\n' "$summary" | notify_send "$subject"
}

# Install smtp.env onto the backup host from the laptop path (if configured).
notify_install_smtp() {
    local src
    src="$(cfg alerting.smtp_env_file "")"
    [[ -n "$src" ]] || { log_info "alerting.smtp_env_file unset — skip SMTP install"; return 0; }
    src="${src/#\~/$HOME}"
    if [[ ! -f "$src" ]]; then
        log_warn "alerting.smtp_env_file not found at ${src}"
        return 0
    fi
    push_file_as_root "backup" "$src" "/etc/openg2p-backup/smtp.env" 0600
    log_success "Installed /etc/openg2p-backup/smtp.env"
}
