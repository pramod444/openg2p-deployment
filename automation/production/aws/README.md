# OpenG2P 3-Node Production — AWS Provisioning

Bash + AWS CLI scripts that create the 3 EC2 instances and supporting AWS resources for the production deployment, then hand off to the orchestrator at `automation/production/`.

```
your laptop
    │
    │ 1. provision (this directory)
    ▼
AWS region — Project=<project> tag on every resource
    ├── 1 key pair
    ├── 3 security groups (RP, k8s-node, storage)
    ├── 1 Elastic IP (attached to RP)
    └── 3 EC2 instances (Ubuntu Server 24.04 LTS)
    │
    │ 2. orchestrator (../openg2p-prod.sh) — uses prod-config.yaml
    │    populated by step 1
    ▼
Running OpenG2P infrastructure
```

---

## Prerequisites on your laptop

- `aws` CLI v2 (`aws --version`)
- AWS credentials with permissions to manage EC2 (instances, key pairs, security groups, EIPs, tags)
- `bash`, `curl`, standard POSIX tools
- `jq` is **not** required

Quick sanity check:

```bash
aws sts get-caller-identity
aws ec2 describe-vpcs --query 'Vpcs[].[VpcId,IsDefault,CidrBlock]' --output table
```

---

## Quick start

```bash
cd automation/production/aws
cp aws-config.example.yaml aws-config.yaml
# Edit aws-config.yaml — minimum: project, region. Leave vpc_id, subnet_id,
# key_mode etc. blank to be prompted interactively (you don't need to look
# anything up in the AWS Console).
./openg2p-aws-provision.sh --config aws-config.yaml
# ~5–8 minutes. Creates resources, waits for status checks AND SSH,
# writes ../provision-output.yaml.

cd ..
cp prod-config.example.yaml prod-config.yaml
# Edit prod-config.yaml — only USER PREFERENCES (no IPs, no SSH paths)
./openg2p-prod.sh --probe     --config prod-config.yaml
./openg2p-prod.sh --preflight --config prod-config.yaml
./openg2p-prod.sh             --config prod-config.yaml
```

The orchestrator auto-loads `provision-output.yaml` next to `prod-config.yaml`. Values from `provision-output.yaml` override matching keys in `prod-config.yaml`, so the IPs/SSH paths/private_subnet/wg_endpoint flow in automatically — you never need to copy them by hand.

To tear down:

```bash
cd automation/production/aws
./openg2p-aws-destroy.sh --config aws-config.yaml
# Also removes ../provision-output.yaml (it's now stale).
```

## The two config files

| File | Purpose | Source | Loaded |
|---|---|---|---|
| `prod-config.yaml` | Your preferences — `cluster_name`, `internal_domain`, versions, `keycloak_admin_email`, `postgres_*`, `wg_subnet`, `wg_peers` | You author it | First |
| `provision-output.yaml` | AWS-derived state — IPs, SSH paths, `private_subnet`, `admin_cidr`, `wg_endpoint` | Auto-generated | Second (overrides) |

Re-running the provision script overwrites `provision-output.yaml` cleanly (with a single `.prev` archive). Your `prod-config.yaml` is never touched.

To override an AWS-derived value (rare), edit `provision-output.yaml` directly — it's plain YAML.

For a non-AWS install (any cloud, on-prem), put everything in `prod-config.yaml` and don't create `provision-output.yaml`. The orchestrator works with just `prod-config.yaml`.

---

## What the provision script does, step by step

1. **AWS credentials sanity check** (`aws sts get-caller-identity`)
2. **VPC + subnet resolution** — uses your config if set; otherwise queries AWS, auto-picks if there's exactly one match, or prompts you with a numbered menu when there are multiple. Selections are saved back to `aws-config.yaml`. `--non-interactive` makes ambiguity an error instead of a prompt.
3. **`admin_cidr` resolution** — uses your config, falls back to auto-detecting your laptop's current public IP via `checkip.amazonaws.com`
4. **AMI resolution** — auto-resolves the latest Canonical Ubuntu 24.04 LTS amd64 AMI in your region (or uses `ubuntu_ami` if set)
5. **Key pair** — if `key_mode` is set, behaves as configured. If blank: lists existing AWS key pairs with a "create new" option, lets you pick interactively, and saves your choice back to `aws-config.yaml`
6. **3 security groups** — `<project>-reverse-proxy`, `<project>-k8s-node`, `<project>-storage`. All allow SSH + ICMP from `admin_cidr` and all-traffic from VPC CIDR; the RP also opens UDP `wg_port` (default 51820) to the world
7. **1 Elastic IP** — allocated and tagged for the RP
8. **3 EC2 instances launched in parallel** — RP, compute, storage with the configured types (defaults match minimums)
9. **Wait for `running`** state on all 3
10. **Disable source/dest check on RP** (required for Wireguard packet forwarding)
11. **Associate EIP to RP**
12. **Wait for `instance-status-ok`** on all 3 (passes both system and instance status checks — this is the "VM is fully booted" signal, takes 2-5 min)
13. **Wait for SSH** (`ssh -o BatchMode=yes ubuntu@<host> true`) on all 3 — the script does **not** declare done until the orchestrator could actually SSH in
14. **Write `../provision-output.yaml`** — emits IPs, SSH host/user/key, `private_subnet`, `admin_cidr`, `wg_endpoint`, `cluster_name`. The previous output (if any) is archived as `.prev`

