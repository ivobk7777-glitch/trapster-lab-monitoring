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
| `logserver/grafana/dashboards/trapster.json` | `/var/lib/grafana/dashboards/` | The dashboard (see "Dashboard" below). |
| `logserver/grafana/provisioning/alerting/trapster-alerts.yaml` | `/etc/grafana/provisioning/alerting/` | Email alert rule, contact point and notification policy. |
| `logserver/setup-email-alerts.sh` | log-server01 | Asks for the mail settings, installs the alert rule, restarts Grafana. |
| `logserver/update-alert-rules.sh` | log-server01 | Reinstalls the alert rules after a repo change, keeping the recipients (no password needed). |
| `honeypot/install-alloy.sh` | linux-server01 | Installs Grafana Alloy, lets it read the Trapster log, adds weekly log rotation. |
| `honeypot/config.alloy` | `/etc/alloy/config.alloy` | Tail, parse, label, push. |
| `honeypot/logrotate-trapster-community` | `/etc/logrotate.d/` | Weekly rotation, 12 copies, copytruncate. |
| `honeypot/trapster.generated.conf` | `/opt/trapster-community/` | Expanded Trapster config: 15 services (see below). |
| `honeypot/deploy-config.sh` | linux-server01 | Backs up the live config, installs the expanded one, restarts Trapster. |
| `honeypot/trapster.service` | `/etc/systemd/system/` | Runs Trapster as user `trapster` with only `CAP_NET_BIND_SERVICE`. |
| `honeypot/setup-unprivileged.sh` | linux-server01 | One-time move from root in `/home/labadmin` to the unprivileged setup in `/opt`. |
| `honeypot/rollback-root.sh` | linux-server01 | Undoes the move: restores the backed-up root service. |
| `honeypot/scan-sensor.nft` | `/etc/hp-scan-sensor/` | nftables table that logs SYN, NULL, FIN and Xmas scan packets (log only, never drops). |
| `honeypot/hp-scan-sensor.service` | `/etc/systemd/system/` | Loads and unloads the sensor table. |
| `honeypot/setup-scan-sensor.sh` | linux-server01 | Installs the scan sensor and the new Alloy config, with checks and automatic Alloy restore. |
| `honeypot/rollback-scan-sensor.sh` | linux-server01 | Removes the scan sensor and restores the previous Alloy config. |

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

Grafana on log-server01 emails the user as soon as anyone touches or scans the honeypot.
`logserver/grafana/provisioning/alerting/trapster-alerts.yaml` has two rules in group `honeypot`,
both evaluated every 30 s:

- **Honeypot touched** (`trapster-touched`): Trapster events,
  `sum by (src_ip, logtype) (count_over_time({job="trapster"} | json [1m]))`.
- **Honeypot scanned (packet level)** (`trapster-scanned`): scan sensor packets,
  `sum by (src_ip, logtype) (count_over_time({job="trapster-sensor"} | json [1m]))`.

One notification policy groups by `src_ip`, so everything one attacker does arrives as one
email thread (a 15-port scan is one message, not fifteen). Resolved messages are off, and the
same attacker is re-notified at most every 4 hours.

After the first setup, install rule changes with `sudo bash logserver/update-alert-rules.sh`.
It keeps the installed recipients, does not ask for the SMTP password, and restores the
previous rules if Grafana rejects the new ones.

1. **FortiGate**: the log server may not send mail yet. Policy 2 (Servers to WAN) needs
   TCP 587 (mail submission with STARTTLS). Port 465 (SMTPS) does not work in this lab: a
   FortiGate capture showed the SYN leaving port1 with no reply, so the hosting provider
   upstream of Proxmox drops it (many providers block 25 and 465 against spam). Add 587 as
   a custom service and drop SMTPS. On the FortiGate console:

   ```
   config firewall service custom
   edit "SMTP-587"
   set tcp-portrange 587
   next
   end
   config firewall policy
   edit 2
   append service "SMTP-587"
   unselect service "SMTPS"
   next
   end
   show firewall policy 2
   ```

   Policy 2 also covers the honeypot, so the honeypot could send mail too. Accepted for
   the trial (isolation is not the priority now); narrowing policy 2's source to the log
   server is in-trial step 2.
2. **Mail account**: an account that may send through SMTP on port 587. For Gmail this
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

## Dashboard

"Trapster honeypot" (folder Honeypot) is built to be read at a glance:

- **Top row**: activity in the last hour (Trapster events plus scan packets; turns red when anyone
  touched or scanned the honeypot), events (Trapster only), attacker IPs (both sources), services
  touched, login attempts (red as soon as there is one).
- **Packet-level scan sensor** section: scan packets (red above 0), ports probed, a Scanners
  table (packets, ports, scan types per source) and scan packets over time by type.
- **Attackers**: one row per source IP with events, number of services and login attempts.
- **What they touched**: events per service and action (`ssh.login`, `http.query`, ...), most first.
- **Events over time, by service**.
- **Activity feed**: every event as one readable line (source, service, port, and the path,
  domain, SNMP community or credentials when present); yellow = contact, red = login attempt.
- **Credentials tried**: every username and password an attacker used.
- **Details** (collapsed row): the HTTP, DNS, scan packet and raw event logs.

Trapster logs completed connections only; half-open, NULL, FIN and Xmas scans show up in the
scan sensor section instead (see below).

Update on log-server01 after `git pull` (Grafana rereads the file within 30 seconds):

