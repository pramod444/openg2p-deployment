#!/usr/bin/env bash
# =============================================================================
# OpenG2P AWS provisioning — shared helpers
# =============================================================================
# Sourced by openg2p-aws-provision.sh and openg2p-aws-destroy.sh.
# Requires: aws CLI v2, bash 4+, jq (optional but improves error messages).
# =============================================================================

# ---------------------------------------------------------------------------
# AWS CLI wrapper — pins region and profile if set.
# ---------------------------------------------------------------------------
aws_cli() {
    local args=()
    [[ -n "${AWS_REGION:-}" ]] && args+=(--region "$AWS_REGION")
    [[ -n "${AWS_PROFILE:-}" ]] && args+=(--profile "$AWS_PROFILE")
    aws "${args[@]}" "$@"
}

# ---------------------------------------------------------------------------
# Sanity check — credentials work, account is accessible
# ---------------------------------------------------------------------------
aws_check_credentials() {
    local who
    if ! who=$(aws_cli sts get-caller-identity --output json 2>&1); then
        log_error "AWS credentials check failed" \
                  "aws sts get-caller-identity returned an error" \
                  "Verify your credentials and region" \
                  "aws sts get-caller-identity"
        echo "$who"
        return 1
    fi
    local account user
    account=$(echo "$who" | grep -o '"Account": "[^"]*"' | cut -d\" -f4)
    user=$(echo    "$who" | grep -o '"Arn":     *"[^"]*"' | cut -d\" -f4)
    log_success "AWS account ${account} accessible (${user})"
}

# ---------------------------------------------------------------------------
# Detect this laptop's public IP (for sensible default admin_cidr)
# ---------------------------------------------------------------------------
aws_detect_my_public_ip() {
    local ip
    ip=$(curl -sS --max-time 5 https://checkip.amazonaws.com 2>/dev/null | tr -d '\r\n ')
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "${ip}/32"
        return 0
    fi
    return 1
}

# ---------------------------------------------------------------------------
# VPC + subnet resolution
# ---------------------------------------------------------------------------
aws_resolve_vpc() {
    local vpc_id="$1"
    if [[ -n "$vpc_id" ]]; then
        # Validate it exists
        if ! aws_cli ec2 describe-vpcs --vpc-ids "$vpc_id" \
                --query 'Vpcs[0].VpcId' --output text >/dev/null 2>&1; then
            log_error "VPC '${vpc_id}' not found in region ${AWS_REGION:-default}" \
                      "vpc_id in config does not exist or wrong region" \
                      "List VPCs: aws ec2 describe-vpcs --query 'Vpcs[].[VpcId,IsDefault,CidrBlock,Tags]' --output table"
            return 1
        fi
        echo "$vpc_id"
        return 0
    fi

    # Auto-detect default VPC
    local default_vpc
    default_vpc=$(aws_cli ec2 describe-vpcs --filters "Name=isDefault,Values=true" \
        --query 'Vpcs[0].VpcId' --output text 2>/dev/null)
    if [[ -z "$default_vpc" || "$default_vpc" == "None" ]]; then
        log_error "No default VPC in this region" \
                  "Cannot auto-detect VPC" \
                  "Specify vpc_id in your config, or pass --interactive"
        return 1
    fi
    echo "$default_vpc"
}

aws_resolve_subnet() {
    local vpc_id="$1"
    local subnet_id="$2"

    if [[ -n "$subnet_id" ]]; then
        # Validate it belongs to the VPC
        local got_vpc
        got_vpc=$(aws_cli ec2 describe-subnets --subnet-ids "$subnet_id" \
            --query 'Subnets[0].VpcId' --output text 2>/dev/null)
        if [[ "$got_vpc" != "$vpc_id" ]]; then
            log_error "Subnet '${subnet_id}' is not in VPC '${vpc_id}'" \
                      "subnet_id and vpc_id mismatch" \
                      "List subnets in VPC: aws ec2 describe-subnets --filters Name=vpc-id,Values=${vpc_id}"
            return 1
        fi
        echo "$subnet_id"
        return 0
    fi

    # Auto-detect: prefer DefaultForAz=true, fall back to first MapPublicIpOnLaunch=true.
    local sub
    sub=$(aws_cli ec2 describe-subnets \
        --filters "Name=vpc-id,Values=${vpc_id}" "Name=defaultForAz,Values=true" \
        --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
    if [[ -z "$sub" || "$sub" == "None" ]]; then
        sub=$(aws_cli ec2 describe-subnets \
            --filters "Name=vpc-id,Values=${vpc_id}" "Name=map-public-ip-on-launch,Values=true" \
            --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
    fi
    if [[ -z "$sub" || "$sub" == "None" ]]; then
        log_error "No suitable subnet found in VPC ${vpc_id}" \
                  "Need a default-AZ subnet or one with MapPublicIpOnLaunch=true" \
                  "Specify subnet_id in your config"
        return 1
    fi
    echo "$sub"
}

aws_get_vpc_cidr() {
    local vpc_id="$1"
    aws_cli ec2 describe-vpcs --vpc-ids "$vpc_id" \
        --query 'Vpcs[0].CidrBlock' --output text
}

# ---------------------------------------------------------------------------
# Interactive picker — used when --interactive and config is blank
# ---------------------------------------------------------------------------
aws_interactive_pick_vpc() {
    log_info "Available VPCs in region ${AWS_REGION:-default}:"
    aws_cli ec2 describe-vpcs \
        --query 'Vpcs[].[VpcId,CidrBlock,IsDefault,Tags[?Key==`Name`]|[0].Value]' \
        --output table >&2
    local pick
    read -rp "Enter VPC ID: " pick
    echo "$pick"
}

aws_interactive_pick_subnet() {
    local vpc_id="$1"
    log_info "Available subnets in VPC ${vpc_id}:"
    aws_cli ec2 describe-subnets --filters "Name=vpc-id,Values=${vpc_id}" \
        --query 'Subnets[].[SubnetId,AvailabilityZone,CidrBlock,MapPublicIpOnLaunch,Tags[?Key==`Name`]|[0].Value]' \
        --output table >&2
    local pick
    read -rp "Enter Subnet ID: " pick
    echo "$pick"
}

# ---------------------------------------------------------------------------
# Ubuntu 24.04 LTS AMI resolution (Canonical owner)
# ---------------------------------------------------------------------------
aws_resolve_ubuntu_ami() {
    local ami="$1"
    if [[ -n "$ami" ]]; then
        # Validate
        if ! aws_cli ec2 describe-images --image-ids "$ami" \
                --query 'Images[0].ImageId' --output text >/dev/null 2>&1; then
            log_error "AMI '${ami}' not found in this region"
            return 1
        fi
        echo "$ami"
        return 0
    fi

    log_info "Resolving latest Ubuntu Server 24.04 LTS AMI..." >&2
    local resolved
    resolved=$(aws_cli ec2 describe-images \
        --owners 099720109477 \
        --filters \
            "Name=name,Values=ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*" \
            "Name=state,Values=available" \
            "Name=architecture,Values=x86_64" \
        --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
        --output text 2>/dev/null)
    if [[ -z "$resolved" || "$resolved" == "None" ]]; then
        # Fallback: try the older naming pattern (some regions use hvm-ssd not hvm-ssd-gp3)
        resolved=$(aws_cli ec2 describe-images \
            --owners 099720109477 \
            --filters \
                "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-noble-24.04-amd64-server-*" \
                "Name=state,Values=available" \
                "Name=architecture,Values=x86_64" \
            --query 'Images | sort_by(@, &CreationDate) | [-1].ImageId' \
            --output text 2>/dev/null)
    fi
    if [[ -z "$resolved" || "$resolved" == "None" ]]; then
        log_error "Could not resolve an Ubuntu 24.04 AMI" \
                  "No matching Canonical AMI in this region" \
                  "Specify ubuntu_ami in your config"
        return 1
    fi
    log_info "Resolved AMI: ${resolved}" >&2
    echo "$resolved"
}

# ---------------------------------------------------------------------------
# Key pair: create-or-verify
# ---------------------------------------------------------------------------
aws_ensure_key_pair() {
    local key_name="$1"
    local key_path="$2"
    local mode="$3"     # "create" or "existing"
    local project="$4"

    case "$mode" in
        create)
            local exists
            exists=$(aws_cli ec2 describe-key-pairs --key-names "$key_name" \
                --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || true)
            if [[ -n "$exists" && "$exists" != "None" ]]; then
                if [[ -f "$key_path" ]]; then
                    log_success "Key pair '${key_name}' already exists in AWS, .pem present locally."
                    return 0
                fi
                log_error "Key pair '${key_name}' exists in AWS but .pem is missing locally at ${key_path}" \
                          "Cannot recover the private key from AWS" \
                          "Either delete the AWS key pair (aws ec2 delete-key-pair --key-name ${key_name}) and re-run, or copy the .pem file to ${key_path}"
                return 1
            fi
            log_info "Creating new key pair '${key_name}'..."
            mkdir -p "$(dirname "$key_path")"
            aws_cli ec2 create-key-pair \
                --key-name "$key_name" \
                --key-format pem \
                --tag-specifications "ResourceType=key-pair,Tags=[{Key=Project,Value=${project}},{Key=ManagedBy,Value=openg2p-aws-provision}]" \
                --query 'KeyMaterial' --output text > "$key_path"
            chmod 0400 "$key_path"
            log_success "Key pair created. Private key saved to ${key_path} (mode 0400)."
            ;;
        existing)
            local exists
            exists=$(aws_cli ec2 describe-key-pairs --key-names "$key_name" \
                --query 'KeyPairs[0].KeyName' --output text 2>/dev/null || true)
            if [[ -z "$exists" || "$exists" == "None" ]]; then
                log_error "Key pair '${key_name}' not found in AWS" \
                          "key_mode is 'existing' but the named key pair doesn't exist" \
                          "Either import it first or switch key_mode to 'create'"
                return 1
            fi
            if [[ ! -f "$key_path" ]]; then
                log_error "Key file '${key_path}' not found locally" \
                          "key_mode is 'existing' but key_path does not point to a real file" \
                          "Place your .pem file at the configured path"
                return 1
            fi
            chmod 0400 "$key_path" 2>/dev/null || true
            log_success "Using existing key pair '${key_name}' with .pem at ${key_path}"
            ;;
        *)
            log_error "Invalid key_mode: '${mode}'" "Expected 'create' or 'existing'"
            return 1
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Security groups — describe-or-create with role-specific ingress
# ---------------------------------------------------------------------------
# Echoes the SG ID on stdout; logs go to stderr.
aws_ensure_security_group() {
    local name="$1"
    local description="$2"
    local vpc_id="$3"
    local project="$4"
    local role="$5"

    local sg_id
    sg_id=$(aws_cli ec2 describe-security-groups \
        --filters "Name=group-name,Values=${name}" "Name=vpc-id,Values=${vpc_id}" \
        --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null || true)

    if [[ -n "$sg_id" && "$sg_id" != "None" ]]; then
        log_info "Security group '${name}' already exists (${sg_id})." >&2
        echo "$sg_id"
        return 0
    fi

    log_info "Creating security group '${name}'..." >&2
    sg_id=$(aws_cli ec2 create-security-group \
        --group-name "$name" \
        --description "$description" \
        --vpc-id "$vpc_id" \
        --tag-specifications "ResourceType=security-group,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${project}},{Key=Role,Value=${role}},{Key=ManagedBy,Value=openg2p-aws-provision}]" \
        --query 'GroupId' --output text)
    echo "$sg_id"
}

# Add ingress rule (idempotent — ignores DuplicatePermission errors).
aws_add_ingress() {
    local sg_id="$1"; shift
    aws_cli ec2 authorize-security-group-ingress --group-id "$sg_id" "$@" \
        2>&1 | grep -v -E '(InvalidPermission.Duplicate|already exists)' >&2 || true
}

# ---------------------------------------------------------------------------
# Apply role-specific ingress rules.
# ---------------------------------------------------------------------------
aws_apply_sg_rules_rp() {
    local sg_id="$1"
    local admin_cidr="$2"
    local vpc_cidr="$3"
    local wg_port="$4"

    aws_add_ingress "$sg_id" \
        --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${admin_cidr},Description=admin SSH}]"
    aws_add_ingress "$sg_id" \
        --ip-permissions "IpProtocol=icmp,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=${admin_cidr},Description=admin ping}]"
    aws_add_ingress "$sg_id" \
        --ip-permissions "IpProtocol=udp,FromPort=${wg_port},ToPort=${wg_port},IpRanges=[{CidrIp=0.0.0.0/0,Description=Wireguard}]"
    # All TCP/UDP from VPC CIDR — intra-VPC traffic. ufw on each node provides
    # fine-grained restriction.
    aws_add_ingress "$sg_id" \
        --ip-permissions "IpProtocol=-1,IpRanges=[{CidrIp=${vpc_cidr},Description=intra-VPC}]"
}

aws_apply_sg_rules_compute() {
    local sg_id="$1"; local admin_cidr="$2"; local vpc_cidr="$3"
    aws_add_ingress "$sg_id" \
        --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${admin_cidr},Description=admin SSH}]"
    aws_add_ingress "$sg_id" \
        --ip-permissions "IpProtocol=icmp,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=${admin_cidr},Description=admin ping}]"
    aws_add_ingress "$sg_id" \
        --ip-permissions "IpProtocol=-1,IpRanges=[{CidrIp=${vpc_cidr},Description=intra-VPC}]"
}

