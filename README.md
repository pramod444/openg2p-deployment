# OpenG2P Deployment

This repository contains instructions and scripts to deploy OpenG2P on Kubernetes
infrastructure. Refer to [OpenG2P Docs](https://docs.openg2p.org/v/1.1) for detailed
installation instructions.

## Automation

| Path | Purpose |
|------|---------|
| [`automation/production/`](automation/production/) | 3-node production (RP + compute + storage). See its [README](automation/production/README.md). |
| [`automation/environment/`](automation/environment/) | Optional scripted Commons / environment install. See its [README](automation/environment/README.md). |
| [`automation/single-node/`](automation/single-node/) | Single-node sandbox / PoC automation. |

Production scaffolding does **not** install Commons; use the Rancher UI
(recommended) or `automation/environment/` after the production env stage.

## License

This repository is licensed under [MPL-2.0](LICENSE).
