#!/usr/bin/env bash
# Breaks things on purpose to show the whole alerting chain:
#   Prometheus rule (pending -> firing) -> Alertmanager -> alert-receiver (-> Slack/Discord)
# Every scenario cleans up after itself; "cleanup" removes leftovers of an interrupted run.
#
#   scripts/simulate-alerts.sh <scenario>
#   kubectl -n monitoring logs -f deploy/alert-receiver     # notifications as they arrive
set -euo pipefail
cd "$(dirname "$0")/.."

NS=alert-tests
CREDS=.secrets/credentials.env
get() { grep "^$1=" "$CREDS" | cut -d= -f2-; }
IP=$(minikube ip)
OPS=$(get OPS_PASSWORD)
EP=$(get ELASTIC_PASSWORD)
FILL=/mnt/sda1/alert-test.fill
APISERVER=/etc/kubernetes/manifests/kube-apiserver.yaml

usage() {
    cat <<EOF
usage: scripts/simulate-alerts.sh <scenario>

  node-cpu          busy loops on every CPU for 9 minutes        -> NodeHighCPU
  node-memory       fills the node's memory to ~93% for 9 min    -> NodeHighMemory
  node-disk         fills the node's disk to ~83% for 3 minutes  -> NodeLowDiskSpace
  pod-restarts      a container that crashes again and again     -> PodRestartingTooOften
  container-memory  a container using ~85% of its memory limit   -> ContainerMemoryNearLimit
  pod-pending       a pod asking for 64 CPUs (never scheduled)   -> PodPendingTooLong
  apiserver         stops the Kubernetes API server for 3 min    -> KubeAPIServerDown
  es-yellow         an index whose replica can't be placed       -> ElasticsearchClusterYellow
  fluentbit         blocks writes to today's log index           -> FluentBitOutputErrors
  cleanup           removes whatever an interrupted run left behind
EOF
}

# prints the state of one alert (inactive / pending / firing) every 20s for a while
watch_alert() {
    local alert=$1 seconds=$2 end=$((SECONDS + $2))
    echo "watching $alert for $((seconds / 60)) min (Prometheus: http://$IP/prometheus/alerts)"
    while [ $SECONDS -lt $end ]; do
        state=$(curl -s -u "ops:$OPS" "http://$IP/prometheus/api/v1/query" \
            --data-urlencode "query=ALERTS{alertname=\"$alert\"}" \
            | { grep -o '"alertstate":"[a-z]*"' || true; } | sort -u | cut -d'"' -f4 | tr '\n' ' ')
        echo "  $(date +%H:%M:%S)  $alert: ${state:-inactive}"
        sleep 20
    done
}

test_namespace() {
    kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
    kubectl label namespace "$NS" pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null
}

# restricted-compliant pod with one container: test_pod <name> <image> <requests> <limits> <command...>
test_pod() {
    local name=$1 image=$2 requests=$3 limits=$4 arg cmd=""; shift 4
    for arg in "$@"; do
        arg=${arg//\\/\\\\}
        cmd+="\"${arg//\"/\\\"}\", "
    done
    cmd="[${cmd%, }]"
    kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $name
spec:
  securityContext:
    runAsNonRoot: true
    runAsUser: 1000
    seccompProfile: { type: RuntimeDefault }
  containers:
    - name: $name
      image: $image
      command: $cmd
      resources: { requests: $requests, limits: $limits }
      securityContext:
        allowPrivilegeEscalation: false
        capabilities: { drop: [ALL] }
EOF
}

es() { kubectl -n logging exec elasticsearch-0 -- curl -s -u "elastic:$EP" -H 'Content-Type: application/json' "$@"; echo; }

case "${1:-}" in
node-cpu)
    test_namespace
    cpus=$(kubectl get nodes -o jsonpath='{.items[0].status.capacity.cpu}')
    echo "starting $cpus busy loops (one per CPU)"
    for i in $(seq 1 "$cpus"); do
        test_pod "cpu-burner-$i" busybox:1.38.0 '{cpu: 10m, memory: 8Mi}' '{cpu: "1", memory: 16Mi}' \
            sh -c 'while :; do :; done'
    done
    watch_alert NodeHighCPU 540
    kubectl delete namespace "$NS" --wait=false
    ;;
