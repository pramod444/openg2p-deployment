#!/usr/bin/env bash

export KEYCLOAK_HOSTNAME=${KEYCLOAK_HOSTNAME:-keycloak.${SANDBOX_HOSTNAME:-openg2p.sandbox.net}}
export KEYCLOAK_REALM_NAME=${KEYCLOAK_REALM_NAME:-openg2p}

. ../utils/keycloak.sh

NS=keycloak

helm repo add mosip https://mosip.github.io/mosip-helm
helm repo update

echo Create $NS namespace
kubectl create ns $NS

./copy_secrets.sh

# previous version used 14.2.0.
helm -n $NS install keycloak oci://registry-1.docker.io/bitnamicharts/keycloak --version 18.0.0 -f values.yaml --wait $@

if [ "$KEYCLOAK_ISTIO_ENABLED" != "false" ]; then
  envsubst < istio-virtualservice.template.yaml | kubectl apply -n $NS -f -
fi

if [ "$KEYCLOAK_INIT_ENABLED" != "false" ]; then
  helm -n $NS install keycloak-init mosip/keycloak-init --version 12.0.2 -f values-init.yaml --wait $@

  export OPENG2P_ADMIN_CLIENT_SECRET=$(kubectl -n $NS get secret -o jsonpath={.data.openg2p_admin_client_secret} | base64 --decode)
  export OPENG2P_SELFSERVICE_CLIENT_SECRET=$(kubectl -n $NS get secret -o jsonpath={.data.openg2p_selfservice_client_secret} | base64 --decode)
  export OPENG2P_SERVICEPROVIDER_CLIENT_SECRET=$(kubectl -n $NS get secret -o jsonpath={.data.openg2p_serviceprovider_client_secret} | base64 --decode)
  export OPENG2P_MINIO_CLIENT_SECRET=$(kubectl -n $NS get secret -o jsonpath={.data.openg2p_minio_client_secret} | base64 --decode)
  export OPENG2P_KAFKA_CLIENT_SECRET=$(kubectl -n $NS get secret -o jsonpath={.data.openg2p_kafka_client_secret} | base64 --decode)
  export OPENG2P_KIBANA_CLIENT_SECRET=$(kubectl -n $NS get secret -o jsonpath={.data.openg2p_kibana_client_secret} | base64 --decode)

  keycloak_import_realm \
    "$(keycloak_get_admin_token)" \
    "$(envsubst \
      '${KEYCLOAK_HOSTNAME}
      ${OPENG2P_ADMIN_CLIENT_SECRET}
      ${OPENG2P_SELFSERVICE_CLIENT_SECRET}
      ${OPENG2P_SERVICEPROVIDER_CLIENT_SECRET}
      ${OPENG2P_MINIO_CLIENT_SECRET}
      ${OPENG2P_KAFKA_CLIENT_SECRET}
      ${OPENG2P_KIBANA_CLIENT_SECRET}' < ${KEYCLOAK_REALM_NAME}-realm.json)"
fi
