#!/usr/bin/env bash
# =============================================================================
# OpenG2P Single-Node Orchestrator — runs on your laptop
# =============================================================================
# SSHes into one Ubuntu 24.04 VM and runs the on-box install scripts
# (roles/infra/run.sh, openg2p-environment.sh) remotely.
#
# Typical flow:
#   cd automation/single-node/aws
#   ./openg2p-aws-provision.sh --config aws-config.yaml   # optional
#   cd ..
#   cp single-node-config.example.yaml single-node-config.yaml
#   cp env-config.example.yaml env-config.yaml
#   ./openg2p-single-node.sh --config single-node-config.yaml
#
# Idempotent — node state at /var/lib/openg2p/deploy-state/; laptop markers
# under ./.state/. Use --force to re-run completed stages.
# =============================================================================

set -euo pipefail

trap '
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "" >&2
        echo "[FATAL] openg2p-single-node.sh exited with status ${rc} at line ${LINENO} (${BASH_COMMAND})" >&2
        echo "[FATAL] log: ${LOG_FILE:-<not set>}" >&2
    fi
    ssh_cleanup 2>/dev/null || true
' EXIT

echo "[boot] openg2p-single-node.sh starting (bash ${BASH_VERSION})" >&2

if (( BASH_VERSINFO[0] < 4 )); then
    echo "[FATAL] bash 4 or later required (detected ${BASH_VERSION})." >&2
    echo "[FATAL] macOS: 'brew install bash', then re-open the shell." >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
ENV_CONFIG=""
PROVISION_OUTPUT=""
RUN_STAGE="all"          # all | infra | environment
RUN_PHASE=""             # optional phase within infra (1|2|3) or env (1|2)
FORCE_MODE=false
DRY_RUN=false
PROBE_ONLY=false
SKIP_ENV=false
LOG_FILE="${SCRIPT_DIR}/logs/openg2p-single-node-$(date '+%Y%m%d-%H%M%S').log"

# Laptop-safe logging + cfg() from shared utils.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../production/lib/shared/utils.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/ssh-utils.sh"

# Override STATE_DIR for laptop-side orchestrator markers.
STATE_DIR="${SCRIPT_DIR}/.state"

# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)            CONFIG_FILE="$2";       shift 2 ;;
            --env-config)        ENV_CONFIG="$2";        shift 2 ;;
            --provision-output)  PROVISION_OUTPUT="$2";  shift 2 ;;
            --stage)             RUN_STAGE="$2";         shift 2 ;;
            --phase)             RUN_PHASE="$2";         shift 2 ;;
            --force)             FORCE_MODE=true;        shift ;;
            --dry-run)           DRY_RUN=true;           shift ;;
            --probe)             PROBE_ONLY=true;        shift ;;
            --skip-environment)  SKIP_ENV=true;          shift ;;
            --reset-laptop)
                log_warn "Clearing laptop-side state at ${STATE_DIR}"
                rm -rf "${STATE_DIR}"
                exit 0
                ;;
            --help|-h) show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1" \
                          "This flag is not recognized" \
                          "Run with --help to see available options" \
                          "$0 --help"
                exit 1
                ;;
        esac
    done

    if [[ -z "$CONFIG_FILE" ]]; then
        log_error "No config file specified" \
                  "The --config flag is required" \
                  "Copy single-node-config.example.yaml and provide it" \
                  "$0 --config single-node-config.yaml"
        exit 1
    fi

    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"

    case "$RUN_STAGE" in
        all|infra|environment|env) ;;
        *)
            log_error "Invalid --stage: '${RUN_STAGE}'" \
                      "Expected one of: all, infra, environment"
            exit 1
            ;;
    esac
    if [[ "$RUN_STAGE" == "env" ]]; then RUN_STAGE="environment"; fi
}

