# OpenG2P — Add / Remove Node

Automation for joining a new Ubuntu 24.04 node to an **existing** OpenG2P RKE2 cluster (and removing one).

This complements `automation/single-node/` — you deploy the cluster first with that, then use these scripts to scale out.

```
automation/add-node/
├── README.md                          ← this file
├── openg2p-add-node.sh                ← run on the NEW node
├── openg2p-remove-node.sh             ← run on the PRIMARY
├── add-node-config.example.yaml       ← copy → add-node-config.yaml, edit, pass with --config
└── lib/
    ├── utils.sh                       ← logging, state markers, yaml loader
    └── add-node-steps.sh              ← the 5 steps that do the work
```

---

## When to use what

| You want to… | Run | Where |
|---|---|---|
| Add a worker (data-plane) node | `openg2p-add-node.sh` | On the new node |
| Add another control-plane (HA) node | `openg2p-add-node.sh` with `--role server` | On the new node |
| Remove a node from the cluster | `openg2p-remove-node.sh` | On the primary |

---

## Prerequisites

**On the new node:**
- Ubuntu 24.04 LTS
- Root / sudo access
- TCP reachability to the primary's port **9345** (RKE2 supervisor)

**You'll need from the primary:**
- Its private IP (for `server_url`)
- The RKE2 join token:
  ```bash
  sudo cat /var/lib/rancher/rke2/server/node-token
  ```

---

## Usage — Adding a node

**1.** SSH into the new node, clone this repo (or copy `automation/add-node/` to it).

**2.** Copy and edit the config:
```bash
cd automation/add-node
cp add-node-config.example.yaml add-node-config.yaml
vi add-node-config.yaml
```

Minimum fields to fill:
- `server_url` — e.g. `https://10.0.0.5:9345`
- `rke2_token` — the full token from the primary (`K10...`)
- `node_ip` — this node's private IP
- `node_name` — e.g. `node2` (must be unique in the cluster)
- `node_role` — `server` or `worker` (or leave blank to be prompted)
- `rke2_version` — must match the primary (check: `rke2 --version` on primary)

**3.** Run:
```bash
sudo ./openg2p-add-node.sh --config add-node-config.yaml
```

It runs 5 idempotent steps:

| Step | What |
|------|------|
| 1 | Validate config + probe `server_url:9345` over TCP |
| 2 | Install apt basics (+ `kubectl` if `node_role: server`) |
| 3 | Configure `ufw` (SSH public; K8s/etcd/kubelet/etc. scoped to VPC) |
| 4 | `curl get.rke2.io \| sh -` with `INSTALL_RKE2_TYPE=server|agent`, write `/etc/rancher/rke2/config.yaml` with `server:` + `token:`, start the systemd unit |
| 5 | Verify — server nodes wait for Ready locally; agents verify via `systemctl is-active` and ask you to confirm from the primary |

**4.** Read the post-install guide:
```bash
cat /root/openg2p-add-node-postinstall.txt
```
It walks you through optional follow-up (Nginx upstream update, ingress HA labeling).

---

## Usage — Removing a node

On the **primary** (not the node being removed):
```bash
cd automation/add-node
sudo ./openg2p-remove-node.sh --node node2
```

It runs: `kubectl cordon` → `kubectl drain` (`--ignore-daemonsets --delete-emptydir-data`) → `kubectl delete node`.

Then it **prints** the on-node cleanup commands — SSH to the removed node and run them manually (rke2-killall.sh, rke2-uninstall.sh, `rm -rf` state dirs, optional `ufw --force reset`). On-node cleanup automation is a future task.

**Safety:** the script refuses to remove the last control-plane node.

---

## What this script does **not** do

These are primary-node concerns and stay there:

- **Wireguard server** — VPN lives on the primary only; VPN peers reach all nodes via overlay/VPC routing.
- **dnsmasq / local DNS** — primary only.
- **NFS server** — primary runs the server; this node only installs `nfs-common` so pods can mount PVCs.
- **TLS certs / Nginx / Rancher / Keycloak / Istio / Helmfile** — all managed on the primary during initial install.

All this script does is prepare the OS and join RKE2 — application/ingress layers are already deployed cluster-wide.

---

## Ingress gateway on additional nodes — important

