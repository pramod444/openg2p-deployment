#!/usr/bin/env bash

. ../utils/common.sh

export SANDBOX_HOSTNAME=${SANDBOX_HOSTNAME:-openg2p.sandbox.net}
export OPENSEARCH_HOSTNAME=${OPENSEARCH_HOSTNAME:-opensearch.$SANDBOX_HOSTNAME}

NS=cattle-logging-system
COPY_UTIL=../utils/copy_cm_func.sh

echo Create $NS namespace
kubectl create ns $NS

$COPY_UTIL secret keycloak-client-secrets keycloak $NS

export OPENSEARCH_CLIENT_SECRET=$(kubectl -n $NS get secret keycloak-client-secrets -o jsonpath={.data.openg2p_opensearch_client_secret} | base64 --decode)

export OPENSEARCH_DASHBOARDS_PASSWORD=$(kubectl -n $NS get secret opensearch -o jsonpath={.data.opensearch-dashboards-password} | base64 --decode)
if [ -z "$OPENSEARCH_DASHBOARDS_PASSWORD" ]; then
  export OPENSEARCH_DASHBOARDS_PASSWORD=$(generate_random_secret)
fi

envsubst < opensearch-dashboards.template.yml > /tmp/opensearch_dashboards.yml

kubectl -n $NS delete cm opensearch-conf-files --ignore-not-found
kubectl -n $NS create cm opensearch-conf-files \
  --from-file=opensearch-security-config.yml \
  --from-file=/tmp/opensearch_dashboards.yml

helm -n $NS upgrade --install \
  opensearch \
  oci://registry-1.docker.io/bitnamicharts/opensearch \
  --version 0.8.0 \
  --wait \
  --set dashboards.password=$OPENSEARCH_DASHBOARDS_PASSWORD \
  $@ \
  -f values-os.yaml

if [ "$OPENSEARCH_ISTIO_ENABLED" != "false" ]; then
  envsubst < istio-virtualservice.template.yaml | kubectl apply -n $NS -f -
fi
