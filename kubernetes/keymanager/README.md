# Keymanager

Keymanager can now be installed directly as part of the respective OpenG2P Module.
For example, refer to [Social Registry deployment](https://docs.openg2p.org/social-registry/deployment) or [PBMS deployment](https://docs.openg2p.org/pbms/deployment).

Source code for [OpenG2P Keymanager](../../charts/keymanager) helm chart.

- Note: Helm chart versions 12.0.1 and lower install all dependencies of keymanager along with them. Versions 12.0.2 and higher do NOT install dependencies. The installation of dependencies is left to the user.
- Note: This doesn't require config-server, it directly allows properties to be downloaded from git repos. (See Parameters section below.)
- Note: Helm chart versions 12.1.0 and higher allow to configure which type of keystore you want (PKCS11/PKCS12).
  - Earlier versions keystore type was fixed to PKCS11 (HSM).
  - PKCS12 type keystore requires persistence enabled on the helm chart.
  - For Helm chart versions >=12.1.0 default keystore type is PKCS12. See [Parameters](#parameters) section for changing keystore type to PKCS11.
  - Direct upgrade from PKCS11 keystore to PKCS12 keystore will NOT be possible.

This helm chart is a fork of [MOSIP Keymanager](https://github.com/mosip/mosip-helm/tree/master/charts/keymanager) helm chart, and applies additional modifications to make it easier to install Keymanager  (or with OpenG2P modules).

## Standalone Installation

This section describes steps to install Keymanager on your K8s cluster, if not installing as part of OpenG2P Module.

### Prerequisites

- Install postgresql with name like _keymanager-postgresql_ (Recommended: Use bitnami/postgresql helm chart.)
- Install softhsm with name like _keymanager-softhsm_ (Recommended: Use mosip/softhsm helm chart.)
  - Required only when `keystoreType=PKCS11`.
- Install Artifactory with name like _keymanager-artifactory_ (Recommended: Use openg2p/artifactory helm chart.)
  - Required only when `keystoreType=PKCS11` and `authEnabled=true`.

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
|keystoreType|Type of keystore to use.<br>- PKCS11 requires HSM(or softhsm).<br>- PKCS12 stores the keys into a local p12 file. Persistence should be enabled.|PKCS12|
|p12KeystorePass|Password for the P12 file when using `keystoreType=PKCS12`.<br>If left blank, password will be automatically generated||
|authEnabled|Enable authentication for Keymanager APIs.<br>Disable only when Keymanager APIs are not exposed publicly or when using as an internal service.|true|
|keygen.appIdsList|List of [Module keys](https://docs.mosip.io/1.2.0/id-lifecycle-management/supporting-services/keymanager#key-hierarchy) (APP_ID) to be generated when Keymanager starts.|\["OPENG2P"\]|
|keygen.baseKeysList|List of [Base keys](https://docs.mosip.io/1.2.0/id-lifecycle-management/supporting-services/keymanager#key-hierarchy) (APP_ID:REF_ID) to be generated when Keymanager starts.|\["OPENG2P:ENCRYPT"\]|
|persistence.enabled|Enable persistence for storing Keys. Required only when using `keystoreType=PKCS12`|true|
|persistence.storageClassName|Name of storage class of persistent volume||
|persistence.accessModes|List of persistent volume access modes.<br>This will need to be changed when using `replicas>1`|\["ReadWriteOnce"\]|
|persistence.size|Size of volume required for storing keys|10M|
