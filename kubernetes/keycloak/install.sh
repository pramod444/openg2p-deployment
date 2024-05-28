#!/usr/bin/env bash

export KEYCLOAK_HOSTNAME=${KEYCLOAK_HOSTNAME:-keycloak.openg2p.net}
export KEYCLOAK_ISTIO_OPERATOR=${KEYCLOAK_ISTIO_OPERATOR:-true}
export TLS=${TLS:-false}
export NS=${NS:-keycloak-system}

kubectl create ns $NS

helm -n $NS upgrade --install keycloak oci://registry-1.docker.io/bitnamicharts/keycloak \
    -f values-keycloak.yaml \
    $@

if [[ "$KEYCLOAK_ISTIO_OPERATOR" == "true" ]]; then
    kubectl apply -f istio-operator.yaml
fi

if [[ "$TLS" == "true" ]]; then
    envsubst < istio-virtualservice-tls.template.yaml | kubectl -n $NS apply -f -
else
    envsubst < istio-virtualservice.template.yaml | kubectl -n $NS apply -f -
fi
