#!/usr/bin/env bash

NS=openg2p

helm repo add openg2p https://openg2p.github.io/openg2p-helm
helm repo update

echo Create $NS namespace
kubectl create ns $NS

./copy_secrets.sh

HELM_ARGS=""
if ! [ -z "$OPENG2P_HOSTNAME" ]; then
    HELM_ARGS="$HELM_ARGS --set global.hostname=$OPENG2P_HOSTNAME"
fi
if ! [ -z $OPENG2P_HOSTNAME_SELF_SERVICE ]; then
    HELM_ARGS="$HELM_ARGS --set global.selfServiceHostname=$OPENG2P_HOSTNAME_SELF_SERVICE"
fi
if ! [ -z "$OPENG2P_HOSTNAME_SERVICE_PROV" ]; then
    HELM_ARGS="$HELM_ARGS --set global.serviceProviderHostname=$OPENG2P_HOSTNAME_SERVICE_PROV"
fi
if ! [ -z "$OPENG2P_MAILNAME" ]; then
    HELM_ARGS="$HELM_ARGS --set global.mailName=$OPENG2P_MAILNAME"
fi
if ! [ -z "$OPENG2P_ODOO_IMAGE_REPO" ]; then
    HELM_ARGS="$HELM_ARGS --set odoo.image.repository=$OPENG2P_ODOO_IMAGE_REPO"
fi
if ! [ -z "$OPENG2P_ODOO_IMAGE_TAG" ]; then
    HELM_ARGS="$HELM_ARGS --set odoo.image.tag=$OPENG2P_ODOO_IMAGE_TAG"
fi

helm -n $NS install openg2p openg2p/openg2p --wait $HELM_ARGS $@
