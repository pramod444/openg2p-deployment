#!/usr/bin/env bash
# =============================================================================
# OpenG2P AWS Provisioning — runs on your laptop
# =============================================================================
# Creates: 1 key pair, 3 security groups, 1 Elastic IP, 3 EC2 instances
# (Ubuntu Server 24.04 LTS) for the production OpenG2P deployment.
#
# After provisioning:
#   - All instances are 'running' AND status checks 'ok' AND SSH-reachable
#   - prod-config.yaml is populated (or merged) with IPs, SSH paths, etc.
#
# Usage:
#   cp aws-config.example.yaml aws-config.yaml
#   # edit aws-config.yaml
#   ./openg2p-aws-provision.sh --config aws-config.yaml
# =============================================================================

set -euo pipefail

# Trap any non-zero exit (including silent set-e exits) and emit a line number.
# Preserves the original exit code.
trap '
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "" >&2
        echo "[FATAL] script exited with status ${rc} at line ${LINENO} (${BASH_COMMAND})" >&2
        echo "[FATAL] log: ${LOG_FILE:-<not set>}" >&2
    fi
' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
NON_INTERACTIVE=false
SKIP_SSH_WAIT=false
SSH_WAIT_TIMEOUT=600
LOG_FILE="${SCRIPT_DIR}/logs/aws-provision-$(date '+%Y%m%d-%H%M%S').log"

# Reuse logging + cfg() from the production lib.
source "${SCRIPT_DIR}/../lib/shared/utils.sh"
source "${SCRIPT_DIR}/lib/aws-utils.sh"

# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)          CONFIG_FILE="$2";        shift 2 ;;
            --non-interactive) NON_INTERACTIVE=true;    shift ;;
            --skip-ssh-wait)   SKIP_SSH_WAIT=true;      shift ;;
            --ssh-timeout)     SSH_WAIT_TIMEOUT="$2";   shift 2 ;;
            --help|-h)         show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1" "" "Run with --help for usage"
                exit 1
                ;;
        esac
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        log_error "No config file specified" \
                  "--config is required" \
                  "Copy aws-config.example.yaml and provide it" \
                  "$0 --config aws-config.yaml"
        exit 1
    fi
    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
    export NON_INTERACTIVE
    export CONFIG_FILE
}

show_help() {
    cat <<'EOF'
OpenG2P AWS Provisioning
==========================

Usage:
  ./openg2p-aws-provision.sh --config aws-config.yaml [options]

Options:
  --config <file>      Path to AWS config (required)
  --non-interactive    Never prompt — fail if any required value is unspecified
                       (use in CI; default is interactive when stdin is a TTY)
  --skip-ssh-wait      Don't wait for SSH after instances pass status checks.
                       Use when you know SSH is up (or will be) but the wait
                       is hanging due to a network/SG issue you'll fix later.
  --ssh-timeout <sec>  Per-instance SSH wait timeout (default: 600).
  --help               Show this help

What gets created (all tagged with Project=<project>):
  • 1 key pair       (or referenced existing)
  • 3 security groups (one per role)
  • 1 Elastic IP     (attached to the RP node)
  • 3 EC2 instances  (RP, compute, storage)

When values like vpc_id, subnet_id, or key_mode are blank in your config,
the script queries AWS, presents a menu, and saves your selection back to
aws-config.yaml so subsequent runs are stable.

After provisioning, provision-output.yaml is written next to prod-config.yaml.
Then run:
  cd .. && ./openg2p-prod.sh --config prod-config.yaml
EOF
}

