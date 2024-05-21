#!/usr/bin/env bash

export RANCHER_HOSTNAME=${RANCHER_HOSTNAME:-rancher.openg2p.net}
export TLS=${TLS:-false}
export ISTIO_OPERATOR=${ISTIO_OPERATOR:-true}
export NS=${NS:-cattle-system}

kubectl create ns $NS

helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update

helm -n $NS upgrade --install rancher rancher-latest/rancher \
    --set ingress.enabled=false \
    --set tls=external

if [[ "$ISTIO_OPERATOR" == "true" ]]; then
    kubectl apply -f base-istio-operator.yaml
    kubectl apply -f istio-operator.yaml
fi

if [[ "$TLS" == "true" ]]; then
    envsubst < istio-virtualservice-tls.template.yaml | kubectl -n $NS apply -f -
else
    envsubst < istio-virtualservice.template.yaml | kubectl -n $NS apply -f -
fi