aws_apply_sg_rules_storage() {
    local sg_id="$1"; local admin_cidr="$2"; local vpc_cidr="$3"
    aws_add_ingress "$sg_id" \
        --ip-permissions "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${admin_cidr},Description=admin SSH}]"
    aws_add_ingress "$sg_id" \
        --ip-permissions "IpProtocol=icmp,FromPort=-1,ToPort=-1,IpRanges=[{CidrIp=${admin_cidr},Description=admin ping}]"
    aws_add_ingress "$sg_id" \
        --ip-permissions "IpProtocol=-1,IpRanges=[{CidrIp=${vpc_cidr},Description=intra-VPC}]"
}

# ---------------------------------------------------------------------------
# Elastic IP — allocate-or-find by Project tag + Role tag
# ---------------------------------------------------------------------------
aws_ensure_eip() {
    local project="$1"
    local role_tag="$2"     # e.g. "reverse-proxy-eip"

    local alloc_id
    alloc_id=$(aws_cli ec2 describe-addresses \
        --filters "Name=tag:Project,Values=${project}" "Name=tag:Role,Values=${role_tag}" \
        --query 'Addresses[0].AllocationId' --output text 2>/dev/null || true)

    if [[ -n "$alloc_id" && "$alloc_id" != "None" ]]; then
        log_info "Elastic IP for ${role_tag} already allocated (${alloc_id})." >&2
        echo "$alloc_id"
        return 0
    fi

    log_info "Allocating new Elastic IP for ${role_tag}..." >&2
    alloc_id=$(aws_cli ec2 allocate-address --domain vpc \
        --tag-specifications "ResourceType=elastic-ip,Tags=[{Key=Project,Value=${project}},{Key=Role,Value=${role_tag}},{Key=ManagedBy,Value=openg2p-aws-provision}]" \
        --query 'AllocationId' --output text)
    echo "$alloc_id"
}