# ---------------------------------------------------------------------------
# Validate AWS-specific config keys
# ---------------------------------------------------------------------------
validate_aws_config() {
    validate_config \
        project region \
        key_mode key_name \
        rp_instance_type compute_instance_type storage_instance_type \
        rp_disk_gb compute_disk_gb storage_disk_gb \
        rp_name compute_name storage_name \
        wg_port provision_output_file
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    mkdir -p "${SCRIPT_DIR}/logs" "${SCRIPT_DIR}/keys"
    exec > >(tee -a "$LOG_FILE") 2>&1

    log_banner "OpenG2P AWS Provisioning" "Creates 3 EC2 instances + supporting resources"
    log_info "Config: ${CONFIG_FILE}"
    log_info "Log:    ${LOG_FILE}"
    echo ""

    load_config "$CONFIG_FILE"
    validate_aws_config

    # ── 1. Pin region for all aws calls ──────────────────────────────────
    export AWS_REGION
    AWS_REGION="$(cfg region)"
    log_info "AWS region: ${AWS_REGION}"

    aws_check_credentials

    # ── 2. Project + naming ─────────────────────────────────────────────
    local project=$(cfg project)
    log_info "Project: ${project}"

    # ── 3. VPC + subnet ─────────────────────────────────────────────────
    # Smart pickers: use config if set, auto-pick when single match, prompt
    # interactively when multiple, or fail with a list in --non-interactive.
    local vpc_id subnet_id vpc_cidr
    vpc_id=$(aws_pick_vpc "$(cfg vpc_id)")          || exit 1
    subnet_id=$(aws_pick_subnet "$vpc_id" "$(cfg subnet_id)")  || exit 1
    vpc_cidr=$(aws_get_vpc_cidr "$vpc_id")
    log_success "VPC:    ${vpc_id} (CIDR: ${vpc_cidr})"
    log_success "Subnet: ${subnet_id}"

    # ── 4. admin_cidr default = laptop's public IP /32 ──────────────────
    local admin_cidr=$(cfg admin_cidr)
    if [[ -z "$admin_cidr" ]]; then
        if admin_cidr=$(aws_detect_my_public_ip); then
            log_success "Auto-detected admin_cidr: ${admin_cidr} (this laptop's public IP)"
        else
            log_error "Could not auto-detect public IP" \
                      "checkip.amazonaws.com unreachable" \
                      "Set admin_cidr explicitly in aws-config.yaml"
            exit 1
        fi
    fi
    if [[ "$admin_cidr" == "0.0.0.0/0" ]]; then
        log_warn "admin_cidr is OPEN (0.0.0.0/0). SSH/ping reachable from anywhere."
        log_warn "Tighten this in aws-config.yaml after install for production."
    fi

    # ── 5. AMI ──────────────────────────────────────────────────────────
    local ami
    ami=$(aws_resolve_ubuntu_ami "$(cfg ubuntu_ami)")
    log_success "AMI: ${ami}"

    # ── 6. Key pair ─────────────────────────────────────────────────────
    # Smart picker — if key_mode is blank and stdin is a TTY, list existing
    # keys with a "create new" option. Otherwise default to create.
    local key_resolved
    key_resolved=$(aws_pick_key_pair \
        "$(cfg key_mode)" "$(cfg key_name)" "$(cfg key_path)" \
        "$project" "${SCRIPT_DIR}/keys") || exit 1
    local key_mode="${key_resolved%%|*}"
    local key_rest="${key_resolved#*|}"
    local key_name="${key_rest%%|*}"
    local key_path="${key_rest##*|}"
    aws_ensure_key_pair "$key_name" "$key_path" "$key_mode" "$project"

    # ── 7. Security groups ──────────────────────────────────────────────
    log_step "1" "Creating security groups"
    local rp_sg compute_sg storage_sg
    local wg_port=$(cfg wg_port "51820")

    # AWS SG descriptions must be ASCII-only — keep them simple.
    # SG names default to <project>-<role> if not set in config.
    local rp_sg_name=$(cfg rp_sg_name "${project}-reverse-proxy")
    local compute_sg_name=$(cfg compute_sg_name "${project}-k8s-node")
    local storage_sg_name=$(cfg storage_sg_name "${project}-storage")

    # AWS SG descriptions must be ASCII-only — keep them simple.
    rp_sg=$(aws_ensure_security_group \
        "$rp_sg_name" "OpenG2P RP - Wireguard and Nginx" \
        "$vpc_id" "$project" "reverse-proxy")
    aws_require_nonempty "RP security group" "$rp_sg"
    aws_apply_sg_rules_rp "$rp_sg" "$admin_cidr" "$vpc_cidr" "$wg_port"
    log_success "  RP SG:      ${rp_sg_name} (${rp_sg})"

    compute_sg=$(aws_ensure_security_group \
        "$compute_sg_name" "OpenG2P K8s compute node" \
        "$vpc_id" "$project" "k8s-node")
    aws_require_nonempty "Compute security group" "$compute_sg"
    aws_apply_sg_rules_compute "$compute_sg" "$admin_cidr" "$vpc_cidr"
    log_success "  Compute SG: ${compute_sg_name} (${compute_sg})"

    storage_sg=$(aws_ensure_security_group \
        "$storage_sg_name" "OpenG2P storage node - NFS and Postgres" \
        "$vpc_id" "$project" "storage")
    aws_require_nonempty "Storage security group" "$storage_sg"
    aws_apply_sg_rules_storage "$storage_sg" "$admin_cidr" "$vpc_cidr"
    log_success "  Storage SG: ${storage_sg_name} (${storage_sg})"

    # ── 8. Elastic IP for RP (best-effort) ─────────────────────────────
    # Only the RP gets a static IP. Compute and storage use auto-assigned
    # public IPs, which is fine — they're only for SSH from the laptop.
    # The RP EIP exists so Wireguard peer configs survive instance restarts.
    # If allocation fails (e.g. AddressLimitExceeded), we proceed with the
    # auto-assigned public IP and warn the user.
    log_step "2" "Allocating Elastic IP for RP (best-effort)"
    local rp_eip_alloc rp_eip_addr=""
    rp_eip_alloc=$(aws_ensure_eip "$project" "reverse-proxy-eip")
    if [[ -n "$rp_eip_alloc" && "$rp_eip_alloc" != "None" ]]; then
        rp_eip_addr=$(aws_get_eip_address "$rp_eip_alloc")
        aws_require_nonempty "RP Elastic IP address" "$rp_eip_addr"
        log_success "  RP EIP: ${rp_eip_addr} (alloc: ${rp_eip_alloc})"
    else
        log_warn "  No Elastic IP allocated — falling back to auto-assigned public IP."
        log_warn "  Trade-off: the RP's public IP will change after a stop/start,"
        log_warn "  invalidating Wireguard peer configs (Endpoint mismatch). Allocate"
        log_warn "  one EIP later and re-run this script to attach it."
        rp_eip_alloc=""
    fi

    # ── 9. Launch instances (parallel) ──────────────────────────────────
    log_step "3" "Launching 3 EC2 instances in parallel"

    local rp_id compute_id storage_id

    # RP
    rp_id=$(aws_find_instance "$(cfg rp_name)" "$project")
    if [[ -z "$rp_id" || "$rp_id" == "None" ]]; then
        rp_id=$(aws_run_instance \
            "$(cfg rp_name)" "$project" "reverse-proxy" \
            "$ami" "$(cfg rp_instance_type)" "$subnet_id" "$rp_sg" "$key_name" \
            "$(cfg rp_disk_gb 64)" "$(cfg rp_disk_iops 3000)" "$(cfg rp_disk_throughput 125)")
        aws_require_nonempty "RP instance ID" "$rp_id"
        log_success "  RP launched:      ${rp_id}"
    else
        log_info "  RP already exists: ${rp_id}"
    fi

    # Compute
    compute_id=$(aws_find_instance "$(cfg compute_name)" "$project")
    if [[ -z "$compute_id" || "$compute_id" == "None" ]]; then
        compute_id=$(aws_run_instance \
            "$(cfg compute_name)" "$project" "k8s-node" \
            "$ami" "$(cfg compute_instance_type)" "$subnet_id" "$compute_sg" "$key_name" \
            "$(cfg compute_disk_gb 128)" "$(cfg compute_disk_iops 3000)" "$(cfg compute_disk_throughput 125)")
        aws_require_nonempty "Compute instance ID" "$compute_id"
        log_success "  Compute launched:      ${compute_id}"
    else
        log_info "  Compute already exists: ${compute_id}"
    fi

    # Storage
    storage_id=$(aws_find_instance "$(cfg storage_name)" "$project")
    if [[ -z "$storage_id" || "$storage_id" == "None" ]]; then
        storage_id=$(aws_run_instance \
            "$(cfg storage_name)" "$project" "storage" \
            "$ami" "$(cfg storage_instance_type)" "$subnet_id" "$storage_sg" "$key_name" \
            "$(cfg storage_disk_gb 256)" "$(cfg storage_disk_iops 3000)" "$(cfg storage_disk_throughput 125)")
        aws_require_nonempty "Storage instance ID" "$storage_id"
        log_success "  Storage launched:      ${storage_id}"
    else
        log_info "  Storage already exists: ${storage_id}"
    fi

    # ── 10. Wait for running ────────────────────────────────────────────
    # NOTE: 'wait' with no args blocks on ALL child processes, which includes
    # the tee subprocess from `exec > >(tee ...)` at the top of the script.
    # Track PIDs and wait on those explicitly to avoid the deadlock.
    log_step "4" "Waiting for all 3 instances to reach 'running' state"
    local rp_pid compute_pid storage_pid
    aws_wait_running "$rp_id"      "RP"      & rp_pid=$!
    aws_wait_running "$compute_id" "Compute" & compute_pid=$!
    aws_wait_running "$storage_id" "Storage" & storage_pid=$!
    wait "$rp_pid" "$compute_pid" "$storage_pid"
    log_success "All 3 instances running."

    # ── 11. Disable source/dest check on RP (Wireguard) ────────────────
    aws_disable_source_dest_check "$rp_id"
    log_success "Source/dest check disabled on RP (required for Wireguard forwarding)."

    # ── 12. Associate Elastic IP with RP (if we got one) ───────────────
    if [[ -n "$rp_eip_alloc" ]]; then
        aws_associate_eip "$rp_eip_alloc" "$rp_id"
    fi

    # ── 13. Wait for status checks (running != ready) ──────────────────
    log_step "5" "Waiting for all 3 instances to pass status checks"
    log_info "(This typically takes 2-5 minutes per instance.)"
    local rp_status_pid compute_status_pid storage_status_pid
    aws_wait_status_ok "$rp_id"      "RP"      & rp_status_pid=$!
    aws_wait_status_ok "$compute_id" "Compute" & compute_status_pid=$!
    aws_wait_status_ok "$storage_id" "Storage" & storage_status_pid=$!
    wait "$rp_status_pid" "$compute_status_pid" "$storage_status_pid"
    log_success "All 3 instances passed status checks."

    # ── 14. Capture IPs ────────────────────────────────────────────────
    # describe-instances reflects the EIP after association, but to be robust
    # (and to handle the EIP-skipped case) we prefer the EIP we tracked.
    local rp_ips compute_ips storage_ips
    rp_ips=$(aws_get_instance_ips "$rp_id")
    compute_ips=$(aws_get_instance_ips "$compute_id")
    storage_ips=$(aws_get_instance_ips "$storage_id")

    local rp_public
    if [[ -n "$rp_eip_addr" ]]; then
        rp_public="$rp_eip_addr"     # static EIP
    else
        rp_public="${rp_ips%|*}"     # auto-assigned dynamic IP
    fi
    local rp_private="${rp_ips#*|}"
    local compute_public="${compute_ips%|*}"
    local compute_private="${compute_ips#*|}"
    local storage_public="${storage_ips%|*}"
    local storage_private="${storage_ips#*|}"

    log_info "  RP:      public=${rp_public}      private=${rp_private}"
    log_info "  Compute: public=${compute_public}  private=${compute_private}"
    log_info "  Storage: public=${storage_public}  private=${storage_private}"

    # ── 15. Wait for SSH on all 3 ──────────────────────────────────────
    if [[ "$SKIP_SSH_WAIT" == "true" ]]; then
        log_step "6" "Skipping SSH wait (--skip-ssh-wait)"
        log_warn "Provision-output will be written but SSH wasn't verified."
        log_warn "If openg2p-prod.sh fails its --probe step, fix SG/network and retry."
    else
        log_step "6" "Waiting for SSH to come up on all 3 instances"
        log_info "Common causes of slow SSH: cloud-init still installing the key,"
        log_info "your laptop's public IP not in admin_cidr (SG), or key perms."
        log_info "Pass --skip-ssh-wait to bypass; --ssh-timeout <sec> to extend the wait."

        aws_wait_ssh "$rp_public"      "ubuntu" "$key_path" "$SSH_WAIT_TIMEOUT" "RP"      || exit 1
        aws_wait_ssh "$compute_public" "ubuntu" "$key_path" "$SSH_WAIT_TIMEOUT" "Compute" || exit 1
        aws_wait_ssh "$storage_public" "ubuntu" "$key_path" "$SSH_WAIT_TIMEOUT" "Storage" || exit 1
    fi

    # ── 16. Write provision-output.yaml ─────────────────────────────────
    write_provision_output \
        "$rp_public" "$rp_private" \
        "$compute_public" "$compute_private" \
        "$storage_public" "$storage_private" \
        "$vpc_cidr" "$admin_cidr" "$key_path"

    show_summary "$rp_public" "$compute_public" "$storage_public" \
                 "$key_path" "$rp_id" "$compute_id" "$storage_id"
}

