# AWS provisioning

> **Documentation lives in the OpenG2P GitBook.** See the **AWS provisioning** section of:
> **[Three-Node Automation](https://docs.openg2p.org/operations/deployment/automation/three-node-automation#aws-provisioning)**
>
> That covers prerequisites (AWS CLI, IAM permissions), what gets created, default sizing, the Elastic IP best-effort behaviour, the interactive picker, security-group reuse semantics, the `provision-output.yaml` overlay, costs, and teardown.

---

Quick start:

```bash
cp aws-config.example.yaml aws-config.yaml
# edit project + region
./openg2p-aws-provision.sh --config aws-config.yaml
```

The script auto-prompts for VPC / subnet / key pair when those are blank in the config (saves your selection back so subsequent runs are non-interactive). It writes `../provision-output.yaml` for the orchestrator to consume.

Teardown (only deletes resources tagged `Project=<project>`; pre-existing keys are kept):

```bash
./openg2p-aws-destroy.sh --config aws-config.yaml
```
