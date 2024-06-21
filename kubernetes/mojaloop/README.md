# Mojaloop Install on OpenG2P Sandbox

## Installation

- Run the following command.
  - ```sh
    SANDBOX_HOSTNAME="openg2p.sandbox.net" \
      ./install.sh
    ```

## Oracle Install

- Not required if SPAR is being used.
- Install one simulator for each ID Type. Example:
  - ```sh
    helm -n ml install ml-oracle-iban mojaloop/simulator
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
    - If using SPAR, login to SPAR and use "Update Details" form. Choose the relevant
      bank and type the same account number as in the previous step.
  - Using Postman:
    - Edit all the variables in the environment with prefix `ADD_USER_`.
    - Then run the `MojaloopAddUsers` collection.
    - If using SPAR, login to SPAR and use "Update Details" form. Choose the relevant
      bank and type the same account number as in the previous step.
