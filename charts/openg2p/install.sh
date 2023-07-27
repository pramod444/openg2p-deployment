#!/usr/bin/env bash

NS=openg2p

echo Create $NS namespace
kubectl create ns $NS

helm -n $NS install openg2p . $@
