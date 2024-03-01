#!/usr/bin/env bash

NS=postgres

helm repo add mosip https://mosip.github.io/mosip-helm
helm repo update

echo Create $NS namespace
kubectl create ns $NS

helm -n $NS upgrade --install postgres oci://registry-1.docker.io/bitnamicharts/postgresql --version 13.2.27 --wait -f values.yaml $@

if [ "$POSTGRES_ISTIO_ENABLED" != "false" ]; then
    kubectl apply -n $NS -f istio-virtualservice.yaml
fi

if [ "$POSTGRES_INIT_ENABLED" != "false" ]; then
    echo Removing any existing installation
    helm -n $NS delete postgres-init || true
    echo Initializing DB
    helm -n $NS install postgres-init mosip/postgres-init -f values-init.yaml --version 12.0.2 --wait --wait-for-jobs
fi
