#!/usr/bin/env bash
# =============================================================================
# OpenG2P 3-Node Production — SSH / orchestration helpers
# =============================================================================
# Sourced by openg2p-prod.sh on the admin's laptop.
#
# Responsibilities:
#   • Resolve (user, host, key) per role from config
#   • Multiplexed SSH via ControlMaster for fast repeated commands
#   • Push role scripts + config to remote nodes via rsync
#   • Run scripts remotely under sudo
#   • Pull artifacts (CA cert, kubeconfig, peer config) back to the laptop
# =============================================================================

# Where SSH ControlMaster sockets live on the laptop.
SSH_CTRL_DIR="${SSH_CTRL_DIR:-${HOME}/.ssh/openg2p-ctrl}"

# Where remote scripts and config land on each node.
REMOTE_WORK_DIR="/tmp/openg2p-deploy"

# Where artifacts pulled back from the cluster land on the laptop.
LAPTOP_ARTIFACT_DIR="${LAPTOP_ARTIFACT_DIR:-./artifacts}"

# ---------------------------------------------------------------------------
# Role resolution
# ---------------------------------------------------------------------------
# Echoes "user|host|keyfile" for the given role.
ssh_resolve_role() {
    local role="$1"
    local user host key

    case "$role" in
        rp)
            user=$(cfg "rp_ssh_user" "ubuntu")
            host=$(cfg "rp_ssh_host")
            [[ -z "$host" ]] && host=$(cfg "rp_public_ip")
            key=$(cfg "rp_ssh_key" "~/.ssh/id_rsa")
            ;;
        compute)
            user=$(cfg "compute_ssh_user" "ubuntu")
            host=$(cfg "compute_ssh_host")
            [[ -z "$host" ]] && host=$(cfg "compute_private_ip")
            key=$(cfg "compute_ssh_key" "~/.ssh/id_rsa")
            ;;
        storage)
            user=$(cfg "storage_ssh_user" "ubuntu")
            host=$(cfg "storage_ssh_host")
            [[ -z "$host" ]] && host=$(cfg "storage_private_ip")
            key=$(cfg "storage_ssh_key" "~/.ssh/id_rsa")
            ;;
        *)
            log_error "Unknown role: '${role}'" \
                      "Expected one of: rp, compute, storage" \
                      "Check the --role argument"
            return 1
            ;;
    esac

    if [[ -z "$host" ]]; then
        log_error "No SSH host resolved for role '${role}'" \
                  "Both *_ssh_host and the corresponding *_ip are blank in your config" \
                  "Set either ${role}_ssh_host or the IP field for that role"
        return 1
    fi

    # Expand ~ in key path
    key="${key/#\~/$HOME}"

    echo "${user}|${host}|${key}"
}

# ---------------------------------------------------------------------------
# SSH option builder
# ---------------------------------------------------------------------------
# Echoes the ssh -o options needed for ControlMaster + (optional) ProxyJump.
ssh_options_for() {
    local role="$1"

    local opts=(
        -o "ControlMaster=auto"
        -o "ControlPath=${SSH_CTRL_DIR}/%r@%h:%p"
        -o "ControlPersist=300"
        -o "StrictHostKeyChecking=accept-new"
        -o "UserKnownHostsFile=${SSH_CTRL_DIR}/known_hosts"
        -o "ServerAliveInterval=30"
        -o "ServerAliveCountMax=3"
    )

    # Bastion: if ssh_jump_via_rp is set, route compute/storage through RP.
    if [[ "$role" != "rp" ]] && cfg_bool "ssh_jump_via_rp"; then
        local rp_resolved
        rp_resolved=$(ssh_resolve_role "rp") || return 1
        local rp_user="${rp_resolved%%|*}"
        local rp_rest="${rp_resolved#*|}"
        local rp_host="${rp_rest%%|*}"
        local rp_key="${rp_rest##*|}"

        opts+=(-o "ProxyJump=${rp_user}@${rp_host}")
        # Make sure the jump SSH knows the key — set IdentityFile via env
        opts+=(-o "IdentityFile=${rp_key}")
    fi

    printf '%s\n' "${opts[@]}"
}

# ---------------------------------------------------------------------------
# Init / cleanup
# ---------------------------------------------------------------------------
ssh_init() {
    mkdir -p "$SSH_CTRL_DIR"
    chmod 700 "$SSH_CTRL_DIR"
    touch "${SSH_CTRL_DIR}/known_hosts"
    mkdir -p "$LAPTOP_ARTIFACT_DIR"
}

