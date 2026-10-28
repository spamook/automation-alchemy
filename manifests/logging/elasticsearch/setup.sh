#!/bin/sh
# Prepares Elasticsearch for the log pipeline. Every call is idempotent (PUT/POST of the
# same object), so the Job can run again after any change.
set -eu

ES=http://elasticsearch.logging.svc.cluster.local:9200
AUTH="elastic:${ELASTIC_PASSWORD}"
es() { curl -sS --fail-with-body -u "$AUTH" -H 'Content-Type: application/json' "$@"; echo; }

echo "waiting for elasticsearch..."
until curl -sf -u "$AUTH" "$ES/_cluster/health?timeout=5s" >/dev/null; do sleep 5; done

echo "== password of kibana_system (the user Kibana connects with)"
es -X POST "$ES/_security/user/kibana_system/_password" -d "{\"password\":\"${KIBANA_SYSTEM_PASSWORD}\"}"

echo "== fluentbit: may only create and write log indices"
es -X PUT "$ES/_security/role/log_writer" -d '{
  "cluster": ["monitor"],
  "indices": [{"names": ["k8s-logs-*"], "privileges": ["create_index", "write"]}]
}'
es -X PUT "$ES/_security/user/fluentbit" -d "{\"password\":\"${FLUENTBIT_PASSWORD}\",\"roles\":[\"log_writer\"]}"

echo "== es-exporter: may only read cluster health and stats"
es -X PUT "$ES/_security/role/metrics_reader" -d '{
  "cluster": ["monitor"],
  "indices": [{"names": ["*"], "privileges": ["monitor"]}]
}'
es -X PUT "$ES/_security/user/es-exporter" -d "{\"password\":\"${EXPORTER_PASSWORD}\",\"roles\":[\"metrics_reader\"]}"

echo "== lifecycle policy: log indices are deleted after 7 days"
es -X PUT "$ES/_ilm/policy/k8s-logs" -d '{
  "policy": {"phases": {"hot": {"actions": {}}, "delete": {"min_age": "7d", "actions": {"delete": {}}}}}
}'

echo "== index template for k8s-logs-*"
es -X PUT "$ES/_index_template/k8s-logs" -d @/setup/index-template.json

echo "done"