node-memory)
    test_namespace
    read -r total avail < <(minikube ssh -- \
        "awk '/MemTotal/ {t=\$2} /MemAvailable/ {a=\$2} END {print int(t/1024), int(a/1024)}' /proc/meminfo" | tr -d '\r')
    mb=$(( total * 93 / 100 - (total - avail) ))
    [ "$mb" -gt 64 ] || mb=64
    echo "node memory: ${total} MB total, $((total - avail)) MB used -> allocating ${mb} MB more"
    # small request (schedules anywhere), limit just above what it allocates
    test_pod memory-hog python:3.14.10-alpine3.24 '{cpu: 10m, memory: 64Mi}' "{cpu: 500m, memory: $((mb + 128))Mi}" \
        python3 -c "import time; data = b'1' * ($mb * 1024 * 1024); time.sleep(3600)"
    watch_alert NodeHighMemory 540
    kubectl delete namespace "$NS" --wait=false
    ;;
node-disk)
    read -r size avail < <(minikube ssh -- "df -k /mnt/sda1 | awk 'NR == 2 {print \$2, \$4}'" | tr -d '\r')
    # 17% free: under the 20% alert threshold, above the kubelet's image cleanup at 85% used
    fill=$(( avail - size * 17 / 100 ))
    echo "disk: $((size / 1048576)) GB, $((avail / 1048576)) GB free -> writing a $((fill / 1048576)) GB file"
    trap 'minikube ssh -- "sudo rm -f $FILL"' EXIT
    minikube ssh -- "sudo fallocate -l ${fill}k $FILL"
    watch_alert NodeLowDiskSpace 180
    ;;
pod-restarts)
    test_namespace
    test_pod crashloop busybox:1.38.0 '{cpu: 10m, memory: 8Mi}' '{cpu: 100m, memory: 16Mi}' \
        sh -c 'echo "crashing on purpose"; sleep 5; exit 1'
    watch_alert PodRestartingTooOften 300
    kubectl -n "$NS" delete pod crashloop --wait=false
    ;;
container-memory)
    test_namespace
    # ~110 MB of a 128 MiB limit
    test_pod memory-limit python:3.14.10-alpine3.24 '{cpu: 10m, memory: 64Mi}' '{cpu: 100m, memory: 128Mi}' \
        python3 -c "import time; data = b'1' * (100 * 1024 * 1024); time.sleep(3600)"
    watch_alert ContainerMemoryNearLimit 240
    kubectl -n "$NS" delete pod memory-limit --wait=false
    ;;
pod-pending)
    test_namespace
    test_pod unschedulable busybox:1.38.0 '{cpu: "64", memory: 8Mi}' '{cpu: "64", memory: 16Mi}' sleep 3600
    watch_alert PodPendingTooLong 400
    kubectl -n "$NS" delete pod unschedulable --wait=false
    ;;
apiserver)
    echo "stopping kube-apiserver (kubelet removes the static pod when its manifest disappears)"
    trap 'minikube ssh -- "sudo mv /etc/kubernetes/kube-apiserver.yaml.stopped $APISERVER 2>/dev/null || true"' EXIT
    minikube ssh -- "sudo mv $APISERVER /etc/kubernetes/kube-apiserver.yaml.stopped"
    watch_alert KubeAPIServerDown 180
    echo "starting kube-apiserver again"
    minikube ssh -- "sudo mv /etc/kubernetes/kube-apiserver.yaml.stopped $APISERVER"
    trap - EXIT
    # (not "kubectl get --raw /readyz": Git Bash rewrites arguments that start with "/")
    until kubectl get nodes >/dev/null 2>&1; do sleep 5; done
    echo "API server is back"
    ;;
es-yellow)
    # one node can't hold a primary and its replica: the replica stays unassigned -> yellow
    es -X PUT localhost:9200/alert-test-yellow -d '{"settings": {"number_of_shards": 1, "number_of_replicas": 1}}'
    trap 'es -X DELETE localhost:9200/alert-test-yellow' EXIT
    watch_alert ElasticsearchClusterYellow 150
    ;;
fluentbit)
    index=k8s-logs-$(date -u +%Y.%m.%d)
    echo "blocking writes to $index: Fluent Bit's bulk requests get rejected"
    es -X PUT "localhost:9200/$index/_settings" -d '{"index.blocks.write": true}'
    trap "es -X PUT 'localhost:9200/$index/_settings' -d '{\"index.blocks.write\": false}'" EXIT
    watch_alert FluentBitOutputErrors 240
    ;;
cleanup)
    kubectl delete namespace "$NS" --ignore-not-found --wait=false
    minikube ssh -- "sudo rm -f $FILL; sudo mv /etc/kubernetes/kube-apiserver.yaml.stopped $APISERVER 2>/dev/null || true"
    es -X DELETE localhost:9200/alert-test-yellow || true
    es -X PUT "localhost:9200/k8s-logs-*/_settings" -d '{"index.blocks.write": false}' || true
    ;;
*)
    usage
    exit 1
    ;;
esac
