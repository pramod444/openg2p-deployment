#!/usr/bin/env bash
# =============================================================================
# OpenG2P 3-Node Production Infrastructure Orchestrator
# =============================================================================
# Runs ON YOUR LAPTOP. SSHes into 3 Ubuntu 24.04 nodes (RP, compute, storage)
# and drives role-specific phases on each.
#
# Roles:
#   reverse-proxy (rp) — Nginx, Wireguard server, dnsmasq, local CA
#   compute            — RKE2 single control-plane, Istio, Rancher, Keycloak
#   storage            — NFS server, Postgres host install
#
# Usage:
#   ./openg2p-prod.sh --config prod-config.yaml
#   ./openg2p-prod.sh --config prod-config.yaml --role storage
#   ./openg2p-prod.sh --config prod-config.yaml --role compute --phase 2
#   ./openg2p-prod.sh --config prod-config.yaml --probe
#
# Idempotent — state markers live on each node at /var/lib/openg2p/deploy-state/.
# Re-running picks up where it left off. Use --force to re-run completed steps.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
RUN_ROLE="all"
RUN_PHASE=""
FORCE_MODE=false
DRY_RUN=false
PROBE_ONLY=false
PREFLIGHT_ONLY=false
SKIP_PREFLIGHT=false
LOG_FILE="${SCRIPT_DIR}/logs/openg2p-prod-$(date '+%Y%m%d-%H%M%S').log"

# Source shared utilities (logging, config loader, state) — same library used
# inside the remote nodes too. The orchestrator uses only the laptop-safe bits.
source "${SCRIPT_DIR}/lib/shared/utils.sh"
source "${SCRIPT_DIR}/lib/ssh-utils.sh"

# Override STATE_DIR for the laptop side — orchestrator state is per-config.
STATE_DIR="${SCRIPT_DIR}/.state"

# ---------------------------------------------------------------------------
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)  CONFIG_FILE="$2"; shift 2 ;;
            --role)    RUN_ROLE="$2";    shift 2 ;;
            --phase)   RUN_PHASE="$2";   shift 2 ;;
            --force)   FORCE_MODE=true;  shift ;;
            --dry-run) DRY_RUN=true;     shift ;;
            --probe)           PROBE_ONLY=true;     shift ;;
            --preflight)       PREFLIGHT_ONLY=true; shift ;;
            --skip-preflight)  SKIP_PREFLIGHT=true; shift ;;
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
                  "Copy prod-config.example.yaml and provide it" \
                  "$0 --config prod-config.yaml"
        exit 1
    fi

    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"

    case "$RUN_ROLE" in
        all|rp|reverse-proxy|compute|storage) ;;
        *)
            log_error "Invalid --role: '${RUN_ROLE}'" \
                      "Expected one of: all, rp, compute, storage"
            exit 1
            ;;
    esac

    # Normalize alias
    [[ "$RUN_ROLE" == "reverse-proxy" ]] && RUN_ROLE="rp"
}