ssh_cleanup() {
    # Close all ControlMaster sockets cleanly.
    for sock in "${SSH_CTRL_DIR}"/*; do
        [[ -S "$sock" ]] || continue
        local target
        target=$(basename "$sock")
        ssh -o "ControlPath=${sock}" -O exit "${target}" 2>/dev/null || true
    done
}

# ---------------------------------------------------------------------------
# Probe — verify SSH works for a role before doing anything.
# ---------------------------------------------------------------------------
ssh_probe() {
    local role="$1"
    local resolved
    resolved=$(ssh_resolve_role "$role") || return 1
    local user="${resolved%%|*}"
    local rest="${resolved#*|}"
    local host="${rest%%|*}"
    local key="${rest##*|}"

    log_info "SSH probe: ${role} → ${user}@${host}"

    local opts
    mapfile -t opts < <(ssh_options_for "$role")

    if ! ssh -i "$key" "${opts[@]}" \
            -o "BatchMode=yes" -o "ConnectTimeout=10" \
            "${user}@${host}" "true" 2>/dev/null; then
        log_error "SSH connection failed: ${user}@${host}" \
                  "Cannot connect to the ${role} node" \
                  "Check the host, key, and network reachability" \
                  "ssh -i ${key} ${user}@${host}"
        return 1
    fi

    # Verify passwordless sudo
    if ! ssh -i "$key" "${opts[@]}" -o "BatchMode=yes" \
             "${user}@${host}" "sudo -n true" 2>/dev/null; then
        log_error "Passwordless sudo not available for ${user}@${host}" \
                  "The user must have NOPASSWD:ALL in sudoers (or run as root)" \
                  "Add the user to /etc/sudoers.d/ on the ${role} node" \
                  "echo '${user} ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/openg2p"
        return 1
    fi

    log_success "SSH + sudo OK on ${role}."
}

# ---------------------------------------------------------------------------
# Remote command execution
# ---------------------------------------------------------------------------
# ssh_run <role> <command...>
# Runs the command on the remote node under sudo. Streams stdout/stderr.
ssh_run() {
    local role="$1"; shift
    local resolved
    resolved=$(ssh_resolve_role "$role") || return 1
    local user="${resolved%%|*}"
    local rest="${resolved#*|}"
    local host="${rest%%|*}"
    local key="${rest##*|}"

    local opts
    mapfile -t opts < <(ssh_options_for "$role")

    ssh -i "$key" "${opts[@]}" "${user}@${host}" "sudo -E bash -lc $(printf '%q' "$*")"
}

# ssh_run_raw <role> <command...>
# Runs WITHOUT sudo (e.g. for sudo -n probe, or ad-hoc reads).
ssh_run_raw() {
    local role="$1"; shift
    local resolved
    resolved=$(ssh_resolve_role "$role") || return 1
    local user="${resolved%%|*}"
    local rest="${resolved#*|}"
    local host="${rest%%|*}"
    local key="${rest##*|}"

    local opts
    mapfile -t opts < <(ssh_options_for "$role")

    ssh -i "$key" "${opts[@]}" "${user}@${host}" "$*"
}

# ---------------------------------------------------------------------------
# File push — uses rsync over the ControlMaster connection.
# ---------------------------------------------------------------------------
# ssh_push <role> <local_src> <remote_dest>
# remote_dest is an absolute path on the remote node.
ssh_push() {
    local role="$1"; local src="$2"; local dest="$3"
    local resolved
    resolved=$(ssh_resolve_role "$role") || return 1
    local user="${resolved%%|*}"
    local rest="${resolved#*|}"
    local host="${rest%%|*}"
    local key="${rest##*|}"

    local opts
    mapfile -t opts < <(ssh_options_for "$role")

    # Make sure the remote dir exists and is owned by the SSH user
    # (rsync to root-owned dirs needs --rsync-path="sudo rsync"; we drop into
    # /tmp/openg2p-deploy which the SSH user owns).
    ssh -i "$key" "${opts[@]}" "${user}@${host}" \
        "mkdir -p $(dirname "$dest") && chmod 0755 $(dirname "$dest")" >/dev/null

    local rsync_ssh="ssh -i ${key}"
    for o in "${opts[@]}"; do
        rsync_ssh="${rsync_ssh} ${o}"
    done

    rsync -az --delete \
        -e "$rsync_ssh" \
        "$src" \
        "${user}@${host}:${dest}"
}

# ---------------------------------------------------------------------------
# File pull — copy a remote file to a laptop artifact path.
# ---------------------------------------------------------------------------
# ssh_pull <role> <remote_src> <local_dest>
# Reads via sudo (so root-owned files work) and streams to the laptop.
ssh_pull() {
    local role="$1"; local src="$2"; local dest="$3"
    local resolved
    resolved=$(ssh_resolve_role "$role") || return 1
    local user="${resolved%%|*}"
    local rest="${resolved#*|}"
    local host="${rest%%|*}"
    local key="${rest##*|}"

    local opts
    mapfile -t opts < <(ssh_options_for "$role")

    mkdir -p "$(dirname "$dest")"

    ssh -i "$key" "${opts[@]}" "${user}@${host}" \
        "sudo cat $(printf '%q' "$src")" > "$dest"
}

# ---------------------------------------------------------------------------
# Stage role bundle — push lib/shared/, role dir, and the config to remote.
# ---------------------------------------------------------------------------
# ssh_stage_role <role>
ssh_stage_role() {
    local role="$1"
    local repo_root="$2"
    local config_file="$3"

    log_info "Staging role bundle '${role}' on remote..."

    # We assemble a clean staging dir on the laptop, then rsync it as a unit.
    local stage
    stage=$(mktemp -d -t openg2p-stage.XXXXXX)
    trap "rm -rf '$stage'" RETURN

    mkdir -p "${stage}/lib"
    cp -r "${repo_root}/lib/shared" "${stage}/lib/shared"
    cp -r "${repo_root}/roles/${role}" "${stage}/role"
    cp -r "${repo_root}/charts" "${stage}/charts"
    [[ -f "${repo_root}/helmfile-infra.yaml.gotmpl" ]] && \
        cp "${repo_root}/helmfile-infra.yaml.gotmpl" "${stage}/helmfile-infra.yaml.gotmpl"
    cp "$config_file" "${stage}/prod-config.yaml"

    ssh_push "$role" "${stage}/" "${REMOTE_WORK_DIR}/"

    log_success "Staged ${role} bundle at ${REMOTE_WORK_DIR}/ on remote."
}

# ---------------------------------------------------------------------------
# Run a role's entry script remotely.
# ---------------------------------------------------------------------------
# ssh_run_role <role> [extra args...]
ssh_run_role() {
    local role="$1"; shift
    log_info "Running ${role}/run.sh on remote (args: $*)"
    ssh_run "$role" "cd ${REMOTE_WORK_DIR} && bash role/run.sh --config prod-config.yaml $*"
}
