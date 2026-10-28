#!/usr/bin/env bash
# Generates every password once, keeps them in .secrets/credentials.env (ignored by git)
# and stores them in the cluster as Kubernetes Secrets. Running it again keeps the
# same passwords, so it is safe after "minikube delete" too.
set -euo pipefail
cd "$(dirname "$0")/.."

CREDS=.secrets/credentials.env
mkdir -p .secrets
touch "$CREDS"
chmod 600 "$CREDS"

random() { head -c 32 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c "${1:-20}"; }
ensure() { grep -q "^$1=" "$CREDS" || echo "$1=$2" >> "$CREDS"; }

ensure JENKINS_ADMIN_PASSWORD "$(random)"
ensure GRAFANA_ADMIN_PASSWORD "$(random)"
ensure ELASTIC_PASSWORD "$(random)"
ensure KIBANA_SYSTEM_PASSWORD "$(random)"
ensure FLUENTBIT_ES_PASSWORD "$(random)"
ensure ES_EXPORTER_PASSWORD "$(random)"
ensure KIBANA_ENCRYPTION_KEY "$(random 32)"
ensure OPS_PASSWORD "$(random)"
# Optional: a Slack-compatible incoming webhook (Slack, or Discord with /slack at the end)
# that receives every alert too. Empty = alerts only go to the in-cluster receiver.
ensure ALERT_WEBHOOK_URL ""
# apr1 hash for Traefik basic auth, stored so the Secret doesn't change on every run.
# Single quotes: the hash contains "$" characters.
if ! grep -q '^OPS_HTPASSWD=' "$CREDS"; then
    ops_password=$(grep '^OPS_PASSWORD=' "$CREDS" | cut -d= -f2-)
    echo "OPS_HTPASSWD='ops:$(openssl passwd -apr1 "$ops_password")'" >> "$CREDS"
fi

set -a
# shellcheck disable=SC1090
source "$CREDS"
set +a

apply_secret() {
    kubectl create secret generic "$@" --dry-run=client -o yaml | kubectl apply -f -
}

apply_secret jenkins-admin -n jenkins \
    --from-literal=username=admin \
    --from-literal=password="$JENKINS_ADMIN_PASSWORD"
apply_secret grafana-admin -n monitoring \
    --from-literal=username=admin \
    --from-literal=password="$GRAFANA_ADMIN_PASSWORD"
apply_secret alert-webhook -n monitoring \
    --from-literal=url="$ALERT_WEBHOOK_URL"
apply_secret elasticsearch-credentials -n logging \
    --from-literal=elastic-password="$ELASTIC_PASSWORD" \
    --from-literal=kibana-system-password="$KIBANA_SYSTEM_PASSWORD" \
    --from-literal=fluentbit-password="$FLUENTBIT_ES_PASSWORD" \
    --from-literal=exporter-password="$ES_EXPORTER_PASSWORD" \
    --from-literal=kibana-encryption-key="$KIBANA_ENCRYPTION_KEY"
apply_secret ops-basic-auth -n ingress \
    --from-literal=users="$OPS_HTPASSWD"
