#!/usr/bin/env bash

export KIBANA_HOSTNAME=${KIBANA_HOSTNAME:-kibana.${SANDBOX_HOSTNAME:-openg2p.sandbox.net}}

NS=cattle-logging-system

echo Create $NS namespace
kubectl create ns $NS

helm -n $NS install elasticsearch oci://registry-1.docker.io/bitnamicharts/elasticsearch --version 19.13.14 --wait -f es-values.yaml $@

if [ "$KIBANA_ISTIO_ENABLED" != "false" ]; then
  envsubst < istio-virtualservice.template.yaml | kubectl apply -n $NS -f -
fi
