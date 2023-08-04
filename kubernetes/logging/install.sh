#!/usr/bin/env bash

NS=cattle-logging-system

echo Create $NS namespace
kubectl create ns $NS

helm -n $NS install elasticsearch oci://registry-1.docker.io/bitnamicharts/elasticsearch --wait -f es-values.yaml $@

if [ "$KIBANA_ISTIO_ENABLED" != "false" ]; then
  export KIBANA_HOSTNAME=${KIBANA_HOSTNAME:-kibana.openg2p.sandbox.net}
  envsubst < istio-virtualservice.template.yaml | kubectl apply -n $NS -f -
fi
