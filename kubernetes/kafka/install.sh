#!/usr/bin/env bash

export KAFKA_UI_HOSTNAME=${KAFKA_UI_HOSTNAME:-kafka.${SANDBOX_HOSTNAME:-openg2p.sandbox.net}}

NS=kafka

helm repo add kafka-ui https://provectus.github.io/kafka-ui-charts
helm repo update

echo Create $NS namespace
kubectl create ns $NS

echo "Installing Kafka UI"
helm -n $NS install kafka-ui kafka-ui/kafka-ui --version 0.7.5 -f kafka-ui-values.yaml

echo "Installing Kafka"
helm -n $NS install kafka oci://registry-1.docker.io/bitnamicharts/kafka --version 26.6.2 -f values.yaml --wait $@

if [ "$KAFKA_ISTIO_ENABLED" != "false" ]; then
  envsubst < istio-virtualservice.template.yaml | kubectl apply -n $NS -f -
fi