show_help() {
    cat <<'EOF'
OpenG2P Single-Node Orchestrator
================================

Runs on your laptop. SSHes into one Ubuntu 24.04 VM and executes the on-box
scripts (roles/infra/run.sh, openg2p-environment.sh) remotely.

Usage:
  ./openg2p-single-node.sh --config single-node-config.yaml [options]

Options:
  --config <file>            Path to single-node-config.yaml (required)
  --env-config <file>        Path to env-config.yaml (auto-detect if blank)
  --provision-output <file>  Path to provision-output.yaml (auto-detect if blank)
  --stage <name>             What to run: all | infra | environment  (default: all)
  --phase <n>                Pass --phase N through to the on-box script
                             (infra: 1|2|3 · environment: 1|2)
  --probe                    SSH-probe the node and exit (no changes)
  --skip-environment         With --stage all, run infra only
  --force                    Ignore completion markers, re-run stages
  --dry-run                  Print what would run, do nothing
  --reset-laptop             Clear laptop-side .state/ markers and exit
  --help                     Show this help

Config layering:
  1. single-node-config.yaml — your preferences (cluster_name, local_domain, …)
  2. provision-output.yaml   — AWS-derived state (node_ip, wireguard.endpoint,
                               ssh_host, ssh_user, ssh_key). Auto-detected next
                               to single-node-config.yaml; its keys win on conflict.

Prerequisites on the VM:
  • Ubuntu 24.04 LTS, passwordless sudo for the SSH user (ubuntu@)
  • Reachable over SSH from this laptop (public IP / EIP)

After AWS provisioning:
  cd automation/single-node
  cp single-node-config.example.yaml single-node-config.yaml
  cp env-config.example.yaml   env-config.yaml
  ./openg2p-single-node.sh --config single-node-config.yaml --probe
  ./openg2p-single-node.sh --config single-node-config.yaml
EOF
}

# ---------------------------------------------------------------------------
validate_orchestrator_config() {
    # node_ip must resolve after overlay (required by on-box infra script).
    if [[ -z "$(cfg node_ip)" ]]; then
        log_error "node_ip is blank after loading config + provision-output" \
                  "AWS overlay missing or incomplete" \
                  "Run aws/openg2p-aws-provision.sh, or set node_ip in single-node-config.yaml"
        exit 1
    fi

    # SSH endpoint must resolve (ssh_resolve_role will also check key file).
    local host
    host=$(cfg ssh_host)
    if [[ -z "$host" ]]; then host=$(cfg public_ip); fi
    if [[ -z "$host" ]]; then host=$(cfg wireguard.endpoint); fi
    if [[ -z "$host" ]]; then
        log_error "No SSH host in config" \
                  "ssh_host / public_ip / wireguard.endpoint are blank" \
                  "Ensure provision-output.yaml exists next to single-node-config.yaml"
        exit 1
    fi

    if [[ -z "$(cfg ssh_key)" ]]; then
        log_error "ssh_key is blank" \
                  "Cannot SSH without a key path" \
                  "Set ssh_key in provision-output.yaml or single-node-config.yaml"
        exit 1
    fi
}

# ---------------------------------------------------------------------------
stage_and_run_infra() {
    local marker="orchestrator/infra"
    if [[ -n "$RUN_PHASE" ]]; then marker="orchestrator/infra-phase${RUN_PHASE}"; fi

    if [[ "$FORCE_MODE" != "true" ]] && skip_if_done "$marker" "infrastructure install"; then
        return 0
    fi

    log_step "INFRA" "Stage bundle and run roles/infra/run.sh on remote"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would stage single-node tree and run: roles/infra/run.sh --config single-node-config.yaml${RUN_PHASE:+ --phase $RUN_PHASE}"
        return 0
    fi

    ssh_stage_single_node "$SCRIPT_DIR" "$CONFIG_FILE" "$PROVISION_OUTPUT" "$ENV_CONFIG"

    local remote_cmd="cd ${REMOTE_WORK_DIR} && OPENG2P_ORCHESTRATED=1 bash roles/infra/run.sh --config single-node-config.yaml"
    if [[ -n "$RUN_PHASE" ]]; then remote_cmd+=" --phase ${RUN_PHASE}"; fi
    if [[ "$FORCE_MODE" == "true" ]]; then remote_cmd+=" --force"; fi

    log_info "Remote: ${remote_cmd}"
    ssh_run "node" "$remote_cmd"

    mark_orchestrator_done "$marker"
}

# Ensure parent dirs exist for nested markers like orchestrator/infra.done
mark_orchestrator_done() {
    local marker="$1"
    mkdir -p "${STATE_DIR}/$(dirname "$marker")"
    mark_step_done "$marker"
}

