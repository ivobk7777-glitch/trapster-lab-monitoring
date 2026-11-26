#!/usr/bin/env bash
# Install the packet-level scan sensor on linux-server01 (finding N1).
# The kernel logs SYN, NULL, FIN and Xmas scan packets (own nftables table, log only, never drops);
# Alloy ships them to Loki as job="trapster-sensor". Trapster and its config are not touched.
# Run from the cloned repo on linux-server01:  sudo bash honeypot/setup-scan-sensor.sh
# Undo:                                          sudo bash honeypot/rollback-scan-sensor.sh
# Safe to run again.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
NFT_SRC="$HERE/scan-sensor.nft"
UNIT_SRC="$HERE/hp-scan-sensor.service"
ALLOY_SRC="$HERE/config.alloy"
NFT_DEST=/etc/hp-scan-sensor/scan-sensor.nft
UNIT_DEST=/etc/systemd/system/hp-scan-sensor.service
ALLOY_DEST=/etc/alloy/config.alloy
LOG=/var/log/trapster-community.log
BACKUP="/root/scan-sensor-backup-$(date +%Y%m%d-%H%M%S)"
TCP_PORTS="21 22 23 53 80 389 443 636 873 1433 3306 3389 5432 5900"
UDP_PORTS="53 161"

die() { echo "STOP: $*" >&2; exit 1; }
trap 'echo "STOP: unexpected error on line $LINENO (exit $?)." >&2' ERR

echo "== 1. Preflight (nothing is changed yet)"
[ "$(id -u)" -eq 0 ] || die "run with sudo"
for f in "$NFT_SRC" "$UNIT_SRC" "$ALLOY_SRC"; do [ -f "$f" ] || die "missing $f (git pull?)"; done
NFT="$(command -v nft || true)"
[ -n "$NFT" ] || die "nft not found: sudo apt-get install -y nftables (installs the tool only; nothing is enabled)"
[ "$NFT" = /usr/sbin/nft ] || echo "  note: nft is at $NFT, the unit uses /usr/sbin/nft"
systemctl is-active --quiet alloy || die "alloy is not running; install it first (honeypot/install-alloy.sh)"
systemctl is-active --quiet trapster || die "trapster is not running; fix that first"
# alloy fmt prints the formatted file (not needed here); parse errors still show on stderr.
if /usr/bin/alloy fmt "$ALLOY_SRC" >/dev/null; then
  echo "  alloy fmt: new config.alloy parses"
else
  die "alloy fmt rejected $ALLOY_SRC (output above); nothing was changed"
fi
"$NFT" -c -f "$NFT_SRC" || die "nft rejected $NFT_SRC (output above); nothing was changed"
echo "  nft -c: scan-sensor.nft is valid"
echo "  interfaces:"
ip -br addr | sed 's/^/    /'
if systemctl is-enabled --quiet nftables 2>/dev/null && grep -q 'flush ruleset' /etc/nftables.conf 2>/dev/null; then
  echo "  WARNING: nftables.service is enabled and /etc/nftables.conf has 'flush ruleset'."
  echo "           A later 'systemctl restart nftables' erases the sensor table."
  echo "           Bring it back with: sudo systemctl restart hp-scan-sensor"
fi

echo "== 2. Back up to $BACKUP"
mkdir -p "$BACKUP"
cp -a "$ALLOY_DEST" "$BACKUP/config.alloy"
id alloy > "$BACKUP/id-alloy.txt"
"$NFT" list ruleset > "$BACKUP/nft-ruleset.txt"
echo "  saved config.alloy, id alloy, nft ruleset"

echo "== 3. Let alloy read kernel messages from the journal"
if id -nG alloy | grep -qw systemd-journal; then
  echo "  alloy is already in systemd-journal"
else
  usermod -aG systemd-journal alloy
  echo "  added alloy to systemd-journal (takes effect when Alloy restarts in step 5)"
