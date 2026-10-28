#!/usr/bin/env bash
# Prints every URL of the project with its login.
set -euo pipefail
cd "$(dirname "$0")/.."

IP=$(minikube ip)
CREDS=.secrets/credentials.env
pass() { grep "^$1=" "$CREDS" 2>/dev/null | cut -d= -f2- || echo "(run scripts/create-secrets.sh)"; }

cat <<EOF

  App            http://$IP/
  Jenkins        http://$IP/jenkins/        admin / $(pass JENKINS_ADMIN_PASSWORD)
  Grafana        http://$IP/grafana/        admin / $(pass GRAFANA_ADMIN_PASSWORD)
  Kibana         http://$IP/kibana/         elastic / $(pass ELASTIC_PASSWORD)
  Prometheus     http://$IP/prometheus/     ops / $(pass OPS_PASSWORD)
  Alertmanager   http://$IP/alertmanager/   ops / $(pass OPS_PASSWORD)

  Alert notifications:  kubectl -n monitoring logs -f deploy/alert-receiver
EOF
