#!/bin/sh
# One-shot setup jobs for the logging stack, run by docker compose:
#   es-setup      -> setup.sh elasticsearch   ILM retention policies + index templates
#   kibana-setup  -> setup.sh kibana          data views + System/Application/Docker dashboards
# Every call is a PUT/overwrite, so running it again is safe (idempotent).
set -eu

MODE="${1:?usage: setup.sh elasticsearch|kibana}"
ES_URL="${ES_URL:-http://es01:9200}"
KIBANA_URL="${KIBANA_URL:-http://kibana:5601}"
DIR="$(dirname "$0")"

# PUT a JSON file to Elasticsearch, fail loudly on any non-2xx answer
es_put() {
    echo "PUT $1"
    curl -fsS -X PUT "$ES_URL$1" -H 'Content-Type: application/json' --data-binary "@$2"
    echo
}

case "$MODE" in
elasticsearch)
    until curl -fs "$ES_URL/_cluster/health?wait_for_status=yellow&timeout=5s" >/dev/null; do
        echo "waiting for Elasticsearch..."; sleep 5
    done
    es_put /_ilm/policy/infra-logs-30d             "$DIR/elasticsearch/ilm-infra-logs.json"
    es_put /_ilm/policy/infra-alerts-90d           "$DIR/elasticsearch/ilm-infra-alerts.json"
    es_put /_component_template/infra-mappings     "$DIR/elasticsearch/component-infra-mappings.json"
    es_put /_index_template/infra-logs             "$DIR/elasticsearch/template-infra-logs.json"
    es_put /_index_template/infra-alerts           "$DIR/elasticsearch/template-infra-alerts.json"
    echo "Elasticsearch setup done"
    ;;
kibana)
    until curl -fs "$KIBANA_URL/api/status" | grep -q '"level":"available"'; do
        echo "waiting for Kibana..."; sleep 5
    done
    # data views, saved searches, Lens visualizations and the 3 dashboards
    echo "importing Kibana saved objects"
    result=$(curl -fsS -X POST "$KIBANA_URL/api/saved_objects/_import?overwrite=true" \
        -H 'kbn-xsrf: true' --form file=@"$DIR/kibana/dashboards.ndjson")
    echo "$result"
    # the import API answers 200 even when single objects fail -> check the body
    echo "$result" | grep -q '"success":true' || { echo "saved objects import failed" >&2; exit 1; }
    # open Discover on system logs by default
    curl -fsS -X POST "$KIBANA_URL/api/data_views/default" -H 'kbn-xsrf: true' \
        -H 'Content-Type: application/json' -d '{"data_view_id":"infra-system","force":true}'
    echo
    echo "Kibana setup done"
    ;;
*)
    echo "unknown mode: $MODE" >&2; exit 1
    ;;
esac
