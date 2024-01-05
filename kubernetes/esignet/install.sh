#!/bin/bash

export SANDBOX_HOSTNAME=${SANDBOX_HOSTNAME:-openg2p.sandbox.net}
export ESIGNET_HOSTNAME=${ESIGNET_HOSTNAME:-esignet.$SANDBOX_HOSTNAME}

NS=esignet
COPY_UTIL=../utils/copy_cm_func.sh

helm repo add mosip https://mosip.github.io/mosip-helm
helm repo update

echo Create namespaces
kubectl create ns $NS

echo Istio label
kubectl label ns $NS istio-injection=disabled --overwrite

echo Installing Softhsm for Esignet and mockid
helm -n $NS install softhsm-esignet mosip/softhsm -f softhsm-values.yaml --version 12.0.2 --wait
helm -n $NS install softhsm-mock-identity-system mosip/softhsm -f softhsm-values.yaml --version 12.0.2 --wait

$COPY_UTIL configmap global default $NS
$COPY_UTIL configmap artifactory-share artifactory $NS
$COPY_UTIL configmap config-server-share config-server $NS

echo Installing mock identity system
helm -n $NS install mock-identity-system mosip/mock-identity-system -f values.yaml --version 0.9.1 --wait

echo Installing esignet
helm -n $NS install esignet mosip/esignet -f values.yaml --version 1.2.0 --wait

echo Installing OIDC UI
helm -n $NS install oidc-ui mosip/oidc-ui \
  --set oidc_ui.configmaps.oidc-ui.REACT_APP_API_BASE_URL="http://esignet.$NS/v1/esignet" \
  --set oidc_ui.configmaps.oidc-ui.REACT_APP_SBI_DOMAIN_URI="http://esignet.$NS" \
  --set oidc_ui.configmaps.oidc-ui.OIDC_UI_PUBLIC_URL=''\
  --set istio.enabled=false \
  --version 1.2.0 \
  --wait

envsubst < istio-virtualservice.template.yaml | kubectl -n $NS apply -f -
