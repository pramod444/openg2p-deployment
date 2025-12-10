#!/usr/bin/env bash
export KEYCLOAK_BASE_URL=${KEYCLOAK_BASE_URL:-http://localhost:8080}
export KEYCLOAK_REALM=${KEYCLOAK_REALM:-master}
export KEYCLOAK_ADMIN_AUTH_REALM=${KEYCLOAK_ADMIN_AUTH_REALM:-master}
export KEYCLOAK_ADMIN_USERNAME=${KEYCLOAK_ADMIN_USERNAME:-admin}
export KEYCLOAK_ADMIN_PASSWORD=${KEYCLOAK_ADMIN_PASSWORD:-admin}
export KEYCLOAK_ADMIN_CLIENT_ID=${KEYCLOAK_ADMIN_CLIENT_ID:-admin-cli}
export CONFIG_JSON_FILE_PATH=${CONFIG_JSON_FILE_PATH:-config.template.json}
export CLIENT_JSON_FILE_PATH=${CLIENT_JSON_FILE_PATH:-client.template.json}
export SA_PREFIX=${SA_PREFIX:-service-account-}

# Fetch admin token
ADMIN_TOKEN=$(curl -s \
    -d "client_id=${KEYCLOAK_ADMIN_CLIENT_ID}" \
    -d "username=${KEYCLOAK_ADMIN_USERNAME}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
    -d "grant_type=password" \
    "${KEYCLOAK_BASE_URL}/realms/${KEYCLOAK_ADMIN_AUTH_REALM}/protocol/openid-connect/token" | jq -r '.access_token')

if [ -z "$ADMIN_TOKEN" ] || [ "$ADMIN_TOKEN" == "null" ]; then
    echo "Failed to retrieve admin token."
    exit 1
fi

envsubst < ${CONFIG_JSON_FILE_PATH} > /tmp/config.json

realm_roles_list=$(jq -cr '.realm_roles | .[]' /tmp/config.json)

for role in ${realm_roles_list}; do
    curl -s \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -d "{\"name\":\"${role}\"}" \
        "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/roles"
    echo
done
realm_roles_list=$(curl -s \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer ${ADMIN_TOKEN}" \
    "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/roles" | jq -cj '.')

client_scope_list=$(jq -cr '.client_scopes | keys | .[]' /tmp/config.json)

for client_scope in ${client_scope_list}; do
    scope_in_token=$(jq -cj ".client_scopes.${client_scope}.include_in_token_scope? // false" /tmp/config.json)
    curl -s \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        -d "{\"name\":\"${client_scope}\",\"type\":\"none\",\"protocol\":\"openid-connect\",\"attributes\":{\"display.on.consent.screen\":\"true\",\"include.in.token.scope\":\"${scope_in_token}\"}}" \
        "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/client-scopes"
    echo
done

client_id_lists=$(jq -cr '.clients | keys | .[]' /tmp/config.json)

for client_id in ${client_id_lists}; do
    export client_id=${client_id}
    export client_name=$(jq -cj ".clients.${client_id}.name" /tmp/config.json)
    export client_secret=$(jq -cj ".clients.${client_id}.secret" /tmp/config.json)
    export client_addl_default_scopes=$(jq -cj '[(.clients.'"${client_id}"'.addl_default_scopes // []) | .[] | ("\""+.+"\"") ] | join(",")' /tmp/config.json)
    if [ -n "$client_addl_default_scopes" ]; then
        export client_addl_default_scopes="${client_addl_default_scopes},"
    fi
    export client_addl_optional_scopes=$(jq -cj '[(.clients.'"${client_id}"'.addl_optional_scopes // []) | .[] | ("\""+.+"\"") ] | join(",")' /tmp/config.json)
    if [ -n "$client_addl_optional_scopes" ]; then
        export client_addl_optional_scopes="${client_addl_optional_scopes},"
    fi
    envsubst < ${CLIENT_JSON_FILE_PATH} > /tmp/client.json

    # Create a client in Keycloak using the JSON file
    curl -s \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        --data-binary @/tmp/client.json \
        "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/clients"
    echo
    client_uuid=$(curl -s \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${client_id}" | jq -cj '.[0].id')
    sa_userid=$(curl -s \
        -H "Authorization: Bearer ${ADMIN_TOKEN}" \
        "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${client_uuid}/service-account-user" | jq -cj '.id')

    sa_roles=$(jq -cj ".clients.${client_id}.sa_roles? // []" /tmp/config.json)
    if [ "${sa_roles}" != "[]" ]; then
        sa_roles=$(echo "{\"sa_roles\":${sa_roles},\"roles_list\":${realm_roles_list}}" | jq -cr '[. as $root | .sa_roles[] | . as $role | $root.roles_list[] | select(.name==$role)]')
        curl -s \
            -H "Content-Type: application/json" \
            -H "Authorization: Bearer ${ADMIN_TOKEN}" \
            -d "${sa_roles}" \
            "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/users/${sa_userid}/role-mappings/realm"
        echo
    fi

    client_roles_list=$(jq -cj ".clients.${client_id}.roles? // []" /tmp/config.json)
    if [ "${client_roles_list}" != "[]" ]; then
        client_roles=$(echo $client_roles_list | jq -cr '.[]')
        for role in $client_roles; do
            curl -s \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer ${ADMIN_TOKEN}" \
                -d "{\"name\":\"${role}\",\"clientRole\":true}" \
                "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/clients/${client_uuid}/roles"
            echo
        done
    fi
done