aws_get_eip_address() {
    local alloc_id="$1"
    aws_cli ec2 describe-addresses --allocation-ids "$alloc_id" \
        --query 'Addresses[0].PublicIp' --output text
}

aws_associate_eip() {
    local alloc_id="$1"; local instance_id="$2"

    # Skip if already associated to this instance
    local current
    current=$(aws_cli ec2 describe-addresses --allocation-ids "$alloc_id" \
        --query 'Addresses[0].InstanceId' --output text 2>/dev/null || true)
    if [[ "$current" == "$instance_id" ]]; then
        log_info "Elastic IP ${alloc_id} already associated to ${instance_id}." >&2
        return 0
    fi

    aws_cli ec2 associate-address --allocation-id "$alloc_id" --instance-id "$instance_id" \
        --query 'AssociationId' --output text >/dev/null
    log_success "Associated Elastic IP ${alloc_id} → ${instance_id}." >&2
}

# ---------------------------------------------------------------------------
# Instances
# ---------------------------------------------------------------------------
# Looks up an instance by Name tag + Project tag, in non-terminated state.
# Echoes instance ID or empty.
aws_find_instance() {
    local name="$1"; local project="$2"
    aws_cli ec2 describe-instances \
        --filters \
            "Name=tag:Name,Values=${name}" \
            "Name=tag:Project,Values=${project}" \
            "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        --query 'Reservations[].Instances[0].InstanceId | [0]' \
        --output text 2>/dev/null
}

