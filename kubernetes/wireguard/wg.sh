#!/usr/bin/env bash

# TODO: Consider running the dockers in host networking mode

if [ $USER != "root" ]; then
  echo "Run this as root"
  exit 1
fi

if [ -z $WG_MODE ]; then
  export WG_MODE=docker
elif [ $WG_MODE != "docker" ] && [ $WG_MODE != "k8s" ]; then
  echo "Unsupported WG_MODE. defaulting to docker"
  export WG_MODE=docker
fi

if [ $# -lt 3 ]; then
  echo "Usage: ./wg.sh <wireguard name> <subnet for this wireguard> <port for this wireguard> [no of peers] [clients allowed ips]"
  exit 1
fi

if [ $# -ge 4 ]; then
  WG_PEERS=$4
else
  WG_PEERS=100
fi

if [ $# -ge 5 ]; then
  WG_ALLOWED_IPS=$5
else
  WG_ALLOWED_IPS="0.0.0.0/0"
fi

WG_NAME=$1
WG_SUBNET=$2
WG_PORT=$3

WG_SUBNET_SPLIT_ARR=(${WG_SUBNET//\// })

if [ -z ${WG_SUBNET_SPLIT_ARR[1]} ]; then
  echo "Give subnet range. Ex: 10.15.0.0/16"; exit 1
fi

mkdir -p /etc/$WG_NAME/templates
echo \
'[Interface]
Address = ${INTERFACE}.1
ListenPort = ${SERVERPORT}
PrivateKey = $(cat /config/server/privatekey-server)
PostUp = /config/rules.sh
PostDown = /postdown.rules.sh
' > /etc/$WG_NAME/templates/server.conf

echo \
'#!/bin/sh

cat /config/rules.sh | sed "s/iptables -A/iptables -D/g" | grep -vi "cat\|chmod" > /postdown.rules.sh
chmod +x /postdown.rules.sh

iptables -A FORWARD -i wg0 -j ACCEPT
iptables -A FORWARD -o wg0 -j ACCEPT

iptables -A POSTROUTING -t nat -o eth0 -j MASQUERADE
' > /etc/$WG_NAME/rules.sh
chmod +x /etc/$WG_NAME/rules.sh

if [ $WG_MODE = "docker" ]; then

docker run -d \
  --name=$WG_NAME \
  --cap-add=NET_ADMIN \
  -e PUID=1000 \
  -e PGID=1000 \
  -e TZ=Asia/Calcutta\
  -e PEERS=${WG_PEERS} \
  -e PEERDNS="" \
  -e INTERNAL_SUBNET="${WG_SUBNET_SPLIT_ARR[0]}" \
  -e ALLOWEDIPS="$WG_ALLOWED_IPS" \
  -e SERVERPORT=$WG_PORT \
  -p ${WG_PORT}:${WG_PORT}/udp \
  -v /etc/$WG_NAME/:/config \
  --restart unless-stopped \
  --sysctl="net.ipv4.conf.all.src_valid_mark=1" \
  --sysctl="net.ipv4.ip_forward=1" \
  ghcr.io/linuxserver/wireguard || \
{ echo "Error starting Docker"; exit 1; }

elif [ $WG_MODE = "k8s" ]; then

kubectl create ns wireguard-system || echo "Namespace Already Exists"
echo \
'apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: '"${WG_NAME//_/-}"'
  namespace: wireguard-system
spec:
  selector:
    matchLabels:
      app: '"${WG_NAME//_/-}"'
  template:
    metadata:
      labels:
        app: '"${WG_NAME//_/-}"'
    spec:
      nodeName: node1
      securityContext:
        sysctls:
          - name: net.ipv4.conf.all.src_valid_mark
            value: "1"
          - name: net.ipv4.ip_forward
            value: "1"
      containers:
      - name: wireguard
        image: ghcr.io/linuxserver/wireguard
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
        env:
        - name: PUID
          value: "1000"
        - name: PGID
          value: "1000"
        - name: TZ
          value: "Asia/Calcutta"
        - name: PEERS
          value: "'"${WG_PEERS}"'"
        - name: PEERDNS
          value: ""
        - name: INTERNAL_SUBNET
          value: "'"${WG_SUBNET_SPLIT_ARR[0]}"'"
        - name: ALLOWEDIPS
          value: "'"$WG_ALLOWED_IPS"'"
        - name: SERVERPORT
          value: "'"$WG_PORT"'"
        ports:
        - containerPort: '"$WG_PORT"'
          hostPort: '"$WG_PORT"'
          protocol: UDP
        volumeMounts:
        - mountPath: /config
          name: wg-configs
      volumes:
      - name: wg-configs
        hostPath:
          path: /etc/'"$WG_NAME"'
' | kubectl apply -f - || \
{ echo "Error starting Pod"; exit 1; }

fi
