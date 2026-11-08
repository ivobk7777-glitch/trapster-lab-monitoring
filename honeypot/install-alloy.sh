#!/usr/bin/env bash
# Honeypot lab: install Grafana Alloy on the honeypot VM (linux-server01, 192.168.20.10)
# to ship /var/log/trapster-community.log to Loki on log-server01.
# Run from the cloned repo:  sudo bash honeypot/install-alloy.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
export DEBIAN_FRONTEND=noninteractive
LOG=/var/log/trapster-community.log

echo "== 1/5 Grafana apt repository"
apt-get update
apt-get install -y apt-transport-https software-properties-common wget gpg acl
mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor > /etc/apt/keyrings/grafana.gpg
chmod 644 /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update

echo "== 2/5 Package"
apt-get install -y alloy

echo "== 3/5 Alloy config"
install -o root -g alloy -m 0640 "$HERE/config.alloy" /etc/alloy/config.alloy

echo "== 4/5 Let the alloy user read the Trapster log, and rotate it weekly"
touch "$LOG"
setfacl -m u:alloy:r "$LOG"
install -o root -g root -m 0644 "$HERE/logrotate-trapster-community" /etc/logrotate.d/trapster-community

echo "== 5/5 Start"
systemctl enable alloy >/dev/null
systemctl restart alloy
sleep 5
systemctl is-active alloy
systemctl --no-pager --lines=8 status alloy || true
echo
echo "Done. Alloy tails $LOG and pushes to http://192.168.20.20:3100."
echo "Check on log-server01: curl -s 'http://127.0.0.1:3100/loki/api/v1/label/logtype/values'"
