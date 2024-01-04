#!/usr/bin/env bash

NS=postgres

echo Create $NS namespace
kubectl create ns $NS

helm -n $NS install postgres oci://registry-1.docker.io/bitnamicharts/postgresql --version 13.2.27 --wait -f values.yaml $@

if [ "$POSTGRES_ISTIO_ENABLED" != "false" ]; then
    kubectl apply -n $NS -f istio-virtualservice.yaml
fi
