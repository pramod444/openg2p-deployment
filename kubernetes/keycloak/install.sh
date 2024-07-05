#!/usr/bin/env bash

export KEYCLOAK_HOSTNAME=${KEYCLOAK_HOSTNAME:-keycloak.openg2p.net}
export KEYCLOAK_ISTIO_GATEWAY=${KEYCLOAK_ISTIO_GATEWAY:-true}
export KEYCLOAK_ISTIO_VIRTUALSERVICE=${KEYCLOAK_ISTIO_VIRTUALSERVICE:-true}
export KEYCLOAK_GATEWAY_NAME=${KEYCLOAK_GATEWAY_NAME:-keycloak}
export NS=${NS:-keycloak-system}

kubectl create ns $NS

helm -n $NS upgrade --install keycloak oci://registry-1.docker.io/bitnamicharts/keycloak \
    -f values-keycloak.yaml \
    $@

if [[ "$KEYCLOAK_ISTIO_GATEWAY" == "true" ]]; then
    envsubst < istio-gateway.template.yaml | kubectl -n $NS apply -f -
fi

if [[ "$KEYCLOAK_ISTIO_VIRTUALSERVICE" == "true" ]]; then
    envsubst < istio-virtualservice.template.yaml | kubectl -n $NS apply -f -
fi
