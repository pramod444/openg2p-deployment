#!/usr/bin/env bash

function keycloak_get_admin_token(){
  keycloak_admin_secret=$(kubectl -n keycloak get secret keycloak -o jsonpath={.data.admin-password} | base64 --decode)
  kubectl -n keycloak exec -it keycloak-0 -- curl -d "client_id=admin-cli" -d "username=admin" -d "password=${keycloak_admin_secret}" -d "grant_type=password" "http://keycloak.keycloak/realms/master/protocol/openid-connect/token" | jq -r '.access_token'
}

function keycloak_import_realm(){
  auth_token="$1"
  realm_json="$2"
  kubectl -n keycloak exec -it keycloak-0 -- curl -H "content-type: application/json" -H "Authorization: Bearer ${auth_token}" "http://keycloak.keycloak/admin/realms" -d "${realm_json}"
}

function keycloak_create_client(){
  auth_token="$1"
  client_id="$2"
  client_secret="$3"
  client_name="$4"
  public_client="${5:-false}"
  direct_access_grants="${6:-false}"
  extra_mappers="$7"

  if ! [ -z "$extra_mappers" ]; then extra_mappers=",$extra_mappers"; fi

  kubectl -n keycloak exec -it keycloak-0 -- curl -H "content-type: application/json" -H "Authorization: Bearer ${auth_token}" "http://keycloak.keycloak/admin/realms/$REALM_NAME/clients" \
    -d '{
      "clientId": "'"$client_id"'",
      "name": "'"$client_name"'",
      "secret": "'"$client_secret"'",
      "redirectUris": [
        "*"
      ],
      "protocol": "openid-connect",
      "implicitFlowEnabled": false,
      "directAccessGrantsEnabled": '"$direct_access_grants"',
      "authorizationServicesEnabled": false,
      "serviceAccountsEnabled": false,
      "standardFlowEnabled": true,
      "publicClient": '"$public_client"',
      "protocolMappers": [
        {
          "name": "email",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-usermodel-property-mapper",
          "consentRequired": false,
          "config": {
            "userinfo.token.claim": "true",
            "user.attribute": "email",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "claim.name": "email",
            "jsonType.label": "String"
          }
        },
        {
          "name": "groups",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-usermodel-realm-role-mapper",
          "consentRequired": false,
          "config": {
            "multivalued": "true",
            "id.token.claim": "true",
            "access.token.claim": "true",
            "claim.name": "groups",
            "jsonType.label": "String"
          }
        },
        {
          "name": "Client ID Audience",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-audience-mapper",
          "config": {
            "included.client.audience": "'"$client_id"'",
            "included.custom.audience": "",
            "id.token.claim": "true",
            "access.token.claim": "true"
          }
        }
        '"$extra_mappers"'
      ]
    }'; echo
}
