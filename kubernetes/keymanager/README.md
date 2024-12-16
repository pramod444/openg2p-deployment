# Keymanager

Keymanager can now be installed directly as part of the respective OpenG2P Module.
For example, refer to [Social Registry deployment](https://docs.openg2p.org/social-registry/deployment) or [PBMS deployment](https://docs.openg2p.org/pbms/deployment).

Source code for [OpenG2P Keymanager](../../charts/keymanager) helm chart.

- Note: Helm chart versions 12.0.1 and lower install all dependencies of keymanager along with them. Versions 12.0.2 and higher do NOT install dependencies. The installation of dependencies is left to the user.
- Note: This doesn't require config-server, it directly allows properties to be downloaded from git repos. (See Parameters section below.)

This helm chart is a fork of [MOSIP Keymanager](https://github.com/mosip/mosip-helm/tree/master/charts/keymanager) helm chart, and applies additional modifications to make it easier to install Keymanager  (or with OpenG2P modules).

## Standalone Installation

This section describes steps to install Keymanager on your K8s cluster, if not installing as part of OpenG2P Module.

### Prerequisites

- Install postgresql with name like _keymanager-postgresql_ (Recommended: Use bitnami/postgresql helm chart.)
- Install softhsm with name like _keymanager-softhsm_ (Recommended: Use mosip/softhsm helm chart.)
- Install Artifactory with name like _keymanager-artifactory_ (Recommended: Use openg2p/artifactory helm chart.)

### Using Rancher

- Add OpenG2P to Rancher Apps Repositories, with name like `openg2p-extras` and Url as `https://openg2p.github.io/openg2p-helm`.
- Select namespace in which you want to install Keymanager, from namespace filter on the top-right.
- Navigate to Rancher Menu -> Apps -> Charts. Refresh and search for Keymanager and select it.
- Enable _Customize Helm options before install_ checkbox on _Metadata_ step, and choose any installation name, for example `keymanager` and click _Next_.
- Configure whatever is required in the _Values_ step and click _Next_.
- Disable _Wait_ checkbox on _Helm Options_ step, and click _Install_.

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

## Post Installation

To access keymanager APIs create an OIDC client in Keycloak. Also create a role "KEYMANAGER_ADMIN" and assign this role to service account of the client. (This means that the app, example Social Registry, with the client creds is given permission to access the keymanager APIs. Not the user.)

## Parameters

The following are some of the basic parameters that can be passed to the above helm during installation. (Can be  added as arguments using `--set`. Or can be passed by yaml file using `-f values.yaml`).

For advanced config values refer to [keymanager/values.yaml](../../charts/keymanager/values.yaml).

|Name|Description|Default value|
|-|-|-|
|hostname|Hostname to access keymanager|keymanager.sandbox.your.org|
|keycloakBaseUrl|Keycloak base url, to enable Auth JWTs from this particular Keycloak|https://keycloak.your.org|
|springConfig.profile|Spring Config Profile|default|
|springConfig.gitRepo.repoUrl|Git Repo Url to get configs. (Username & password have to added in this url, if required)|https://github.com/openg2p/mosip-config|
|springConfig.gitRepo.branch|Git Repo Branch to get configs.|master|
