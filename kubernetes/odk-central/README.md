# ODK Central

ODK Central can now be installed directly as part of the respective OpenG2P Module. For example, refer to [Social Registry deployment](https://docs.openg2p.org/social-registry/deployment) or [PBMS deployment](https://docs.openg2p.org/pbms/deployment).

Source code for OpenG2P [ODK Central](../../charts/odk-central) helm chart.
This installs ODK Central along with all the required dependencies.

## Standalone Installation

This section describes steps to install ODK Central on your K8s cluster, if not installing as part of OpenG2P Modules.

### Using Rancher

- Add OpenG2P to Rancher Apps Repositories, with name like `openg2p-extras` and Url as `https://openg2p.github.io/openg2p-helm`.
- Navigate to Rancher Menu -> Apps -> Charts. Refresh and search for ODK Central and select it.
- Configure appropriate options and select namespace when prompted.
- Click "Install" to finalize configurations and install.

### Using helm

- Add openg2p helm repo
  ```sh
  helm repo add openg2p https://openg2p.github.io/openg2p-helm
  helm repo update
  ```
- Install ODK Central.
  ```sh
  helm install odk-central openg2p/odk-central
  ```

This supports installation on any namespace. Namespace can be given using `-n` argument.

## Parameters

The following are some of the basic parameters that can be passed to the above helm during installation. (Can be  added as arguments using `--set`. Or can be passed by yaml file using `-f values.yaml`).

For advanced config values refer to [odk-central/values.yaml](../../charts/odk-central/values.yaml).

|Name|Description|Default value|
|-|-|-|
|hostname|Hostname to access ODK Central|odk.sandbox.your.org|
|backend.envVars.OIDC_ISSUER_URL|OIDC Issuer URL|https://keycloak.your.org/realms/master|
|backend.envVars.OIDC_CLIENT_ID|OIDC Client ID||
|backend.envVars.OIDC_CLIENT_SECRET|OIDC Client Secret||
