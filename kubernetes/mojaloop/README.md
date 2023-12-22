# Mojaloop Install on OpenG2P Sandbox

## Installation

- Configure hostnames in the following files.
  - `ml-sim-frontend.yaml`
  - `ml-istio.yaml`
- Run the following commands.
  - ```sh
    helm repo add mojaloop http://mojaloop.io/helm/repo/
    helm repo add bitnami https://charts.bitnami.com/bitnami
    helm repo update
    kubectl create ns ml
    ```
  - ```sh
    helm -n ml install mysqldb bitnami/mysql -f values-ml-mysql.yaml
    helm -n ml install cl-mongodb bitnami/mongodb -f values-ml-mongodb.yaml
    helm -n ml install kafka bitnami/kafka -f values-ml-kafka.yaml
    ```
  - ```sh
    helm -n ml install ml mojaloop/mojaloop -f values-mojaloop.yaml
    ```
  - ```sh
    helm -n ml install ml-simulators mojaloop/mojaloop-simulator -f values-ml-sim.yaml
    ```
  - ```
    kubectl -n ml apply -f ml-sim-frontend.yaml
    ```
  - ```sh
    kubectl -n ml apply -f ml-istio.yaml
    ```

## Oracle Install

- Not required if SPAR is being used.
- Install one simulator for each ID Type. Example:
  - ```sh
    helm -n ml install ml-oracle-iban mojaloop/simulator 
    ```

## TTK Installation

- This is required for Wallet based simulations (Pink Wallet).
- Configure hostnames in the following files.
  - `values-ml-ttk.yaml`
  - `ml-istio-ttk.yaml`
- Run the following commands.
  - ```sh
    kubectl create ns ml
    helm repo add mojaloop http://mojaloop.io/helm/repo/
    helm repo update
    ```
  - ```sh
    helm -n ml install ml mojaloop/ml-testing-toolkit -f values-ml-ttk.yaml
    ```
  - ```sh
    kubectl -n ml apply -f ml-istio-ttk.yaml
    ```

## Post Installation

- Download this postman environment, and collections from the [postman](./postman/) directory,
  and import them into Postman.
- Edit hostnames and values in the Environment accordingly.
- Run the full `MojaloopHub_Setup_simplified` Collection.
- To add users to DFSP simulators:
  - Using UI:
    - Go to DFSP Simulator UI, example https://bank2.openg2p.sandbox.net
    - Under Users Menu, click "Add User".
    - Fill the pop up form to add user. Date of Birth is in this format YYYY-MM-DD.
      If you chose "Id Type" as "ACCOUNT_ID", then "Id Value" means the bank account
      number. Any unique number can be filled here in "Id Value".
    - If using SPAR, login to SPAR and use "Update Details" form. Chose the relevant
      bank and type the same account number as in the previous step.
  - Using Postman (Will not work with SPAR):
    - Edit all the variables in the environment with prefix `ADD_USER_`.
    - Then run the `MojaloopAddUsers` collection.
