# Keymanager

Keymanager can now be installed directly as part of the respective OpenG2P Module. For example, refer to [Social Registry deployment](https://docs.openg2p.org/social-registry/deployment) or [PBMS deployment](https://docs.openg2p.org/pbms/deployment).

Source code for [OpenG2P Keymanager](../../charts/keymanager) helm chart.
This installs Keymanager along with all the required dependencies like SoftHSM, MOSIP's Artifactory (to pull jars & artifacts), PostgreSQL, etc. Each of these dependencies can be disabled by setting the appropriate helm value. (Note: This doesn't install config server, it directly allows properties to be downloaded from git repos. See Parameters section below.)

This helm chart is a fork of [MOSIP Keymanager](https://github.com/mosip/mosip-helm/tree/master/charts/keymanager) helm chart, and applies additional modifications to make it easier to install Keymanager seperately.

## Standalone Installation

This section describes steps to install Keymanager on your K8s cluster, if not installing as part of OpenG2P Module.

### Using Rancher

- Add OpenG2P to Rancher Apps Repositories, with name like `openg2p-extras` and Url as `https://openg2p.github.io/openg2p-helm`.
- Navigate to Rancher Menu -> Apps -> Charts. Refresh and search for Keymanager and select it.
- Configure appropriate options and select namespace when prompted.
- Click "Install" to finalize configurations and install.

### Using helm

- Add openg2p helm repo
  ```sh
  helm repo add openg2p https://openg2p.github.io/openg2p-helm
  helm repo update
  ```
- Install Keymanager.
  ```sh
  helm install keymanager openg2p/keymanager
  ```

This supports installation on any namespace. Namespace can be given using `-n` argument.

Keymanager pod may fail and restart a few times initially. But it should come up by itself in 5-10mins.

## Parameters

The following are some of the basic parameters that can be passed to the above helm during installation. (Can be  added as arguments using `--set`. Or can be passed by yaml file using `-f values.yaml`).

For advanced config values refer to [keymanager/values.yaml](../../charts/keymanager/values.yaml).

|Name|Description|Default value|
|-|-|-|
|global.keymanagerHostname|Hostname to access keymanager|keymanager.sandbox.your.org|
|keycloakBaseUrl|Keycloak base url, to enable Auth JWTs from this particular Keycloak|https://keycloak.your.org|
|springConfig.profile|Spring Config Profile|default|
|springConfig.gitRepo.repoUrl|Git Repo Url to get configs. (Username & password have to added in this url, if required)|https://github.com/openg2p/mosip-config|
|springConfig.gitRepo.branch|Git Repo Branch to get configs.|develop3-v3|
