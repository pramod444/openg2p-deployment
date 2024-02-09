#!/usr/bin/env bash

export SANDBOX_HOSTNAME=${SANDBOX_HOSTNAME:-openg2p.sandbox.net}
export SOCIAL_REGISTRY_HOSTNAME=${SOCIAL_REGISTRY_HOSTNAME:-socialregistry.$SANDBOX_HOSTNAME}

NS=social-registry
VERSION=1.2.0

helm repo add openg2p https://openg2p.github.io/openg2p-helm
helm repo update

echo Create $NS namespace
kubectl create ns $NS

./copy_secrets.sh

helm -n $NS install social-registry openg2p/openg2p-social-registry \
    --version ${VERSION} \
    --set fullnameOverride=social-registry \
    --set global.hostname=$SOCIAL_REGISTRY_HOSTNAME \
    --set odoo.image.repository=${SOCIAL_REGISTRY_ODOO_IMAGE_REPO:-openg2p/openg2p-social-registry-odoo-package} \
    --set odoo.image.tag=${SOCIAL_REGISTRY_ODOO_IMAGE_TAG:-17.0-develop} \
    --wait $@
