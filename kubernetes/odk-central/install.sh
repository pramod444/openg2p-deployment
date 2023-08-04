#!/usr/bin/env bash

NS=odk

helm repo add openg2p https://openg2p.github.io/openg2p-helm
helm repo update

echo Create $NS namespace
kubectl create ns $NS

./copy_secrets.sh

HELM_ARGS=""
if ! [ -z "$ODK_HOSTNAME" ]; then
    HELM_ARGS="$HELM_ARGS --set global.hostname=$ODK_HOSTNAME"
fi

helm -n $NS install odk-central openg2p/odk-central --wait $HELM_ARGS $@
