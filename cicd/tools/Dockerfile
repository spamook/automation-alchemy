# Small image for the pipeline's deploy and smoke-test steps: kubectl + curl + a shell.
FROM alpine:3.24.3
ARG KUBECTL_VERSION=v1.35.10
RUN apk add --no-cache curl ca-certificates \
    && curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    && echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl.sha256")  /usr/local/bin/kubectl" \
       | sha256sum -c - \
    && chmod +x /usr/local/bin/kubectl
USER 1000:1000
