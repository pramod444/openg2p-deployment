#!/usr/bin/env bash

export SANDBOX_HOSTNAME=${SANDBOX_HOSTNAME:-openg2p.sandbox.net}
export ML_DFSP1_HOSTNAME=${ML_DFSP1_HOSTNAME:-bank1.$SANDBOX_HOSTNAME}
export ML_DFSP2_HOSTNAME=${ML_DFSP2_HOSTNAME:-bank2.$SANDBOX_HOSTNAME}
export ML_ALS_HOSTNAME=${ML_ALS_HOSTNAME:-ml-als.$SANDBOX_HOSTNAME}
export ML_ALS_ADMIN_HOSTNAME=${ML_ALS_ADMIN_HOSTNAME:-ml-als-admin.$SANDBOX_HOSTNAME}
export ML_API_ADAPTER_HOSTNAME=${ML_API_ADAPTER_HOSTNAME:-ml-api-adapter.$SANDBOX_HOSTNAME}
export ML_CENTRAL_LEDGER_HOSTNAME=${ML_CENTRAL_LEDGER_HOSTNAME:-ml-central-ledger.$SANDBOX_HOSTNAME}
export ML_QUOTING_HOSTNAME=${ML_QUOTING_HOSTNAME:-ml-quoting.$SANDBOX_HOSTNAME}
export ML_TRANSACTION_HOSTNAME=${ML_TRANSACTION_HOSTNAME:-ml-transaction.$SANDBOX_HOSTNAME}
export ML_TTK_HOSTNAME=${ML_TTK_HOSTNAME:-ml-ttk.$SANDBOX_HOSTNAME}

NS=ml

helm repo add mojaloop http://mojaloop.io/helm/repo/
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

kubectl create ns ml

helm -n $NS install mysqldb bitnami/mysql --version 9.16.1 -f values-ml-mysql.yaml
helm -n $NS install cl-mongodb bitnami/mongodb --version 14.4.9 -f values-ml-mongodb.yaml
helm -n $NS install kafka bitnami/kafka --version 26.6.2 -f values-ml-kafka.yaml

helm -n $NS install ml mojaloop/mojaloop --version 15.2.0 -f values-mojaloop.yaml

helm -n $NS install ml-simulators mojaloop/mojaloop-simulator --version 15.0.0 -f values-ml-sim.yaml

envsubst < ml-sim-frontend.yaml | kubectl -n $NS apply -f -

envsubst < values-ml-ttk.yaml | helm -n $NS install ml-ttk mojaloop/ml-testing-toolkit --version 17.0.0 -f -

envsubst < ml-istio.yaml | kubectl -n $NS apply -f -
envsubst < ml-istio-ttk.yaml | kubectl -n $NS apply -f -
