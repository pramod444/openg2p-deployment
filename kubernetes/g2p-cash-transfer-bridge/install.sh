#!/usr/bin/env bash

export SANDBOX_HOSTNAME=${SANDBOX_HOSTNAME:-openg2p.sandbox.net}
export GCTB_HOSTNAME=${GCTB_HOSTNAME:-gctb.$SANDBOX_HOSTNAME}

NS=gctb

helm repo add openg2p https://openg2p.github.io/openg2p-helm
helm repo update

echo Create $NS namespace
kubectl create ns $NS

./copy_secrets.sh

helm -n $NS install gctb openg2p/g2p-cash-transfer-bridge -f values.yaml --set global.hostname=${GCTB_HOSTNAME} --wait $@
