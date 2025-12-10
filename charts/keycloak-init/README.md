# Keycloak Init (The chart creation is still inprogress)

* Make sure Keycloak server is running
* Update helm dependencies using:
```
$ helm dependency update
```
* Run the helm chart
```
$ helm upgrade --install keycloak-init -n keycloak-system
```
