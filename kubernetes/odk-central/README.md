## ODK Central

- ODK Central can now be installed directly as part of the relevant OpenG2P Module. For example, refer to [Social Registry deployment](https://docs.openg2p.org/social-registry/deployment) or [PBMS deployment](https://docs.openg2p.org/pbms/deployment).

- If you want to install ODK Central seperately on your K8s cluster, install [OpenG2P's ODK Central helm chart](../../charts/odk-central) using the following instructions:
  ```sh
  helm repo add openg2p https://openg2p.github.io/openg2p-helm
  helm repo update
  helm install odk-central openg2p/odk-central --set global.odkHostname=odk.your.org
  ```
  - Add `-n <namespace name>` to the `helm install` command, to install this in a specific namespace.
  - For the list of all helm options refer to [odk-central/values.yaml](../../charts/odk-central/values.yaml)