show_help() {
    cat <<'EOF'
OpenG2P 3-Node Production Orchestrator
========================================

Runs on your laptop. Drives 3 nodes via SSH.

Usage:
  ./openg2p-prod.sh --config prod-config.yaml [options]

Options:
  --config <file>      Path to configuration file (required)
  --role  <name>       Run only one role: rp | compute | storage  (default: all)
  --phase <n>          Run only one phase within the role (1, 2, 3)
  --probe              SSH-probe all 3 nodes and exit (no changes)
  --preflight          Run preflight checks on all 3 nodes and exit (no changes)
  --skip-preflight     Skip preflight (use with caution — for re-runs only)
  --force              Ignore completion markers, re-run all steps
  --dry-run            Print what would run, do nothing
  --reset-laptop       Clear laptop-side state and exit
  --help               Show this help

Order when --role all (default):
  1. SSH probes for all 3 nodes
  2. Storage node: phase 1 (NFS server + Postgres host)
  3. Compute node: phase 1 (RKE2 + NFS client)
  4. Reverse-proxy:  phase 1 (Wireguard, dnsmasq, local CA, Nginx)
  5. Compute node: phase 2 (helmfile — Istio, Rancher, Keycloak, monitoring)
  6. Compute node: phase 3 (Rancher-Keycloak SAML)

State markers:
  • Each node:  /var/lib/openg2p/deploy-state/*.done
  • Laptop:     ./.state/orchestrator/*.done
EOF
}

# ---------------------------------------------------------------------------
validate_orchestrator_config() {
    local required=(
        cluster_name internal_domain
        rp_public_ip rp_private_ip
        compute_private_ip compute_node_name
        storage_private_ip storage_node_name
        private_subnet
        wg_subnet wg_port
        rke2_version rancher_version
        keycloak_admin_email
        postgres_version postgres_port
        nfs_export_path nfs_mount_path
    )
    validate_config "${required[@]}"
    check_subnet_overlap
}

# ---------------------------------------------------------------------------
# Sanity-check: WG subnet must not overlap private subnet, and all 3 node
# private IPs must fall inside private_subnet.
# ---------------------------------------------------------------------------
check_subnet_overlap() {
    local priv=$(cfg private_subnet)
    local wg=$(cfg wg_subnet)

    # Strip masks for a coarse first-octet comparison — good enough to catch
    # the common mistake of using the same /16 for both.
    local priv_base="${priv%%/*}"
    local wg_base="${wg%%/*}"
    local priv_2="${priv_base%.*.*}"
    local wg_2="${wg_base%.*.*}"

    if [[ "$priv_2" == "$wg_2" ]]; then
        log_error "Subnet overlap: private_subnet (${priv}) and wg_subnet (${wg}) share a prefix" \
                  "Wireguard peers will collide with private IPs" \
                  "Pick a different wg_subnet (e.g. 10.15.0.0/16 if private is 10.0.0.0/16)"
        exit 1
    fi

    # Verify each configured private IP falls inside private_subnet (first
    # two octets — coarse but catches IP-swap mistakes).
    local rp_ip=$(cfg rp_private_ip)
    local compute_ip=$(cfg compute_private_ip)
    local storage_ip=$(cfg storage_private_ip)
    for ip in "$rp_ip" "$compute_ip" "$storage_ip"; do
        local ip_2="${ip%.*.*}"
        if [[ "$ip_2" != "$priv_2" ]]; then
            log_warn "IP ${ip} appears to be outside private_subnet ${priv}"
            log_warn "  ufw rules use private_subnet — IPs outside it will be denied"
        fi
    done
}

# ---------------------------------------------------------------------------
probe_all() {
    log_step "0" "SSH probe — verifying access to all nodes"
    ssh_probe rp
    ssh_probe storage
    ssh_probe compute
    log_success "All 3 nodes reachable with passwordless sudo."
}

# ---------------------------------------------------------------------------
# Preflight — runs on all 3 nodes in parallel, aggregates, hard-fail on any
# FAIL line. Use --skip-preflight to bypass.
# ---------------------------------------------------------------------------
preflight_one() {
    local role="$1"
    local outfile="$2"

    # Push only what preflight needs: lib/shared/ + the config file.
    # Reuses the same /tmp/openg2p-deploy/ staging dir as full role bundles.
    {
        ssh_push "$role" "${SCRIPT_DIR}/lib/shared/" "${REMOTE_WORK_DIR}/lib/shared/"
        ssh_run "$role" "mkdir -p ${REMOTE_WORK_DIR} && cat > ${REMOTE_WORK_DIR}/prod-config.yaml" \
            < "$CONFIG_FILE" 2>/dev/null || true
    } >>"$outfile" 2>&1

    # Run preflight. Capture both stdout and exit code.
    local rc=0
    ssh_run "$role" \
        "cd ${REMOTE_WORK_DIR} && bash lib/shared/preflight.sh --role ${role} --config prod-config.yaml" \
        >>"$outfile" 2>&1 || rc=$?

    echo "::EXIT::${rc}" >> "$outfile"
}

preflight_all() {
    log_step "0" "Preflight — resource + network checks on all 3 nodes (parallel)"

    local tmp
    tmp=$(mktemp -d -t openg2p-preflight.XXXXXX)
    trap "rm -rf '$tmp'" RETURN

    # Push config to each node first (sequential, fast — ssh_push uses rsync).
    # This avoids the inline cat-stdin trick which is fragile.
    for role in storage compute rp; do
        ssh_push "$role" "${SCRIPT_DIR}/lib/shared/" "${REMOTE_WORK_DIR}/lib/shared/" \
            >"${tmp}/${role}.push" 2>&1 &
    done
    wait

    # Send the config file by piping its content (rsync of a single file is
    # also fine but stdin keeps perms predictable on the remote).
    for role in storage compute rp; do
        ssh_run "$role" \
            "mkdir -p ${REMOTE_WORK_DIR} && cat > ${REMOTE_WORK_DIR}/prod-config.yaml" \
            < "$CONFIG_FILE" >"${tmp}/${role}.cfg" 2>&1 &
    done
    wait

    # Run preflight in parallel.
    for role in storage compute rp; do
        (
            ssh_run "$role" \
                "cd ${REMOTE_WORK_DIR} && bash lib/shared/preflight.sh --role ${role} --config prod-config.yaml" \
                >"${tmp}/${role}.out" 2>&1
            echo $? > "${tmp}/${role}.rc"
        ) &
    done
    wait

    # Print all 3 outputs in fixed order.
    local total_fail=0
    for role in storage compute rp; do
        echo ""
        echo -e "${CYAN}── ${role} ─────────────────────────────────────${NC}"
        cat "${tmp}/${role}.out" 2>/dev/null
        local rc
        rc=$(cat "${tmp}/${role}.rc" 2>/dev/null || echo 1)
        if [[ "$rc" != "0" ]]; then
            total_fail=$((total_fail + 1))
        fi
    done
    echo ""

    # Inter-node TCP-22 reachability — WARN-only signal that the private
    # subnet routes between the 3 nodes. Real ports (5432, 2049, 30080)
    # aren't listening yet, so SSH/22 is the only thing reachable.
    log_info "Inter-node connectivity probe (SSH/22 over private subnet)..."
    local storage_ip=$(cfg storage_private_ip)
    local compute_ip=$(cfg compute_private_ip)
    local rp_ip=$(cfg rp_private_ip)

    inter_node_probe() {
        local from="$1" to_label="$2" to_ip="$3"
        if ssh_run "$from" \
            "timeout 5 bash -c '</dev/tcp/${to_ip}/22' 2>/dev/null" 2>/dev/null; then
            log_success "  ${from} → ${to_label} (${to_ip}:22) reachable"
        else
            log_warn   "  ${from} → ${to_label} (${to_ip}:22) NOT reachable — SG/firewall may block, install may fail later"
        fi
    }

    inter_node_probe compute storage "$storage_ip"
    inter_node_probe compute rp      "$rp_ip"
    inter_node_probe storage compute "$compute_ip"
    inter_node_probe rp      compute "$compute_ip"
    echo ""

    if [[ $total_fail -gt 0 ]]; then
        log_error "Preflight failed on ${total_fail} node(s)" \
                  "Resource or environment checks did not pass" \
                  "Fix the [FAIL] items shown above and re-run, or pass --skip-preflight (advanced)" \
                  "$0 --config $(basename "$CONFIG_FILE") --preflight"
        exit 1
    fi
    log_success "Preflight passed on all 3 nodes."
}

run_role_phase() {
    local role="$1"
    local phase="$2"

    local marker="orchestrator/${role}-phase${phase}"
    if [[ "$FORCE_MODE" != "true" ]] && skip_if_done "$marker" "${role} phase ${phase}"; then
        return 0
    fi

    log_step "${role^^} phase ${phase}" "Staging and executing on remote node"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[dry-run] would stage role bundle and run: role/run.sh --phase ${phase}"
        return 0
    fi

    ssh_stage_role "$role" "$SCRIPT_DIR" "$CONFIG_FILE"

    local extra=""
    [[ "$FORCE_MODE" == "true" ]] && extra="--force"
    ssh_run_role "$role" --phase "$phase" $extra

    mark_step_done "$marker"
}

# ---------------------------------------------------------------------------
main() {
    parse_args "$@"

    mkdir -p "${SCRIPT_DIR}/logs" "${STATE_DIR}/orchestrator"

    log_banner "OpenG2P 3-Node Production Setup" "Orchestrator · runs on your laptop"

    log_info "Config: ${CONFIG_FILE}"
    log_info "Log:    ${LOG_FILE}"
    echo ""

    load_config "$CONFIG_FILE"
    validate_orchestrator_config

    ssh_init
    trap ssh_cleanup EXIT

    if [[ "$PROBE_ONLY" == "true" ]]; then
        probe_all
        log_success "Probe complete."
        exit 0
    fi

    if [[ "$PREFLIGHT_ONLY" == "true" ]]; then
        probe_all
        preflight_all
        log_success "Preflight complete."
        exit 0
    fi

    case "$RUN_ROLE" in
        all)
            probe_all
            [[ "$SKIP_PREFLIGHT" == "true" ]] || preflight_all
            run_role_phase storage 1
            run_role_phase compute 1
            run_role_phase rp      1
            run_role_phase compute 2
            run_role_phase compute 3
            show_summary
            ;;
        storage)
            ssh_probe storage
            run_role_phase storage "${RUN_PHASE:-1}"
            ;;
        compute)
            ssh_probe compute
            if [[ -n "$RUN_PHASE" ]]; then
                run_role_phase compute "$RUN_PHASE"
            else
                run_role_phase compute 1
                run_role_phase compute 2
                run_role_phase compute 3
            fi
            ;;
        rp)
            ssh_probe rp
            run_role_phase rp "${RUN_PHASE:-1}"
            ;;
    esac

    log_success "Orchestrator run complete."
}

show_summary() {
    local internal=$(cfg internal_domain)
    local rancher_host="rancher.${internal}"
    local keycloak_host="keycloak.${internal}"
    local rp_user=$(cfg rp_ssh_user ubuntu)
    local rp_host=$(cfg rp_ssh_host)
    [[ -z "$rp_host" ]] && rp_host=$(cfg rp_public_ip)
    local rp_key=$(cfg rp_ssh_key "~/.ssh/id_rsa")
    local compute_user=$(cfg compute_ssh_user ubuntu)
    local compute_host=$(cfg compute_ssh_host)
    [[ -z "$compute_host" ]] && compute_host=$(cfg compute_private_ip)

    cat <<EOF

╔════════════════════════════════════════════════════════════════════╗
║  OpenG2P 3-Node Production Infrastructure — Setup Complete       ║
╠════════════════════════════════════════════════════════════════════╣
║                                                                    ║
║  Admin tools (reachable only via Wireguard):                       ║
║    Rancher:   https://${rancher_host}
║    Keycloak:  https://${keycloak_host}
║
║  Post-install steps on your laptop:
║
║  1) Wireguard peer config:
║     scp -i ${rp_key} ${rp_user}@${rp_host}:/etc/wireguard/peers/peer1/peer1.conf .
║     # then import into the Wireguard client app
║
║  2) Local CA certificate (trust on your laptop):
║     scp -i ${rp_key} ${rp_user}@${rp_host}:/etc/openg2p/ca/ca.crt .
║     # macOS:    sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt
║     # Linux:    sudo cp ca.crt /usr/local/share/ca-certificates/openg2p-ca.crt && sudo update-ca-certificates
║     # Windows:  import into "Trusted Root Certification Authorities"
║
║  3) kubectl access (after Wireguard is up):
║     scp -i ${rp_key} ${compute_user}@${compute_host}:/etc/rancher/rke2/rke2-remote.yaml ~/.kube/openg2p-prod
║     export KUBECONFIG=~/.kube/openg2p-prod
║     kubectl get nodes
║
║  Log: ${LOG_FILE}
║
╚════════════════════════════════════════════════════════════════════╝

EOF
}

mkdir -p "${SCRIPT_DIR}/logs"
exec > >(tee -a "$LOG_FILE") 2>&1

main "$@"
