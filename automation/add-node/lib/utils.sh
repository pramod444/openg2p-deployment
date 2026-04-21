#!/usr/bin/env bash
# =============================================================================
# OpenG2P Add-Node Automation — Utility Library
# =============================================================================
# Minimal subset of helpers, modeled on single-node/lib/utils.sh.
# Sourced by openg2p-add-node.sh and openg2p-remove-node.sh.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log_info()    { echo -e "${BLUE}[INFO]${NC}  $(date '+%H:%M:%S') $*"; }
log_success() { echo -e "${GREEN}[OK]${NC}    $(date '+%H:%M:%S') $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}  $(date '+%H:%M:%S') $*"; }
log_step()    { echo -e "\n${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; \
                echo -e "${BOLD}${CYAN}  STEP $1: $2${NC}"; \
                echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

log_error() {
    echo -e "\n${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ERROR${NC}"
    echo -e "${RED}╠══════════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║${NC}  ${BOLD}What failed:${NC}    $1"
    echo -e "${RED}║${NC}  ${BOLD}Likely cause:${NC}   $2"
    echo -e "${RED}║${NC}  ${BOLD}What to check:${NC}  $3"
    [[ -n "${4:-}" ]] && echo -e "${RED}║${NC}  ${BOLD}Try running:${NC}    $4"
    [[ -n "${5:-}" ]] && echo -e "${RED}║${NC}  ${BOLD}Docs:${NC}           $5"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}\n"
}

log_banner() {
    local title="${1:-OpenG2P Add Node}"
    local subtitle="${2:-Join a node to an existing RKE2 cluster}"
    echo -e "${CYAN}"
    echo "  ╔══════════════════════════════════════════════════════════╗"
    echo "  ║                                                          ║"
    printf "  ║  %-56s  ║\n" "$title"
    printf "  ║  %-56s  ║\n" "$subtitle"
    echo "  ║                                                          ║"
    echo "  ╚══════════════════════════════════════════════════════════╝"
    echo -e "${NC}"
}

# ---------------------------------------------------------------------------
# State management (idempotency)
# ---------------------------------------------------------------------------
STATE_DIR="/var/lib/openg2p/deploy-state"

init_state_dir() { mkdir -p "$STATE_DIR"; }

mark_step_done() {
    local step_id="$1"
    touch "${STATE_DIR}/${step_id}.done"
    log_success "Step '${step_id}' completed and marked."
}

is_step_done() {
    [[ -f "${STATE_DIR}/$1.done" ]]
}

skip_if_done() {
    local step_id="$1"
    local description="$2"
    if is_step_done "$step_id"; then
        log_info "Skipping '${description}' — already completed. Use --force to re-run."
        return 0
    fi
    return 1
}

reset_state() {
    local prefix="${1:-add-node.}"
    log_warn "Resetting state markers with prefix '${prefix}'..."
    rm -f "${STATE_DIR}/${prefix}"*.done
    log_success "State reset complete."
}

# ---------------------------------------------------------------------------
# YAML config loader (single-level nesting, no yq dependency)
# ---------------------------------------------------------------------------
declare -A CONFIG

load_config() {
    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        log_error "Config file not found: ${config_file}" \
                  "The file does not exist at the specified path" \
                  "Copy the example config and edit it" \
                  "cp add-node-config.example.yaml add-node-config.yaml"
        exit 1
    fi

    local current_parent=""
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" =~ ^[[:space:]]*$ ]] && continue

        local stripped="${line#"${line%%[![:space:]]*}"}"
        local indent=$(( ${#line} - ${#stripped} ))

        stripped="${stripped%%#*}"
        stripped="${stripped%"${stripped##*[![:space:]]}"}"

        if [[ "$stripped" == *":"* ]]; then
            local key="${stripped%%:*}"
            local value="${stripped#*:}"
            key="${key%"${key##*[![:space:]]}"}"
            key="${key#"${key%%[![:space:]]*}"}"
            value="${value#"${value%%[![:space:]]*}"}"
            value="${value%\"}"; value="${value#\"}"
            value="${value%\'}"; value="${value#\'}"

            if [[ -z "$value" ]]; then
                [[ $indent -eq 0 ]] && current_parent="$key"
            else
                if [[ $indent -gt 0 && -n "$current_parent" ]]; then
                    CONFIG["${current_parent}.${key}"]="$value"
                else
                    current_parent=""
                    CONFIG["$key"]="$value"
                fi
            fi
        fi
    done < "$config_file"
}

cfg() {
    local key="$1"
    local default="${2:-}"
    echo "${CONFIG[$key]:-$default}"
}

# ---------------------------------------------------------------------------
# Prerequisite / environment checks
# ---------------------------------------------------------------------------
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root" \
                  "You are running as user '$(whoami)'" \
                  "Re-run with sudo" \
                  "sudo $0 $*"
        exit 1
    fi
}

check_ubuntu_24() {
    log_info "Checking operating system..."
    if [[ ! -f /etc/os-release ]]; then
        log_error "Cannot detect OS" "/etc/os-release not found" \
                  "This script requires Ubuntu 24.04 LTS"
        exit 1
    fi
    # shellcheck disable=SC1091
    source /etc/os-release
    if [[ "$ID" != "ubuntu" ]]; then
        log_error "Unsupported OS: ${PRETTY_NAME:-$ID}" \
                  "OpenG2P requires Ubuntu 24.04 LTS" \
                  "Install Ubuntu 24.04 on this machine"
        exit 1
    fi
    local major; major=$(echo "$VERSION_ID" | cut -d. -f1)
    if [[ "$major" -lt 24 ]]; then
        log_error "Unsupported Ubuntu version: ${VERSION_ID}" \
                  "OpenG2P requires Ubuntu 24.04 LTS or later" \
                  "Upgrade or reinstall with 24.04"
        exit 1
    fi
    log_success "Operating system: ${PRETTY_NAME} — OK."
}

# ---------------------------------------------------------------------------
# Wait helpers
# ---------------------------------------------------------------------------
wait_for_command() {
    local description="$1"
    local command="$2"
    local timeout="${3:-300}"
    local interval="${4:-10}"

    log_info "Waiting for: ${description} (timeout: ${timeout}s)..."
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if eval "$command" &>/dev/null; then
            log_success "${description} — ready."
            return 0
        fi
        sleep "$interval"
        elapsed=$((elapsed + interval))
        echo -ne "\r  Waiting... ${elapsed}s / ${timeout}s"
    done
    echo ""
    log_error "Timed out waiting for: ${description}" \
              "The operation did not complete within ${timeout} seconds" \
              "Check service logs for errors" \
              "$command"
    return 1
}

# ---------------------------------------------------------------------------
# Tool install helper
# ---------------------------------------------------------------------------
install_if_missing() {
    local tool_name="$1"
    local check_command="$2"
    local install_commands="$3"

    if eval "$check_command" &>/dev/null; then
        log_success "${tool_name} is already installed."
        return 0
    fi
    log_info "Installing ${tool_name}..."
    if ! eval "$install_commands"; then
        log_error "Failed to install ${tool_name}" \
                  "The install command exited with an error" \
                  "Check internet connectivity and try again"
        return 1
    fi
    log_success "${tool_name} installed successfully."
}
