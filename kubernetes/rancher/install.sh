#!/usr/bin/env bash

export RANCHER_HOSTNAME=${RANCHER_HOSTNAME:-rancher.openg2p.net}
export KEYCLOAK_HOSTNAME=${KEYCLOAK_HOSTNAME:-keycloak.openg2p.net}
export NS=${NS:-cattle-system}

kubectl create ns $NS

helm repo add rancher-latest https://releases.rancher.com/server-charts/latest
helm repo update

helm -n $NS upgrade --install rancher rancher-latest/rancher \
    --set ingress.enabled=false --set tls=external

helm -n $NS upgrade --install keycloak oci://registry-1.docker.io/bitnamicharts/keycloak \
    -f keycloak-values.yaml

envsubst < istio-virtualservice.template.yaml | kubectl -n $NS apply -f -