aws_run_instance() {
    local name="$1"
    local project="$2"
    local role="$3"
    local ami="$4"
    local instance_type="$5"
    local subnet_id="$6"
    local sg_id="$7"
    local key_name="$8"
    local disk_gb="$9"
    local disk_iops="${10}"
    local disk_throughput="${11}"

    log_info "Launching ${role} (${instance_type}, ${disk_gb} GB gp3)..." >&2

    local bdm
    bdm=$(printf '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":%d,"VolumeType":"gp3","Iops":%d,"Throughput":%d,"DeleteOnTermination":true,"Encrypted":true}}]' \
        "$disk_gb" "$disk_iops" "$disk_throughput")

    local id
    id=$(aws_cli ec2 run-instances \
        --image-id "$ami" \
        --instance-type "$instance_type" \
        --key-name "$key_name" \
        --security-group-ids "$sg_id" \
        --subnet-id "$subnet_id" \
        --associate-public-ip-address \
        --block-device-mappings "$bdm" \
        --tag-specifications \
            "ResourceType=instance,Tags=[{Key=Name,Value=${name}},{Key=Project,Value=${project}},{Key=Role,Value=${role}},{Key=ManagedBy,Value=openg2p-aws-provision}]" \
            "ResourceType=volume,Tags=[{Key=Project,Value=${project}},{Key=Role,Value=${role}},{Key=ManagedBy,Value=openg2p-aws-provision}]" \
        --query 'Instances[0].InstanceId' --output text)
    echo "$id"
}

