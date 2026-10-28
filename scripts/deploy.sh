#!/usr/bin/env bash
# Deploys the whole project to the running cluster (start it with scripts/cluster-up.sh).
# Safe to run again: it only changes what differs from the manifests.
set -euo pipefail
cd "$(dirname "$0")/.."

REGISTRY=10.96.0.50
step() { printf '\n==> %s\n' "$*"; }

step "namespaces, limits and storage"
kubectl apply -k manifests/namespaces
kubectl apply -k manifests/storage

step "secrets"
scripts/create-secrets.sh

step "image registry"
kubectl apply -k manifests/registry
kubectl -n registry rollout status deployment/registry --timeout=300s

step "bootstrap images (built inside the node, skipped when already in the registry)"
scripts/build-images.sh

step "all manifests"
# The manifests carry the bootstrap tag "initial". Once the pipeline has deployed newer
# images, keep those: apply through a generated overlay with the tags that run now.
tag_of() {
    local image
    # empty on a fresh cluster, where the deployment doesn't exist yet
    image=$(kubectl -n app get deployment "$1" -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null) || true
    if [ -n "$image" ]; then echo "${image##*:}"; fi
}
backend_tag=$(tag_of backend); frontend_tag=$(tag_of frontend)
ip=$(minikube ip)
mkdir -p .deploy
cat > .deploy/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../manifests
images:
  - name: $REGISTRY/backend
    newTag: "${backend_tag:-initial}"
  - name: $REGISTRY/frontend
    newTag: "${frontend_tag:-initial}"
# the address Jenkins, Kibana and Alertmanager use in the links they generate
configMapGenerator:
  - name: jenkins-env
    namespace: jenkins
    behavior: merge
    literals:
      - JENKINS_PUBLIC_URL=http://$ip/jenkins/
patches:
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: kibana
        namespace: logging
      spec:
        template:
          spec:
            containers:
              - name: kibana
                env:
                  - name: SERVER_PUBLICBASEURL
                    value: http://$ip/kibana
  - patch: |-
      apiVersion: apps/v1
      kind: Deployment
      metadata:
        name: alertmanager
        namespace: monitoring
      spec:
        template:
          spec:
            containers:
              - name: alertmanager
                env:
                  - name: PUBLIC_URL
                    value: http://$ip/alertmanager/
EOF
# a Job's pod template can't change: remove finished setup Jobs so new versions run
kubectl -n logging delete job elasticsearch-setup kibana-setup --ignore-not-found
kubectl apply -k .deploy

step "waiting for everything to start (first run: images are pulled, can take 10+ minutes)"
for target in \
    ingress/deployment/traefik \
    app/deployment/backend app/deployment/frontend \
    jenkins/deployment/jenkins \
    monitoring/deployment/prometheus monitoring/deployment/alertmanager \
    monitoring/deployment/alert-receiver monitoring/deployment/grafana \
    monitoring/deployment/kube-state-metrics monitoring/daemonset/node-exporter \
    logging/statefulset/elasticsearch logging/daemonset/fluent-bit \
    logging/deployment/kibana logging/deployment/elasticsearch-exporter; do
    kubectl -n "${target%%/*}" rollout status "${target#*/}" --timeout=900s
done
kubectl -n logging wait --for=condition=complete job/elasticsearch-setup job/kibana-setup --timeout=900s

scripts/info.sh
