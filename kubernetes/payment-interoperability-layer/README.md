# Payment Interoperability Layer Install on OpenG2P Sandbox

LEGACY. Use G2P Cash Transfer Bridge instead.

## Instructions

- Configure and deploy one dfsp-ml-payment-manager.yaml for each DFSP available; (This assumes mojaloop SDK adapter service for the DFSP is already deployed and running)
  ```sh
  kubectl apply -f dfsp-ml-payment-manager.yaml
  ```
- Configure and deploy G2P payment-interoperability-layer.yaml, one per G2P system;
  ```sh
  kubectl apply -f payment-interoperability-layer.yaml
  ```