After step 13 the script declares done; before that, it's still waiting.

---

## Default sizing (matches OpenG2P resource minimums)

| Role | Instance type | vCPU | RAM | Root disk (gp3) |
|---|---|---|---|---|
| Reverse Proxy | `t3a.medium`   | 2  | 4 GB  | 64 GB  |
| Compute / K8s | `m5a.4xlarge`  | 16 | 64 GB | 128 GB |
| Storage       | `t3a.2xlarge`  | 8  | 32 GB | 256 GB |

All three are configurable in `aws-config.yaml` (`*_instance_type`, `*_disk_gb`, `*_disk_iops`, `*_disk_throughput`). Larger is fine; smaller may fail the orchestrator's preflight.

The storage node's 256 GB hosts both the NFS export and the host PostgreSQL data dir in v1. If you anticipate large databases, bump `storage_disk_gb` or wait for the upcoming "separate data volume" feature.

---

## Resources created (every one tagged `Project=<project>`)

| Resource | Name |
|---|---|
| Key pair | `openg2p-prod-key` (configurable) |
| Security group: RP | `<project>-reverse-proxy` |
| Security group: compute | `<project>-k8s-node` |
| Security group: storage | `<project>-storage` |
| Elastic IP | tagged `Role=reverse-proxy-eip` |
| Instance: RP | `<project>-reverse-proxy` |
| Instance: compute | `<project>-k8s-node-1` |
| Instance: storage | `<project>-storage` |

The destroy script finds everything by `Project=<project>` and tears it down.

---

## Reusing existing security groups

The script does **describe-or-create** by name in the chosen VPC. If a security group already exists with the configured name, it's reused — no new SG created. The required ingress rules are then verified one-by-one and added if missing (no rules are removed).

Three ways to drive this:

1. **Defaults** — leave `rp_sg_name` / `compute_sg_name` / `storage_sg_name` blank (or at the example values). The script creates SGs named `<project>-reverse-proxy`, `<project>-k8s-node`, `<project>-storage` on first run; reuses them on subsequent runs.
2. **Pre-created by your infra team** — set the SG name fields in `aws-config.yaml` to match the SGs they've already created. The script reuses them and adds any missing rules.
3. **Shared across installs** — point multiple OpenG2P deployments at the same SG names. They'll all share the rule set.

Per-rule status is logged so you can see what changed:
```
    + TCP/22  from 203.0.113.5/32: added
    · ICMP    from 203.0.113.5/32: already present
    · UDP/51820 (Wireguard) from 0.0.0.0/0: already present
```

## Security group rules

All three SGs allow:
- SSH (TCP 22) from `admin_cidr`
- ICMP from `admin_cidr` (ping)
- All traffic from the VPC CIDR (intra-VPC, between the 3 nodes)

The RP additionally allows:
- Wireguard (UDP 51820 by default) from `0.0.0.0/0` — the public entry point for admin VPN

The OpenG2P orchestrator configures `ufw` on each node to lock down further (e.g. NFS only from compute IP, K8s API only from VPC CIDR + WG subnet). The cloud SG is the outer perimeter; ufw is the host-level depth.

---

## Interactive selection (default)

When you leave `vpc_id`, `subnet_id`, or `key_mode` blank in `aws-config.yaml`, the script queries AWS and presents a numbered menu — no need to leave the terminal to look anything up. Example:

```
[INFO] No vpc_id in config — querying available VPCs...
[INFO] Multiple VPCs available in region ap-south-1:
  [1] vpc-0a1b2c3d4e5f67890  10.0.0.0/16 (default)
  [2] vpc-0123456789abcdef0  10.10.0.0/16 — staging
  [3] vpc-abcdef0123456789a  10.20.0.0/16 — prod
  Select [1-3] or paste VPC ID:
```

