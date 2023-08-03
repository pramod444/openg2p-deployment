#!/usr/bin/env bash

. ../utils/common.sh
. ../utils/keycloak.sh

NS=minio
export REALM_NAME=${REALM_NAME:-master}
export MINIO_AUTH_CLIENT_SECRET=${MINIO_AUTH_CLIENT_SECRET:-$(generate_random_secret)}

echo Create $NS namespace
kubectl create ns $NS

if [ "$CREATE_MINIO_KEYCLOAK_CLIENT" != "false" ]; then
  keycloak_admin_token=$(keycloak_get_admin_token)
  echo "Creating Keycloak Minio Client"
  keycloak_create_client "$keycloak_admin_token" "minio-auth-client" "$MINIO_AUTH_CLIENT_SECRET" "Minio Auth Client" "false" "false" '{
    "protocol": "openid-connect",
    "protocolMapper": "oidc-role-name-mapper",
    "name": "Minio Console role remove prefix",
    "config": {
      "role": "minio_consoleAdmin",
      "new.role.name": "consoleAdmin"
    }
  }'
fi

envsubst < values-minio.template.yaml | helm -n $NS install minio oci://registry-1.docker.io/bitnamicharts/minio --wait -f - $@

if [ "$MINIO_ISTIO_ENABLED" != "false" ]; then
  export MINIO_HOSTNAME=${MINIO_HOSTNAME:-minio.openg2p.sandbox.net}
  envsubst < istio-virtualservice.template.yaml | kubectl apply -n $NS -f -
fi