aws_disable_source_dest_check() {
    local id="$1"
    aws_cli ec2 modify-instance-attribute --instance-id "$id" --no-source-dest-check
}

aws_get_instance_ips() {
    local id="$1"
    # Echoes "public_ip|private_ip"
    aws_cli ec2 describe-instances --instance-ids "$id" \
        --query 'Reservations[0].Instances[0].[PublicIpAddress,PrivateIpAddress]' \
        --output text | awk '{print $1"|"$2}'
}

aws_wait_running() {
    local id="$1"
    log_info "Waiting for ${id} to reach 'running'..." >&2
    aws_cli ec2 wait instance-running --instance-ids "$id"
}

aws_wait_status_ok() {
    local id="$1"
    log_info "Waiting for ${id} status checks (this can take 2-5 min)..." >&2
    aws_cli ec2 wait instance-status-ok --instance-ids "$id"
}

aws_wait_ssh() {
    local host="$1"; local user="$2"; local key="$3"; local timeout="${4:-300}"
    log_info "Waiting for SSH on ${user}@${host}..." >&2
    local end=$(( $(date +%s) + timeout ))
    while [[ $(date +%s) -lt $end ]]; do
        if ssh -i "$key" \
                -o BatchMode=yes \
                -o StrictHostKeyChecking=accept-new \
                -o ConnectTimeout=5 \
                -o UserKnownHostsFile=/dev/null \
                "${user}@${host}" "true" 2>/dev/null; then
            return 0
        fi
        sleep 5
    done
    return 1
}

# ---------------------------------------------------------------------------
# YAML key writer — flat one-key-per-line schema (matches prod-config.yaml).
# Updates in place, or appends if key not present.
# ---------------------------------------------------------------------------
yaml_set_key() {
    local file="$1"
    local key="$2"
    local value="$3"

    # Quote the value to avoid YAML ambiguity
    local quoted="\"${value//\"/\\\"}\""

    if grep -q "^${key}:" "$file" 2>/dev/null; then
        local tmp
        tmp=$(mktemp)
        awk -v k="$key" -v v="$quoted" '
            $0 ~ "^"k":" { print k": "v; next }
            { print }
        ' "$file" > "$tmp"
        mv "$tmp" "$file"
    else
        echo "${key}: ${quoted}" >> "$file"
    fi
}
