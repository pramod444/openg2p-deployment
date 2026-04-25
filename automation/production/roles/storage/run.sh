#!/usr/bin/env bash
# =============================================================================
# OpenG2P Storage Node — entry script (runs ON the storage node via SSH)
# =============================================================================
# Invoked by the orchestrator on the laptop:
#   ssh storage "cd /tmp/openg2p-deploy && bash role/run.sh --config prod-config.yaml --phase 1"
#
# Phases:
#   1 — host setup: tools, ufw, NFS server, Postgres host install
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"   # /tmp/openg2p-deploy
CONFIG_FILE=""
RUN_PHASE="1"
FORCE_MODE=false

source "${WORK_DIR}/lib/shared/utils.sh"
source "${SCRIPT_DIR}/phase1.sh"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config) CONFIG_FILE="$2"; shift 2 ;;
            --phase)  RUN_PHASE="$2";  shift 2 ;;
            --force)  FORCE_MODE=true; shift ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done
    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${WORK_DIR}/${CONFIG_FILE}"
}

main() {
    parse_args "$@"

    check_root
    init_state_dir

    if [[ "$FORCE_MODE" == "true" ]]; then
        reset_state "storage.phase${RUN_PHASE}."
    fi

    load_config "$CONFIG_FILE"

    log_banner "OpenG2P Storage Node" "Phase ${RUN_PHASE}"

    case "$RUN_PHASE" in
        1) run_storage_phase1 ;;
        *)
            log_error "Invalid phase for storage role: ${RUN_PHASE}" \
                      "Valid phases for storage: 1"
            exit 1
            ;;
    esac

    log_success "Storage node phase ${RUN_PHASE} complete."
}

main "$@"