Your selection is written back to `aws-config.yaml`, so the next run is fully non-interactive.

The same applies to subnet selection and to the SSH key pair: existing AWS key pairs are listed with an "Create new" option at the top.

For CI / automation, pass `--non-interactive` and pre-fill all required values in `aws-config.yaml`. The script will fail loudly (with a list of options) on anything ambiguous instead of hanging on a prompt.

---

## `admin_cidr` — what it controls

`admin_cidr` is the only public ingress for SSH and ping. Three modes:

- Leave blank → auto-detect this laptop's public IP via `checkip.amazonaws.com` and use it as `/32` (recommended)
- Set to `"0.0.0.0/0"` → SSH/ping open to the world (acceptable for sandbox; tighten for production)
- Set to a CIDR like `"203.0.113.0/24"` → only your office/VPN range

Note: this is **independent** of the VPC choice. Putting the instances in a "private VPC" doesn't restrict public SSH; the security group does. With public IPs (which you explicitly want), `admin_cidr` is the only thing limiting who can reach SSH from the internet.

---

## Idempotency

Re-running `openg2p-aws-provision.sh` is safe:

- Existing key pair is kept (will fail if local .pem is missing — recreate or copy it back)
- Existing security groups are reused (rules are added if missing, never removed)
- Existing Elastic IP (tagged `Role=reverse-proxy-eip` for this project) is reused
- Existing instances (matched by Name + Project tag, in any non-terminated state) are reused
- Only missing resources are created

If you change instance types or disk sizes in `aws-config.yaml`, the existing instances are NOT modified. Destroy and recreate them, or do the modifications manually via `aws ec2 modify-instance-attribute`.

---

## Costs (rough, us-east-1, on-demand, April 2025)

| Item | $/hour | $/month (730 h) |
|---|---|---|
| `t3a.medium`     | $0.0376 | ~$27  |
| `m5a.4xlarge`    | $0.688  | ~$502 |
| `t3a.2xlarge`    | $0.301  | ~$220 |
| EIP (attached)   | free    | $0    |
| EIP (released-but-unattached) | $0.005 | ~$3.65 |
| EBS gp3 storage  | $0.08/GB-month | 64+128+256 = 448 GB → ~$36 |
| **Total**        |         | **~$785/month** if running 24/7 |

Stop instances when not using them to drop the EC2 charges to near-zero (you still pay for EBS). Note: stopping releases dynamic public IPs but keeps the EIP attached to the (stopped) RP, so the WG endpoint survives a stop/start.

---

## Files

```
automation/production/aws/
├── aws-config.example.yaml         # template — copy to aws-config.yaml
├── openg2p-aws-provision.sh        # creates everything
├── openg2p-aws-destroy.sh          # tears it down
├── lib/aws-utils.sh                # AMI/VPC/SG/key/EIP helpers
├── keys/                           # auto-saved .pem files (gitignored)
└── logs/                           # provision + destroy logs (gitignored)
```

---

## Troubleshooting

**"VPC not found" / "No default VPC in this region"**
Some accounts have no default VPC. Either create one (`aws ec2 create-default-vpc`), or set `vpc_id` and `subnet_id` explicitly in `aws-config.yaml`, or pass `--interactive` and pick from a list.

**"Could not auto-detect public IP"**
Your laptop's egress can't reach `checkip.amazonaws.com`. Set `admin_cidr` explicitly.

**"Key pair exists in AWS but .pem is missing locally"**
AWS doesn't let you re-download a key pair after creation. Either copy the .pem back to the configured path, or delete the AWS key pair (`aws ec2 delete-key-pair --key-name <name>`) and re-run provision to recreate.

**Instance status checks pass but SSH still fails**
Sometimes happens on first boot of new images. The script waits up to 5 minutes for SSH; if it times out, try `ssh -i keys/<name>.pem ubuntu@<public-ip>` manually after another minute or two.

**Destroy script: "Could not delete security group — lingering ENI dependencies"**
Usually means an instance hasn't fully terminated yet, or there's a lingering ENI. Wait 30 seconds and re-run destroy. If persistent: `aws ec2 describe-network-interfaces --filters Name=group-id,Values=<sg-id>`.

**You changed `admin_cidr` and re-ran provision — old rule is still there**
The provision script never removes existing rules (idempotent ADD only). Remove the old CIDR manually:
```
aws ec2 revoke-security-group-ingress --group-id <sg-id> --ip-permissions ...
```

**Multiple environments on the same AWS account**
Use a different `project:` value for each (e.g. `openg2p-prod`, `openg2p-staging`). Resources are isolated by tag and by name. The destroy script only touches `Project=<project>` so they don't interfere.
