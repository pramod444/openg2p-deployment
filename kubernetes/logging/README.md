## Logging and OpenSearch

- Refer to [Logging & OpenSearch instructions](https://docs.openg2p.org/deployment/base-infrastructure/openg2p-cluster/fluentd-and-opensearch)

- If you want to install OpenSearch seperately on your K8s cluster, it is recommended to use [Bitnami's OpenSearch helm chart](https://github.com/bitnami/charts/tree/main/bitnami/opensearch). (You can also use OpenSearch [main helm charts](https://opensearch.org/docs/latest/install-and-configure/install-opensearch/helm), but the Bitnami one is found to have better secret management, is easy to customize, and is easy to integrate Security Plugin, etc).
