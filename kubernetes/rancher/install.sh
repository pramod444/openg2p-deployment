#!/usr/bin/env bash

export RANCHER_HOSTNAME=${RANCHER_HOSTNAME:-rancher.openg2p.net}
export RANCHER_ISTIO_GATEWAY=${RANCHER_ISTIO_GATEWAY:-true}
export RANCHER_ISTIO_VIRTUALSERVICE=${RANCHER_ISTIO_VIRTUALSERVICE:-true}
export RANCHER_GATEWAY_NAME=${RANCHER_GATEWAY_NAME:-rancher}
export NS=${NS:-cattle-system}

kubectl create ns $NS

helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update

helm -n $NS upgrade --install rancher rancher-latest/rancher \
    --set ingress.enabled=false \
    --set tls=external \
    $@

if [[ "$RANCHER_ISTIO_GATEWAY" == "true" ]]; then
    envsubst < istio-gateway.template.yaml | kubectl -n $NS apply -f -
fi

if [[ "$RANCHER_ISTIO_VIRTUALSERVICE" == "true" ]]; then
    envsubst < istio-virtualservice.template.yaml | kubectl -n $NS apply -f -
fi
