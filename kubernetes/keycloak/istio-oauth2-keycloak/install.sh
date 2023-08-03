#!/usr/bin/env bash

. ../../utils/common.sh
. ../../utils/keycloak.sh

export NS=${OAUTH_PROXY_NS:-keycloak}
export REALM_NAME=${REALM_NAME:-master}
export ROOT_HOSTNAME=${OPENG2P_HOSTNAME:-openg2p.sandbox.net}
export KEYCLOAK_HOSTNAME=${KEYCLOAK_HOSTNAME:-keycloak.$ROOT_HOSTNAME}
export KIBANA_HOSTNAME=${KIBANA_HOSTNAME:-kibana.$ROOT_HOSTNAME}
export KAFKA_UI_HOSTNAME=${KAFKA_UI_HOSTNAME:-kafka.$ROOT_HOSTNAME}
export BANK1_HOSTNAME=${BANK1_HOSTNAME:-bank1.$ROOT_HOSTNAME}
export BANK2_HOSTNAME=${BANK2_HOSTNAME:-bank2.$ROOT_HOSTNAME}
export ISTIO_AUTH_CLIENT_SECRET=${ISTIO_AUTH_CLIENT_SECRET:-$(generate_random_secret)}
export OPENG2P_AUTH_CLIENT_SECRET=${OPENG2P_AUTH_CLIENT_SECRET:-$(generate_random_secret)}

kubectl -n keycloak rollout status statefulset keycloak

if [ "$CREATE_KEYCLOAK_CLIENTS" != "false" ]; then
  keycloak_admin_token=$(keycloak_get_admin_token)
  echo "Creating Keycloak Istio Client"
  keycloak_create_client "$keycloak_admin_token" "istio-auth-client" "$ISTIO_AUTH_CLIENT_SECRET" "Istio Auth Client" "true" "true"

  echo "Creating Keycloak OpenG2P Client"
  keycloak_create_client "$keycloak_admin_token" "openg2p-auth-client" "$OPENG2P_AUTH_CLIENT_SECRET" "OpenG2P Auth Client"
fi

if [ "$INSTALL_ISTIO_POLICY" != "false" ]; then
  envsubst < istio-auth.template.yaml | kubectl -n istio-system apply -f -
fi

if [ "$INSTALL_OAUTH2_PROXY" != "false" ]; then
  envsubst < oauth2-proxy-values.template.yaml | helm -n $NS upgrade --install oauth2-proxy oci://registry-1.docker.io/bitnamicharts/oauth2-proxy -f - --set configuration.clientID=istio-auth-client --set configuration.clientSecret=$ISTIO_AUTH_CLIENT_SECRET --wait $@
  envsubst < oauth2-proxy-virtualservice.template.yaml | kubectl -n $NS apply -f -
fi

