# Simple Mpesa Install on OpenG2P Sandbox

## Instructions

- Edit the `config.yaml` file with appropriate database location, username and password.
- Edit the `virtualService.yaml` file with appropriate hostname.
- Run
  ```
  kubectl create ns mpesa
  kubectl -n mpesa apply -f config.yaml
  kubectl -n mpesa apply -f deployment.yaml
  kubectl -n mpesa apply -f service.yaml
  kubectl -n mpesa apply -f virtualservice.yaml
  ```
