# OpenG2P 3-Node Production Automation

> **Documentation lives in the OpenG2P GitBook**, not here. See:
> **[Three-Node Automation](https://docs.openg2p.org/operations/deployment/automation/three-node-automation)**
>
> That page covers prerequisites, configuration, the install workflow, AWS provisioning, post-install login flow, troubleshooting, manual uninstall, and the `.state/` directory.

---

Quick start for the impatient:

```bash
# (Optional) provision EC2 instances on AWS
cd aws
cp aws-config.example.yaml aws-config.yaml   # edit project + region
./openg2p-aws-provision.sh --config aws-config.yaml

# Run the orchestrator
cd ..
cp prod-config.example.yaml prod-config.yaml   # edit user preferences
./openg2p-prod.sh --probe     --config prod-config.yaml
./openg2p-prod.sh --preflight --config prod-config.yaml
./openg2p-prod.sh             --config prod-config.yaml
```

The orchestrator prints a completion summary with login URLs, both Rancher and Keycloak admin passwords, and the `cat-via-ssh` commands to fetch your Wireguard peer config and CA cert. Follow it step by step.
