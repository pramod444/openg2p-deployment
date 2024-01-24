## Logging and OpenSearch

## Install OpenSearch (and related components)

- Run this to install OpenSearch and related components.
  ```sh
  SANDBOX_HOSTNAME="openg2p.sandbox.net" ./install.sh
  ```

## Install Rancher Logging (Fluentd)

1. On Rancher UI, navigate to Apps (or Apps & Marketplace) -> Charts
1. Search and install Logging from the list, with default values.

## Add _Index State Policy_ to OpenSearch

- Run this to add ISM Policy (This is responsible for automatically deleting logstash indices after 3 days. Configure the minimum age to delete indices, in the same script below.)
  ```sh
  ./opensearch-ism-script.sh
  ```

## Configure Rancher FluentD

- Run this to create _ClusterOutput_ (This is responsible for redirecting all logs to OpenSearch.)
  ```sh
  kubectl apply -f clusterflow-opensearch.yaml
  ```
- Run this to create a _ClusterFlow_ (This is responsible for filtering OpenG2P service logs, from the logs of all pods.)
  ```sh
  kubectl apply -f clusterflow-all.yaml
  ```

## Filters
Note the filters applied in [clusterflow-all.yaml](clusterflow-all.yaml). You may update the same for your install if required, and rerun the apply command.

## Dashboards

- TODO

## TraceId

- TODO

## Troubleshooting
- TODO