By default, `istio-ingressgateway` is pinned to the primary via:

```yaml
# automation/single-node/charts/istio-install/templates/operator.yaml
nodeSelector:
  shouldInstallIstioIngress: "true"
hpaSpec:
  minReplicas: 2
```

In single-node, both replicas land on the primary (only labeled node) → pods exist for redundancy but not true HA.

If you want ingress to also run on the new node:

1. **Add pod anti-affinity** to the operator config (so the 2 replicas actually spread across nodes — without this, both can still pile on one node). See `/root/openg2p-add-node-postinstall.txt` for the exact YAML to add.
2. **Re-apply the helmfile** on the primary:
   ```bash
   cd automation/single-node
   helmfile -f helmfile-infra.yaml.gotmpl apply
   ```
3. **Label the new node** (from the primary):
   ```bash
   kubectl label node <node-name> shouldInstallIstioIngress=true
   ```
4. **Update Nginx upstream** on the primary to add `server <new-node-ip>:30080;` inside the `upstream istio_ingress { ... }` block, then `nginx -t && systemctl reload nginx`.

Skipping this is fine — your new node can happily run app pods while ingress stays pinned to the primary. NodePort routing forwards client traffic from primary → worker pods transparently.

---

## Manual fallback (if you don't want to run the script)

The whole script is ~5 shell commands. If you're diagnosing a failure mid-run or prefer to do it by hand:

```bash
# 1. Basics
apt-get update && apt-get install -y curl wget jq openssl dnsutils nfs-common ufw

# 2. Firewall (replace 10.0.0.0/16 with your VPC and 10.15.0.0/16 with wireguard subnet)
ufw --force reset
ufw default deny incoming && ufw default allow outgoing
ufw allow 22/tcp
for p in 6443 9345 10250 2379 2380 9796 2049; do
    ufw allow from 10.0.0.0/16 to any port $p proto tcp
done
ufw allow from 10.0.0.0/16 to any port 30000:32767 proto tcp
ufw allow from 10.0.0.0/16 to any port 8472 proto udp
ufw allow from 10.0.0.0/16 proto icmp
ufw allow from 10.15.0.0/16
ufw --force enable

# 3. inotify tuning
sysctl -w fs.inotify.max_user_watches=524288
sysctl -w fs.inotify.max_user_instances=1024

# 4. RKE2 config — change "agent" to "server" to join as control-plane
mkdir -p /etc/rancher/rke2
cat > /etc/rancher/rke2/config.yaml <<EOF
server: https://<PRIMARY-IP>:9345
token: <TOKEN-FROM-PRIMARY>
node-name: <THIS-NODE-NAME>
node-ip: <THIS-NODE-IP>
kubelet-arg:
  - --container-log-max-size=50Mi
  - --container-log-max-files=5
EOF

# 5. Install + start (type=agent for worker, type=server for control-plane)
curl -sfL https://get.rke2.io | INSTALL_RKE2_VERSION=v1.33.6+rke2r1 INSTALL_RKE2_TYPE=agent sh -
systemctl enable --now rke2-agent   # or rke2-server

# 6. Verify from the primary:
kubectl get nodes -o wide
```

---

## Troubleshooting

**Script fails at step 1 "Cannot reach `<host>:9345`"**
→ Firewall on the primary is blocking port 9345 from this node's IP. Check primary's `ufw status` — the VPC CIDR rule must cover this node.

**`rke2-agent` starts but node never appears in `kubectl get nodes`**
→ Token mismatch or version mismatch. Check `journalctl -u rke2-agent -n 100` on this node. Common causes:
  - Wrong/stale token (re-read from primary)
  - `rke2_version` doesn't match the primary
  - Clock skew (run `timedatectl` on both)

**Re-running the script after a failure**
→ It's idempotent via markers in `/var/lib/openg2p/deploy-state/`. Failed step gets retried on next run. Nuke everything with `sudo ./openg2p-add-node.sh --reset`.

**Joined wrong cluster / need to start over**
→ `sudo /usr/local/bin/rke2-uninstall.sh` (destroys all RKE2 state on this node), then re-run.


## Specifics
Our wireguard subnet
10.11.0.1/32
node1 with control plane: 172.29.2.4	