```
sudo install -o grafana -g grafana -m 0644 logserver/grafana/dashboards/trapster.json /var/lib/grafana/dashboards/trapster.json
```

## Packet-level scan sensor

**Problem (finding N1).** Trapster logs only completed TCP connections. A half-open SYN scan
(`nmap -sS`) sends a SYN, gets a SYN-ACK and resets, so Trapster never sees a session: no event,
no dashboard entry, no email. NULL, FIN and Xmas scans (`-sN`, `-sF`, `-sX`) are invisible the
same way. Only the UDP decoys (DNS, SNMP) recorded the 23 November `-sS -sU` scan.

**Design.** The honeypot's own kernel logs scan packets, and Alloy ships them as a second stream:

```
Kali --SYN--> linux-server01
                ├─ nftables table inet hp_scan_sensor: log (rate-limited), prefix "hp-scan <type>: "
                │     └─ kernel log -> journal -> Alloy (loki.source.journal, kernel only)
                │           -> JSON line {"logtype":"scan.syn","src_ip":...,"dst_port":...}
                │           -> Loki {job="trapster-sensor", logtype="scan.syn|null|fin|xmas"}
                └─ Trapster (unchanged), job="trapster"
log-server01: rule "Honeypot scanned (packet level)" -> same policy -> email; dashboard section
```

Why this way:

- **Kernel logging instead of a sniffer**: no new long-running process, no `CAP_NET_RAW`, no
  new code parsing hostile packets, so no new attack surface on the honeypot.
- **Its own table and unit**: `/etc/nftables.conf`, ufw and Trapster are untouched. The chain
  policy is accept and the only verdict is `return`: the sensor never drops or changes a packet,
  so a bug in it cannot change what an attacker sees.
- **Rate limit** (25 packets/s, burst 100, per scan type): a full `nmap -p-` is 65 535 SYNs.
  Detection needs a sample; without a limit the journal and Loki would fill up.
- **Log level info**: below Ubuntu's console level, so the serial and noVNC consoles are not
  flooded.
- **Separate stream** `job="trapster-sensor"` with Trapster's field names (`src_ip`, `dst_port`,
  `logtype`): the Trapster panels keep their meaning, and the same `| json` queries work.
- **All TCP ports are logged**, not only the 14 decoys: nothing legitimate connects in to the
  honeypot (Alloy pushes out), and probes of other ports show how wide a scan was.
- An empty set `allow_src` is ready for a future management address (the web UI).

**Install.** On linux-server01, after `git pull`:

```
sudo bash honeypot/setup-scan-sensor.sh
```

It checks first (nft, Alloy and Trapster running, `alloy fmt` and `nft -c` accept the files),
backs up to `/root/scan-sensor-backup-<time>`, lets `alloy` read the journal (group
`systemd-journal`), loads the table and `hp-scan-sensor.service`, installs the new Alloy config
(restoring the old one automatically if Alloy fails to start), and checks that Trapster is
unchanged (user, 14 TCP + 2 UDP ports) and Alloy still reads the Trapster log. Safe to run again.

On log-server01, after `git pull`:

```
sudo bash logserver/update-alert-rules.sh
sudo install -o grafana -g grafana -m 0644 logserver/grafana/dashboards/trapster.json /var/lib/grafana/dashboards/trapster.json
```

**Rollback.** `sudo bash honeypot/rollback-scan-sensor.sh` on linux-server01 removes the table
and unit and restores the pre-sensor Alloy config. On log-server01, check out the previous
version, then run `update-alert-rules.sh` and reinstall the dashboard.

**Tests** (from Kali, inside the lab only):

1. `sudo nmap -sS -p 21,22,23,80,389,443,636,873,1433,3306,3389,5432,5900 192.168.20.10`:
   "Scan packets" above 0, "Events" (Trapster) unchanged, email "Honeypot scanned (packet level)".
2. Without the browser, on log-server01:
   `curl -sG http://127.0.0.1:3100/loki/api/v1/query --data-urlencode 'query=sum by (logtype) (count_over_time({job="trapster-sensor"}[15m]))'`
3. `sudo nmap -sN -p 22,80 192.168.20.10`, then `-sF`, then `-sX`: `scan.null`, `scan.fin`, `scan.xmas`.
4. `sudo nmap -sS -p- -T4 192.168.20.10`: "Ports probed" large, packet count capped near
   25 per second; `journalctl --disk-usage` on linux-server01 stays small.
5. Regression: the `/alerttest` curl still sends "Honeypot touched"; `nmap -sT -sV` still fills
   the Trapster panels; `systemctl is-active trapster alloy hp-scan-sensor` prints `active` 3 times.
6. Idle: no traffic from Kali for 10 minutes means no sensor lines.

**Known limitations.**

- Counts are a rate-limited sample, not every packet.
- ACK scans (`-sA`) are not classified: an ACK-only packet cannot be told apart from stray packets
  of old connections without connection tracking.
- UDP probes of ports without a decoy are not logged (only DNS 53 and SNMP 161 are seen, by Trapster).
- If `nftables.service` is enabled and `/etc/nftables.conf` has `flush ruleset`, a
  `systemctl restart nftables` erases the sensor table. `sudo systemctl restart hp-scan-sensor`
  brings it back (the setup script warns when this applies).

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
- Alloy runs as the `alloy` user with read access (ACL) to the Trapster log, and (for the scan
  sensor) membership of `systemd-journal` to read kernel messages. Trapster runs
  as `trapster` (see "Run Trapster without root").
- Timestamps are UTC (Trapster's own); the dashboard is set to UTC.
