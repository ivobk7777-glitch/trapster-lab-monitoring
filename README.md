# Trapster lab monitoring (Grafana + Loki + Alloy)

Dashboard for the Trapster Community honeypot in the internship lab.

```
Kali (192.168.10.10)  --policy 1-->  FortiGate  -->  Servers segment (VLAN 20)
                                                       ├─ linux-server01  192.168.20.10  Trapster + Alloy (ships the log)
                                                       └─ log-server01    192.168.20.20  Loki (stores) + Grafana (shows)
```

- Alloy on the honeypot VM tails `/var/log/trapster-community.log`, takes the event's own UTC
  timestamp, adds the label `logtype`, and pushes to Loki on the log server (port 3100).
- Loki keeps 90 days on local disk. Grafana reads Loki and shows the provisioned
  dashboard "Trapster honeypot" (folder Honeypot).
- Both VMs sit in the Servers segment, so the log traffic never crosses the FortiGate.
  The new VM reaches the internet for packages through policy 2.

## Files

| Path | Goes to | Purpose |
|---|---|---|
| `logserver/install-logserver.sh` | log-server01 | Adds the Grafana apt repo, installs Grafana + Loki, provisions everything, sets ufw. |
| `logserver/loki/config.yml` | `/etc/loki/config.yml` | Single-node Loki, filesystem storage, 90-day retention. |
| `logserver/grafana/provisioning/datasources/loki.yaml` | `/etc/grafana/provisioning/datasources/` | Loki data source (uid `loki`). |
| `logserver/grafana/provisioning/dashboards/trapster.yaml` | `/etc/grafana/provisioning/dashboards/` | Loads dashboards from `/var/lib/grafana/dashboards`. |
| `logserver/grafana/dashboards/trapster.json` | `/var/lib/grafana/dashboards/` | The dashboard (10 panels). |
| `honeypot/install-alloy.sh` | linux-server01 | Installs Grafana Alloy, lets it read the Trapster log, adds weekly log rotation. |
| `honeypot/config.alloy` | `/etc/alloy/config.alloy` | Tail, parse, label, push. |
| `honeypot/logrotate-trapster-community` | `/etc/logrotate.d/` | Weekly rotation, 12 copies, copytruncate. |

## Install

On **log-server01** (Ubuntu Server, 192.168.20.20), from the Proxmox console:

```
sudo apt-get install -y git
git clone https://github.com/<user>/<repo>.git
cd <repo>
sudo bash logserver/install-logserver.sh
```

On **linux-server01** (the honeypot VM):

```
sudo apt-get install -y git
git clone https://github.com/<user>/<repo>.git
cd <repo>
sudo bash honeypot/install-alloy.sh
```

Then from Kali open `http://192.168.20.20:3000`, log in with `admin` / `admin`, set a new
password, and open Dashboards → Honeypot → Trapster honeypot.

## Checks

- Loki ready: `curl -s http://127.0.0.1:3100/ready` on log-server01 → `ready`.
- Labels arriving: `curl -s 'http://127.0.0.1:3100/loki/api/v1/label/logtype/values'` on log-server01.
- Alloy: `systemctl status alloy --no-pager` on linux-server01; `journalctl -u alloy -n 20 --no-pager`.
- New events show up within seconds. Old history from the log file shows up after the first
  flush (a few minutes), because those chunks go straight to the store.

## Lab notes

- Loki has no authentication (`auth_enabled: false`). ufw on log-server01 allows port 3100
  only from the Servers segment and port 3000 (Grafana) from anywhere in the lab, because
  Kali is the only machine with a browser. In a real deployment Grafana belongs on a
  management network, not on a segment the attacker can reach.
- Grafana runs as a normal service; change the admin password at first login.
- Alloy runs as the `alloy` user with read access (ACL) to the Trapster log. Trapster
  itself is unchanged.
- Timestamps are UTC (Trapster's own); the dashboard is set to UTC.
