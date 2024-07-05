#!/usr/bin/env bash

export SANDBOX_HOSTNAME=${SANDBOX_HOSTNAME:-openg2p.sandbox.net}
export OPENG2P_SELFSERVICE_HOSTNAME=${OPENG2P_SELFSERVICE_HOSTNAME:-beneficiary.$SANDBOX_HOSTNAME}

NS=openg2p

helm repo add openg2p https://openg2p.github.io/openg2p-helm
helm repo update

echo Create $NS namespace
kubectl create ns $NS

helm -n $NS upgrade --install openg2p-selfservice-ui openg2p/openg2p-selfservice-ui -f values.yaml --set global.hostname=$OPENG2P_SELFSERVICE_HOSTNAME $@

helm -n $NS upgrade --install openg2p-selfservice-api openg2p/openg2p-selfservice-api -f values.yaml --set global.hostname=$OPENG2P_SELFSERVICE_HOSTNAME --wait $@
