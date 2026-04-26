# OpenG2P 3-Node Production Infrastructure

Automated end-to-end setup of OpenG2P's 3-node production architecture, driven from your laptop.

```
                  ┌─── Wireguard ────┐
   admin laptop  ───────────────────▶  Reverse Proxy node
                                       (Wireguard server, dnsmasq,
                                        local CA, Nginx)
                                              │ HTTP (private subnet)
                                              ▼
                                       Compute node
                                       (RKE2, Istio, Rancher,
                                        Keycloak, monitoring)
                                              │
                                  ┌───────────┴──────────┐
                                  │ NFS                  │ Postgres
                                  ▼                      ▼
                                 Storage node — NFS server, host PostgreSQL
                                              (PG installed but unused; for env automation)
```

Admin tools (Rancher, Keycloak) are reachable **only via Wireguard**, on hostnames under an internal domain (default `*.openg2p.internal`). Public domains and customer-supplied certs are deferred to environment automation — they are not required to install the infrastructure.

---

## Prerequisites

| | Reverse Proxy | Compute | Storage |
|---|---|---|---|
| **OS** | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS | Ubuntu 24.04 LTS |
| **vCPU / RAM / disk** | 2 / 4 GB / 64 GB | 16 / 64 GB / 128 GB | 8 / 32 GB / 256 GB |
| **Network** | Public IP for Wireguard | Private IP only | Private IP only |
| **All three** | On the same private subnet, internet egress, root/sudo SSH access from your laptop | | |

Your laptop needs: bash, ssh, rsync. Nothing else.

If you're on AWS and want the 3 VMs created for you, see [`aws/README.md`](aws/README.md). The `aws/` scripts provision the EC2 instances + supporting resources, then write the IPs/SSH details into `prod-config.yaml` for the orchestrator below.

---

## One-time setup

```bash
cd automation/production
cp prod-config.example.yaml prod-config.yaml
# Edit prod-config.yaml — preferences only (cluster_name, internal_domain,
# keycloak_admin_email, versions). For a non-AWS install also fill in IPs,
# SSH paths, and private_subnet. AWS users skip those — see aws/ for the
# provisioning that fills them automatically into provision-output.yaml.
./openg2p-prod.sh --probe     --config prod-config.yaml  # SSH + sudo to all 3 nodes
./openg2p-prod.sh --preflight --config prod-config.yaml  # CPU/RAM/disk/internet/IP checks
./openg2p-prod.sh             --config prod-config.yaml  # run everything end-to-end
```

Total runtime: 25–40 minutes. Idempotent — re-run on failure to resume.

## Two configuration files (one for you, one for your provisioning)

The orchestrator loads two flat YAML files and merges them:

| File | Source | Contains | Load order |
|---|---|---|---|
| `prod-config.yaml` | You author it | preferences: `cluster_name`, `internal_domain`, `keycloak_admin_email`, `wg_subnet/port/peers`, `rke2_version`, `rancher_version`, `postgres_*`, `nfs_*`, `ssh_jump_via_rp` | First |
| `provision-output.yaml` | Auto-written by `aws/openg2p-aws-provision.sh` | provisioning state: `*_public_ip`, `*_private_ip`, `*_ssh_host`, `*_ssh_key`, `private_subnet`, `admin_cidr`, `wg_endpoint`, `cluster_name` | Second — **overrides matches** |

The orchestrator auto-detects `provision-output.yaml` next to your `--config` file. Pass `--provision-output <path>` to override.

For a non-AWS install (any other cloud, on-prem), put everything in `prod-config.yaml` and skip `provision-output.yaml` — the orchestrator works fine with just one file.

The `[USER]` and `[AWS]` tags in `prod-config.example.yaml` mark which keys come from where.

## Preflight checks (built-in)

Before any installation work starts, the orchestrator runs `lib/shared/preflight.sh` on all 3 nodes in parallel and aggregates results. **Hard fail** on any of:

| Check | RP | Compute | Storage |
|---|---|---|---|
| OS = Ubuntu 24.04 LTS+ | ✓ | ✓ | ✓ |
| CPU vCPU minimum | 2 | 16 | 8 |
| RAM minimum (10% slack) | 4 GB | 64 GB | 32 GB |
| Disk on `/` (20% slack) | 64 GB | 128 GB | 256 GB |
| Internet egress (`get.rke2.io`) | ✓ | ✓ | ✓ |
| Configured `*_private_ip` actually bound on the host | ✓ | ✓ | ✓ |

