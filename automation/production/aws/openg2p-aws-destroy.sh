#!/usr/bin/env bash
# =============================================================================
# OpenG2P AWS Teardown
# =============================================================================
# Destroys everything tagged with Project=<project> that the provision script
# created: 3 instances, 1 EIP, 3 security groups, optionally the key pair.
#
# Requires explicit confirmation by typing the project name back.
# =============================================================================

set -euo pipefail

trap '
    rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "" >&2
        echo "[FATAL] script exited with status ${rc} at line ${LINENO} (${BASH_COMMAND})" >&2
    fi
' EXIT

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE=""
KEEP_KEY=false
ASSUME_YES=false

source "${SCRIPT_DIR}/../lib/shared/utils.sh"
source "${SCRIPT_DIR}/lib/aws-utils.sh"

parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --config)    CONFIG_FILE="$2"; shift 2 ;;
            --keep-key)  KEEP_KEY=true;    shift ;;
            --yes|-y)    ASSUME_YES=true;  shift ;;
            --help|-h)
                cat <<'EOF'
OpenG2P AWS Teardown

Usage:
  ./openg2p-aws-destroy.sh --config aws-config.yaml [options]

Options:
  --config <file>  AWS config (required)
  --keep-key       Keep the key pair (and local .pem)
  --yes / -y       Don't prompt for confirmation
EOF
                exit 0
                ;;
            *) log_error "Unknown option: $1"; exit 1 ;;
        esac
    done
    [[ -z "$CONFIG_FILE" ]] && { log_error "--config is required"; exit 1; }
    [[ "$CONFIG_FILE" = /* ]] || CONFIG_FILE="${SCRIPT_DIR}/${CONFIG_FILE}"
}

main() {
    parse_args "$@"

    log_banner "OpenG2P AWS Teardown" "Destroys instances, EIP, SGs, key pair"

    load_config "$CONFIG_FILE"
    export AWS_REGION
    AWS_REGION="$(cfg region)"
    aws_check_credentials

    local project=$(cfg project)
    log_info "Project: ${project}"
    log_info "Region:  ${AWS_REGION}"

    # ── Confirm ─────────────────────────────────────────────────────────
    if [[ "$ASSUME_YES" != "true" ]]; then
        echo ""
        log_warn "This will permanently destroy all AWS resources tagged Project=${project}"
        local typed
        read -rp "Type the project name '${project}' to confirm: " typed
        if [[ "$typed" != "$project" ]]; then
            log_error "Confirmation mismatch. Aborting."
            exit 1
        fi
    fi

    # ── 1. Find + terminate instances ───────────────────────────────────
    log_step "1" "Terminating EC2 instances"
    local ids
    ids=$(aws_cli ec2 describe-instances \
        --filters "Name=tag:Project,Values=${project}" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[].InstanceId' --output text 2>/dev/null)

    if [[ -n "$ids" ]]; then
        log_info "  Terminating: ${ids}"
        # shellcheck disable=SC2086
        aws_cli ec2 terminate-instances --instance-ids $ids \
            --query 'TerminatingInstances[].[InstanceId,CurrentState.Name]' --output table
        log_info "  Waiting for instances to fully terminate..."
        # shellcheck disable=SC2086
        aws_cli ec2 wait instance-terminated --instance-ids $ids
        log_success "  All instances terminated."
    else
        log_info "  No active instances tagged Project=${project}"
    fi

    # ── 2. Release Elastic IPs ──────────────────────────────────────────
    log_step "2" "Releasing Elastic IPs"
    local eip_allocs
    eip_allocs=$(aws_cli ec2 describe-addresses \
        --filters "Name=tag:Project,Values=${project}" \
        --query 'Addresses[].AllocationId' --output text 2>/dev/null)

    if [[ -n "$eip_allocs" ]]; then
        for alloc in $eip_allocs; do
            log_info "  Releasing ${alloc}..."
            aws_cli ec2 release-address --allocation-id "$alloc" || \
                log_warn "  Could not release ${alloc} (may already be gone or still associated)"
        done
        log_success "  Elastic IPs released."
    else
        log_info "  No EIPs tagged Project=${project}"
    fi

    # ── 3. Delete security groups ───────────────────────────────────────
    log_step "3" "Deleting security groups"
    local sg_ids
    sg_ids=$(aws_cli ec2 describe-security-groups \
        --filters "Name=tag:Project,Values=${project}" \
        --query 'SecurityGroups[].GroupId' --output text 2>/dev/null)

    if [[ -n "$sg_ids" ]]; then
        for sg in $sg_ids; do
            log_info "  Deleting ${sg}..."
            if ! aws_cli ec2 delete-security-group --group-id "$sg" 2>&1 | tee /tmp/sg-del.err; then
                log_warn "  Could not delete ${sg} — may have lingering ENI dependencies"
                log_warn "  Inspect: aws ec2 describe-network-interfaces --filters Name=group-id,Values=${sg}"
            fi
        done
        rm -f /tmp/sg-del.err
        log_success "  Security groups deleted."
    else
        log_info "  No SGs tagged Project=${project}"
    fi

    # ── 4. Optionally delete key pair ───────────────────────────────────
    if [[ "$KEEP_KEY" == "true" ]]; then
        log_step "4" "Keeping key pair (--keep-key set)"
    else
        log_step "4" "Deleting key pair"
        local key_name=$(cfg key_name)
        local key_path=$(cfg key_path)
        [[ -z "$key_path" ]] && key_path="${SCRIPT_DIR}/keys/${key_name}.pem"

        if aws_cli ec2 describe-key-pairs --key-names "$key_name" >/dev/null 2>&1; then
            aws_cli ec2 delete-key-pair --key-name "$key_name"
            log_success "  Deleted key pair '${key_name}' from AWS."
        fi
        if [[ -f "$key_path" ]]; then
            rm -f "$key_path"
            log_success "  Removed local .pem at ${key_path}"
        fi
    fi

    # ── 5. Remove provision-output.yaml (it's now stale) ───────────────
    local out=$(cfg provision_output_file "../provision-output.yaml")
    [[ "$out" = /* ]] || out="${SCRIPT_DIR}/${out}"
    if [[ -f "$out" ]]; then
        rm -f "$out" "${out}.prev"
        log_success "Removed stale ${out}"
    fi

    # ── 6. Show anything left tagged Project=<project> ─────────────────
    log_step "6" "Sweep — anything still tagged Project=${project}"
    local leftover
    leftover=$(aws_cli resourcegroupstaggingapi get-resources \
        --tag-filters "Key=Project,Values=${project}" \
        --query 'ResourceTagMappingList[].ResourceARN' --output text 2>/dev/null || true)
    if [[ -n "$leftover" ]]; then
        log_warn "Leftover resources tagged Project=${project} (delete manually):"
        echo "$leftover" | tr '\t' '\n' | sed 's/^/    /'
    else
        log_success "Nothing left tagged Project=${project}"
    fi

    log_success "Teardown complete."
}

main "$@"
