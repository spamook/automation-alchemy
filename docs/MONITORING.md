# Monitoring & Logging

This document explains how monitoring, logging and alerting work in this project, how to
test every alert, and answers the "why / how" questions about the chosen tools.

- [Architecture](#architecture)
- [What runs where](#what-runs-where)
- [Metrics: Prometheus + Grafana](#metrics-prometheus--grafana)
- [Logs: Filebeat + ELK](#logs-filebeat--elk)
- [Dashboards](#dashboards)
- [Alerts](#alerts)
- [Testing the alerts](#testing-the-alerts)
- [Historical data & retention](#historical-data--retention)
- [Automation: Ansible + Jenkins](#automation-ansible--jenkins)
- [Troubleshooting](#troubleshooting)
- [Concepts & design decisions (Q&A)](#concepts--design-decisions-qa)

---

## Architecture

```
                         every VM (7x)                                     monitoring-server 192.168.56.16
 +--------------------------------------------------+     +---------------------------------------------------------------+
 |  node-exporter :9100   host CPU/RAM/disk/net      |<----|  Prometheus :9090  --scrapes every 15s (PULL)                  |
 |  cAdvisor      :8081   per-container metrics      |<----|     |                                                         |
 |  backend       :3001/prometheus (app-server,     |<----|     +--> Grafana :3000  dashboards + alert rules ------+     |
 |                 web sidecars) prom-client metrics |     |                                                       |     |
 |                                                  |     |  es-exporter :9114 (ES health -> Prometheus)           |     |
 |  Filebeat  --- syslog, auth.log, script logs,  ---|---->|  Logstash :5044  parse / normalize / match patterns --+|     |
 |                Docker container logs   (PUSH)     |     |     |                                                ||     |
 +--------------------------------------------------+     |     v                                                vv     |
                                                          |  Elasticsearch es01 (master+data) + es02 (data)   alert-    |
                                                          |     |                                            receiver  |
                                                          |     v                                            :9095     |
                                                          |  Kibana :5601  log dashboards + search                       |
                                                          +---------------------------------------------------------------+
```

Two independent pipelines:

| | Metrics | Logs |
|---|---|---|
| Model | **pull** — Prometheus fetches `/metrics` from targets | **push** — Filebeat sends lines to Logstash |
| Collect | node-exporter, cAdvisor, prom-client, es-exporter | Filebeat (system + container logs) |
| Store | Prometheus TSDB (30 days) | Elasticsearch, daily indices (30 days, alerts 90 days) |
| Visualize | Grafana | Kibana |
| Alert | Grafana alert rules | Logstash pattern rules |
| Notify | webhook -> `alert-receiver` (optionally forwarded to Slack/Discord) | same |

## What runs where

All components run as Docker containers.

| Component | VM | Port | Purpose |
|---|---|---|---|
| node-exporter | every VM | 9100 | host metrics |
| cAdvisor | every VM | 8081 | container metrics (8080 is Jenkins on ci-server) |
| Filebeat | every VM | – | ships logs to Logstash |
| Prometheus | monitoring-server | 9090 | metrics collection + storage |
| Grafana | monitoring-server | 3000 | dashboards, alerting (`admin` / `admin` by default) |
| Elasticsearch es01 | monitoring-server | 9200 (localhost only) | master + data node |
| Elasticsearch es02 | monitoring-server | – | data node (replicas) |
| es-exporter | monitoring-server | 9114 (internal) | ES cluster health as metrics |
| Logstash | monitoring-server | 5044 | Beats input, parsing, log alerts |
| Kibana | monitoring-server | 5601 | log search & dashboards |
| alert-receiver | monitoring-server | 9095 (internal) | receives Grafana + Logstash notifications |

Files:

```
monitoring/
├── docker-compose.yml                   # the whole server stack
├── prometheus/
│   ├── prometheus.yml                   # scrape interval, jobs
│   └── targets/{node,cadvisor,backend}.yml   # file-based service discovery
├── grafana/
│   ├── provisioning/datasources/        # Prometheus + Elasticsearch data sources
│   ├── provisioning/dashboards/         # loads dashboards/ into folder "Infrastructure"
│   ├── provisioning/alerting/rules.yml  # alert rules
│   ├── provisioning/alerting/notifications.yml  # contact point + notification policy
│   └── dashboards/*.json                # VM / Docker / Application dashboards
├── logstash/
│   ├── logstash.yml
│   └── pipeline/logstash.conf           # input -> filters -> outputs (+ alert rules)
├── setup/
│   ├── setup.sh                         # one-shot jobs es-setup / kibana-setup
│   ├── elasticsearch/                   # ILM policies, index templates, mappings
│   └── kibana/dashboards.ndjson         # data views + 3 dashboards
├── alert-receiver/receiver.py           # webhook receiver for notifications
└── agents/
    ├── docker-compose.yml               # node-exporter + cAdvisor + Filebeat
    └── filebeat.yml
```

---

## Metrics: Prometheus + Grafana

**Scrape interval.** `monitoring/prometheus/prometheus.yml` → `global.scrape_interval: 15s`.
15 s gives near real-time graphs (Grafana refreshes every 10 s) while keeping the load on
targets and the TSDB size small. To change it:

1. edit `scrape_interval` globally, or per job (a job-level value overrides the global one;
   `scrape_timeout` must stay ≤ the interval),
2. apply without restart: `curl -X POST http://localhost:9090/-/reload` on monitoring-server
   (enabled by `--web.enable-lifecycle`; the Jenkins pipeline does this automatically),
3. keep the Grafana data source `timeInterval` equal to it, so `$__rate_interval` is correct.

Shorter interval = more resolution but more samples (RAM/disk) and more load on exporters;
`rate()` windows must cover at least 2 scrapes (we use `[1m]` / `$__rate_interval`).

**Targets** are not hard-coded in `prometheus.yml` but in `targets/*.yml`
(`file_sd_configs`). Prometheus re-reads these files every minute, so adding a VM means
adding two lines — no restart. Each target has a `host` label used by dashboards and alerts.
Status of all targets: <http://192.168.56.16:9090/targets>.

**Application metrics.** The backend uses the official Node.js client library
[`prom-client`](https://github.com/siimon/prom-client) (`backend/src/prometheus.ts`):

| Metric | Type | Meaning |
|---|---|---|
| `nodejs_*`, `process_*` | default | heap, event-loop lag, GC, CPU, RSS (`collectDefaultMetrics`) |
| `http_request_duration_seconds` | histogram | every request, labels `method`, `route`, `status_code` → request rate, error rate, latency percentiles |
| `infra_metrics_served_total` | counter | **custom business metric**: how many times the backend served `/metrics` |

They are exposed in the Prometheus text format on `GET /prometheus`
(`/metrics` stays the JSON endpoint used by the adaptive load balancer):

```bash
curl -s http://192.168.56.13:3001/prometheus | grep -E '^(infra_metrics_served_total|http_request_duration_seconds_count)'
```

The `route` label uses the Express route pattern (`/metrics`), not the raw URL — otherwise
every random 404 path would create a new time series (cardinality explosion).

## Logs: Filebeat + ELK

**Shipping.** Filebeat on every VM reads

- `/var/log/syslog`, `/var/log/auth.log` → `fields.log_type: system`
- our scripts' logs (`adaptive_lb.log`, `backup.log`, `jenkins-notifications.log`) → `system`
- all container logs `/var/lib/docker/containers/*/*.log` → `fields.log_type: docker`
  (+ `container.name`, `container.image.name` from the Docker API)

and sends them to Logstash `192.168.56.16:5044`. Filebeat remembers its read offsets
(registry volume) and retries with backoff if Logstash is down, so nothing is lost.

**The application's logs.** The backend writes **structured JSON** to stdout with
[winston](https://github.com/winstonjs/winston) (`backend/src/logger.ts`), one line per
request with `method`, `path`, `status`, `durationMs`, and a level derived from the status
(5xx = `error`, 4xx = `warn`). Docker stores stdout, Filebeat ships it, Logstash parses it.
Logging to stdout (12-factor) instead of sending from the app directly means the app never
blocks or loses logs when Logstash is unavailable.

**Parsing in Logstash** (`monitoring/logstash/pipeline/logstash.conf`):

| Source | Filter | Result |
|---|---|---|
| system | `grok` with 3 patterns (classic syslog, RFC 3339 syslog, `[date] text` of our scripts) | `process.name`, `process.pid`, `log_message`, event time from the line (`date`) |
| backend containers | `json` (only if the line starts with `{`) | `app.level`, `app.method`, `app.path`, `app.status`, `app.durationMs`, `log.level` |
| other containers | – | raw `message`, `container.name`, `stream` |

Index per type: `infra-system-YYYY.MM.dd`, `infra-app-*`, `infra-docker-*`, `infra-alerts-*`.

**Handling inconsistent formats and parse errors** — the rule is *never drop a log line*:

- several grok patterns are tried in order (`match => { "message" => [p1, p2, p3] }`);
- a line that matches none is stored as-is with tag `_grokparsefailure_system`
  (Kibana: `tags : "_grokparsefailure_system"`; the System Logs dashboard counts them);
- JSON is only parsed when the line looks like JSON; stack traces etc. get tag `_not_json`,
  broken JSON gets `_jsonparsefailure` — both stay searchable;
- values are normalized: level lower-cased (`INFO` → `info`), `status`/`durationMs`
  converted to integers, so a logger that sends `"200"` as a string doesn't break the
  mapping; `event.original` keeps the untouched line;
- a failed timestamp parse gets `_dateparsefailure` and keeps the Filebeat read time;
- the index template maps fields explicitly (`app.status` = integer, strings = keyword), so
  a wrong type is rejected for that field instead of corrupting the index mapping.

**Elasticsearch cluster.** Two nodes: `es01` (master + data) and `es02` (data only).
Every index has 1 primary + 1 replica shard, placed on different nodes. If `es02` stops,
the replicas become unassigned → cluster health **yellow** (all data still available);
if a primary is missing → **red**. The cluster is a lab setup: no TLS/auth (private network
only, port 9200 bound to localhost).

---

## Dashboards

Grafana (<http://192.168.56.16:3000>, folder **Infrastructure**), data source Prometheus
(+ Elasticsearch for one log panel):

| Dashboard | Shows |
|---|---|
| **VM Performance** | UP/DOWN per VM, uptime, CPU %, memory %, load per core, disk used %, disk I/O, network — threshold lines = alert thresholds |
| **Docker Container Dashboard** (`Docker Containers`) | running containers, restarts in 15 min, CPU/memory per container, memory % of limit, network, uptime table |
| **Application Performance** | backend UP, requests/s, 5xx rate, p50/p95/p99 latency, requests by route/status, custom metric `infra_metrics_served_total`, Node.js heap / event loop / CPU, backend log levels from Elasticsearch |

Every dashboard has a `host` variable (and `container` on the Docker one) at the top,
auto-refresh 10 s and a time picker for history.

Kibana (<http://192.168.56.16:5601> → Dashboards):

| Dashboard | Data view | Shows |
|---|---|---|
| **System Logs** | `infra-system-*` | events over time per host, events by host, auth failures (SSH/sudo), top processes, unparsed lines, latest log table |
| **Application Logs** | `infra-app-*` | backend log lines by level, status codes, avg/p95 response time, top paths, errors & warnings table |
| **Docker Logs** | `infra-docker-*,infra-app-*` | log lines per container, volume by container, stderr per container, containers per host, latest container logs |

### Grafana query editor: filtering and aggregating

Panel → Edit → query editor (Code mode = PromQL, Builder mode = clicks):

- **filter** with label matchers: `node_load1{host="app-server"}`, regex `{host=~"web-.*"}`,
  negative `{device!~"lo|veth.*"}`; dashboard variables: `{host=~"$host"}`;
- **rates** for counters: `rate(http_request_duration_seconds_count[$__rate_interval])`;
- **aggregate** across series: `sum by (route) (...)`, `avg by (host)`, `max`, `count`,
  `topk(5, ...)`;
- **percentiles** from histograms: `histogram_quantile(0.95, sum by (le) (rate(..._bucket[5m])))`;
- **math between metrics**: `100 * used / total`;
- legend: `{{host}}`; "Instant" for a single value (stat/table), "Range" for graphs;
- **Transformations** tab: join/organize/filter results; **Explore** for ad-hoc queries.

### Kibana: search and filtering

- **KQL** in the search bar: `host.name : "app-server" and process.name : "sshd"`,
  `app.status >= 500`, `app.durationMs > 100`, `message : *timeout*`,
  `not container.name : "filebeat"`, `tags : "_grokparsefailure_system"`.
- **Filters** (pills under the search bar): click a value in a chart/table or the
  ➕/➖ icons in Discover; can be pinned across apps, negated, disabled temporarily.
- **Time picker**: relative (`Last 24 hours`) or absolute; drag-select on a chart to zoom.
- **Discover**: pick a data view, add columns (`host.name`, `log_message`), expand a document
  to see all fields, *surrounding documents* to see what happened right before/after a line.
- **Field statistics** (left sidebar): top 5 values of a field → quick anomaly spotting.

---

## Alerts

Grafana alert rules (`monitoring/grafana/provisioning/alerting/rules.yml`), evaluated every 30 s:

| Alert | PromQL (simplified) | Condition | Pending (`for`) | Severity |
|---|---|---|---|---|
| High CPU usage | `100 * (1 - avg by (host) (rate(node_cpu_seconds_total{mode=~"idle\|iowait"}[1m])))` | > 80 | 5m | warning |
| High memory usage | `100 * (1 - MemAvailable / MemTotal)` | > 90 | 5m | warning |
| Low disk space | `100 * avail / size` of `/` | < 20 | 1m | critical |
| VM unreachable | `max_over_time(up{job="node"}[2m])` (no successful scrape for 2 min) | < 1 | 1m | critical |
| Container restarting | `changes(container_start_time_seconds[15m])` | > 3 | 0 (the 15 min window is in the query) | warning |
| Container memory near limit | `working_set / (memory_limit > 0) * 100` | > 80 | 1m | warning |
| Elasticsearch cluster yellow or red | `elasticsearch_cluster_health_status{color=~"yellow\|red"}` | > 0 | 1m | critical |
| Elasticsearch unreachable | `count(elasticsearch_cluster_health_status) or vector(0)` (exporter publishes health only while ES answers) | < 1 | 1m | critical |
| Backend instance down | `max_over_time(up{job="backend"}[2m])` | < 1 | 1m | critical |

Notifications go to the **contact point** `alert-receiver` (webhook). The **notification
policy** groups alerts by `alertname` + `host`, waits 30 s to batch related alerts,
sends updates at most every 5 min and repeats a still-firing alert every 4 h (critical: 1 h).
Resolved alerts are sent too.

Log-based alerts in **Logstash** (section 3 of `logstash.conf`):

| Rule | Source | Pattern | Severity |
|---|---|---|---|
| `auth_failure` | auth.log / syslog | `Invalid user`, `authentication failure`, `incorrect password attempt`, `Failed password` | warning |
| `oom_killer` | syslog (kernel) | `Out of memory`, `oom-kill`, `Killed process` | critical |
| `ci_build_failed` | jenkins-notifications.log | `BUILD #N FAILED`, `ROLLBACK ... FAILED` | warning |
| `app_error` | backend JSON logs | `app.level == "error"` (5xx responses) | critical |

A matching line gets `alert.rule` / `alert.severity`, is stored in `infra-alerts-*` (history,
data view "Log alerts") and sent to the webhook. The `throttle` filter sends only the first
match per rule + host every 5 minutes (a brute-force attack = hundreds of lines = 1 notification).

Where to see notifications:

```bash
vagrant ssh monitoring-server -c "docker logs -f alert-receiver"
# 2026-10-04 15:02:11 [GRAFANA] FIRING warning: CPU usage on app-server is 100% (above 80% for 5 minutes)
# 2026-10-04 15:09:41 [GRAFANA] RESOLVED warning: CPU usage on app-server is 3% (above 80% for 5 minutes)
# 2026-10-04 15:12:03 [LOGSTASH] WARNING auth_failure on app-server: Invalid user hacker from 10.0.0.66 ...
```

To get them in Slack/Discord: set `alert_forward_webhook_url` in `ansible/group_vars/all.yml`
(Slack incoming webhook, or a Discord webhook URL + `/slack`) and re-provision.
In Grafana itself: **Alerting → Alert rules** (state Normal / Pending / Firing).

---

## Testing the alerts

`scripts/simulate-alerts.sh` creates every condition. Run it on the VM that should alert and
watch Grafana → Alerting → Alert rules (Normal → **Pending** → **Firing**) and the receiver log.

| Test | Command | Expected |
|---|---|---|
| CPU > 80% for 5 min | `vagrant ssh app-server -c "bash /vagrant/scripts/simulate-alerts.sh cpu"` (= `stress-ng --cpu 8 --timeout 420s`) | Pending after ~1 min, Firing 5 min later, Resolved when stress-ng ends |
| Disk < 20% free | `... simulate-alerts.sh disk` (= `fallocate` up to 85% used), then `... cleanup` | Firing after ~1–2 min |
| Memory > 90% for 5 min | `vagrant ssh web-server-1 -c "bash /vagrant/scripts/simulate-alerts.sh memory"` (holds usage at ~92% for 7 min, see notes) | Firing after ~5–6 min |
| Container restarts > 3 in 15 min | `... simulate-alerts.sh container-restarts` (= `docker run --restart=always --name test_container ubuntu bash -c "sleep 10; exit 1"`), then `... cleanup` | Firing after ~1–3 min |
| Container memory > 80% of limit | `... simulate-alerts.sh container-memory` (= `docker run -m 256m --name memory_test python:3.12-alpine` holding 225 MB — the task's 450M-of-512M scaled down for the 768 MB VMs) | Firing after ~2 min |
| VM unreachable | `vagrant ssh load-balancer -c "bash /vagrant/scripts/simulate-alerts.sh unreachable"` (= `sudo ip link set enp0s8 down` for 5 min) | Firing after ~3 min, resolves when the interface is back |
| Elasticsearch yellow | `vagrant ssh monitoring-server -c "bash /vagrant/scripts/simulate-alerts.sh es-yellow"` (= `docker stop es02`), then `es-green` | Firing after ~2 min, resolved a few minutes after es02 is back |
| Logstash log pattern | `... simulate-alerts.sh log-alert` or a real one: `ssh nobody@192.168.56.13` from another VM, or a wrong `sudo` password | notification within seconds |

Notes:

- **Run one test per VM at a time.** The VMs are tiny (1 vCPU, 640–768 MB, swap on the
  host disk): CPU stress + memory stress + a crash-looping container together make a VM so
  slow that even Docker's restart manager gives up, and the measurements get muddy.
- The VMs have 1–2 vCPUs, so `--cpu 8` saturates them. The CPU/memory alerts need the
  condition to hold for 5 minutes plus the rate window and one evaluation interval, which
  is why the script runs stress-ng for 7 minutes instead of 6.
- **Memory test and swap.** The VMs have a swap file. Memory that a process allocated but
  doesn't touch gets moved to swap and "available" memory grows again, so
  `stress-ng --vm 2 --vm-bytes 80%` from the task peaked at only ~82–87% here (stress-ng
  also limits a percentage to what is available). The script uses a small Python allocator
  instead: it adds 16 MB blocks until usage is 92% and writes one byte per page every second,
  so its pages stay in RAM. To use stress-ng anyway, give it an explicit size bigger than
  the available memory, e.g. `stress-ng --vm 1 --vm-bytes 400M --timeout 420s` on a 640 MB VM.
- **Interface names.** `ifconfig eth0 down` from the task would hit Vagrant's NAT interface
  (the one `vagrant ssh` uses), and in this Ubuntu box the interfaces are called `enp0s3`
  (NAT) and `enp0s8` (host-only 192.168.56.x) anyway. Prometheus talks to the VMs over
  the host-only network, so the script looks up the interface with the 192.168.56.x address,
  takes it down for 5 minutes and brings it back automatically.
- The stock `ubuntu` image has no `stress-ng`, so the container tests use small images
  that have what they need.

### Test run (2026-10-14)

All scenarios were run on the VMs; times are from Grafana's alert state history:

| Alert | Trigger started | Pending | Firing | Notes |
|---|---|---|---|---|
| Elasticsearch cluster yellow | 19:19:39 `docker stop es02` | 19:20:51 | 19:21:53 | resolved 19:40 after `docker start es02` |
| High CPU usage (app-server) | ~19:21 stress-ng | 19:22:08 | 19:27:09 | |
| Container restarting (test_container) | ~19:20 | – | 19:26:39 | slow start because the VM was also running other tests |
| Logstash `auth_failure` | 19:30:09 fake sshd line | – | notification 19:30:23 | |
| Low disk space (web-server-1) | 19:29:28 fallocate | 19:32:40 | 19:33:40 | |
| High memory usage (web-server-1) | 20:44:47 | 20:47:09 | 20:52:41 | |
| Container memory near limit (memory_test) | 21:32:46 | 21:35:05 | 21:36:05 | |
| VM unreachable (load-balancer) | ~21:34 enp0s8 down | 21:36:50 | 21:37:50 | resolved 21:40 when the interface came back |

---

## Historical data & retention

| Data | Where | Retention | Configured in |
|---|---|---|---|
| Metrics | Prometheus TSDB, volume `prometheus-data` | 30 days **or** 5 GB (first limit wins) | `--storage.tsdb.retention.time/size` (`prometheus_retention_*` Ansible vars) |
| Logs | Elasticsearch daily indices | 30 days (ILM policy `infra-logs-30d`) | `monitoring/setup/elasticsearch/ilm-infra-logs.json` |
| Log alerts | `infra-alerts-*` | 90 days (`infra-alerts-90d`) | `ilm-infra-alerts.json` |
| Dashboards, alert rules | git (provisioning files) | forever | `monitoring/grafana/` |

History is viewed with the time picker in Grafana/Kibana (e.g. "Last 7 days").
Index templates attach the ILM policy to every new daily index; with
`index.lifecycle.parse_origination_date` the age is taken from the date in the index name.

Long-term retention strategy (beyond this lab):

- **Metrics**: Prometheus is not meant to keep years of data on one disk. Use
  `remote_write` to a long-term store (Thanos, Grafana Mimir, VictoriaMetrics, Cortex) with
  object storage (S3) and **downsampling** (e.g. raw 15 s for 30 days, 5 min for 1 year,
  1 h for 5 years); recording rules pre-aggregate expensive queries.
- **Logs**: ILM hot → warm (read-only, force-merge, cheaper nodes) → cold/frozen
  (searchable snapshots on S3) → delete; size retention by compliance needs (e.g. auth logs
  1 year, debug logs 7 days) — different policies per index type is exactly why logs are
  split into `infra-system/app/docker`. Snapshots (`_snapshot` API) for backups.

---

## Automation: Ansible + Jenkins

`vagrant up` creates the 7th VM (`monitoring-server`, 4.5 GB RAM, 4 vCPUs) and runs the same
`ansible/site.yml` as for the other VMs:

- role **docker** — now on every VM (the agents are containers), compose v2 plugin,
  log rotation for container logs (`max-size 10m × 3`);
- role **monitoring-server** — `vm.max_map_count=262144` for Elasticsearch, UFW rules,
  copies `monitoring/` to `/home/devops/monitoring`, writes `.env`, `docker compose up -d`;
  on config changes reloads Prometheus and restarts Grafana;
- role **monitoring-agents** — on every VM: UFW allows 9100/8081 only from 192.168.56.16,
  copies `monitoring/agents/`, writes the per-host `.env`, `docker compose up -d`.

Jenkins pipeline (`Jenkinsfile`) has two new stages:

- **Deploy monitoring stack** — `rsync` of `monitoring/` to monitoring-server, `docker compose up -d`,
  Prometheus reload, Grafana restart → targets, alert rules and dashboards are deployed from git;
- **Deploy monitoring agents** — loops over all 7 VMs: rsync `monitoring/agents/`, writes
  `.env` (host name, `DEPLOY_ENV` build parameter, Logstash address), `docker compose up -d`,
  restarts Filebeat;
- **Smoke Test** additionally checks `/prometheus` on the backend, Prometheus and Grafana health
  and prints how many targets of each job are up.

**Dynamic agent configuration per environment.** The agent files are identical everywhere;
everything that differs is injected through environment variables (`.env` → container env →
`${VAR}` in `filebeat.yml`):

| Variable | Set by | Example |
|---|---|---|
| `HOST_NAME` | Ansible `ansible_hostname` / Jenkins host list | `web-server-1` |
| `ENVIRONMENT` | Ansible `monitoring_environment` / Jenkins parameter `DEPLOY_ENV` | `lab`, `staging`, `production` |
| `LOGSTASH_HOST` | Ansible `logstash_host` / Jenkins env | `192.168.56.16` |

For real multi-environment setups: one inventory + `group_vars/<env>.yml` per environment
(different Logstash/Prometheus addresses, log levels, retention), secrets from Jenkins
credentials or Ansible Vault, and service discovery instead of static target files
(Consul, EC2/Kubernetes SD in Prometheus) so new hosts are scraped automatically.

---

## Troubleshooting

**A target is DOWN in Prometheus** (Status → Targets shows the error):

1. `curl http://<vm>:9100/metrics` from monitoring-server — "connection refused" = agent not
   running (`docker ps` / `docker logs node-exporter` on the VM); timeout = firewall.
2. UFW: `sudo ufw status` on the VM must allow 9100/8081 from 192.168.56.16. Note: ports
   published with `docker run -p` **bypass UFW** (Docker adds its own iptables rules) — that's
   why the agents use the host network, where UFW does apply.
3. Wrong endpoint: cAdvisor is on **8081** not 8080, backend metrics are on `/prometheus`
   not `/metrics` (that one is JSON → "unsupported Content-Type"/parse error in Prometheus).
4. On monitoring-server itself, Prometheus scrapes from the Docker bridge network
   (172.16.0.0/12), which needs its own UFW rule.
5. `scrape_timeout` exceeded → slow exporter (cAdvisor with many metrics: we disable unused groups).
6. Clock skew between VMs → samples "out of bounds"/strange gaps: keep NTP running.

**Graph is empty but target is UP**: wrong label in the query (`host` vs `instance`), metric
name changed between exporter versions, or the `rate()` window is shorter than 2 scrape intervals.
Use **Explore** and start from the bare metric name. Real examples from this project:
`elasticsearch_cluster_health_up` doesn't exist in elasticsearch-exporter 1.9 (the alert was
stuck in NoData), and cAdvisor reporting only `id="/"`, see below.

**Docker dashboard empty for one VM, cAdvisor target UP**: cAdvisor registers its Docker
support once at start-up; if containerd answers slowly at that moment (VM boot, heavy load)
its log says `Registration of the docker container factory failed: ... context deadline
exceeded` and it silently reports only the host cgroup. The healthcheck in
`monitoring/agents/docker-compose.yml` detects that (cAdvisor can't see its own container)
and restarts it; by hand: `docker restart cadvisor`.

**Target flaps between UP and DOWN while the VM is busy**: the VM answers slower than
`scrape_timeout` (10 s). Usually a sign of heavy swapping on a small VM. The agents have
`memswap_limit` = `mem_limit` so they are never swapped out, and the *VM unreachable* rule
waits for 2 minutes without a single successful scrape before it counts as an outage.

**Kibana saved objects import returns 500** (`Cannot read properties of undefined (reading
'layers')` in the Kibana log): the objects have no `typeMigrationVersion`, so Kibana runs every
migration since 7.x on them and the old Lens migrations crash on the current format. Objects
exported from the same Kibana version always carry these fields.

**No logs in Kibana**: `docker logs filebeat` on the VM (connection to 5044?), `docker logs
logstash` (pipeline errors, mapping errors), `curl localhost:9200/_cat/indices?v` on
monitoring-server, time picker range, and the right data view.

**Elasticsearch won't start**: `max virtual memory areas vm.max_map_count [65530] is too low`
→ sysctl (done by Ansible); out of memory → heap is 256 MB per node (`ES_HEAP` in `.env`).

---

## Concepts & design decisions (Q&A)

### Push vs pull monitoring — and why Prometheus pulls

- **Push** (Graphite/StatsD, InfluxDB Telegraf, Zabbix active agents, Datadog agent): each
  host/app sends its metrics to a central server whenever it wants.
- **Pull** (Prometheus, Nagios checks, Zabbix passive): the server connects to each target
  on a schedule and fetches the current values.

Prometheus pulls because:

1. **Health for free** — if a scrape fails, `up == 0`. A silent pushing host looks the same as
   a host with nothing to say; with pull, "unreachable" is detected immediately (this is our
   *VM unreachable* alert).
2. **The server controls the load** — scrape interval and timeouts are set centrally;
   a misbehaving app can't flood the monitoring server.
3. **Simple targets** — an app only has to expose an HTTP page with the current values; no
   knowledge of where the monitoring server is, no buffering/retry logic.
4. **Easy to debug** — open `http://host:9100/metrics` in a browser and see exactly what
   Prometheus sees; you can run a second Prometheus (e.g. on a laptop) against the same targets.
5. **Service discovery** — the list of what *should* exist comes from discovery (files,
   Consul, Kubernetes), so missing targets are visible.

Downsides: targets must be reachable from Prometheus (firewalls/NAT — see our UFW rules),
and short-lived jobs may finish before being scraped → Prometheus offers the **Pushgateway**
for batch jobs. Logs are the opposite case: they are events, not current state, so they are
**pushed** (Filebeat → Logstash).

### ELK architecture

- **Elasticsearch** — distributed search engine/database built on Lucene. Stores logs as
  JSON documents in indices; an index is split into **shards** spread over **nodes**, each
  primary shard can have **replicas** on other nodes (redundancy + read scaling). Gives
  full-text search and aggregations (counts, percentiles, terms) over billions of lines.
  Cluster health: green (all shards assigned), yellow (replicas missing), red (primaries missing).
- **Logstash** — processing pipeline: **inputs** (beats, tcp, syslog, kafka...) → **filters**
  (grok, json, date, mutate, geoip, throttle...) → **outputs** (elasticsearch, http, email,
  file...). Turns raw lines into structured fields, normalizes, enriches, routes.
- **Kibana** — web UI on top of Elasticsearch: Discover (search), Lens/visualizations,
  dashboards, data views, index management.
- **Beats (Filebeat)** — the "B" in today's "Elastic Stack": lightweight shippers on each
  host that tail files and forward them (Logstash is too heavy to run on every server).

Flow here: Filebeat → Logstash → Elasticsearch ← Kibana.

### Prometheus vs Nagios / Zabbix

| | Prometheus | Nagios | Zabbix |
|---|---|---|---|
| Model | pull of numeric time series | pull of check results (OK/WARN/CRIT) | agent (pull or push) + SNMP, stores in SQL DB |
| Data | multi-dimensional labels, PromQL | state of a check, little history | items/triggers, history in MySQL/Postgres |
| Dynamic infra (containers, autoscaling) | excellent (service discovery, labels) | poor (static host config) | ok (discovery rules, templates) |
| Querying | very powerful (rates, percentiles, math across series) | none really | limited functions |
| Visualization | via Grafana | basic | built-in UI |
| Config | YAML in git, everything as code | many config files | mostly via web UI / API |
| Long-term storage / HA | single node; needs Thanos/Mimir for HA & years of data | – | built-in DB, proxies for scale |
| Logs, events, SNMP, inventory | no (metrics only) | via plugins | yes, very broad |

Advantages of Prometheus: cloud-native, labels, PromQL, huge exporter ecosystem, client
libraries for apps, alerting as code. Disadvantages: only metrics (no logs/traces), no
built-in long-term storage/clustering, pull needs network reachability, no built-in
dashboards worth using (Grafana needed), high-cardinality labels can kill it.
Nagios/Zabbix are better for classic static server fleets, network devices (SNMP) and
"is the service up?" checks with a built-in UI.

### Node Exporter & cAdvisor setup — common issues

- **Firewall**: port must be open from the Prometheus host only (UFW rules in the roles);
  forgetting it = target DOWN with "context deadline exceeded".
- **Docker bypassing UFW**: `-p 9100:9100` opens the port to everyone regardless of UFW →
  host network mode instead.
- **Wrong endpoint / port**: cAdvisor default 8080 collides with Jenkins → 8081;
  `/metrics` vs custom paths (`metrics_path: /prometheus` for our backend).
- **Seeing the container instead of the host**: node-exporter in a container needs
  `--path.rootfs=/host`, `pid: host`, host network and `/` mounted read-only, otherwise it
  reports the container's filesystem and network.
- **cAdvisor needs** `/sys`, `/var/lib/docker`, `/var/run` mounts and `privileged`; with
  Docker 29's containerd image store an old cAdvisor can't map containers → use ≥ 0.54.
- **Noise**: filesystem metrics for `tmpfs`, `overlay`, the VirtualBox shared folder → excluded
  with `--collector.filesystem.*-exclude`; cAdvisor metric groups we don't use are disabled.
- **Labels**: without a `host` label you see `192.168.56.13:9100` everywhere — we add it in
  the target files.

### Grafana vs Kibana vs Datadog

- **Grafana**: best for **metrics** dashboards; many data sources in one dashboard (here
  Prometheus + Elasticsearch side by side), templating variables, strong alerting with
  routing/grouping, dashboards and alerts as code (provisioning files in git), open source.
- **Kibana**: tied to Elasticsearch, unbeatable for **log exploration** (Discover, full-text
  search, field statistics), weaker for time-series metrics. That's why we use both: Grafana
  for metrics, Kibana for logs.
- **Datadog**: SaaS — nothing to host, agents + integrations + APM in one product, very fast
  setup; but paid per host/GB (gets expensive), data leaves your network, vendor lock-in.
  Grafana is free, self-hosted and vendor-neutral.

### Prometheus client libraries

Official/community libraries exist for Go, Java, Python, Ruby, .NET, Node.js (`prom-client`).
Steps (see `backend/src/prometheus.ts`):

1. create a registry, optionally `collectDefaultMetrics()` for runtime metrics;
2. define metrics with a name, help text and labels: **Counter** (only goes up: requests,
   errors), **Gauge** (up and down: queue length, temperature), **Histogram** (bucketed
   durations/sizes → percentiles), **Summary** (client-side quantiles);
3. update them in code (`counter.inc()`, `histogram.startTimer()`), e.g. in a middleware;
4. expose `register.metrics()` on an HTTP endpoint with `Content-Type: text/plain; version=0.0.4`;
5. add the endpoint as a scrape target.

Rules: base units (seconds, bytes), `_total` suffix for counters, low-cardinality labels only
(never user IDs or raw URLs).

### Troubleshooting metric collection — see [Troubleshooting](#troubleshooting).

### Avoiding alert fatigue and false positives

- **Alert on symptoms that need action**, not on every metric (a CPU spike during a backup
  isn't an incident; 5 minutes at > 80% is).
- **`for` durations** (pending period) filter short spikes: 5 min for CPU/memory, 1 min for
  disk/availability (they don't flap by themselves).
- **Sensible thresholds** from the baseline: look at a week of history in the dashboards first;
  memory is measured with `MemAvailable` (page cache is not "used").
- **Severities and routing**: critical vs warning, different repeat intervals; in a real team
  critical → pager, warning → chat channel.
- **Grouping and repeat interval** (notification policy): one message per alert+host, updates
  max every 5 min, reminders every 4 h — not a message every evaluation.
- **Inhibition / silences / mute timings**: silence during maintenance; don't send "container
  down" alerts when the whole VM is down.
- **Throttle log alerts** (Logstash `throttle`): one notification per rule+host per 5 min.
- **Review regularly**: alerts that fire often and nobody acts on should be tuned or deleted.

**Fine-tuning thresholds/conditions** to reduce false positives:

- use a time window or average instead of a single sample (`rate(...[5m])`,
  `avg_over_time`, `for: 5m`);
- add hysteresis: fire at 80%, but only consider it resolved below e.g. 70% (Grafana
  "recovery threshold") to avoid flapping;
- predictive conditions instead of static ones for slow trends:
  `predict_linear(node_filesystem_avail_bytes[6h], 24*3600) < 0` ("disk full in 24 h");
- per-host thresholds via labels when hosts differ (ci-server builds are CPU-heavy by design);
- require several conditions (`high CPU and high load`), exclude known noise
  (`name!~"test_.*"`), and check `noDataState` (a missing series isn't always an incident);
- test with real load (the simulation script) and watch the Pending → Firing transitions.

What testing actually changed in this project's rules:

- **CPU usage counts `iowait` as idle.** During the memory test the VM was swapping and
  `100 - idle` reported "100% CPU" although the CPU was just waiting for the disk.
  Now: `1 - rate(idle + iowait)`.
- **"Unreachable" = no successful scrape for 2 minutes** (`max_over_time(up[2m]) < 1`) instead
  of `up == 0`. On a VM under heavy load single scrapes time out; with the old rule
  *VM unreachable* and *Backend down* flapped during every load test. A real outage is still
  detected after ~3 minutes.
- **Monitoring must not be the first victim**: the agents are excluded from swap, otherwise
  memory pressure on a VM makes it look "down" instead of "high memory".
- **monitoring-server got more RAM** (4.5 GB): with 4 GB it idled at 87–89% memory, right
  under the 90% threshold — a guaranteed source of false alerts.

### Logstash filters for parsing and matching

- **grok** — regex with named patterns: `%{SYSLOGTIMESTAMP:ts} %{SYSLOGHOST} %{DATA:prog}...`
  turns a text line into fields; multiple patterns tried in order; `tag_on_failure`.
- **json** — parse a JSON string into fields (`target => "app"`).
- **date** — take the event time from a field instead of the ingest time.
- **mutate** — rename, convert types, lowercase, add/remove fields and tags.
- **conditionals** — `if [field] =~ /regex/ { ... }`, `in [...]`, `and/or` to route events and
  **match patterns** for alerting (`Invalid user|authentication failure`).
- **throttle** — limit how many matching events trigger an action per time window.
- Outputs can be conditional too: the `http` output only runs for alert events.
- Debug patterns in Kibana → Dev Tools → **Grok Debugger**.
