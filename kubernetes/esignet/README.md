# eSignet

eSignet can now be installed directly as part of the respective OpenG2P Module. For example, refer to [Social Registry deployment](https://docs.openg2p.org/social-registry/deployment) or [PBMS deployment](https://docs.openg2p.org/pbms/deployment).

Source code for [OpenG2P eSignet](../../charts/esignet) helm chart.

This installs eSignet along with all the required dependencies like SoftHSM, MOSIP's Artifactory (to pull jars & artifacts), PostgreSQL, etc.
This installs Mock Identity System and eSignet's OIDC UI modules also.

Each of these dependencies can be disabled by setting the appropriate helm value. (Note: This doesn't install config server, it directly allows properties to be downloaded from git repos. See Parameters section below.)

This helm chart is a fork of [MOSIP eSignet](https://github.com/mosip/esignet/tree/master/helm) helm chart, and applies additional modifications to make it easier to install eSignet seperately.

## Standalone Installation

This section describes steps to install eSignet on your K8s cluster, if not installing as part of OpenG2P Module.

### Using Rancher

- Add OpenG2P to Rancher Apps Repositories, with name like `openg2p-extras` and Url as `https://openg2p.github.io/openg2p-helm`.
- Select namespace in which you want to install eSignet, from namespace filter on the top-right.
- Navigate to Rancher Menu -> Apps -> Charts. Refresh and search for eSignet and select it.
- Enable _Customize Helm options before install_ checkbox on _Metadata_ step, and choose any installation name, for example `esignet` and click _Next_.
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
  helm install esignet openg2p/esignet
  ```

This supports using any name for the installation. This can be installed on any namespace. Namespace can be given using `-n` argument.

Some pods may fail and restart a few times initially. But they should come up on their own in 5-10mins.

## Post Installation

To access esignet APIs:
- Create an OIDC client in Keycloak.
- Create a client scope "esignet_admin_access" in Keycloak and mark this client scope to be "Included in token scope".
- Assign this client scope as a "default" scope to the above client.
- Get the client token using client_credentials grant type, and pass it as Bearer token to the required eSignet admin apis.

## Parameters

The following are some of the basic parameters that can be passed to the above helm during installation. (Can be  added as arguments using `--set`. Or can be passed by yaml file using `-f values.yaml`).

For advanced config values refer to [esignet/values.yaml](../../charts/esignet/values.yaml).

|Name|Description|Default value|
|-|-|-|
|global.esignetHostname|Hostname to access eSignet|esignet.sandbox.your.org|
|keycloakBaseUrl|Keycloak base url, to enable Auth JWTs from this particular Keycloak|https://keycloak.your.org|
|springConfig.profile|Spring Config Profile|default|
|springConfig.gitRepo.repoUrl|Git Repo Url to get configs. (Username & password have to added in this url, if required)|https://github.com/openg2p/mosip-config|
|springConfig.gitRepo.branch|Git Repo Branch to get configs.|master|
