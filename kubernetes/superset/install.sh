#!/usr/bin/env bash

. ../utils/common.sh

export SANDBOX_HOSTNAME=${SANDBOX_HOSTNAME:-openg2p.sandbox.net}
export KEYCLOAK_HOSTNAME=${KEYCLOAK_HOSTNAME:-keycloak.$SANDBOX_HOSTNAME}
export SUPERSET_HOSTNAME=${SUPERSET_HOSTNAME:-superset.$SANDBOX_HOSTNAME}
export KEYCLOAK_REALM_NAME=${KEYCLOAK_REALM_NAME:-openg2p}
export SUPERSET_SECRET_KEY=$(generate_random_secret)

helm repo add superset https://apache.github.io/superset
helm repo update

COPY_UTIL=../utils/copy_cm_func.sh
NS=superset

echo Create $NS namespace
kubectl create ns $NS

$COPY_UTIL secret keycloak-client-secrets keycloak $NS

envsubst < values-superset.template.yaml | helm -n $NS upgrade --install superset superset/superset --version 0.11.2 --wait $@ -f -

envsubst < istio-virtualservice.template.yaml | kubectl -n $NS apply -f -