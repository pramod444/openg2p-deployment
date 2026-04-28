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

    # ── 4. Key pair — only delete if WE created it ─────────────────────
    # When the script creates a new key pair (key_mode=create), it tags it
    # with Project=<project> + ManagedBy=openg2p-aws-provision. Pre-existing
    # keys (key_mode=existing) supplied by the user do NOT have those tags,
    # so they're safe even if --keep-key isn't passed.
    #
    # Decision tree:
    #   --keep-key                      → keep regardless
    #   key has our Project tag         → script-created → delete (key + .pem)
    #   key exists but missing our tag  → user-provided  → keep (loud log)
    #   key doesn't exist at all        → already gone   → no-op
    if [[ "$KEEP_KEY" == "true" ]]; then
        log_step "4" "Keeping key pair (--keep-key set)"
    else
        log_step "4" "Deleting key pair (only if script-created)"

        # Find key(s) we created for this project — tag-based, so it works
        # whether key_name is filled in config or auto-derived. Pre-existing
        # user keys won't have these tags and won't be touched.
        local owned_keys
        owned_keys=$(aws_cli ec2 describe-key-pairs \
            --filters "Name=tag:Project,Values=${project}" \
                      "Name=tag:ManagedBy,Values=openg2p-aws-provision" \
            --query 'KeyPairs[].KeyName' --output text 2>/dev/null || true)

        if [[ -z "$owned_keys" ]]; then
            # Maybe user explicitly named one in config — sanity-check that it
            # exists but has no tags (= user-imported), and report accordingly.
            local cfg_kn
            cfg_kn=$(cfg key_name)
            if [[ -n "$cfg_kn" ]] && \
               aws_cli ec2 describe-key-pairs --key-names "$cfg_kn" \
                   --query 'KeyPairs[0].KeyName' --output text >/dev/null 2>&1; then
                log_warn "  Key pair '${cfg_kn}' is NOT tagged Project=${project}"
                log_warn "  → pre-existing / user-supplied; keeping it in AWS"
            else
                log_info "  No script-created key pair found for Project=${project}"
            fi
        else
            for key_name in $owned_keys; do
                aws_cli ec2 delete-key-pair --key-name "$key_name"
                log_success "  Deleted key pair '${key_name}' (created by this script)"

                # Also remove any local .pem matching the configured/default path
                local key_path
                key_path=$(cfg key_path)
                if [[ -z "$key_path" ]]; then key_path="${SCRIPT_DIR}/keys/${key_name}.pem"; fi
                key_path="${key_path/#\~\//${HOME}/}"
                if [[ -f "$key_path" ]]; then
                    rm -f "$key_path"
                    log_success "  Removed local .pem at ${key_path}"
                fi
            done
        fi
    fi

    # ── 5. Delete any leftover EBS volumes / snapshots / ENIs ──────────
    # Instance termination auto-deletes the root volume (DeleteOnTermination=true)
    # and the primary ENI. This step catches resources that detached, were
    # snapshotted, or were never tied to an instance — e.g. volumes left
    # in 'available' state after a manual detach.
    log_step "5" "Sweeping leftover EBS volumes / snapshots / ENIs"

    # 5a. Volumes tagged Project=<project> in 'available' state
    local stray_vols
    stray_vols=$(aws_cli ec2 describe-volumes \
        --filters "Name=tag:Project,Values=${project}" "Name=status,Values=available,creating,error" \
        --query 'Volumes[].VolumeId' --output text 2>/dev/null || true)
    if [[ -n "$stray_vols" ]]; then
        log_info "  Deleting volumes: ${stray_vols}"
        for v in $stray_vols; do
            aws_cli ec2 delete-volume --volume-id "$v" 2>&1 \
                | grep -v -E '^$' >&2 \
                || log_warn "  Could not delete volume ${v} — may already be deleting"
        done
    else
        log_info "  No stray volumes tagged Project=${project}"
    fi

    # 5b. Snapshots tagged Project=<project> (we don't create any, but if a
    # user manually snapshotted with our tag, clean up here)
    local stray_snaps
    stray_snaps=$(aws_cli ec2 describe-snapshots \
        --owner-ids self \
        --filters "Name=tag:Project,Values=${project}" \
        --query 'Snapshots[].SnapshotId' --output text 2>/dev/null || true)
    if [[ -n "$stray_snaps" ]]; then
        log_info "  Deleting snapshots: ${stray_snaps}"
        for s in $stray_snaps; do
            aws_cli ec2 delete-snapshot --snapshot-id "$s" 2>&1 \
                | grep -v -E '^$' >&2 \
                || log_warn "  Could not delete snapshot ${s}"
        done
    else
        log_info "  No stray snapshots tagged Project=${project}"
    fi

    # 5c. ENIs that aren't attached to anything (primary ENIs auto-delete
    # with the instance; this catches manually-created or detached ones)
    local stray_enis
    stray_enis=$(aws_cli ec2 describe-network-interfaces \
        --filters "Name=tag:Project,Values=${project}" "Name=status,Values=available" \
        --query 'NetworkInterfaces[].NetworkInterfaceId' --output text 2>/dev/null || true)
    if [[ -n "$stray_enis" ]]; then
        log_info "  Deleting ENIs: ${stray_enis}"
        for e in $stray_enis; do
            aws_cli ec2 delete-network-interface --network-interface-id "$e" 2>&1 \
                | grep -v -E '^$' >&2 \
                || log_warn "  Could not delete ENI ${e}"
        done
    else
        log_info "  No stray network interfaces tagged Project=${project}"
    fi

    # ── 6. Remove provision-output.yaml (it's now stale) ───────────────
    local out=$(cfg provision_output_file "../provision-output.yaml")
    [[ "$out" = /* ]] || out="${SCRIPT_DIR}/${out}"
    if [[ -f "$out" ]]; then
        rm -f "$out" "${out}.prev"
        log_success "Removed stale ${out}"
    fi

    # ── 7. Final sweep — anything still tagged Project=<project> ───────
    log_step "7" "Sweep — anything still tagged Project=${project}"
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