stage_and_run_environment() {
    if [[ -z "$ENV_CONFIG" || ! -f "$ENV_CONFIG" ]]; then
        log_warn "No env-config.yaml found — skipping environment stage."
        log_warn "Create one with: cp env-config.example.yaml env-config.yaml"
        log_warn "Then re-run: $0 --config $(basename "$CONFIG_FILE") --stage environment"
        return 0
    fi

    local marker="orchestrator/environment"
    if [[ -n "$RUN_PHASE" ]]; then marker="orchestrator/environment-phase${RUN_PHASE}"; fi

    if [[ "$FORCE_MODE" != "true" ]] && skip_if_done "$marker" "environment install"; then
        return 0
    fi

    log_step "ENVIRONMENT" "Stage bundle and run openg2p-environment.sh on remote"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would stage and run: openg2p-environment.sh --config env-config.yaml${RUN_PHASE:+ --phase $RUN_PHASE}"
        return 0
    fi

    # Re-stage so env-config changes are picked up even if infra already ran.
    ssh_stage_single_node "$SCRIPT_DIR" "$CONFIG_FILE" "$PROVISION_OUTPUT" "$ENV_CONFIG"

    local remote_cmd="cd ${REMOTE_WORK_DIR} && OPENG2P_ORCHESTRATED=1 bash openg2p-environment.sh --config env-config.yaml"
    if [[ -n "$RUN_PHASE" ]]; then remote_cmd+=" --phase ${RUN_PHASE}"; fi
    if [[ "$FORCE_MODE" == "true" ]]; then remote_cmd+=" --force"; fi

    log_info "Remote: ${remote_cmd}"
    ssh_run "node" "$remote_cmd"

    mark_orchestrator_done "$marker"
}

# ---------------------------------------------------------------------------
pull_laptop_artifacts() {
    log_step "ARTIFACTS" "Pull Wireguard peer, CA cert, and kubeconfig to laptop"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would pull peer1.conf, ca.crt, rke2-remote.yaml into ${LAPTOP_ARTIFACT_DIR}/"
        return 0
    fi

    mkdir -p "$LAPTOP_ARTIFACT_DIR"

    if ssh_pull "node" "/etc/wireguard/peers/peer1/peer1.conf" \
            "${LAPTOP_ARTIFACT_DIR}/peer1.conf" 2>/dev/null; then
        log_success "  Wireguard peer → ${LAPTOP_ARTIFACT_DIR}/peer1.conf"
    else
        log_warn "  Could not pull peer1.conf (Wireguard may not be ready yet)"
    fi

    if ssh_pull "node" "/etc/openg2p/ca/ca.crt" \
            "${LAPTOP_ARTIFACT_DIR}/openg2p-ca.crt" 2>/dev/null; then
        log_success "  CA certificate → ${LAPTOP_ARTIFACT_DIR}/openg2p-ca.crt"
    else
        log_warn "  Could not pull ca.crt"
    fi

    if ssh_pull "node" "/etc/rancher/rke2/rke2-remote.yaml" \
            "${LAPTOP_ARTIFACT_DIR}/rke2-remote.yaml" 2>/dev/null; then
        chmod 600 "${LAPTOP_ARTIFACT_DIR}/rke2-remote.yaml" 2>/dev/null || true
        log_success "  kubeconfig     → ${LAPTOP_ARTIFACT_DIR}/rke2-remote.yaml"
    else
        log_warn "  Could not pull rke2-remote.yaml"
    fi
}

