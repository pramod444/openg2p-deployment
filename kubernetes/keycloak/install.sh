#!/usr/bin/env bash

export KEYCLOAK_HOSTNAME=${KEYCLOAK_HOSTNAME:-keycloak.openg2p.net}
export TLS=${TLS:-false}
export ISTIO_OPERATOR=${ISTIO_OPERATOR:-true}
export NS=${NS:-keycloak-system}

kubectl create ns $NS

helm -n $NS upgrade --install keycloak oci://registry-1.docker.io/bitnamicharts/keycloak \
    -f values-keycloak.yaml

if [[ "$ISTIO_OPERATOR" == "true" ]]; then
    kubectl apply -f base-istio-operator.yaml
    kubectl apply -f istio-operator.yaml
fi

if [[ "$TLS" == "true" ]]; then
    envsubst < istio-virtualservice-tls.template.yaml | kubectl -n $NS apply -f -
else
    envsubst < istio-virtualservice.template.yaml | kubectl -n $NS apply -f -
fi
