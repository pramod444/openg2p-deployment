#!/bin/bash

export NS=${NS:-kube-system}
export NFS_SERVER=${NFS_SERVER:-}
export NFS_PATH=${NFS_PATH:-/srv/nfs/global}

if [ -z "$NFS_SERVER" ]; then
  echo "NFS_SERVER not provided; EXITING;";
  exit 1;
fi
if [ -z "$NFS_PATH" ]; then
  echo "NFS_PATH not provided; EXITING;";
  exit 1;
fi

echo Add helm csi-driver-nfs repo
helm repo add csi-driver-nfs https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts
helm repo update

echo "Installing CSI Driver for NFS"
helm -n $NS upgrade --install csi-driver-nfs csi-driver-nfs/csi-driver-nfs \
  --version v4.7.0

echo "Installing NFS CSI Storage Class"
envsubst '${NFS_PATH},${NFS_SERVER}' < storage-class.template.yaml | kubectl apply -f -