# Resolve ssh_key to an absolute path for copy-pasteable summary commands.
_resolve_ssh_key_display() {
    local key
    key=$(cfg ssh_key "")
    key="${key/#\~/$HOME}"
    if [[ -n "$key" && "$key" != /* ]]; then
        key="${SCRIPT_DIR}/${key}"
    fi
    # Prefer a path relative to SCRIPT_DIR when possible (shorter for display).
    case "$key" in
        "${SCRIPT_DIR}/"*) echo "./${key#${SCRIPT_DIR}/}" ;;
        *) echo "$key" ;;
    esac
}

show_completion_summary() {
    local node_ip rancher_host local_domain public_ip ssh_user ssh_key_disp
    local public_access cluster_name rancher_pw wg_subnet wg_server_ip
    node_ip=$(cfg node_ip)
    local_domain=$(cfg local_domain "openg2p.test")
    cluster_name=$(cfg cluster_name "openg2p")
    public_access=$(cfg public_access "false")
    public_ip=$(cfg ssh_host)
    if [[ -z "$public_ip" ]]; then public_ip=$(cfg public_ip); fi
    if [[ -z "$public_ip" ]]; then public_ip=$(cfg wireguard.endpoint); fi
    ssh_user=$(cfg ssh_user "ubuntu")
    ssh_key_disp=$(_resolve_ssh_key_display)
    rancher_host="rancher.${local_domain}"
    wg_subnet=$(cfg "wireguard.subnet" "10.15.0.0/16")
    # Wireguard server address is typically .1 in the WG subnet (e.g. 10.15.0.1)
    wg_server_ip="${wg_subnet%%/*}"
    wg_server_ip="${wg_server_ip%.*}.1"

    # Live-fetch Rancher admin password from the node.
    rancher_pw="<failed to fetch — see kubectl command below>"
    rancher_pw=$(ssh_run "node" \
        "KUBECONFIG=/etc/rancher/rke2/rke2.yaml /var/lib/rancher/rke2/bin/kubectl -n cattle-system get secret rancher-secret -o jsonpath='{.data.adminPassword}' 2>/dev/null | base64 -d 2>/dev/null" \
        2>/dev/null) || rancher_pw="<failed to fetch>"
    if [[ -z "$rancher_pw" ]]; then
        rancher_pw=$(ssh_run "node" \
            "cat /var/lib/openg2p/deploy-state/rancher-admin-password 2>/dev/null" \
            2>/dev/null) || rancher_pw="<failed to fetch>"
    fi
    if [[ -z "$rancher_pw" ]]; then rancher_pw="<empty — secret may not exist>"; fi

    local access_line="private — reachable only via Wireguard / VPC"
    if [[ "$public_access" == "true" ]]; then
        access_line="PUBLIC — 80/443 open to the Internet"
    fi

    local summary_dir="${SCRIPT_DIR}/setup-output"
    local summary_file="${summary_dir}/SETUP-SUMMARY.txt"
    mkdir -p "$summary_dir"
    chmod 700 "$summary_dir" 2>/dev/null || true

    local art="${LAPTOP_ARTIFACT_DIR}"
    # Prefer relative artifact path for display
    case "$art" in
        "${SCRIPT_DIR}/"*) art="./${art#${SCRIPT_DIR}/}" ;;
    esac

    cat > "$summary_file" <<EOF


╔══════════════════════════════════════════════════════════════════════════════╗
║                                                                              ║
║    OpenG2P Single-Node Infrastructure — SETUP COMPLETE                       ║
║                                                                              ║
╚══════════════════════════════════════════════════════════════════════════════╝

  Cluster:     ${cluster_name}
  Node IP:     ${node_ip}  (private)
  Public IP:   ${public_ip}
  Rancher:     https://${rancher_host}
  Access:      ${access_line}

  SSH into the VM (from this laptop):

      ssh -i ${ssh_key_disp} ${ssh_user}@${public_ip}


  CREDENTIALS — KEEP THESE SAFE

    ┌─ Rancher local admin ────────────────────────────────────────────────────┐
    │   username:  admin                                                       │
    │   password:  ${rancher_pw}
    │   (also in K8s secret: cattle-system/rancher-secret)                     │
    └──────────────────────────────────────────────────────────────────────────┘


══════════════════════════════════════════════════════════════════════════════
  WHAT TO DO NEXT — on your laptop
══════════════════════════════════════════════════════════════════════════════

  STEP 1.  Wireguard VPN

      Artifacts already pulled (if present):
        ${art}/peer1.conf

      Or pull manually anytime:

      ssh -i ${ssh_key_disp} ${ssh_user}@${public_ip} \\
          "sudo cat /etc/wireguard/peers/peer1/peer1.conf" > peer1.conf

      Import peer1.conf into the Wireguard app and activate the tunnel.
      Verify:  ping ${wg_server_ip}

  STEP 2.  Per-domain DNS (split tunnel)

      macOS:
        sudo mkdir -p /etc/resolver
        echo 'nameserver ${node_ip}' | sudo tee /etc/resolver/${local_domain}

      Windows (PowerShell as Admin):
        Add-DnsClientNrptRule -Namespace '.${local_domain}' -NameServers '${node_ip}'

      Linux:
        sudo resolvectl dns wg0 ${node_ip}
        sudo resolvectl domain wg0 '~${local_domain}'

  STEP 3.  Trust the local CA certificate

      Already pulled (if present):  ${art}/openg2p-ca.crt

      Or pull manually:

      ssh -i ${ssh_key_disp} ${ssh_user}@${public_ip} \\
          "sudo cat /etc/openg2p/ca/ca.crt" > openg2p-ca.crt

      macOS:
        sudo security add-trusted-cert -d -r trustRoot \\
          -k /Library/Keychains/System.keychain openg2p-ca.crt

      Linux:
        sudo cp openg2p-ca.crt /usr/local/share/ca-certificates/openg2p-ca.crt
        sudo update-ca-certificates

      Windows: Import into Trusted Root Certification Authorities.

  STEP 4.  Login to Rancher (local authentication)

      Open:     https://${rancher_host}
      Username: admin
      Password: (see CREDENTIALS above)

      Create additional users in Rancher:
        ☰ → Users & Authentication → Users


══════════════════════════════════════════════════════════════════════════════
  OPTIONAL — kubectl / helm from your laptop (Wireguard must be active)
══════════════════════════════════════════════════════════════════════════════

      Already pulled (if present):  ${art}/rke2-remote.yaml

      Or pull manually:

      ssh -i ${ssh_key_disp} ${ssh_user}@${public_ip} \\
          "sudo cat /etc/rancher/rke2/rke2-remote.yaml" > ~/.kube/openg2p-single-node
      chmod 600 ~/.kube/openg2p-single-node
      export KUBECONFIG=~/.kube/openg2p-single-node
      # or: export KUBECONFIG=${art}/rke2-remote.yaml
      kubectl get nodes


══════════════════════════════════════════════════════════════════════════════
  WHAT'S NEXT
══════════════════════════════════════════════════════════════════════════════

      Create an environment (from this laptop):

        ./openg2p-single-node.sh --config $(basename "$CONFIG_FILE") --stage environment

      Or full re-run / continue:

        ./openg2p-single-node.sh --config $(basename "$CONFIG_FILE")


  Log:     ${LOG_FILE}
  Summary: ${summary_file}

EOF

    chmod 600 "$summary_file" 2>/dev/null || true
    cat "$summary_file"
    log_success "Setup summary saved to ${summary_file}"
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    mkdir -p "${SCRIPT_DIR}/logs" "${SCRIPT_DIR}/.state/orchestrator" "${SCRIPT_DIR}/artifacts"
    exec > >(tee -a "$LOG_FILE") 2>&1

    log_banner "OpenG2P Single-Node Orchestrator" "Laptop → SSH → on-box install scripts"
    log_info "Config: ${CONFIG_FILE}"
    log_info "Log:    ${LOG_FILE}"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "Mode:   dry-run"
    fi
    echo ""

    load_config "$CONFIG_FILE"

    # Auto-detect provision-output overlay next to single-node-config.yaml.
    if [[ -z "$PROVISION_OUTPUT" ]]; then
        PROVISION_OUTPUT="$(dirname "$CONFIG_FILE")/provision-output.yaml"
    fi
    if [[ -f "$PROVISION_OUTPUT" ]]; then
        log_info "Loading provision-output overlay: ${PROVISION_OUTPUT}"
        load_config "$PROVISION_OUTPUT"
    else
        PROVISION_OUTPUT=""
        log_info "No provision-output.yaml found — using single-node-config.yaml only"
    fi

    # Auto-detect env-config
    if [[ -z "$ENV_CONFIG" ]]; then
        local auto_env
        auto_env="$(dirname "$CONFIG_FILE")/env-config.yaml"
        if [[ -f "$auto_env" ]]; then
            ENV_CONFIG="$auto_env"
        fi
    else
        [[ "$ENV_CONFIG" = /* ]] || ENV_CONFIG="${SCRIPT_DIR}/${ENV_CONFIG}"
    fi
    if [[ -n "$ENV_CONFIG" && -f "$ENV_CONFIG" ]]; then
        log_info "Env config: ${ENV_CONFIG}"
    fi

    validate_orchestrator_config

    init_state_dir
    mkdir -p "${STATE_DIR}/orchestrator"
    ssh_init

    if [[ "$PROBE_ONLY" == "true" ]]; then
        log_step "PROBE" "SSH + sudo check"
        ssh_probe "node"
        log_success "Probe complete — node is reachable."
        return 0
    fi

    log_step "PROBE" "SSH + sudo check"
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would probe SSH + sudo"
    else
        ssh_probe "node"
    fi

    case "$RUN_STAGE" in
        infra)
            stage_and_run_infra
            pull_laptop_artifacts
            show_completion_summary
            ;;
        environment)
            stage_and_run_environment
            ;;
        all)
            stage_and_run_infra
            pull_laptop_artifacts
            if [[ "$SKIP_ENV" == "true" ]]; then
                log_info "Skipping environment stage (--skip-environment)."
                show_completion_summary
            else
                stage_and_run_environment
                show_completion_summary
            fi
            ;;
    esac

    log_success "Orchestrator finished."
}

main "$@"
