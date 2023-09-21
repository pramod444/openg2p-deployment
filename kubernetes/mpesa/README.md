# Simple Mpesa Install on OpenG2P Sandbox

## Instructions

- Edit the configmap section of `simple-mpesa-deployment.yaml` file with appropriate database location, username and password.
- Edit the VirtualService section of `simple-mpesa-deployment.yaml` file with appropriate hostname.
- Run
  ```sh
  kubectl create ns mpesa
  kubectl -n mpesa apply -f simple-mpesa-deployment.yaml
  ```