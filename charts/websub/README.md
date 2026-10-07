# WebSub

Helm chart for the MOSIP WebSub hub and consolidator.

Chart version 1.3.2. Images are `mosipid/websub-service:1.3.2` and `mosipid/consolidator-websub-service:1.3.2`.

By default this chart installs its own Kafka and points the hub and consolidator at it.

Commons Base already runs Kafka as the Service `commons-kafka`. Use that broker instead of a second one:

```yaml
kafka:
  enabled: false
kafkaInstallationName: commons-kafka
```
