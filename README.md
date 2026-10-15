# Sherlock Logs

Centralized **monitoring, logging and alerting** for the Automation Alchemy infrastructure: a full-stack infrastructure monitoring application with fully automated provisioning, configuration management and CI/CD pipeline, now observed by Prometheus + Grafana and the ELK stack.

7 virtual machines, network configuration, security hardening, application deployment, CI/CD, Prometheus + Grafana metrics, ELK logs and alerts — created with a single command.

---

## Quick Start

```bash
git clone https://gitea.kood.tech/danilakargajev/sherlock-logs.git
cd sherlock-logs
ssh-keygen -t ed25519 -f ansible/files/jenkins_key -N ""
vagrant up
```

The application will be available at `http://192.168.56.10` after provisioning completes (15–30 minutes).

Monitoring (from the host browser):

| Tool | URL | Login |
|------|-----|-------|
| Grafana — metrics dashboards & alerts | http://192.168.56.16:3000 | `admin` / `admin` |
| Kibana — log search & dashboards | http://192.168.56.16:5601 | – |
| Prometheus — targets, raw queries | http://192.168.56.16:9090 | – |

---

## Requirements

- [Vagrant](https://www.vagrantup.com/) 2.3+
- [VirtualBox](https://www.virtualbox.org/) 7.0+
- ~10 GB free RAM — all 7 VMs together use ~9.3 GB, so a 16 GB host works with browsers/games closed
- Hardware virtualization (AMD-V / VT-x) enabled in BIOS; on Windows the Hyper-V hypervisor should be off (see [Troubleshooting](#troubleshooting-the-host)), otherwise VirtualBox falls back to a much slower mode
- 40 GB free disk space

---

## Architecture

```
[Browser]
    |
    v
[Load Balancer]   192.168.56.10  nginx + adaptive load balancing
    |
    +-----------> [Web Server 1]  192.168.56.11  frontend + metrics sidecar
    +-----------> [Web Server 2]  192.168.56.12  frontend + metrics sidecar
                        |
                        v
                 [App Server]     192.168.56.13  backend API (Node.js/Express)

[CI Server]      192.168.56.15  Jenkins + Docker private registry
[Backup Server]  192.168.56.14  weekly rsync backups

[Monitoring Server] 192.168.56.16  Prometheus, Grafana, Elasticsearch x2, Logstash, Kibana
        ^   scrapes node-exporter / cAdvisor / backend metrics on every VM (pull)
        +-- receives logs from Filebeat on every VM (push)
```

| VM | IP | RAM | Role |
|----|----|-----|------|
| load-balancer | 192.168.56.10 | 640 MB | nginx reverse proxy, adaptive load balancing |
| web-server-1 | 192.168.56.11 | 640 MB | frontend container, metrics sidecar |
| web-server-2 | 192.168.56.12 | 640 MB | frontend container, metrics sidecar |
| app-server | 192.168.56.13 | 768 MB | backend API container |
| backup-server | 192.168.56.14 | 640 MB | scheduled rsync backups |
| ci-server | 192.168.56.15 | 1.5 GB | Jenkins CI/CD, Docker registry |
| monitoring-server | 192.168.56.16 | 4.5 GB | Prometheus, Grafana, Elasticsearch (2 nodes), Logstash, Kibana |

Every VM also runs the monitoring agents: **node-exporter** (host metrics), **cAdvisor** (container metrics) and **Filebeat** (logs).

---

## Technology Stack

| Layer | Technology |
|-------|-----------|
| Backend | Node.js 20, Express 5, TypeScript |
| Frontend | Vite, TypeScript, Tailwind CSS |
| Containers | Docker, Docker Compose v2 |
| Load Balancer | nginx |
| Infrastructure | Vagrant, VirtualBox |
| Configuration Management | Ansible |
| CI/CD | Jenkins |
| Backup | rsync, cron |
| Metrics & alerting | Prometheus, Grafana, node-exporter, cAdvisor, prom-client |
| Logging | Filebeat, Logstash, Elasticsearch, Kibana (ELK), winston |

---

## Project Structure

```
sherlock-logs/
├── Vagrantfile                    # 7 VM definitions with ansible_local provisioner
├── Jenkinsfile                    # CI/CD pipeline (Build > Push > Deploy > Monitoring > Smoke Test)
├── Jenkinsfile.rollback           # Parameterized rollback pipeline
│
├── ansible/
│   ├── site.yml                   # Main playbook — assigns roles by hostname
│   ├── ansible.cfg                # Ansible settings (roles_path, no host key check)
│   ├── inventory.ini              # localhost with ansible_connection=local
│   ├── files/
│   │   └── jenkins_key.pub        # Jenkins SSH public key (distributed to all VMs)
│   └── roles/
│       ├── common/                # Base packages, devops user, SSH hardening, UFW, /etc/hosts
│       ├── docker/                # Docker CE, docker-compose, insecure registry config
│       ├── app-server/            # Firewall rules, backend container deployment
│       ├── web-server/            # Firewall rules, frontend + sidecar deployment
│       ├── load-balancer/         # nginx, adaptive_lb.sh, cron every minute
│       ├── backup-server/         # backup.sh, restore.sh, cron every Sunday
│       ├── ci-server/             # Jenkins, Docker registry, SSH deploy key, notifications log
│       ├── monitoring-server/     # Prometheus/Grafana/ELK stack on monitoring-server
│       └── monitoring-agents/     # node-exporter, cAdvisor, Filebeat on every VM
│
├── backend/
│   ├── src/                       # Express API source (TypeScript), prometheus.ts + logger.ts
│   └── Dockerfile                 # Multi-stage build (builder + runner)
│
├── frontend/
│   ├── src/                       # Vite + TypeScript + Tailwind source
│   └── Dockerfile
│
├── load-balancer/
│   ├── nginx.conf                 # Initial config deployed by Ansible to /etc/nginx/conf.d/lb.conf
│   └── nginx.conf.template        # Template with WEB1_WEIGHT / WEB2_WEIGHT placeholders
│
├── scripts/
│   ├── adaptive_lb.sh             # Adaptive load balancing algorithm
│   ├── backup.sh                  # rsync backup over SSH
│   ├── restore.sh                 # Restore from backup archive
│   └── simulate-alerts.sh         # Triggers every alert condition for testing
│
├── monitoring/
│   ├── docker-compose.yml         # Monitoring server stack
│   ├── prometheus/                # prometheus.yml + scrape targets
│   ├── grafana/                   # provisioned data sources, dashboards, alert rules
│   ├── logstash/                  # Logstash pipeline (parsing + log alerts)
│   ├── setup/                     # Elasticsearch ILM/templates, Kibana dashboards
│   ├── alert-receiver/            # Webhook receiver for alert notifications
│   └── agents/                    # node-exporter + cAdvisor + Filebeat (every VM)
│
├── docs/
│   └── MONITORING.md              # Monitoring & logging in depth + Q&A
│
├── docker-compose.backend.yml
├── docker-compose.frontend.yml
└── docker-compose.sidecar.yml
```

---

## Ansible Roles

**common** — runs on every VM:
- Installs base packages: curl, wget, git, ufw, sshguard, rsync, acl
- Creates `devops` group and user, added to `sudo` group (password required for sudo)
- Adds the Jenkins public key to `devops` authorized_keys
- Disables SSH password authentication and root login
- Enables UFW with default deny-incoming, allows port 22
- Adds all VM hostnames to `/etc/hosts` for hostname resolution

**docker** — runs on every VM (the monitoring agents are containers):
- Writes `/etc/docker/daemon.json` first: `insecure-registries` (`192.168.56.15:5000`) and container log rotation (10 MB × 3)
- Installs Docker CE and the Compose v2 plugin (`docker compose`) from the official Docker repository
- Adds `devops` to the docker group

**load-balancer**:
- Installs nginx and jq
- Deploys nginx config and template
- Copies `adaptive_lb.sh` to `/home/devops/scripts/`
- Adds sudoers rule for nginx reload without password
- Schedules cron job every minute

**app-server**:
- Opens port 3001 only for web-server-1, web-server-2, ci-server and monitoring-server
- Deploys backend container using docker-compose

**web-server**:
- Opens port 80 only from the load balancer, 3001 from the load balancer and monitoring-server
- Creates `.env` with `BACKEND_HOST=192.168.56.13`
- Deploys frontend and metrics sidecar containers

**backup-server**:
- Creates `/backups` and `/home/devops/scripts` directories
- Copies `backup.sh` and `restore.sh`
- Schedules weekly cron job (Sunday at 02:00)

**ci-server**:
- Opens ports 8080 (Jenkins) and 5000 (Docker registry)
- Installs Java 21 and Jenkins
- Adds `jenkins` to the docker group
- Starts a Docker registry container on port 5000
- Copies Jenkins private SSH key to `/var/lib/jenkins/.ssh/id_ed25519`
- Adds deployment servers to `known_hosts`
- Creates `/var/log/jenkins-notifications.log`

**monitoring-server**:
- Sets `vm.max_map_count=262144` (required by Elasticsearch)
- Opens 3000 (Grafana), 5601 (Kibana), 9090 (Prometheus) and 5044 (Logstash, from 192.168.56.0/24)
- Copies `monitoring/` to `/home/devops/monitoring`, writes `.env`, starts the stack with `docker compose up -d`
- On config changes reloads Prometheus and restarts Grafana

**monitoring-agents** — runs on every VM:
- Opens 9100 (node-exporter) and 8081 (cAdvisor) only for monitoring-server
- Copies `monitoring/agents/` to `/home/devops/monitoring-agents`, writes the per-host `.env` (host name, environment, Logstash address)
- Starts node-exporter, cAdvisor and Filebeat with `docker compose up -d`

### Idempotency

All Ansible tasks are idempotent. Running `vagrant provision` multiple times does not cause unintended changes.

---

## Load Balancing Algorithm

The load balancer uses a **Resource-Based Adaptive** algorithm.

Every minute, `scripts/adaptive_lb.sh`:

1. Fetches `/metrics` from both web servers on port 3001 (metrics sidecar)
2. Calculates a load score for each server:
   ```
   score = load_avg_1min * 50 + ram_usage_%
   ```
3. Assigns nginx weights inversely proportional to the score (range 1–10):
   - Lower score = less load = higher weight = more traffic
   - If a server is unreachable, its score is 999 and receives weight 1
4. Writes the result into `/etc/nginx/conf.d/lb.conf` by substituting placeholders in the template
5. Validates with `nginx -t` and reloads nginx

Example log:
```
[2026-06-29 12:01:00] scores  -> web1=21.4  web2=67.8
[2026-06-29 12:01:00] weights -> web1=8  web2=2
[2026-06-29 12:01:00] nginx reloaded (web1=8 web2=2)
```

---

## CI/CD Pipeline

Jenkins is accessible at `http://192.168.56.15:8080`.

### Main pipeline (`Jenkinsfile`)

| Stage | Action |
|-------|--------|
| Build | Build Docker images for backend and frontend |
| Push | Push images to registry with `latest` and `$BUILD_NUMBER` tags |
| Deploy backend | SSH to app-server, pull image, restart container |
| Deploy frontend | SSH to web-server-1 and web-server-2, pull image, restart containers |
| Deploy monitoring stack | rsync `monitoring/` to monitoring-server, `docker compose up -d`, reload Prometheus, restart Grafana |
| Deploy monitoring agents | For all 7 VMs: rsync `monitoring/agents/`, write `.env` (host, `DEPLOY_ENV`, Logstash), `docker compose up -d` |
| Smoke Test | Verify backend API, load balancer, web servers, `/prometheus` endpoint, Prometheus and Grafana; print scrape targets that are up |

The pipeline has one parameter, `DEPLOY_ENV` (`lab` / `staging` / `production`), passed to the agents as the `environment` field of every log event.

After every build, the result is written to `/var/log/jenkins-notifications.log` on ci-server.

### Rollback pipeline (`Jenkinsfile.rollback`)

A separate parameterized job that rolls back to any previous build:

1. Takes `ROLLBACK_BUILD` parameter (build number, e.g. `5`)
2. Pulls the versioned image tag from registry (`backend:5`, `frontend:5`)
3. Redeploys on all servers
4. Runs smoke tests to confirm the rollback succeeded
5. Writes result to the notifications log

### Setting up Jenkins

After `vagrant up`, do the following once:

**1. Restart Docker on ci-server** (required to pick up insecure registry config):
```bash
vagrant ssh ci-server -- sudo systemctl restart docker
```

**2. Unlock Jenkins** at `http://192.168.56.15:8080`:
```bash
vagrant ssh ci-server -- sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```
Paste the password into the Jenkins unlock page, install suggested plugins, create an admin user.

**3. Create the main pipeline job:**
1. New Item → `infra-insight` → Pipeline
2. Definition → `Pipeline script from SCM`
3. SCM → Git, repository URL, branch `master`
4. Script Path → `Jenkinsfile`
5. Save → Build Now

**4. Create the rollback job:**
1. New Item → `infra-insight-rollback` → Pipeline
2. Definition → `Pipeline script from SCM`
3. SCM → Git, repository URL, branch `master`
4. Script Path → `Jenkinsfile.rollback`
5. Save

---

## Security

- SSH password authentication is disabled on all VMs
- Root login via SSH is disabled on all VMs
- UFW firewall enabled on all VMs with deny-incoming by default
- Each VM only opens ports required for its specific role
- `devops` is the only login-capable user on all VMs
- `sudo` for `devops` requires a password (`devops_password` in `ansible/group_vars/all.yml`, default `DevOps!2026`); only the load-balancer's automated `nginx`/`tee` reload commands are exempt via a scoped NOPASSWD rule for the cron-driven adaptive LB script
- `sshguard` blocks brute-force SSH attempts on all VMs
- The Jenkins SSH private key is in `.gitignore` and is never committed

### Firewall Rules

| Server | Open ports |
|--------|-----------|
| load-balancer | 22 (any), 80 (any) |
| web-server-1/2 | 22 (any), 80 (from load-balancer), 3001 (from load-balancer) |
| app-server | 22 (any), 3001 (from web-server-1, web-server-2, ci-server) |
| backup-server | 22 (any) |
| ci-server | 22 (any), 8080 (any), 5000 (any) |
| monitoring-server | 22 (any), 3000 / 5601 / 9090 (any), 5044 (from 192.168.56.0/24) |
| every VM | + 9100, 8081 (from monitoring-server) |

Note: ports published by Docker (`-p`) bypass UFW because Docker adds its own iptables rules. That's why the monitoring agents use the host network and Elasticsearch is published on `127.0.0.1` only.

---

## SSH Key Setup

Generate the Jenkins deploy key pair once before running `vagrant up`:

```bash
ssh-keygen -t ed25519 -f ansible/files/jenkins_key -N ""
```

The private key (`ansible/files/jenkins_key`) is in `.gitignore` and must never be committed. The public key (`ansible/files/jenkins_key.pub`) is committed and distributed automatically by Ansible.

---

## Backup and Restore

The backup server runs automatically every Sunday at 02:00.

Manual backup:
```bash
vagrant ssh backup-server
/home/devops/scripts/backup.sh
```

Restore from a specific date:
```bash
vagrant ssh backup-server
/home/devops/scripts/restore.sh <server-name> <date>

# Example:
/home/devops/scripts/restore.sh web-server-1 2026-06-29
```

Logs: `/var/log/backup.log`

---

## Monitoring & Logging

Full details, design decisions and the theory behind them: **[docs/MONITORING.md](docs/MONITORING.md)**.

**Metrics** — Prometheus scrapes every 15 s: node-exporter (host), cAdvisor (containers), the backend's `/prometheus` endpoint (prom-client) and Elasticsearch health. Retention: 30 days / 5 GB.

**Logs** — Filebeat on every VM ships syslog, auth.log, our scripts' logs and all container logs to Logstash, which parses them (grok for syslog, JSON for the backend's winston logs) into daily Elasticsearch indices `infra-system-*`, `infra-app-*`, `infra-docker-*`. Retention: 30 days (ILM). Elasticsearch runs as a 2-node cluster (replicas on the second node).

**Dashboards**

| Grafana (folder *Infrastructure*) | Kibana (Dashboards) |
|---|---|
| VM Performance | System Logs |
| Docker Containers | Application Logs |
| Application Performance | Docker Logs |

**Alerts** (Grafana, notifications to the `alert-receiver` webhook):

| Alert | Condition |
|---|---|
| High CPU usage | CPU > 80% for 5 minutes (iowait not counted) |
| High memory usage | memory > 90% for 5 minutes |
| Low disk space | free space on `/` < 20% |
| VM unreachable | no successful node-exporter scrape for 2 minutes (fires after ~3 min) |
| Container restarting | > 3 restarts in 15 minutes |
| Container memory near limit | > 80% of its memory limit |
| Elasticsearch cluster yellow or red | cluster health not green for 1 minute |
| Elasticsearch unreachable / Backend instance down | health check failing |

Logstash additionally sends notifications for log patterns: failed SSH/sudo logins, OOM killer, failed CI builds, backend errors (throttled to one per rule and host every 5 minutes).

See all notifications:
```bash
vagrant ssh monitoring-server -c "docker logs -f alert-receiver"
```

**Testing the alerts** — run on the VM that should alert:
```bash
vagrant ssh app-server -c "bash /vagrant/scripts/simulate-alerts.sh cpu"                 # CPU > 80% for 7 min
vagrant ssh web-server-1 -c "bash /vagrant/scripts/simulate-alerts.sh memory"            # memory at ~92% for 7 min
vagrant ssh app-server -c "bash /vagrant/scripts/simulate-alerts.sh disk"                # fill / to 85%
vagrant ssh app-server -c "bash /vagrant/scripts/simulate-alerts.sh container-restarts"  # crash-looping container
vagrant ssh app-server -c "bash /vagrant/scripts/simulate-alerts.sh container-memory"    # 225M in a 256M container
vagrant ssh load-balancer -c "bash /vagrant/scripts/simulate-alerts.sh unreachable"      # host-only interface down for 5 min
vagrant ssh monitoring-server -c "bash /vagrant/scripts/simulate-alerts.sh es-yellow"    # stop es02 (es-green to restore)
vagrant ssh app-server -c "bash /vagrant/scripts/simulate-alerts.sh log-alert"           # fake failed SSH login
vagrant ssh app-server -c "bash /vagrant/scripts/simulate-alerts.sh cleanup"
```

Run one test per VM at a time — the VMs are small, several heavy tests at once make a VM so slow that the results get muddy. Timings and results of a full test run: [docs/MONITORING.md](docs/MONITORING.md#test-run-2026-10-14).

Optional settings (`ansible/group_vars/all.yml`): `grafana_admin_password`, `monitoring_environment`, `prometheus_retention_time`, `prometheus_retention_size`, `alert_forward_webhook_url` (Slack / Discord webhook to forward notifications to).

---

## API

```
GET /metrics
```

Response:
```json
{
  "hostname": "web-server-1",
  "os": { "type": "Linux", "platform": "linux", "release": "5.15.0" },
  "cpu": { "model": "Intel Core...", "cores": 1, "loadAvg": [0.12, 0.08, 0.03] },
  "ram": { "total": 987, "used": 412, "free": 575 },
  "uptime": 18432,
  "timestamp": "2026-06-29T10:00:00.000Z"
}
```

```
GET /prometheus
```

The same backend's metrics in Prometheus text format (scraped by Prometheus): Node.js runtime metrics, `http_request_duration_seconds` histogram and the custom counter `infra_metrics_served_total`.

---

## Useful Commands

```bash
# Start all 7 VMs
vagrant up

# Destroy everything and start from scratch
vagrant destroy -f && vagrant up

# SSH into a specific VM
vagrant ssh load-balancer
vagrant ssh ci-server

# Re-run Ansible on one VM only
vagrant provision app-server

# Check status of all VMs
vagrant status

# Monitor adaptive load balancing in real time
vagrant ssh load-balancer -- sudo tail -f /var/log/adaptive_lb.log

# Verify nginx config and current weights
vagrant ssh load-balancer -- cat /etc/nginx/conf.d/lb.conf

# Check running containers on app-server
vagrant ssh app-server -- docker ps

# Check Jenkins logs
vagrant ssh ci-server -- sudo journalctl -u jenkins -f

# Monitor CI/CD notifications
vagrant ssh ci-server -- sudo tail -f /var/log/jenkins-notifications.log

# Check Docker registry contents
curl http://192.168.56.15:5000/v2/_catalog
curl http://192.168.56.15:5000/v2/backend/tags/list

# Monitoring stack status / logs
vagrant ssh monitoring-server -c "cd /home/devops/monitoring && sudo -u devops docker compose ps"
vagrant ssh monitoring-server -c "sudo docker logs -f logstash"

# Elasticsearch cluster health and indices
vagrant ssh monitoring-server -c "curl -s localhost:9200/_cluster/health?pretty"
vagrant ssh monitoring-server -c "curl -s 'localhost:9200/_cat/indices/infra-*?v'"

# Agents on any VM
vagrant ssh web-server-1 -c "sudo docker ps --filter name=node-exporter --filter name=cadvisor --filter name=filebeat"

# Reload Prometheus after editing monitoring/prometheus/*
vagrant ssh monitoring-server -c "curl -X POST localhost:9090/-/reload"
```

---

## Troubleshooting the host

**`AMD-V is disabled in the BIOS (VERR_SVM_DISABLED)` / `VT-x is disabled`** — hardware virtualization is off in the firmware (BIOS updates reset it). Enable *SVM Mode* (AMD) or *Intel Virtualization Technology* in the BIOS.

**VMs are very slow, VBox.log says `Attempting fall back to NEM`** — Windows runs its own hypervisor (Hyper-V, needed by WSL2 / Docker Desktop / VBS), so VirtualBox can't use AMD-V/VT-x directly and runs on top of Hyper-V ("turtle" icon). Elasticsearch and Kibana then take 10–20 minutes to start. Turn the Windows hypervisor off in an **administrator** terminal and reboot (WSL2 and Docker Desktop won't work until it's back on):
```powershell
bcdedit /set hypervisorlaunchtype off
reg add "HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard" /v EnableVirtualizationBasedSecurity /t REG_DWORD /d 0 /f
```
To undo: `bcdedit /set hypervisorlaunchtype auto` and set `EnableVirtualizationBasedSecurity` back to `1`, then reboot.

**Not enough RAM** — close browsers/games before `vagrant up`. During a demo, VMs you don't need at the moment can be paused with `vagrant suspend <vm>` (frees their RAM) and brought back with `vagrant resume <vm>` — note that a suspended VM fires the *VM unreachable* alert.

**First provisioning after a VM was off for a long time** — Ubuntu's unattended-upgrades runs right after boot and holds the apt lock; the `common` role waits for it (can take a few minutes) and finishes interrupted `dpkg` runs automatically.
