NS=config-server
MINIO_NS=minio

S3_PRETEXT_VALUE=""
USER=$(kubectl -n $MINIO_NS get secret minio -o jsonpath='{.data.root-user}' | base64 --decode)
PASS=$(kubectl -n $MINIO_NS get secret minio -o jsonpath='{.data.root-password}' | base64 --decode)
kubectl -n $NS create configmap s3 --from-literal=s3-user-key=$USER --from-literal=s3-region=""
kubectl -n $NS create secret generic s3 --from-literal=s3-user-secret=$PASS --from-literal=s3-pretext-value=$S3_PRETEXT_VALUE

kubectl -n $NS create secret generic softhsm-ida --from-literal=security-pin=""

kubectl -n $NS create cm activemq-activemq-artemis-share --from-literal=activemq-core-port=61616 --from-literal=activemq-host=activemq-activemq-artemis.activemq
kubectl -n $NS create secret generic activemq-activemq-artemis --from-literal=artemis-password=""

kubectl -n $NS create cm msg-gateway --from-literal=sms-host=mock-smtp.mock-smtp --from-literal=sms-port=8080 --from-literal=sms-username="" --from-literal=smtp-host=smtp.gmail.com --from-literal=smtp-port=587 --from-literal=smtp-username=notifications@openg2p.org
kubectl -n $NS create secret generic msg-gateway --from-literal=sms-secret="" --from-literal=smtp-secret=""

kubectl -n $NS create secret generic mosip-captcha --from-literal=prereg-captcha-site-key="" --from-literal=prereg-captcha-secret-key="" --from-literal=resident-captcha-site-key="" --from-literal=resident-captcha-secret-key=""
