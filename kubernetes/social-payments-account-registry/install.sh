#!/usr/bin/env bash

NS=spar
echo Create $NS namespace
kubectl create ns $NS

./copy_secrets.sh

kubectl -n $NS delete cm mapper-registry-schemas --ignore-not-found=true
kubectl -n $NS create cm mapper-registry-schemas --from-file=schemas/FinancialAddressMapper.json

helm -n $NS install spar-self-service-ui openg2p/spar-self-service-ui $@

helm -n $NS install spar openg2p/social-payments-account-registry -f values.yaml --wait $@
