#!/usr/bin/env bash

export NS=${NS:-}

export ADMIN_PASSWORD=$(kubectl -n $NS get secret opensearch -o jsonpath={.data.opensearch-password} | base64 --decode)
kubectl exec -it opensearch-master-0 -c opensearch -n $NS -- curl -k -u admin:$ADMIN_PASSWORD -XPUT "https://opensearch:9200/_plugins/_ism/policies/logstash_3_days_delete_policy" -H 'Content-Type: application/json' -d'
{
    "policy": {
        "description": "Delete logstash indices after 3days",
        "default_state": "hot",
        "states": [
            {
                "name": "hot",
                "actions": [],
                "transitions": [
                    {
                        "state_name": "delete",
                        "conditions": {
                            "min_index_age": "3d"
                        }
                    }
                ]
            },
            {
                "name": "delete",
                "actions": [
                    {
                        "delete": {}
                    }
                ],
                "transitions": []
            }
        ],
        "ism_template": {
            "index_patterns": ["logstash-*"],
            "priority": 100
        }
    }
}'; echo
