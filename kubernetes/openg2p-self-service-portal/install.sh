#!/usr/bin/env bash

export SANDBOX_HOSTNAME=${SANDBOX_HOSTNAME:-openg2p.sandbox.net}
export OPENG2P_SELFSERVICE_HOSTNAME=${OPENG2P_SELFSERVICE_HOSTNAME:-selfservice.$SANDBOX_HOSTNAME}

NS=openg2p
echo Create $NS namespace
kubectl create ns $NS

helm -n $NS upgrade --install openg2p-self-service-portal-ui openg2p/openg2p-self-service-portal-ui -f values.yaml --set global.hostname=$SELFSERVICE_HOSTNAME $@

helm -n $NS upgrade --install openg2p-self-service-portal-api openg2p/openg2p-self-service-portal-api -f values.yaml --set global.hostname=$SELFSERVICE_HOSTNAME --wait $@
