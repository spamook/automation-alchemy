#!/usr/bin/env bash
# Creates (or starts) the Minikube cluster and prepares the node for this project.
# Safe to run again: every step only changes what is missing.
#
#   MINIKUBE_MEMORY=8000 MINIKUBE_CPUS=8 scripts/cluster-up.sh
set -euo pipefail

MEMORY=${MINIKUBE_MEMORY:-7000}
CPUS=${MINIKUBE_CPUS:-6}
DISK=${MINIKUBE_DISK:-40g}
DRIVER=${MINIKUBE_DRIVER:-virtualbox}
K8S_VERSION=${K8S_VERSION:-v1.35.10}
REGISTRY_IP=10.96.0.50

driver_args=(--driver="$DRIVER")
if [ "$DRIVER" = virtualbox ]; then
    # Reuse VirtualBox's default host-only network: creating a new one needs admin rights on Windows
    driver_args+=(--host-only-cidr="${HOST_ONLY_CIDR:-192.168.56.1/24}")
fi

if [ "$(minikube status --format '{{.Host}}' 2>/dev/null)" = Running ]; then
    echo "==> minikube is already running"
else
    echo "==> starting minikube (${CPUS} CPUs, ${MEMORY} MB RAM, Kubernetes ${K8S_VERSION})"
    # calico: a CNI that enforces NetworkPolicies
    # insecure-registry: lets the node pull over plain HTTP from the in-cluster registry
    minikube start "${driver_args[@]}" \
        --cpus="$CPUS" --memory="$MEMORY" --disk-size="$DISK" \
        --kubernetes-version="$K8S_VERSION" \
        --container-runtime=containerd \
        --cni=calico \
        --insecure-registry="$REGISTRY_IP" \
        --addons=metrics-server
fi

echo "==> preparing the node"
# - one directory per PersistentVolume, owned by the user the app inside runs as
# - containerd: plain HTTP (and push) for the in-cluster registry; written on every run
#   because /etc lives in RAM on the Minikube VM
minikube ssh -- "sudo sh -c '
    install -d -o 1000  -g 1000  -m 0750 /data/registry /data/jenkins /data/trivy-cache
    install -d -o 65534 -g 65534 -m 0750 /data/prometheus
    install -d -o 472   -g 472   -m 0750 /data/grafana
    install -d -o 1000  -g 0     -m 0770 /data/elasticsearch
    mkdir -p /etc/containerd/certs.d/$REGISTRY_IP
    printf \"server = \\\"http://$REGISTRY_IP\\\"\n\n[host.\\\"http://$REGISTRY_IP\\\"]\n  capabilities = [\\\"pull\\\", \\\"resolve\\\", \\\"push\\\"]\n  skip_verify = true\n\" \
        > /etc/containerd/certs.d/$REGISTRY_IP/hosts.toml
'"

echo "==> cluster is ready: $(minikube ip)"
kubectl get nodes
