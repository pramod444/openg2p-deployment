#!/usr/bin/env bash
# =============================================================================
# OpenG2P Add-Node
# =============================================================================
# Joins a fresh Ubuntu 24.04 node to an existing RKE2 cluster as either a
# server (control-plane) or agent (worker) node.
#
# Run THIS script ON THE NEW NODE (via SSH as root / sudo).
#
# Usage:
#   sudo ./openg2p-add-node.sh --config add-node-config.yaml
#   sudo ./openg2p-add-node.sh --config add-node-config.yaml --role worker
#
# Prerequisites:
#   • Ubuntu 24.04 on the new node
#   • root/sudo access
#   • Network reachability from this node to the primary's port 9345 (TCP)
#   • rke2_token from the primary node:
#       sudo cat /var/lib/rancher/rke2/server/node-token
#
# Docs: automation/add-node/README.md
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
FORCE_MODE=false
ROLE_OVERRIDE=""
LOG_FILE="/var/log/openg2p-add-node-$(date '+%Y%m%d-%H%M%S').log"

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/utils.sh"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/add-node-steps.sh"

show_help() {
    cat <<'EOF'
OpenG2P Add Node — join a new Ubuntu 24.04 node to an existing RKE2 cluster
===========================================================================

Usage:
  sudo ./openg2p-add-node.sh --config add-node-config.yaml [options]

Options:
  --config <file>     Path to configuration file (required)
  --role server|worker
                      Override node_role from config. 'server' joins as a
                      control-plane node (rke2-server); 'worker' joins as
                      a data-plane node (rke2-agent).
  --force             Ignore completion markers, re-run all steps
  --reset             Clear add-node state markers and exit
  --help              Show this help message

What this script does:
  1. Validates config and reachability to the primary node
  2. Installs apt tools + kubectl (server role only)
  3. Configures ufw firewall (same port set as primary)
  4. Installs RKE2 and joins the existing cluster
  5. Verifies the node is healthy

What this script does NOT do (these live on the primary):
  • Wireguard server, dnsmasq, NFS server, TLS certs, Nginx, Rancher, Keycloak

After a successful join, a manual follow-up guide is written to:
  /root/openg2p-add-node-postinstall.txt
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config) CONFIG_FILE="$2"; shift 2 ;;
            --role)   ROLE_OVERRIDE="$2"; shift 2 ;;
            --force)  FORCE_MODE=true; shift ;;
            --reset)  init_state_dir; reset_state "add-node."; exit 0 ;;
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
                  "Copy add-node-config.example.yaml to add-node-config.yaml and provide it" \
                  "$0 --config add-node-config.yaml"
        exit 1
    fi

    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
}

# Prompt for role if not set in config and not overridden on CLI.
resolve_role_interactive() {
    local current; current=$(cfg "node_role")
    if [[ -n "$ROLE_OVERRIDE" ]]; then
        if [[ "$ROLE_OVERRIDE" != "server" && "$ROLE_OVERRIDE" != "worker" ]]; then
            log_error "Invalid --role value: '${ROLE_OVERRIDE}'" \
                      "Must be 'server' or 'worker'" \
                      "Re-run with --role server  OR  --role worker"
            exit 1
        fi
        CONFIG["node_role"]="$ROLE_OVERRIDE"
        log_info "node_role overridden on CLI: ${ROLE_OVERRIDE}"
        return
    fi

    if [[ -z "$current" ]]; then
        echo ""
        echo "Which role should this node join as?"
        echo "  1) server  — control-plane node (runs etcd, apiserver). Choose this for HA."
        echo "  2) worker  — data-plane node (runs app pods only). Most common choice."
        echo ""
        local choice=""
        while [[ "$choice" != "1" && "$choice" != "2" ]]; do
            read -r -p "Enter choice [1/2]: " choice
        done
        if [[ "$choice" == "1" ]]; then
            CONFIG["node_role"]="server"
        else
            CONFIG["node_role"]="worker"
        fi
        log_info "node_role set interactively: $(cfg node_role)"
    fi
}

main() {
    parse_args "$@"

    # Mirror stdout+stderr to log file (and still show in terminal)
    mkdir -p "$(dirname "$LOG_FILE")"
    exec > >(tee -a "$LOG_FILE") 2>&1

    log_banner "OpenG2P Add Node" "Join an existing RKE2 cluster"
    log_info "Log file: $LOG_FILE"

    check_root
    check_ubuntu_24

    init_state_dir
    if [[ "$FORCE_MODE" == "true" ]]; then
        reset_state "add-node."
    fi

    log_info "Loading config: $CONFIG_FILE"
    load_config "$CONFIG_FILE"

    resolve_role_interactive

    # Run the steps in order. Any failure aborts (set -e).
    step1_validate
    step2_tools
    step3_firewall
    step4_rke2
    step5_verify

    print_post_install_guide

    echo ""
    log_success "Add-node workflow complete."
}

main "$@"
