# Security

What protects the cluster and where it is configured.

## Pod Security Admission

Every namespace carries an `enforce` level ([manifests/namespaces](../manifests/namespaces/namespaces.yaml));
the API server rejects pods that break it. `audit: restricted` logs anything that would fail
the strictest level.

| Namespace | Level | Why not stricter |
|---|---|---|
| `app`, `registry` | restricted | – |
| `jenkins` | baseline | Kaniko must run as root to unpack image layers (still unprivileged, no host access) |
| `ingress` | privileged | Traefik binds port 80 of the node (`hostPort`) |
| `monitoring` | privileged | node-exporter reads the host's `/proc`, `/sys`, `/` and uses the host network |
| `logging` | privileged | Fluent Bit reads the node's log files (`hostPath`, read-only) |

## Containers

Unless a component can't work that way, every container has:

- `runAsNonRoot: true` with an explicit user (Fluent Bit and Kaniko are the two root
  exceptions above, both without capabilities)
- `allowPrivilegeEscalation: false`, `capabilities: drop [ALL]`, seccomp `RuntimeDefault`
- `readOnlyRootFilesystem: true`, with `emptyDir` volumes only where the app must write
  (`/tmp`, nginx's rendered config) — not possible for Elasticsearch and the build tools
- requests and limits; LimitRange defaults catch any container that has none, ResourceQuotas
  cap the `app` and `jenkins` namespaces
- `enableServiceLinks: false` (no Service variables injected into the environment) and
  `automountServiceAccountToken: false` when the pod never calls the Kubernetes API

The app images were changed for this: the backend runs as the `node` user without npm in the
final image, the frontend runs on `nginxinc/nginx-unprivileged` (uid 101, port 8080), and both
apply Alpine's security updates at build time.

## RBAC

One ServiceAccount per component, bound to the narrowest role it needs:

| Account | Can do |
|---|---|
| `jenkins/jenkins` | create / watch / delete pods (build agents) in `jenkins` only |
| `jenkins/jenkins-deployer` | update Deployments, Services, ConfigMaps, Ingress, HPA, PDB in `app` only — no Secrets, no deletes |
| `monitoring/prometheus` | read nodes, pods, services, endpoints (discovery) and the kubelet's metrics |
| `monitoring/kube-state-metrics` | list/watch the object kinds it reports — no Secrets or ConfigMaps |
| `logging/fluent-bit` | read pods, namespaces and events |
| `ingress/traefik` | read Ingresses, Services, EndpointSlices, Secrets; update Ingress status |

## Secrets

[scripts/create-secrets.sh](../scripts/create-secrets.sh) generates a random password per
user on the first deploy, keeps them in `.secrets/credentials.env` (ignored by git) and
creates the Kubernetes Secrets: `jenkins-admin`, `grafana-admin`,
`elasticsearch-credentials` (elastic, kibana_system, fluentbit, exporter, Kibana encryption
key), `ops-basic-auth` (htpasswd for the ingress) and `alert-webhook`. Pods read them through
`secretKeyRef`; nothing secret is in a manifest or an image.

Elasticsearch has its security enabled, and each client has its own user:

| User | Privileges |
|---|---|
| `kibana_system` | Kibana's built-in service user |
| `fluentbit` | `create_index` and `write` on `k8s-logs-*` only |
| `es-exporter` | `monitor` (cluster health and stats) only |
| `elastic` | superuser, used by people to log in to Kibana |

## Network

- Only Traefik is reachable from outside the cluster. Prometheus and Alertmanager have no
  login of their own, so the ingress asks for basic auth (`ops` user) before them.
- [network-policies/](network-policies) — optional, Calico enforces them:

  ```bash
  kubectl apply -k security/network-policies
  ```

  Each namespace denies all incoming traffic by default, then allows exactly the flows the
  platform uses: Traefik → frontend → backend, Prometheus → metrics endpoints, Fluent Bit /
  Kibana / exporter → Elasticsearch, Alertmanager → alert-receiver, build agents → registry
  and → the app (smoke test). The node (kubelet probes, image pulls) is always allowed.

  ```bash
  # from a random pod, the backend is now unreachable; through the frontend it still works
  kubectl run probe --rm -it --restart=Never --image=busybox:1.38.0 -- \
      wget -T 5 -qO- http://backend.app.svc.cluster.local:3001/health    # times out
  curl http://$(minikube ip)/api/health                                  # {"status":"ok"}
  ```

## Images and supply chain

- Every image tag is pinned; nothing runs from `latest`.
- Trivy scans every image the pipeline builds and fails the build on any CRITICAL finding,
  before the deploy stage (see the README for the two real findings it caught).
- Trivy is pinned to 0.76.1: the 0.69.4–0.69.6 releases were compromised in a supply-chain
  attack in March 2026.
- Kaniko comes from the maintained fork (`martizih/kaniko`, osscontainertools): Google archived
  the original project in 2025.
- Traefik instead of ingress-nginx: ingress-nginx was retired in March 2026 and gets no more
  security fixes.
