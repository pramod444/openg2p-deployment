#!/usr/bin/env bash

# TODO: Consider running the dockers in host networking mode

if [ $USER != "root" ]; then
  echo "Run this as root"
  exit 1
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

#iptables -A FORWARD -m iprange --src-range 10.13.13.2-10.13.13.51 -d 172.31.35.104 -j ACCEPT
#iptables -A FORWARD -m iprange --dst-range 10.13.13.2-10.13.13.51 -s 172.31.35.104 -j ACCEPT

#iptables -A FORWARD -m iprange --src-range 10.13.13.2-10.13.13.51 -d 172.31.31.67 -j ACCEPT
#iptables -A FORWARD -m iprange --dst-range 10.13.13.2-10.13.13.51 -s 172.31.31.67 -j ACCEPT

iptables -A POSTROUTING -t nat -o eth0 -j MASQUERADE
' > /etc/$WG_NAME/rules.sh
chmod +x /etc/$WG_NAME/rules.sh

docker run -d \
  --name=$WG_NAME \
  --cap-add=NET_ADMIN \
  --cap-add=SYS_MODULE \
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
  -v /lib/modules:/lib/modules \
  --restart unless-stopped \
  ghcr.io/linuxserver/wireguard

WG_CONT_IP=$(docker inspect -f '{{range.NetworkSettings.Networks}}{{.IPAddress}}{{end}}' $WG_NAME)
ip route add $WG_SUBNET via $WG_CONT_IP

