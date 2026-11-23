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
| `logserver/grafana/provisioning/alerting/trapster-alerts.yaml` | `/etc/grafana/provisioning/alerting/` | Email alert rule, contact point and notification policy. |
| `logserver/setup-email-alerts.sh` | log-server01 | Asks for the mail settings, installs the alert rule, restarts Grafana. |
| `honeypot/install-alloy.sh` | linux-server01 | Installs Grafana Alloy, lets it read the Trapster log, adds weekly log rotation. |
| `honeypot/config.alloy` | `/etc/alloy/config.alloy` | Tail, parse, label, push. |
| `honeypot/logrotate-trapster-community` | `/etc/logrotate.d/` | Weekly rotation, 12 copies, copytruncate. |
| `honeypot/trapster.generated.conf` | `/opt/trapster-community/` | Expanded Trapster config: 15 services (see below). |
| `honeypot/deploy-config.sh` | linux-server01 | Backs up the live config, installs the expanded one, restarts Trapster. |
| `honeypot/trapster.service` | `/etc/systemd/system/` | Runs Trapster as user `trapster` with only `CAP_NET_BIND_SERVICE`. |
| `honeypot/setup-unprivileged.sh` | linux-server01 | One-time move from root in `/home/labadmin` to the unprivileged setup in `/opt`. |
| `honeypot/rollback-root.sh` | linux-server01 | Undoes the move: restores the backed-up root service. |

## Expanded service coverage

`honeypot/trapster.generated.conf` enables all 15 Trapster modules so the honeypot
presents a full enterprise surface and the dashboard shows coverage across protocols:

FTP (21), SSH (22), Telnet (23), DNS (53), HTTP (80), SNMP (161), LDAP (389),
HTTPS (443), LDAPS (636), rsync (873), MSSQL (1433), MySQL (3306), RDP (3389),
PostgreSQL (5432), VNC (5900).

HTTP, HTTPS and DNS keep the settings already deployed. The other twelve use Trapster's
module defaults (banners such as "Microsoft FTP Service", MySQL 8.4.3, RDP host WIN-RDP).
Those banners are identifying defaults in the same category as the HTTP demo skin — fine
for a detection/coverage test, to be reviewed with the mentor before any real deployment.

Deploy (after `git pull` on the honeypot VM):

```
sudo bash honeypot/deploy-config.sh
```

It backs up the current config to a timestamped `.bak`, installs the new one, restarts the
service, and lists the bound ports. Each service logs `connection` / `data` / `login` /
`query` events; Alloy labels them by `logtype`, so the "Events by type" and "Events over
time" panels pick up the new services automatically.

## Run Trapster without root

Ten of the fifteen ports are below 1024, which is the only reason Trapster ran as root.
Every listener is an ordinary TCP/UDP socket, so the single capability `CAP_NET_BIND_SERVICE`
is enough. systemd grants it to the Trapster process only (`AmbientCapabilities`), instead of
`setcap` on the Python interpreter, which would give every Python program that power.

Layout after the move:

- Code and venv in `/opt/trapster-community`, owned by root, read-only for `trapster`.
  A compromised honeypot process cannot change its own code.
- Writable for `trapster` only: `trapster/data/ssh` (SSH host keys), `trapster/data/ssl`
  (HTTPS, LDAPS and RDP certificates) and `/var/log/trapster-community.log`.
- Alloy keeps its read ACL on the log.
- The old copy in `/home/labadmin/trapster-community` is not touched; it is the rollback path.

On linux-server01, after `git pull` (needs internet through policy 2 for the new venv):

```
sudo bash honeypot/setup-unprivileged.sh
```

It backs up the current unit and package versions to `/root/trapster-backup-<time>`, creates
the `trapster` system user, copies the code, rebuilds the venv with the same versions, sets
ownership, installs `trapster.service`, starts it, and checks: process user, capability set,
all 14 TCP and 2 UDP ports, and Alloy's read access. Undo with
`sudo bash honeypot/rollback-root.sh`.

## Email alerts

Grafana on log-server01 emails the user as soon as anyone touches the honeypot: one email
per attacker IP, listing each service touched (a 15-port scan is one message, not fifteen).
The rule (`logserver/grafana/provisioning/alerting/trapster-alerts.yaml`) runs every 30 s
on `sum by (src_ip, logtype) (count_over_time({job="trapster"} | json [1m]))`; resolved
messages are off, and the same attacker is re-notified at most every 4 hours.

1. **FortiGate**: the log server may not send mail yet. Policy 2 (Servers to WAN) needs
   SMTPS (TCP 465, a predefined service). On the FortiGate console:

   ```
   config firewall policy
   edit 2
   append service SMTPS
   next
   end
   show firewall policy 2
   ```

   Policy 2 also covers the honeypot, so the honeypot could send mail too. Accepted for
   the trial (isolation is not the priority now); narrowing policy 2's source to the log
   server is in-trial step 2.
2. **Mail account**: an account that may send through SMTP on port 465. For Gmail this
   needs 2-step verification and an app password; a company mailbox works the same way.
3. **log-server01**, after `git pull`:

   ```
   sudo bash logserver/setup-email-alerts.sh
   ```

   It asks for the server, login, password (hidden), sender and recipients; keeps them in
   `/etc/default/grafana-server` (root only, never in this repo); installs the rule;
   restarts Grafana and checks for alerting errors.
4. **Test from Kali**: `curl -m 5 -s -o /dev/null http://192.168.20.10/alerttest`. The email
   arrives within about 2 minutes (30 s evaluation plus 30 s grouping).

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
- Alloy runs as the `alloy` user with read access (ACL) to the Trapster log. Trapster runs
  as `trapster` (see "Run Trapster without root").
- Timestamps are UTC (Trapster's own); the dashboard is set to UTC.