fi
# journalctl exits 0 even when it may not read anything, so check that a line comes back.
[ -n "$(sudo -u alloy journalctl -k -n 1 --no-pager -q -o cat 2>&1 | grep -vE 'insufficient permissions|^Hint:|No journal files|^-- No entries' || true)" ] \
  || die "the alloy user cannot read the kernel journal; nothing else was changed"
echo "  journal readable for alloy"

echo "== 4. Load the sensor table and its unit"
install -D -o root -g root -m 0644 "$NFT_SRC" "$NFT_DEST"
install -o root -g root -m 0644 "$UNIT_SRC" "$UNIT_DEST"
systemctl daemon-reload
systemctl enable --quiet hp-scan-sensor
systemctl restart hp-scan-sensor
"$NFT" list table inet hp_scan_sensor | sed 's/^/    /'

echo "== 5. Install the new Alloy config (restored automatically if Alloy does not start)"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
install -o root -g alloy -m 0640 "$ALLOY_SRC" "$ALLOY_DEST"
systemctl restart alloy
sleep 10
if ! systemctl is-active --quiet alloy; then
  echo "  Alloy did not start with the new config:"
  journalctl -u alloy --since "$SINCE" --no-pager | tail -n 20
  install -o root -g alloy -m 0640 "$BACKUP/config.alloy" "$ALLOY_DEST"
  systemctl restart alloy
  sleep 5
  systemctl is-active --quiet alloy && echo "  previous Alloy config restored and running; the Trapster pipeline is intact"
  die "new Alloy config failed; the sensor table is loaded but nothing ships it. Fix the repo, or undo with rollback-scan-sensor.sh"
fi
if journalctl -u alloy --since "$SINCE" --no-pager | grep -E 'level=error'; then
  echo "  WARNING: Alloy logged the errors above since the restart. It is running; check them."
fi
echo "  alloy active with the new config"

echo "== 6. Checks"
FAIL=0
ok()  { echo "  OK: $*"; }
bad() { echo "  FAIL: $*"; FAIL=1; }
systemctl is-active --quiet trapster && ok "trapster active" || bad "trapster not active"
PID="$(systemctl show -p MainPID --value trapster)"
RUNAS="$(ps -o user= -p "$PID" | tr -d ' ')"
[ "$RUNAS" = trapster ] && ok "trapster runs as trapster" || bad "trapster runs as '$RUNAS'"
for p in $TCP_PORTS; do
  ss -tlnpH "sport = :$p" | grep -q "pid=$PID," || bad "TCP $p not listening"
done
for p in $UDP_PORTS; do
  ss -ulnpH "sport = :$p" | grep -q "pid=$PID," || bad "UDP $p not listening"
done
[ "$FAIL" -eq 0 ] && ok "14 TCP + 2 UDP Trapster ports bound"
systemctl is-active --quiet hp-scan-sensor && ok "hp-scan-sensor active" || bad "hp-scan-sensor not active"
CHAIN="$("$NFT" list chain inet hp_scan_sensor input 2>&1 || true)"
case "$CHAIN" in *"policy accept"*) ok "sensor chain policy is accept (log only)" ;; *) bad "sensor chain not loaded with policy accept" ;; esac
systemctl is-active --quiet alloy && ok "alloy active" || bad "alloy not active"
getfacl -p "$LOG" 2>/dev/null | grep -q '^user:alloy:r' && ok "alloy can still read $LOG" || bad "alloy lost read access to $LOG"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "OK: scan sensor installed. Trapster unchanged; scan packets go to Loki as job=\"trapster-sensor\"."
  echo "Test from Kali:  sudo nmap -sS -p 21,22,23,80,389,443,636,873,1433,3306,3389,5432,5900 192.168.20.10"
  echo "Then on log-server01 / Grafana: dashboard section 'Packet-level scan sensor', email 'Honeypot scanned'."
  echo "Backup: $BACKUP   Undo: sudo bash honeypot/rollback-scan-sensor.sh"
else
  echo "Some checks failed (see FAIL lines). Undo: sudo bash honeypot/rollback-scan-sensor.sh"
  exit 1
fi
