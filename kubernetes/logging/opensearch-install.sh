#!/usr/bin/env bash

. ../utils/common.sh

export NS=${NS:-}
export OPENSEARCH_HOSTNAME=${OPENSEARCH_HOSTNAME:-}
export OPENSEARCH_CLIENT_ID=${OPENSEARCH_CLIENT_ID:-}
export OPENSEARCH_CLIENT_SECRET=${OPENSEARCH_CLIENT_SECRET:-}
export KEYCLOAK_ISSUER_URL=${KEYCLOAK_ISSUER_URL:-https://keycloak.openg2p.org/realms/master}
export KEYCLOAK_ISSUER_URL=${KEYCLOAK_ISSUER_URL%*/}

export OPENSEARCH_DASHBOARDS_PASSWORD=${OPENSEARCH_DASHBOARDS_PASSWORD:-}

if [ -z "$OPENSEARCH_DASHBOARDS_PASSWORD" ]; then
  export OPENSEARCH_DASHBOARDS_PASSWORD=$(kubectl -n $NS get secret opensearch -o jsonpath={.data.opensearch-dashboards-password} 2> /dev/null)
  if [ -z "$OPENSEARCH_DASHBOARDS_PASSWORD" ]; then
    export OPENSEARCH_DASHBOARDS_PASSWORD=$(generate_random_secret)
  else
    export OPENSEARCH_DASHBOARDS_PASSWORD=$(echo $OPENSEARCH_DASHBOARDS_PASSWORD | base64 --decode)
  fi
fi

# TODO: Perform ENV Var checks

envsubst < opensearch-dashboards.template.yml > /tmp/opensearch_dashboards.yml
envsubst < opensearch-security-config.template.yml > /tmp/opensearch-security-config.yml

kubectl -n $NS delete cm opensearch-conf-files --ignore-not-found
kubectl -n $NS create cm opensearch-conf-files \
  --from-file=/tmp/opensearch-security-config.yml \
  --from-file=/tmp/opensearch_dashboards.yml

helm -n $NS upgrade --install \
  opensearch \
  oci://registry-1.docker.io/bitnamicharts/opensearch \
  --version 1.2.0 \
  --set dashboards.password=$OPENSEARCH_DASHBOARDS_PASSWORD \
  -f opensearch-values.yml \
  --wait \
  $@

if [ "$OPENSEARCH_ISTIO_ENABLED" != "false" ]; then
  envsubst < opensearch-istio-vs.template.yml | kubectl -n $NS apply -f -
fi

if [ "$OPENSEARCH_LOGGING_ENABLED" != "false" ]; then
  envsubst < opensearch-logging-output.yml | kubectl -n $NS apply -f -
fi
