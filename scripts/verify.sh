#!/usr/bin/env bash
# Checks every part of the project end to end. Handy right before a demo.
set -uo pipefail
cd "$(dirname "$0")/.."

IP=$(minikube ip)
CREDS=.secrets/credentials.env
get() { grep "^$1=" "$CREDS" | cut -d= -f2-; }
OPS=$(get OPS_PASSWORD); EP=$(get ELASTIC_PASSWORD); GP=$(get GRAFANA_ADMIN_PASSWORD); JP=$(get JENKINS_ADMIN_PASSWORD)

fails=0
check() {
    local name=$1; shift
    if "$@" >/dev/null 2>&1; then printf '  ok    %s\n' "$name"
    else printf '  FAIL  %s\n' "$name"; fails=$((fails + 1)); fi
}
es() { kubectl -n logging exec elasticsearch-0 -- curl -s -u "elastic:$EP" "localhost:9200/$1"; }

echo "Cluster"
check "every pod is running (or a finished job)" \
    bash -c '! kubectl get pods -A --no-headers | grep -vE "Running|Completed"'
check "every persistent volume claim is bound" \
    bash -c '! kubectl get pvc -A --no-headers | grep -v Bound'

echo "Application"
check "frontend pod reaches the backend Service" \
    kubectl -n app exec deploy/frontend -- wget -qO- http://backend.app.svc.cluster.local:3001/health
check "app answers through the ingress" curl -fsS "http://$IP/"
check "API answers through ingress -> frontend -> backend" curl -fsS "http://$IP/api/metrics"
check "requests are spread over the frontend replicas" bash -c \
    "for i in \$(seq 12); do curl -sI http://$IP/ | grep -i x-served-by; done | sort -u | awk 'END { exit NR < 2 }'"
check "HPA reads the frontend CPU usage" bash -c \
    "kubectl -n app get hpa frontend -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' | grep -q '[0-9]'"

echo "CI/CD"
check "Jenkins is up" curl -fsS -u "admin:$JP" "http://$IP/jenkins/api/json"
check "the last pipeline run succeeded" bash -c \
    "curl -fsS -u admin:$JP http://$IP/jenkins/job/infra-insight/lastBuild/api/json | grep -q '\"result\":\"SUCCESS\"'"
check "the app runs an image built by the pipeline" bash -c \
    "kubectl -n app get deploy backend -o jsonpath='{.spec.template.spec.containers[0].image}' | grep -qv ':initial'"

echo "Monitoring"
check "every Prometheus target is up" bash -c \
    "curl -fsS -u ops:$OPS 'http://$IP/prometheus/api/v1/query?query=min(up)' | grep -q '\"1\"\]'"
check "alert rules are loaded" bash -c \
    "curl -fsS -u ops:$OPS http://$IP/prometheus/api/v1/rules | grep -q KubeAPIServerDown"
check "Alertmanager is ready" curl -fsS -u "ops:$OPS" "http://$IP/alertmanager/-/ready"
check "Grafana has the three dashboards" bash -c \
    "curl -fsS -u admin:$GP 'http://$IP/grafana/api/search?type=dash-db' | grep -o '\"uid\"' | wc -l | grep -q 3"

echo "Logging"
check "Elasticsearch cluster is green" bash -c "$(declare -f es); EP=$EP es _cluster/health | grep -q '\"status\":\"green\"'"
check "logs of the last 5 minutes are in Elasticsearch" bash -c \
    "$(declare -f es); EP=$EP es 'k8s-logs-*/_count?q=@timestamp:>now-5m' | grep -vq '\"count\":0'"
check "Kibana has the three dashboards" bash -c \
    "curl -fsS -u elastic:$EP 'http://$IP/kibana/api/saved_objects/_find?type=dashboard' | grep -q '\"total\":3'"

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; exit 1; fi
