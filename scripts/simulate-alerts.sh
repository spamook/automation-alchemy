#!/bin/bash
# Creates the conditions for each alert, to demonstrate that alerting works.
# Run it ON the VM that should raise the alert, e.g.:
#   vagrant ssh app-server -c "bash /vagrant/scripts/simulate-alerts.sh cpu"
# Alerts show up in Grafana (Alerting -> Alert rules) and in the receiver log:
#   vagrant ssh monitoring-server -c "docker logs -f alert-receiver"
set -euo pipefail

# "vagrant ssh" logs in as user vagrant, which is not in the docker group
DOCKER="docker"
docker info >/dev/null 2>&1 || DOCKER="sudo docker"

case "${1:-}" in
cpu)
    # 8 workers keep every vCPU at 100%. The alert needs > 80% for 5 minutes, plus
    # the 1m rate window and the 30s evaluation interval -> run for 7 minutes.
    echo "CPU stress for ${2:-420s} -> expect 'High CPU usage' after ~5-6 min"
    stress-ng --cpu 8 --timeout "${2:-420s}" --metrics-brief
    ;;
memory)
    # Keeps memory usage at ~92% for 7 minutes (alert: > 90% for 5 minutes).
    # The VMs have swap, so a fixed allocation isn't enough: the kernel moves other
    # processes' idle memory to swap and "available" memory grows again (that's why
    # "stress-ng --vm 2 --vm-bytes 80%" often stays below 90% here). This allocator adds
    # memory until usage is 92% and touches every page once a second so its own pages
    # stay in RAM. Needs almost no CPU.
    secs="${2:-420}"
    echo "Holding memory usage at ~92% for ${secs}s -> expect 'High memory usage' after ~5-6 min"
    python3 - "$secs" <<'PY'
import sys, time

def meminfo():
    return {l.split(":")[0]: int(l.split()[1]) * 1024 for l in open("/proc/meminfo")}

chunks, end = [], time.time() + int(sys.argv[1])
while time.time() < end:
    m = meminfo()
    usage = 1 - m["MemAvailable"] / m["MemTotal"]
    if usage < 0.92 and sum(map(len, chunks)) < m["MemTotal"]:
        chunks.append(bytearray(16 * 2**20))      # +16 MB, zero-filled = really allocated
    for c in chunks:                             # one write per page keeps it in RAM
        for i in range(0, len(c), 4096):
            c[i] ^= 1
    print(f"\rusage {usage:.1%}, holding {sum(map(len, chunks)) // 2**20} MB ", end="", flush=True)
    time.sleep(1)
print()
PY
    ;;
disk)
    # Fill / until only 15% stays free (alert: < 20% free). fallocate only reserves
    # blocks, so it's instant and doesn't write 30 GB.
    size_kb=$(df --output=size -k / | tail -1)
    avail_kb=$(df --output=avail -k / | tail -1)
    fill_kb=$(( avail_kb - size_kb * 15 / 100 ))
    echo "Allocating $(( fill_kb / 1024 / 1024 )) GB in /var/tmp/large_file.img -> expect 'Low disk space' after ~1-2 min"
    fallocate -l "${fill_kb}K" /var/tmp/large_file.img
    df -h /
    echo "Clean up with: $0 cleanup"
    ;;
container-restarts)
    # exits with error after 10s, Docker restarts it forever -> > 3 restarts in 15 min
    $DOCKER rm -f test_container >/dev/null 2>&1 || true
    $DOCKER run -d --restart=always --name test_container ubuntu /bin/bash -c "sleep 10; exit 1"
    echo "test_container restarts every ~10s -> expect 'Container restarting' after ~1-2 min"
    echo "Clean up with: $0 cleanup"
    ;;
container-memory)
    # 225 MB inside a 256 MB limit = ~88% of the limit (alert: > 80% for 1 min).
    # Same idea as "-m 512m + stress-ng 450M" from the task, scaled down for the 768 MB
    # VMs; the pages are touched every second so they stay in RAM (no swapping) and the
    # container needs almost no CPU.
    $DOCKER rm -f memory_test >/dev/null 2>&1 || true
    $DOCKER run -d -m 256m --name memory_test python:3.12-alpine python -c '
import time
buf = bytearray(225 * 2**20)
end = time.time() + 360
while time.time() < end:
    for i in range(0, len(buf), 4096):
        buf[i] ^= 1
    time.sleep(1)
'
    echo "memory_test holds 225M of its 256M limit for 6 min -> expect 'Container memory near limit' after ~1-2 min"
    ;;
unreachable)
    # Prometheus reaches the VMs over the host-only network 192.168.56.x. In this Ubuntu
    # box the interfaces are called enp0s3 (Vagrant NAT, used by "vagrant ssh") and
    # enp0s8 (host-only), not eth0/eth1 -> look the interface up by its address.
    # Only the host-only one goes down, so this ssh session survives, and the interface
    # comes back by itself afterwards.
    secs="${2:-300}"
    iface=$(ip -o -4 addr show | awk '/ 192\.168\.56\./ {print $2; exit}')
    echo "$iface down for ${secs}s -> expect 'VM unreachable' after ~3-4 min"
    sudo ip link set "$iface" down
    sleep "$secs"
    sudo ip link set "$iface" up
    echo "$iface is up again -> the alert resolves within ~1 min"
    ;;
es-yellow)
    # run on monitoring-server: without the data node es02 all replica shards are unassigned
    $DOCKER stop es02
    echo "es02 stopped -> cluster YELLOW -> expect 'Elasticsearch cluster yellow or red' after ~1-2 min"
    echo "Bring it back with: $0 es-green"
    ;;
es-green)
    $DOCKER start es02
    echo "es02 started -> replicas are copied back, cluster turns GREEN"
    ;;
log-alert)
    # writes an sshd-style failed login into /var/log/auth.log -> Logstash rule "auth_failure"
    logger -p auth.warning -t sshd "Invalid user hacker from 10.0.0.66 port 4242 (simulated attack)"
    echo "Fake failed SSH login written to auth.log -> Logstash sends an 'auth_failure' notification within seconds"
    ;;
cleanup)
    $DOCKER rm -f test_container memory_test >/dev/null 2>&1 || true
    rm -f /var/tmp/large_file.img
    echo "Removed test containers and /var/tmp/large_file.img"
    ;;
*)
    echo "usage: $0 cpu|memory|disk|container-restarts|container-memory|unreachable|es-yellow|es-green|log-alert|cleanup"
    exit 1
    ;;
esac
