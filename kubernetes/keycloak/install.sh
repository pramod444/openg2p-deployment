#!/usr/bin/env bash

NS=keycloak

echo Create $NS namespace
kubectl create ns $NS

./copy_secrets.sh

helm -n $NS install keycloak oci://registry-1.docker.io/bitnamicharts/keycloak --version 14.2.0 -f values.yaml --wait $@

if [ "$KEYCLOAK_ISTIO_ENABLED" != "false" ]; then
  export KEYCLOAK_HOSTNAME=${KEYCLOAK_HOSTNAME:-keycloak.openg2p.sandbox.net}
  envsubst < istio-virtualservice.template.yaml | kubectl apply -n $NS -f -
fi

if [ "$INSTALL_ISTIO_AUTH" != "false" ]; then
  cd istio-oauth2-keycloak && ./install.sh
fi
