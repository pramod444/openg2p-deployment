#!/usr/bin/env bash

export KEYCLOAK_REALM_NAME=${KEYCLOAK_REALM_NAME:-openg2p}
export OPENG2P_MINIO_CLIENT_SECRET=$(kubectl -n $NS get secret keycloak-client-secrets -o jsonpath={.data.openg2p_minio_client_secret} | base64 --decode)
export SANDBOX_HOSTNAME=${SANDBOX_HOSTNAME:-openg2p.sandbox.net}
export MINIO_HOSTNAME=${MINIO_HOSTNAME:-minio.$SANDBOX_HOSTNAME}

NS=minio

echo Create $NS namespace
kubectl create ns $NS

envsubst < values-minio.template.yaml | helm -n $NS install minio oci://registry-1.docker.io/bitnamicharts/minio --version 12.12.2 --wait $@ -f -

if [ "$MINIO_ISTIO_ENABLED" != "false" ]; then
  envsubst < istio-virtualservice.template.yaml | kubectl apply -n $NS -f -
fi
