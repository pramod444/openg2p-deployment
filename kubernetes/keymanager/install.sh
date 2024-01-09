#!/bin/bash

SOFTHSM_NS=softhsm
ARTIFACTORY_NS=artifactory
CONF_SECRETS_NS=conf-secrets
CONFIG_SERVER_NS=config-server
KEYMANAGER_NS=keymanager
MINIO_NS=minio

COPY_UTIL=../utils/copy_cm_func.sh

export SANDBOX_HOSTNAME=${SANDBOX_HOSTNAME:-openg2p.sandbox.net}
export KEYMANAGER_HOSTNAME=${KEYMANAGER_HOSTNAME:-$SANDBOX_HOSTNAME}

helm repo add mosip https://mosip.github.io/mosip-helm
helm repo update

echo Create namespaces
kubectl create ns $SOFTHSM_NS
kubectl create ns $ARTIFACTORY_NS
kubectl create ns $CONF_SECRETS_NS
kubectl create ns $CONFIG_SERVER_NS
kubectl create ns $KEYMANAGER_NS

echo Istio label
kubectl label ns $SOFTHSM_NS istio-injection=disabled --overwrite
kubectl label ns $ARTIFACTORY_NS istio-injection=disabled --overwrite
kubectl label ns $CONF_SECRETS_NS istio-injection=disabled --overwrite
kubectl label ns $CONFIG_SERVER_NS istio-injection=disabled --overwrite
kubectl label ns $KEYMANAGER_NS istio-injection=disabled --overwrite

envsubst < global-conf-map.yaml | kubectl apply -f -

echo Installing Softhsm for Kernel
helm -n $SOFTHSM_NS install softhsm-kernel mosip/softhsm -f softhsm-values.yaml --version 12.0.2 --wait

echo Installing Secrets required by config-server
helm -n $CONF_SECRETS_NS install conf-secrets mosip/conf-secrets --version 12.0.2 --wait

echo Installing Config Server
$COPY_UTIL configmap global default $CONFIG_SERVER_NS
$COPY_UTIL configmap keycloak-host keycloak $CONFIG_SERVER_NS

$COPY_UTIL secret db-common-secrets postgres $CONFIG_SERVER_NS
$COPY_UTIL secret keycloak keycloak $CONFIG_SERVER_NS
$COPY_UTIL secret keycloak-client-secrets keycloak $CONFIG_SERVER_NS
$COPY_UTIL secret softhsm-kernel $SOFTHSM_NS $CONFIG_SERVER_NS
$COPY_UTIL secret conf-secrets-various $CONF_SECRETS_NS $CONFIG_SERVER_NS

./dummy_secrets.sh

helm -n $CONFIG_SERVER_NS install config-server mosip/config-server -f config-server-values.yaml --version 12.0.2

kubectl -n $CONFIG_SERVER_NS set env --keys=openg2p_admin_client_secret --from=secret/keycloak-client-secrets deployment/config-server --prefix=SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_
kubectl -n $CONFIG_SERVER_NS set env deployment/config-server SPRING_CLOUD_CONFIG_SERVER_OVERRIDES_HUB_SECRET_ENCRYPTION_KEY-

kubectl -n $CONFIG_SERVER_NS rollout status deploy/config-server

echo Installing Artifactory
helm -n $ARTIFACTORY_NS install artifactory mosip/artifactory --version 12.0.2 --wait

echo Installing kernel Keygen
$COPY_UTIL configmap global default $KEYMANAGER_NS
$COPY_UTIL configmap artifactory-share $ARTIFACTORY_NS $KEYMANAGER_NS
$COPY_UTIL configmap config-server-share $CONFIG_SERVER_NS $KEYMANAGER_NS
$COPY_UTIL configmap softhsm-kernel-share $SOFTHSM_NS $KEYMANAGER_NS

helm -n $KEYMANAGER_NS install kernel-keygen mosip/keygen -f keygen-values.yaml --version 12.0.2 --wait --wait-for-jobs

echo Installing Keymanager
helm -n $KEYMANAGER_NS install keymanager mosip/keymanager --version 12.0.2 --set istio.enabled=false --wait

envsubst < istio-virtualservice.template.yaml | kubectl -n $KEYMANAGER_NS apply -f -
