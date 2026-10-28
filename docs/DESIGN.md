# Design decisions

Why the cluster looks the way it does, and the problems met while building it.

## Cluster

**Minikube on VirtualBox.** The host is Windows with the Hyper-V hypervisor turned off
(VirtualBox is several times faster on raw AMD-V/VT-x), so Docker Desktop / WSL2 — and with
them Minikube's docker driver — aren't available. The VirtualBox driver runs a real VM, close
to a cloud node. `scripts/cluster-up.sh` reuses VirtualBox's default host-only network
`192.168.56.1/24`: creating a new one on Windows needs administrator rights.

**containerd + Calico.** containerd is Minikube's default runtime (Kubernetes no longer talks
to Docker directly). Calico is the CNI because it enforces NetworkPolicies; the default bridge
network silently ignores them.

**Kubernetes 1.35.** kubectl supports one minor version of skew in each direction; 1.35 works
with kubectl 1.34–1.36, the versions people usually have installed.

**Plain manifests + Kustomize, no Helm.** Every object is a readable YAML file, and Kustomize
(built into kubectl) adds what is missing: configuration files next to the manifests become
ConfigMaps with a content hash in their name, so editing `prometheus.yml` and re-applying
rolls Prometheus automatically. A chart such as kube-prometheus-stack would bring an operator,
CRDs and about twice the memory, and hide most of what there is to learn.

## Images

**An in-cluster registry on a fixed ClusterIP.** The VM version used a private registry VM;
here the registry is a Deployment with a PersistentVolume. The node's container runtime pulls
images itself and can't resolve cluster DNS names, so the Service has a fixed address from
the static range, `10.96.0.50`, on port 80 (image names stay short: `10.96.0.50/backend:12-ab12cd3`).
It speaks plain HTTP: it is only reachable inside the cluster, and containerd is told to
trust it.

**Bootstrap images.** Before Jenkins exists something has to build the app, Jenkins and the
CI tools image. `scripts/build-images.sh` builds them inside the node (BuildKit) and pushes
them as `:initial`; from then on the pipeline builds everything.

**Hardened app images.** Node 20 reached end of life in April 2026 and nginx 1.25 is long out
of support, so the images moved to Node 24 LTS and `nginx-unprivileged` 1.30 (uid 101, port
8080). The backend's final image has no npm, both images apply Alpine's security updates at
build time.

## Networking

**Traefik instead of the minikube ingress addon.** The addon installs ingress-nginx, which
was retired in March 2026 (no further releases or security fixes). Traefik implements the
same Ingress API, so the Ingress objects are standard. It binds port 80 of the node through
`hostPort`, so no `minikube tunnel` (which needs admin rights) is required.

**Routing by path on one address.** Every tool runs under its own base path (`/jenkins`,
`/grafana`, `/kibana`, `/prometheus`, `/alertmanager`), so everything works on the bare
Minikube IP without DNS or editing the hosts file.

**Basic auth at the ingress.** Prometheus and Alertmanager have no login, so a Traefik
middleware (file provider, users from a Secret) asks for one. Jenkins, Grafana and Kibana
have their own.

## CI/CD

**Jenkins with Kubernetes agents.** Same tool as before, but nothing runs on the controller:
every build is a pod with one container per tool (node, kaniko, trivy, kubectl), deleted when
the build ends. The controller is configured completely by Configuration as Code + Job DSL
(security realm, Kubernetes cloud, the pipeline job), and its plugins are baked into its
image, so a wiped volume comes back identical.

**Kaniko** builds images from a Dockerfile without a Docker daemon. The alternatives were
Docker-in-Docker (a privileged container) or mounting the node's runtime socket (root on the
node). Google archived Kaniko in 2025; the maintained osscontainertools fork is used.

**Trivy gate.** Each image is scanned in the registry before anything is deployed; any
CRITICAL vulnerability fails the build. Trivy is pinned to 0.76.1, well past the releases
compromised in March 2026.

**Deploy with the same manifests.** The pipeline applies `manifests/backend` and
`manifests/frontend` through a small generated Kustomize overlay that only changes the image
tags (`<build>-<commit>`), so a config change in git is deployed the same way as code. A
failed smoke test rolls both deployments back.

**Polling instead of webhooks.** GitHub can't reach a Jenkins inside a local VM, so Jenkins
polls the repository every two minutes.

**Least privilege.** Two ServiceAccounts: the controller can only manage pods in `jenkins`,
the agents can only update the app's objects in `app`.

## Storage

