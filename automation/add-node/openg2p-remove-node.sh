#!/usr/bin/env bash
# =============================================================================
# OpenG2P Remove-Node
# =============================================================================
# Drains and removes a node from the cluster.
#
# Run THIS script ON THE PRIMARY (control-plane) node — it needs kubectl
# with cluster-admin access to the existing cluster.
#
# After this script finishes, SSH to the removed node and run the cleanup
# commands it prints (we do the on-node cleanup manually for now).
#
# Usage:
#   sudo ./openg2p-remove-node.sh --node <node-name>
#   sudo ./openg2p-remove-node.sh --node node2 --timeout 600
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_NAME=""
DRAIN_TIMEOUT=300
SKIP_DRAIN=false

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/lib/utils.sh"

show_help() {
    cat <<'EOF'
OpenG2P Remove Node — drain and remove a node from the cluster
===============================================================

Run this on the PRIMARY control-plane node (needs kubectl + cluster-admin).

Usage:
  sudo ./openg2p-remove-node.sh --node <node-name> [options]

Options:
  --node <name>       Node to remove (as shown in 'kubectl get nodes')  [required]
  --timeout <sec>     Drain timeout in seconds (default: 300)
  --skip-drain        Skip cordon+drain (use only if the node is already gone)
  --help              Show this help message

What this does (on the primary):
  1. kubectl cordon  <node>    — stop scheduling new pods on the node
  2. kubectl drain   <node>    — evict existing pods (respects PDBs)
  3. kubectl delete  node <node> — remove the node object from the cluster

Then it PRINTS the cleanup commands you should run ON the removed node
(manually via SSH — we'll automate this later).
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --node)       NODE_NAME="$2"; shift 2 ;;
            --timeout)    DRAIN_TIMEOUT="$2"; shift 2 ;;
            --skip-drain) SKIP_DRAIN=true; shift ;;
            --help|-h)    show_help; exit 0 ;;
            *)
                log_error "Unknown option: $1" \
                          "This flag is not recognized" \
                          "Run with --help to see available options"
                exit 1
                ;;
        esac
    done

    if [[ -z "$NODE_NAME" ]]; then
        log_error "Missing required flag: --node" \
                  "You must specify the node to remove" \
                  "Run: kubectl get nodes  to see node names" \
                  "$0 --node <node-name>"
        exit 1
    fi
}

ensure_kubeconfig_or_die() {
    # Prefer RKE2's default kubeconfig on a server node. Fall back to
    # whatever is already in the environment (e.g. ~/.kube/config).
    if [[ -f /etc/rancher/rke2/rke2.yaml ]]; then
        export KUBECONFIG="/etc/rancher/rke2/rke2.yaml"
        export PATH="$PATH:/var/lib/rancher/rke2/bin"
    fi
    if ! command -v kubectl &>/dev/null; then
        log_error "kubectl not found on this machine" \
                  "This script must run on a control-plane (server) node" \
                  "Run it on the primary, or install kubectl and set KUBECONFIG"
        exit 1
    fi
    if ! kubectl get nodes &>/dev/null; then
        log_error "kubectl cannot reach the cluster" \
                  "Kubeconfig may be missing or point to an unreachable API server" \
                  "Verify with: kubectl get nodes" \
                  "kubectl --kubeconfig ${KUBECONFIG:-~/.kube/config} get nodes"
        exit 1
    fi
}

print_cleanup_guide() {
    local node="$1"
    cat <<EOF

=============================================================================
  NODE REMOVED FROM CLUSTER: ${node}
=============================================================================

FINAL MANUAL STEP — clean up the node itself:

  SSH to ${node} (as root) and run:

    # Stop and uninstall RKE2 (handles both server and agent installs)
    if systemctl is-active --quiet rke2-server; then
        sudo systemctl stop rke2-server
    fi
    if systemctl is-active --quiet rke2-agent; then
        sudo systemctl stop rke2-agent
    fi
    if [ -x /usr/local/bin/rke2-killall.sh ]; then
        sudo /usr/local/bin/rke2-killall.sh
    fi
    if [ -x /usr/local/bin/rke2-uninstall.sh ]; then
        sudo /usr/local/bin/rke2-uninstall.sh
    fi

    # Remove OpenG2P state
    sudo rm -rf /var/lib/openg2p /etc/rancher /var/lib/rancher

    # (Optional) Reset firewall rules this script added
    sudo ufw --force reset

ON THE PRIMARY — also update Nginx upstream if you had added this node there:

    sudo vi /etc/nginx/sites-available/openg2p-infra.conf
    # Remove the line:   server ${node}:30080;
    sudo nginx -t && sudo systemctl reload nginx

=============================================================================
EOF
}

main() {
    parse_args "$@"

    log_banner "OpenG2P Remove Node" "Drain and delete: ${NODE_NAME}"

    check_root
    ensure_kubeconfig_or_die

    # ── Verify the node exists ───────────────────────────────────────────
    if ! kubectl get node "$NODE_NAME" &>/dev/null; then
        log_error "Node '${NODE_NAME}' not found in the cluster" \
                  "The node name does not match any existing node" \
                  "List nodes: kubectl get nodes"
        exit 1
    fi

    # ── Safety: refuse to remove the only control-plane node ────────────
    local is_cp
    is_cp=$(kubectl get node "$NODE_NAME" -o jsonpath='{.metadata.labels.node-role\.kubernetes\.io/control-plane}' 2>/dev/null || true)
    if [[ "$is_cp" == "true" ]]; then
        local cp_count
        cp_count=$(kubectl get nodes -l node-role.kubernetes.io/control-plane=true --no-headers 2>/dev/null | wc -l)
        if [[ "$cp_count" -le 1 ]]; then
            log_error "Refusing to remove the only control-plane node" \
                      "'${NODE_NAME}' is the last remaining control-plane — removing it would destroy the cluster" \
                      "Add another control-plane node first, or tear down the cluster instead"
            exit 1
        fi
        log_warn "This node is a control-plane node. Cluster will have ${cp_count} → $((cp_count-1)) control-planes after removal."
    fi

    # ── Cordon + drain ──────────────────────────────────────────────────
    if [[ "$SKIP_DRAIN" == "true" ]]; then
        log_warn "Skipping cordon+drain (--skip-drain was set)."
    else
        log_info "Cordoning ${NODE_NAME}..."
        kubectl cordon "$NODE_NAME"

        log_info "Draining ${NODE_NAME} (timeout: ${DRAIN_TIMEOUT}s)..."
        if ! kubectl drain "$NODE_NAME" \
                --ignore-daemonsets \
                --delete-emptydir-data \
                --force \
                --timeout="${DRAIN_TIMEOUT}s"; then
            log_error "Drain did not complete cleanly" \
                      "Some pods could not be evicted within the timeout" \
                      "Inspect pods on the node and retry, or use --skip-drain if you accept data loss" \
                      "kubectl get pods --all-namespaces --field-selector spec.nodeName=${NODE_NAME}"
            exit 1
        fi
        log_success "Drain complete."
    fi

    # ── Delete node object ──────────────────────────────────────────────
    log_info "Deleting node object from the cluster..."
    kubectl delete node "$NODE_NAME"
    log_success "Node '${NODE_NAME}' removed from the cluster."

    print_cleanup_guide "$NODE_NAME"
}

main "$@"
