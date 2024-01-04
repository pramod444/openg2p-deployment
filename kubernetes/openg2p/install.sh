#!/usr/bin/env bash

export SANDBOX_HOSTNAME=${SANDBOX_HOSTNAME:-openg2p.sandbox.net}
export OPENG2P_MAILNAME=${OPENG2P_MAILNAME:-${SANDBOX_HOSTNAME}}
export OPENG2P_HOSTNAME=${OPENG2P_HOSTNAME:-${SANDBOX_HOSTNAME}}
export OPENG2P_SELFSERVICE_HOSTNAME=${OPENG2P_SELFSERVICE_HOSTNAME:-selfservice.${SANDBOX_HOSTNAME}}
export OPENG2P_SERVICEPROV_HOSTNAME=${OPENG2P_SERVICEPROV_HOSTNAME:-serviceprovider.${SANDBOX_HOSTNAME}}

NS=openg2p

helm repo add openg2p https://openg2p.github.io/openg2p-helm
helm repo update

echo Create $NS namespace
kubectl create ns $NS

./copy_secrets.sh

helm -n $NS install openg2p openg2p/openg2p \
    --set global.hostname=$OPENG2P_HOSTNAME \
    --set global.mailName=$OPENG2P_MAILNAME \
    --set global.selfServiceHostname=$OPENG2P_SELFSERVICE_HOSTNAME \
    --set global.serviceProviderHostname=$OPENG2P_SERVICEPROV_HOSTNAME \
    --set odoo.image.repository= ${OPENG2P_ODOO_IMAGE_REPO:-openg2p/openg2p-odoo-package}\
    --set odoo.image.tag= ${OPENG2P_ODOO_IMAGE_TAG:-15.0-develop}\
    --wait \
    $@
