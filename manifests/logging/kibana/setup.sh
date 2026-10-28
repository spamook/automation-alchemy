#!/bin/sh
# Imports the data view and the three log dashboards into Kibana (overwriting older copies).
set -eu

KB=http://kibana.logging.svc.cluster.local:5601/kibana
AUTH="elastic:${ELASTIC_PASSWORD}"

echo "waiting for kibana..."
until curl -sf -u "$AUTH" "$KB/api/status" | grep -q '"level":"available"'; do sleep 10; done

echo "== importing saved objects"
curl -sS --fail-with-body -u "$AUTH" -H 'kbn-xsrf: true' \
    -X POST "$KB/api/saved_objects/_import?overwrite=true" \
    --form file=@/setup/dashboards.ndjson
echo

echo "== default data view"
curl -sS --fail-with-body -u "$AUTH" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' \
    -X POST "$KB/api/data_views/default" -d '{"data_view_id": "k8s-logs", "force": true}'
echo
echo "done"
