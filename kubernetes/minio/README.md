## Install Minio on OpenG2P Cluster

- Run the following commands from the current directory to install minio, on openg2p cluster.
  ```sh
  helm repo add bitnami https://charts.bitnami.com/bitnami
  helm repo update
  kubectl create ns minio
  helm -n minio install minio bitnami/minio -f values-minio.yaml
  ```
- Navigate to OpenG2P Documents (From OpenG2P Menu), then to Document Store. Configure URL and password for this backend service. Pasword and account-id/username can be obtained from the secrets in minio namespace.