# ---------------------------------------------------------------------------
# Write a separate provision-output.yaml — only AWS-derived keys.
#
# The orchestrator loads this file as an overlay on top of prod-config.yaml,
# so AWS-provisioned values (IPs, SSH paths, etc.) win over any defaults the
# user has in prod-config. The user's hand-edited preferences in prod-config
# (cluster_name, internal_domain, keycloak_admin_email, postgres_*, etc.) are
# untouched and stable across re-provisioning.
# ---------------------------------------------------------------------------
write_provision_output() {
    local rp_pub="$1"      rp_priv="$2"
    local compute_pub="$3" compute_priv="$4"
    local storage_pub="$5" storage_priv="$6"
    local vpc_cidr="$7"    admin_cidr="$8"
    local key_path="$9"

    local out=$(cfg provision_output_file "../provision-output.yaml")
    [[ "$out" = /* ]] || out="${SCRIPT_DIR}/${out}"
    out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"

    log_step "7" "Writing provision-output.yaml"

    # If a previous output exists, briefly archive it (single .prev — not a
    # timestamped backup, since the file is regenerable on every provision run).
    if [[ -f "$out" ]]; then
        cp "$out" "${out}.prev"
    fi

    # Make the key_path relative to prod-config.yaml's directory if we can —
    # makes the file portable across different repo checkouts.
    local key_for_prod="$key_path"
    local prod_dir
    prod_dir="$(dirname "$out")"
    case "$key_path" in
        "${prod_dir}/"*) key_for_prod="./${key_path#${prod_dir}/}" ;;
    esac

    cat > "$out" <<EOF
# =============================================================================
# OpenG2P provision-output — AWS-derived configuration
# =============================================================================
# AUTO-GENERATED by aws/openg2p-aws-provision.sh — overwritten on every run.
#
# The orchestrator (openg2p-prod.sh) loads this file AFTER prod-config.yaml,
# so values here override matching keys in prod-config.yaml.
#
# To override a value back, either:
#   1. Edit this file directly (changes survive until next provision run)
#   2. Or set the same key in prod-config.yaml with a "user override" comment
#      and tell the orchestrator to swap precedence (advanced — see README)
#
# Generated:  $(date -u '+%Y-%m-%d %H:%M:%S UTC')
# Region:     ${AWS_REGION}
# Project:    $(cfg project)
# =============================================================================

# ─── Reverse Proxy ───────────────────────────────────────────────────────
rp_public_ip:    "${rp_pub}"
rp_private_ip:   "${rp_priv}"
rp_ssh_host:     "${rp_pub}"
rp_ssh_user:     "ubuntu"
rp_ssh_key:      "${key_for_prod}"

# ─── Compute (K8s) ───────────────────────────────────────────────────────
compute_private_ip:  "${compute_priv}"
compute_ssh_host:    "${compute_pub}"
compute_ssh_user:    "ubuntu"
compute_ssh_key:     "${key_for_prod}"

# ─── Storage ─────────────────────────────────────────────────────────────
storage_private_ip:  "${storage_priv}"
storage_ssh_host:    "${storage_pub}"
storage_ssh_user:    "ubuntu"
storage_ssh_key:     "${key_for_prod}"

# ─── Network (derived from VPC) ──────────────────────────────────────────
private_subnet:  "${vpc_cidr}"
admin_cidr:      "${admin_cidr}"
wg_endpoint:     "${rp_pub}"
wg_port:         "$(cfg wg_port 51820)"

# ─── Identity ────────────────────────────────────────────────────────────
cluster_name:    "$(cfg project openg2p-prod)"
EOF

    log_success "Wrote ${out}"
}

show_summary() {
    local rp_pub="$1" compute_pub="$2" storage_pub="$3"
    local key_path="$4"
    local rp_id="$5" compute_id="$6" storage_id="$7"

    local out=$(cfg provision_output_file "../provision-output.yaml")
    [[ "$out" = /* ]] || out="${SCRIPT_DIR}/${out}"
    out="$(cd "$(dirname "$out")" && pwd)/$(basename "$out")"

    cat <<EOF

╔════════════════════════════════════════════════════════════════════╗
║  AWS provisioning complete                                         ║
╠════════════════════════════════════════════════════════════════════╣
║                                                                    ║
║  Instances:                                                        ║
║    Reverse Proxy: ${rp_id} → ${rp_pub}
║    Compute:       ${compute_id} → ${compute_pub}
║    Storage:       ${storage_id} → ${storage_pub}
║
║  SSH key:          ${key_path}
║  provision-output: ${out}
║
║  The orchestrator auto-loads provision-output.yaml as an overlay
║  on top of prod-config.yaml. You only need to fill prod-config.yaml
║  with your own preferences (internal_domain, keycloak_admin_email,
║  versions, etc.) — IPs and SSH paths are inherited automatically.
║
║  Next:
║    cd ..
║    cp prod-config.example.yaml prod-config.yaml   # if you haven't already
║    # edit prod-config.yaml — only USER PREFERENCES, no IPs needed
║    ./openg2p-prod.sh --probe     --config prod-config.yaml
║    ./openg2p-prod.sh --preflight --config prod-config.yaml
║    ./openg2p-prod.sh             --config prod-config.yaml
║
║  Log: ${LOG_FILE}
║
╚════════════════════════════════════════════════════════════════════╝

EOF
}

main "$@"
