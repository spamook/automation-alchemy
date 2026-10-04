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
    # 2 workers share the given % of AVAILABLE memory and keep it allocated (--vm-keep)
    echo "Memory stress (${2:-90%} of available RAM) for 7 min -> expect 'High memory usage' after ~5-6 min"
    stress-ng --vm 2 --vm-bytes "${2:-90%}" --vm-keep --timeout 420s --metrics-brief
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
    # 450 MB inside a 512 MB limit = 88% of the limit (alert: > 80% for 1 min)
    $DOCKER rm -f memory_test >/dev/null 2>&1 || true
    $DOCKER run -d -m 512m --name memory_test colinianking/stress-ng \
        --vm 1 --vm-bytes 450M --vm-keep --timeout 360s
    echo "memory_test holds 450M of its 512M limit for 6 min -> expect 'Container memory near limit' after ~1-2 min"
    ;;
unreachable)
    # Prometheus reaches the VMs over the host-only network (eth1 = 192.168.56.x).
    # eth0 is Vagrant's NAT used by "vagrant ssh", so this session survives, and the
    # interface comes back by itself afterwards.
    secs="${2:-180}"
    echo "eth1 down for ${secs}s -> expect 'VM unreachable' after ~1-2 min"
    sudo ip link set eth1 down
    sleep "$secs"
    sudo ip link set eth1 up
    echo "eth1 is up again -> the alert resolves within ~1 min"
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
