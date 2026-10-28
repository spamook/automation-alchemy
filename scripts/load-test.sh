#!/usr/bin/env bash
# Sends load to the frontend through the ingress (like real users) and prints how the
# HorizontalPodAutoscaler adds replicas, then removes them once the load stops.
#
#   scripts/load-test.sh            # 3 minutes, 32 parallel connections
#   scripts/load-test.sh 5m 64
set -euo pipefail

DURATION=${1:-3m}
CONNECTIONS=${2:-32}
IMAGE=fortio/fortio:1.76.0

kubectl create namespace load-test --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n load-test delete pod fortio --ignore-not-found >/dev/null
kubectl -n load-test run fortio --image="$IMAGE" --restart=Never --overrides="$(cat <<EOF
{"spec": {
  "securityContext": {"runAsNonRoot": true, "runAsUser": 1000, "seccompProfile": {"type": "RuntimeDefault"}},
  "containers": [{
    "name": "fortio", "image": "$IMAGE",
    "args": ["load", "-qps", "0", "-c", "$CONNECTIONS", "-t", "$DURATION",
             "http://traefik.ingress.svc.cluster.local/"],
    "resources": {"requests": {"cpu": "200m", "memory": "64Mi"}, "limits": {"cpu": "1", "memory": "128Mi"}},
    "securityContext": {"allowPrivilegeEscalation": false, "capabilities": {"drop": ["ALL"]}}
  }]
}}
EOF
)" >/dev/null
echo "load: $CONNECTIONS connections for $DURATION -> http://traefik.ingress.svc.cluster.local/"
echo "watch it in Grafana too: Application Performance -> Frontend replicas (HPA)"
echo

# print the HPA every 15s: during the load and until it has scaled back down to 2
minimum=$(kubectl -n app get hpa frontend -o jsonpath='{.spec.minReplicas}')
seen_load=0
while :; do
    hpa=$(kubectl -n app get hpa frontend -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization} {.status.currentReplicas} {.status.desiredReplicas}')
    read -r cpu replicas desired <<< "$hpa"
    phase=$(kubectl -n load-test get pod fortio -o jsonpath='{.status.phase}' 2>/dev/null || echo gone)
    printf '%s  cpu %4s%% of request (target 50%%)   replicas %s -> %s   load: %s\n' \
        "$(date +%H:%M:%S)" "${cpu:-?}" "$replicas" "$desired" "$phase"
    [ "$replicas" -gt "$minimum" ] && seen_load=1
    if [ "$phase" != Running ] && [ "$phase" != Pending ] && { [ "$seen_load" = 1 ] && [ "$replicas" -le "$minimum" ]; }; then
        break
    fi
    if [ "$phase" = Succeeded ] && [ "$seen_load" = 0 ]; then
        echo "the load finished without a scale-up (try more connections)"; break
    fi
    sleep 15
done

echo
kubectl -n load-test logs fortio --tail=30 2>/dev/null | grep -E "^(All done|Code|Sockets used|# target)" || true
kubectl delete namespace load-test --wait=false >/dev/null