**Static PersistentVolumes.** Minikube has a dynamic provisioner, but then the PV step is
invisible. Here an administrator-style StorageClass without provisioner plus one hostPath PV
per component, each reserved for one claim with `claimRef`, and `Retain` so deleting a claim
keeps the data. The directories live under `/data`, which Minikube keeps across VM restarts.
`hostPath` volumes ignore `fsGroup`, so `cluster-up.sh` creates each directory owned by the
user its app runs as, and the PV uses `type: Directory` so a missing directory fails loudly.

## Monitoring

- **Service discovery** through the Kubernetes API, plus a `prometheus.io/scrape` annotation
  convention for application pods: a new pod is scraped without touching Prometheus.
- **Keep-lists** on the API server and cAdvisor jobs: they expose thousands of series, the
  dashboards need about ten.
- **`honor_labels`** on kube-state-metrics, whose `namespace`/`pod` labels describe the
  objects, not the exporter pod.
- **Rule details:** `changes()` counts restarts exactly (`increase()` extrapolates);
  `absent()` makes the API server alert fire even when there is no series at all; the disk
  alert groups by device because one disk is mounted at several paths on the VM;
  inhibition rules stop pod alerts while the API server is down.

## Logging

- **Fluent Bit rather than Fluentd:** about 20 MB of memory per node instead of ~200 MB,
  same job.
- **Only the app's JSON is parsed.** Parsing every container's JSON into top-level fields
  sooner or later makes two apps disagree on a field type, Elasticsearch rejects the
  documents and logs are lost. Our own apps (namespace `app`) are parsed; everything else
  stays as text in `log`.
- **Index template:** 0 replicas (a single node can't host replicas — otherwise the cluster
  is permanently yellow and the alert fires forever), strings as keywords, labels as
  `flattened`, date detection off, deletion after 7 days.
- **Security on** with a user per client instead of the default "no auth".
- **`node.store.allow_mmap: false`** instead of a privileged init container that raises
  `vm.max_map_count` on the node.

## Resource budget

The VM has 7 GB; Minikube's OS lives in RAM (~1.2 GB), so the platform must fit in roughly
5 GB. Measured steady-state usage:

| Component | Memory |
|---|---|
| Elasticsearch (512 MB heap) | ~900 MB |
| Kibana (needs 1 GB heap for its first start) | ~600–900 MB |
| Jenkins (512 MB heap) | ~650 MB |
| Kubernetes control plane + Calico | ~600 MB |
| Grafana | ~350 MB |
| Prometheus | ~100–250 MB |
| everything else | < 30 MB each |
| a running build agent | +0.5–1.3 GB while it runs |

## Problems met on the way

| Problem | Cause | Fix |
|---|---|---|
| `minikube start` would hang waiting for a UAC prompt | a new VirtualBox host-only network needs admin rights | reuse `192.168.56.1/24` |
| the node couldn't pull from the registry | with containerd, `--insecure-registry=10.96.0.0/12` became a meaningless `certs.d/10.96.0.0/12` directory | a fixed registry IP and an explicit containerd host config written by `cluster-up.sh` |
| pipeline #1 failed at the scan | CVE-2026-90711 (critical) in `proxy-addr`, pulled in by Express | updated the lockfile, `npm audit` clean |
| pipeline #2 failed at the scan | CVE-2026-111497 (critical) in Alpine's `brotli-libs` in the nginx base image | `apk upgrade` in both Dockerfiles |
| Elasticsearch and Kibana stuck in `ImagePullBackOff` | the version taken from Elastic's artifacts API (9.5.6) had no published image yet | checked the registry's tag list, pinned 9.5.5 |
| Kibana crash-looping | Kibana 9 runs out of a 512 MB heap during its first-start migrations | 1 GB heap, 1.4 GiB limit |
| StatefulSet kept the broken pod after the image fix | StatefulSets don't replace a pod that never became ready | deleted the pod once |
| `ElasticsearchUnreachable` kept firing with a healthy cluster | elasticsearch-exporter 1.11 no longer has `elasticsearch_cluster_health_up`, so `absent()` was always true | alert on `elasticsearch_clusterinfo_up` |
| `ContainerMemoryNearLimit` fired for Grafana | Grafana 13 needs ~350 MB, its limit was 384 MiB | limit raised to 512 MiB |

The monitoring caught several of these on its own: `ElasticsearchUnreachable`,
`PodPendingTooLong` (pods waiting for images), `FluentBitOutputErrors` (nowhere to send logs),
`PodRestartingTooOften` (Kibana) and `ContainerMemoryNearLimit` (Grafana) fired before anyone
looked, and resolved once the problems were fixed.
