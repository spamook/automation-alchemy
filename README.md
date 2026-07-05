# Automation Alchemy

A full-stack infrastructure monitoring application with fully automated provisioning, configuration management, and CI/CD pipeline.

6 virtual machines, network configuration, security hardening, application deployment, and CI/CD — created with a single command.

---

## Quick Start

```bash
git clone https://gitea.kood.tech/danilakargajev/automation-alchemy.git
cd automation-alchemy
ssh-keygen -t ed25519 -f ansible/files/jenkins_key -N ""
vagrant up
```

The application will be available at `http://192.168.56.10` after provisioning completes (15–30 minutes).

---

## Requirements

- [Vagrant](https://www.vagrantup.com/) 2.3+
- [VirtualBox](https://www.virtualbox.org/) 7.0+
- 6 GB free RAM
- 20 GB free disk space

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
```

| VM | IP | RAM | Role |
|----|----|-----|------|
| load-balancer | 192.168.56.10 | 512 MB | nginx reverse proxy, adaptive load balancing |
| web-server-1 | 192.168.56.11 | 1 GB | frontend container, metrics sidecar |
| web-server-2 | 192.168.56.12 | 1 GB | frontend container, metrics sidecar |
| app-server | 192.168.56.13 | 1 GB | backend API container |
| backup-server | 192.168.56.14 | 512 MB | scheduled rsync backups |
| ci-server | 192.168.56.15 | 2 GB | Jenkins CI/CD, Docker registry |

---

## Technology Stack

| Layer | Technology |
|-------|-----------|
| Backend | Node.js 20, Express 5, TypeScript |
| Frontend | Vite, TypeScript, Tailwind CSS |
| Containers | Docker, docker-compose |
| Load Balancer | nginx |
| Infrastructure | Vagrant, VirtualBox |
| Configuration Management | Ansible |
| CI/CD | Jenkins |
| Backup | rsync, cron |

---

## Project Structure

```
automation-alchemy/
├── Vagrantfile                    # 6 VM definitions with ansible_local provisioner
├── Jenkinsfile                    # CI/CD pipeline (Build > Push > Deploy > Smoke Test)
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
│       └── ci-server/             # Jenkins, Docker registry, SSH deploy key, notifications log
│
├── backend/
│   ├── src/                       # Express API source (TypeScript)
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
│   └── restore.sh                 # Restore from backup archive
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

**docker** — runs on app-server, web servers, ci-server:
- Installs Docker CE and docker-compose from the official Docker repository
- Adds `devops` to the docker group
- Configures `insecure-registries` pointing to `192.168.56.15:5000`

**load-balancer**:
- Installs nginx and jq
- Deploys nginx config and template
- Copies `adaptive_lb.sh` to `/home/devops/scripts/`
- Adds sudoers rule for nginx reload without password
- Schedules cron job every minute

**app-server**:
- Opens port 3001 only for web-server-1, web-server-2, and ci-server
- Deploys backend container using docker-compose

**web-server**:
- Opens port 80 and 3001 only from the load balancer
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
| Smoke Test | Verify backend API and load balancer respond with HTTP 200 |

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

---

## Useful Commands

```bash
# Start all 6 VMs
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
```
