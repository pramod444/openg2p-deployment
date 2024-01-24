#!/usr/bin/env bash

export SANDBOX_HOSTNAME=${SANDBOX_HOSTNAME:-openg2p.sandbox.net}
export KEYCLOAK_HOSTNAME=${KEYCLOAK_HOSTNAME:-keycloak.$SANDBOX_HOSTNAME}
export KEYCLOAK_REALM_NAME=${KEYCLOAK_REALM_NAME:-openg2p}

. ../utils/keycloak.sh

NS=keycloak

echo Create $NS namespace
kubectl create ns $NS

./copy_secrets.sh

# previous version used 14.2.0.
helm -n $NS install keycloak oci://registry-1.docker.io/bitnamicharts/keycloak --version 18.0.0 -f values.yaml --wait $@

kubectl -n $NS create cm keycloak-host \
  --from-literal=keycloak-internal-host=keycloak.$NS \
  --from-literal=keycloak-internal-url=http://keycloak.$NS \
  --from-literal=keycloak-external-host=$KEYCLOAK_HOSTNAME \
  --from-literal=keycloak-external-url=https://$KEYCLOAK_HOSTNAME

if [ "$KEYCLOAK_ISTIO_ENABLED" != "false" ]; then
  envsubst < istio-virtualservice.template.yaml | kubectl apply -n $NS -f -
fi

if [ "$KEYCLOAK_INIT_ENABLED" != "false" ]; then
  helm -n $NS install keycloak-init ./keycloak-init --wait $@

  export OPENG2P_ADMIN_CLIENT_SECRET=$(kubectl -n $NS get secret keycloak-client-secrets -o jsonpath={.data.openg2p_admin_client_secret} | base64 --decode)
  export OPENG2P_SELFSERVICE_CLIENT_SECRET=$(kubectl -n $NS get secret keycloak-client-secrets -o jsonpath={.data.openg2p_selfservice_client_secret} | base64 --decode)
  export OPENG2P_SERVICEPROVIDER_CLIENT_SECRET=$(kubectl -n $NS get secret keycloak-client-secrets -o jsonpath={.data.openg2p_serviceprovider_client_secret} | base64 --decode)
  export OPENG2P_MINIO_CLIENT_SECRET=$(kubectl -n $NS get secret keycloak-client-secrets -o jsonpath={.data.openg2p_minio_client_secret} | base64 --decode)
  export OPENG2P_KAFKA_CLIENT_SECRET=$(kubectl -n $NS get secret keycloak-client-secrets -o jsonpath={.data.openg2p_kafka_client_secret} | base64 --decode)
  export OPENG2P_OPENSEARCH_CLIENT_SECRET=$(kubectl -n $NS get secret keycloak-client-secrets -o jsonpath={.data.openg2p_opensearch_client_secret} | base64 --decode)
  export OPENG2P_SUPERSET_CLIENT_SECRET=$(kubectl -n $NS get secret keycloak-client-secrets -o jsonpath={.data.openg2p_superset_client_secret} | base64 --decode)

  envsubst \
    '${KEYCLOAK_HOSTNAME}
    ${OPENG2P_ADMIN_CLIENT_SECRET}
    ${OPENG2P_SELFSERVICE_CLIENT_SECRET}
    ${OPENG2P_SERVICEPROVIDER_CLIENT_SECRET}
    ${OPENG2P_MINIO_CLIENT_SECRET}
    ${OPENG2P_KAFKA_CLIENT_SECRET}
    ${OPENG2P_OPENSEARCH_CLIENT_SECRET}
    ${OPENG2P_SUPERSET_CIENT_SECRET}' < ${KEYCLOAK_REALM_NAME}-realm.json > /tmp/${KEYCLOAK_REALM_NAME}-realm.json

  keycloak_import_realm \
    "$(keycloak_get_admin_token)" \
    "/tmp/${KEYCLOAK_REALM_NAME}-realm.json"
fi