**Warn-only** (won't block install): rotational/HDD detected, port already in use, inter-node TCP-22 reachability over the private subnet.

The orchestrator also sanity-checks the config itself: `private_subnet` and `wg_subnet` must not overlap, and each `*_private_ip` must fall inside `private_subnet`.

Skip with `--skip-preflight` only when re-running on validated nodes (e.g. after a partial failure).

---

## Phase order when run end-to-end

| # | Where | What |
|---|---|---|
| 0 | Laptop | SSH + sudo probe on all 3 nodes |
| 0 | All 3 nodes | Preflight: OS, CPU, RAM, disk, internet, IP-matches-config (parallel) |
| 1 | Storage | apt basics, ufw, NFS server export, host PostgreSQL install (no app DBs yet) |
| 2 | Compute | apt basics, kubectl/helm/istioctl/helmfile, ufw, NFS client mount, RKE2 server, NFS CSI default StorageClass |
| 3 | Reverse Proxy | apt basics, ufw, Wireguard server + peer configs, dnsmasq, local CA + wildcard cert, Nginx server blocks |
| 4 | Compute | helmfile sync — Istio, Rancher, Keycloak (with embedded NFS-backed Postgres), monitoring, logging |
| 5 | Compute | Rancher-Keycloak SAML integration |

State markers live on each node at `/var/lib/openg2p/deploy-state/*.done`. Laptop-side state is at `./.state/orchestrator/*.done`.

---

## Common command shapes

```bash
# Run only one role end-to-end
./openg2p-prod.sh --config prod-config.yaml --role storage
./openg2p-prod.sh --config prod-config.yaml --role compute
./openg2p-prod.sh --config prod-config.yaml --role rp

# Re-run a single phase on a single role (e.g. compute helmfile sync)
./openg2p-prod.sh --config prod-config.yaml --role compute --phase 2

# Force re-run completed steps
./openg2p-prod.sh --config prod-config.yaml --force

# Probe SSH only — no changes
./openg2p-prod.sh --config prod-config.yaml --probe

# Reset laptop-side orchestrator state (does not touch the nodes)
./openg2p-prod.sh --reset-laptop
```

---

## Post-install steps on your laptop

After the orchestrator finishes you'll see a summary with the exact `scp` commands. The three things you do once:

### 1. Wireguard peer config

```bash
scp -i <your-key> <user>@<rp-public-ip>:/etc/wireguard/peers/peer1/peer1.conf .
```

Import into the [Wireguard client app](https://www.wireguard.com/install/) and activate the tunnel. The peer config includes the RP's WG IP as DNS server, so `*.openg2p.internal` resolves automatically while connected.

### 2. Trust the local CA certificate

```bash
scp -i <your-key> <user>@<rp-public-ip>:/etc/openg2p/ca/ca.crt .
```

| OS | Install command |
|---|---|
| macOS | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt` |
| Linux | `sudo cp ca.crt /usr/local/share/ca-certificates/openg2p-ca.crt && sudo update-ca-certificates` |
| Windows | Import via `certmgr.msc` into "Trusted Root Certification Authorities" |

### 3. (Optional) kubectl access

Compute node generates a remote-access kubeconfig:

```bash
scp -i <your-key> <user>@<compute-private-ip>:/etc/rancher/rke2/rke2-remote.yaml ~/.kube/openg2p-prod
export KUBECONFIG=~/.kube/openg2p-prod
kubectl get nodes
```

Requires the Wireguard tunnel to be up (the K8s API listens on the private IP).

---

## Logging in to Rancher

After Wireguard is connected and the CA is trusted:

1. Open `https://rancher.openg2p.internal` (or whatever you set `internal_domain` to).
2. Click **Login with Keycloak**.
3. Username = the email configured at `keycloak_admin_email` in `prod-config.yaml`.
4. Password lives in a Kubernetes secret — fetch it from the compute node:

```bash
kubectl -n keycloak-system get secret keycloak \
  -o jsonpath='{.data.admin-password}' | base64 -d && echo
```

Local Rancher admin (fallback):

```bash
kubectl -n cattle-system get secret rancher-secret \
  -o jsonpath='{.data.adminPassword}' | base64 -d && echo
```

---

## File structure

```
automation/production/
├── openg2p-prod.sh                    # Laptop orchestrator
├── prod-config.example.yaml           # Single config file (flat YAML)
├── helmfile-infra.yaml.gotmpl         # Platform helmfile (Istio EnvoyFilter, Rancher, Keycloak,
│                                       monitoring, logging, Gateways)
├── lib/
│   ├── ssh-utils.sh                   # ControlMaster SSH, rsync push/pull, optional ProxyJump
│   └── shared/
│       ├── utils.sh                   # Vendored from single-node — logging, state, config loader
│       ├── preflight.sh               # Per-node OS/CPU/RAM/disk/internet/IP checks
│       ├── hostnames.sh               # Hostname helpers + config-key bridge
│       └── phase3.sh                  # Vendored — Rancher-Keycloak SAML
├── charts/
│   ├── raw/                           # Minimal chart for applying K8s manifests
│   └── istio-install/                 # Istio operator config
├── aws/                                # Optional — provisions 3 EC2 instances + supporting resources
│   ├── aws-config.example.yaml
│   ├── openg2p-aws-provision.sh       # Creates EC2 + writes prod-config.yaml
│   ├── openg2p-aws-destroy.sh         # Tears down by Project tag
│   ├── lib/aws-utils.sh
│   ├── keys/                          # Auto-saved .pem files (gitignored)
│   └── README.md
└── roles/
    ├── reverse-proxy/
    │   ├── run.sh
    │   └── phase1.sh                  # Wireguard, dnsmasq, local CA, Nginx
    ├── compute/
    │   ├── run.sh
    │   ├── phase1.sh                  # apt+tools, ufw, NFS client, RKE2, NFS CSI
    │   └── phase2.sh                  # Istio + helmfile sync
    └── storage/
        ├── run.sh
        └── phase1.sh                  # apt+tools, ufw, NFS server, host PostgreSQL
```

---

## What this script does NOT do (yet)

These are deferred to follow-up work, not gaps:

- **Environment automation** — no `prod`, `staging`, `qa` namespaces created. The host-installed PostgreSQL on the storage node sits idle until env automation lands and creates per-environment databases on per-environment ports.
- **Customer public domains and certs** — admin tools live entirely under `*.openg2p.internal` with self-signed certs. Customer-supplied per-FQDN certs (mixed formats: PEM, PFX, etc.) are an env-automation concern.
- **Local Docker registry** — RKE2 pulls images from upstream. A local pull-through cache will come in a later phase.
- **Local Git** — deferred.
- **Air-gap / offline operation** — initial install requires internet. Self-contained operation is a later phase.
- **Backup node** — out of scope for v1.
- **Domain migration script** — single-node has one (`openg2p-migrate-domain.sh`); will be ported when env automation arrives.

---

## Troubleshooting

**Probe fails on a node.**
The orchestrator checks SSH and passwordless sudo. Make sure `sudo -n true` works for the user listed in your config (`/etc/sudoers.d/openg2p` is the convention: `<user> ALL=(ALL) NOPASSWD:ALL`).

**Storage role fails at PostgreSQL step.**
Ubuntu 24.04 ships PG16 by default — the script assumes that. If you've installed a different major version, set `postgres_version` in your config to match what `dpkg -l | grep postgresql-` reports.

**Compute helmfile sync hangs / errors out.**
SSH into the compute node and check pod status:

```bash
sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl get pods -A | grep -v Running
sudo KUBECONFIG=/etc/rancher/rke2/rke2.yaml kubectl get events -A --sort-by=.lastTimestamp | tail -30
```

Re-run `./openg2p-prod.sh --config prod-config.yaml --role compute --phase 2` to retry — completed releases are skipped by helmfile, only the failing one is reattempted.

**Wireguard connects but `*.openg2p.internal` doesn't resolve.**

- macOS: `dig` bypasses the resolver. Test with `dscacheutil -q host -a name rancher.openg2p.internal` instead.
- For reliable per-domain DNS on macOS:
  ```
  sudo mkdir -p /etc/resolver
  echo "nameserver <wg-server-ip>" | sudo tee /etc/resolver/openg2p.internal
  ```
  (`<wg-server-ip>` is `10.15.0.1` if you kept the default `wg_subnet`.)

**Browser cert warning even after trusting CA.**
Either the CA wasn't trusted at the system level (must be system keychain on macOS, not user) or you opened the page before trust took effect — restart the browser.

---

## Uninstall

Per-node uninstall scripts are not included in v1. Manual cleanup:

- Compute: `sudo /usr/local/bin/rke2-uninstall.sh && rm -rf /etc/openg2p /var/lib/openg2p`
- Storage: `apt purge -y postgresql nfs-kernel-server && rm -rf /etc/openg2p /var/lib/openg2p /srv/nfs`
- RP: `apt purge -y wireguard-tools dnsmasq nginx && rm -rf /etc/openg2p /etc/wireguard /var/lib/openg2p`

State markers under `/var/lib/openg2p/deploy-state/` on each node make incremental re-installs safe; full uninstall scripts will be added when the environment automation work lands.
