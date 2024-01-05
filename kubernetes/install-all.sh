#!/usr/bin/env bash

export ROOT_DIR=${ROOT_DIR:-$(pwd)}

declare -a components=(
    "postgresql"
    "keycloak"
    "kafka"
    "logging"
    "minio"
    "openg2p"
    "odk-central"
    # "g2p-cash-transfer-bridge"
    # "social-payments-account-registry"
)

for i in "${components[@]}"; do
    cd "$ROOT_DIR/$i"
    ./install.sh
done
