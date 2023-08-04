#!/usr/bin/env bash

NS=kafka

helm repo add kafka-ui https://provectus.github.io/kafka-ui-charts
helm repo update

echo Create $NS namespace
kubectl create ns $NS

echo "Installing Kafka UI"
helm -n $NS install kafka-ui kafka-ui/kafka-ui -f kafka-ui-values.yaml

echo "Installing Kafka"
helm -n $NS install kafka oci://registry-1.docker.io/bitnamicharts/kafka --version "23.0.7" --wait -f values.yaml $@

if [ "$KAFKA_ISTIO_ENABLED" != "false" ]; then
  export KAFKA_UI_HOSTNAME=${KAFKA_UI_HOSTNAME:-kafka.openg2p.sandbox.net}
  envsubst < istio-virtualservice.template.yaml | kubectl apply -n $NS -f -
fi
