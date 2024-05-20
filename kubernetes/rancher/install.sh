#!/usr/bin/env bash

export RANCHER_HOSTNAME=${RANCHER_HOSTNAME:-rancher.openg2p.net}
export KEYCLOAK_HOSTNAME=${KEYCLOAK_HOSTNAME:-keycloak.openg2p.net}
export NS=${NS:-cattle-system}

kubectl create ns $NS

helm -n $NS install rancher https://releases.rancher.com/server-charts/latest/rancher \
    --set ingress.enabled=false

helm -n $NS install keycloak oci://registry-1.docker.io/bitnamicharts/keycloak \
    -f keycloak-values.yaml

envsubst < istio-virtualservice.yaml | kubectl -n $NS apply -f -
