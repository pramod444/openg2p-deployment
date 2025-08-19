#!/bin/bash

# --- Env Vars ---
# KEYCLOAK_URL=
# REALM=
# ADMIN_USER=
# ADMIN_PASSWORD=
# MASTER_REALM=

# --- Authentication: Get Admin Access Token ---
TOKEN=$(curl -s -X POST "$KEYCLOAK_URL/realms/$MASTER_REALM/protocol/openid-connect/token" \
  -H 'Content-Type: application/x-www-form-urlencoded' \
  -d "username=$ADMIN_USER" \
  -d "password=$ADMIN_PASSWORD" \
  -d 'grant_type=password' \
  -d 'client_id=admin-cli')
echo $TOKEN
TOKEN=$(echo $TOKEN | jq -r '.access_token')

if [ -z "$TOKEN" ]; then
  echo "Error: Failed to obtain access token."
  exit 1
fi

echo "Successfully obtained access token."

# --- Get All Client IDs ---
CLIENT_IDS=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/$REALM/clients" \
  -H "Authorization: Bearer $TOKEN")
echo $CLIENT_IDS
CLIENT_IDS=$(echo $CLIENT_IDS | jq -r '.[].id')

if [ -z "$CLIENT_IDS" ]; then
  echo "No clients found in realm '$REALM'."
  exit 0
fi

echo "Processing $(echo "$CLIENT_IDS" | wc -l) clients."

# --- Iterate and Delete Mappers ---
for CLIENT_ID in $CLIENT_IDS; do
  echo "Checking client ID: $CLIENT_ID"

  # Get all mappers for the current client
  MAPPERS=$(curl -s -X GET "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_ID/protocol-mappers/models" \
    -H "Authorization: Bearer $TOKEN" | jq -r '.[] | select(.name | contains("email")) | .id')

  if [ -z "$MAPPERS" ]; then
    echo "  No email mappers found."
    continue
  fi

  # Delete each identified mapper
  for MAPPER_ID in $MAPPERS; do
    echo "  Deleting mapper ID: $MAPPER_ID"
    curl -s -X DELETE "$KEYCLOAK_URL/admin/realms/$REALM/clients/$CLIENT_ID/protocol-mappers/models/$MAPPER_ID" \
      -H "Authorization: Bearer $TOKEN"

    if [ $? -eq 0 ]; then
      echo "    Mapper deleted successfully."
    else
      echo "    Error deleting mapper."
    fi
  done
done

echo "Script execution complete."
