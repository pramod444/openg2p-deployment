#!/usr/bin/env bash

export SANDBOX_HOSTNAME=${SANDBOX_HOSTNAME:-openg2p.sandbox.net}
export SPAR_HOSTNAME=${SPAR_HOSTNAME:-spar.$SANDBOX_HOSTNAME}

NS=spar
echo Create $NS namespace
kubectl create ns $NS

./copy_secrets.sh

kubectl -n $NS delete cm mapper-registry-schemas --ignore-not-found=true
kubectl -n $NS create cm mapper-registry-schemas --from-file=schemas/FinancialAddressMapper.json

helm -n $NS upgrade --install spar-self-service-ui openg2p/spar-self-service-ui -f values.yaml --set global.hostname=$SPAR_HOSTNAME $@

helm -n $NS upgrade --install spar openg2p/social-payments-account-registry -f values.yaml --set global.hostname=$SPAR_HOSTNAME --wait $@
