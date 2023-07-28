#!/usr/bin/env bash

NS=openg2p

helm repo add openg2p https://openg2p.github.io/openg2p-helm
helm repo update

echo Create $NS namespace
kubectl create ns $NS

helm -n $NS install openg2p openg2p/openg2p  $@
