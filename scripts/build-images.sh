#!/usr/bin/env bash
# Builds the images the cluster needs before Jenkins can build anything itself (the app,
# the Jenkins controller and the CI tools image) inside the Minikube node, and pushes them
# to the in-cluster registry. Images already in the registry are skipped (FORCE=1 rebuilds).
#
#   scripts/build-images.sh            # all images
#   scripts/build-images.sh backend    # just one
set -euo pipefail
cd "$(dirname "$0")/.."

REGISTRY=10.96.0.50
TAG=${TAG:-initial}

declare -A CONTEXT=(
    [backend]=backend
    [frontend]=frontend
    [jenkins]=cicd/jenkins
    [ci-tools]=cicd/tools
)

in_registry() {
    minikube ssh -- "curl -sf http://$REGISTRY/v2/$1/tags/list" 2>/dev/null | grep -q "\"$TAG\""
}

images=("$@")
[ ${#images[@]} -gt 0 ] || images=(backend frontend jenkins ci-tools)

for name in "${images[@]}"; do
    image=$REGISTRY/$name:$TAG
    if [ "${FORCE:-0}" != 1 ] && in_registry "$name"; then
        echo "==> $image is already in the registry"
        continue
    fi
    echo "==> building $image from ${CONTEXT[$name]}"
    minikube image build -t "$image" "${CONTEXT[$name]}"
    echo "==> pushing $image"
    minikube ssh -- "sudo nerdctl --namespace k8s.io push --insecure-registry $image" >/dev/null
done
