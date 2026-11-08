#!/usr/bin/env bash
# Honeypot lab: install Grafana + Loki on log-server01 (Ubuntu Server, 192.168.20.20).
# Run from the cloned repo:  sudo bash logserver/install-logserver.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
export DEBIAN_FRONTEND=noninteractive

echo "== 1/6 Grafana apt repository"
apt-get update
apt-get install -y apt-transport-https software-properties-common wget gpg acl
mkdir -p /etc/apt/keyrings
wget -q -O - https://apt.grafana.com/gpg.key | gpg --dearmor > /etc/apt/keyrings/grafana.gpg
chmod 644 /etc/apt/keyrings/grafana.gpg
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" > /etc/apt/sources.list.d/grafana.list
apt-get update

echo "== 2/6 Packages"
apt-get install -y grafana loki

echo "== 3/6 Loki"
id loki >/dev/null 2>&1 || useradd --system --home /var/lib/loki --shell /usr/sbin/nologin loki
getent group loki >/dev/null || groupadd -r loki
usermod -g loki loki
install -d -o loki -g loki -m 0750 /var/lib/loki /var/lib/loki/chunks /var/lib/loki/rules /var/lib/loki/compactor
install -o root -g loki -m 0640 "$HERE/loki/config.yml" /etc/loki/config.yml
systemctl enable loki >/dev/null
systemctl restart loki

echo "== 4/6 Grafana provisioning (Loki data source + Trapster dashboard)"
install -d -o grafana -g grafana -m 0755 /var/lib/grafana/dashboards
install -o root -g grafana -m 0640 "$HERE/grafana/provisioning/datasources/loki.yaml" /etc/grafana/provisioning/datasources/loki.yaml
install -o root -g grafana -m 0640 "$HERE/grafana/provisioning/dashboards/trapster.yaml" /etc/grafana/provisioning/dashboards/trapster.yaml
install -o grafana -g grafana -m 0644 "$HERE/grafana/dashboards/trapster.json" /var/lib/grafana/dashboards/trapster.json
systemctl enable grafana-server >/dev/null
systemctl restart grafana-server

echo "== 5/6 Host firewall (ufw): Grafana 3000 from anywhere in the lab, Loki 3100 only from the Servers segment"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 3000/tcp comment 'Grafana web UI' >/dev/null
ufw allow from 192.168.20.0/24 to any port 3100 proto tcp comment 'Loki push API, Servers segment only' >/dev/null
ufw --force enable >/dev/null
ufw status numbered

echo "== 6/6 Checks"
sleep 5
systemctl is-active loki grafana-server
printf 'Loki ready: '; curl -s http://127.0.0.1:3100/ready || true; echo
printf 'Grafana health: '; curl -s http://127.0.0.1:3000/api/health || true; echo
echo
echo "Done. Open http://192.168.20.20:3000 from Kali. First login: admin / admin, then set a new password."
