#!/usr/bin/env bash

NS=gctb
echo Create $NS namespace
kubectl create ns $NS

./copy_secrets.sh

helm -n $NS install gctb openg2p/g2p-cash-transfer-bridge -f values.yaml --wait $@
