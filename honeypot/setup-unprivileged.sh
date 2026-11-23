#!/usr/bin/env bash
# Move Trapster from /home/labadmin to /opt and run it as the system user "trapster"
# with only CAP_NET_BIND_SERVICE. The home copy is left untouched as the rollback path.
# Run from the cloned repo on linux-server01:  sudo bash honeypot/setup-unprivileged.sh
# Undo:                                          sudo bash honeypot/rollback-root.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OLD=/home/labadmin/trapster-community
NEW=/opt/trapster-community
LOG=/var/log/trapster-community.log
UNIT_DEST=/etc/systemd/system/trapster.service
BACKUP="/root/trapster-backup-$(date +%Y%m%d-%H%M%S)"
TCP_PORTS="21 22 23 53 80 389 443 636 873 1433 3306 3389 5432 5900"
UDP_PORTS="53 161"

die() { echo "STOP: $*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -f "$OLD/main.py" ] || die "no Trapster checkout at $OLD"
[ -f "$OLD/trapster.generated.conf" ] || die "no trapster.generated.conf in $OLD"
[ -x "$OLD/venv/bin/pip" ] || die "no venv at $OLD/venv"
[ ! -e "$NEW" ] || die "$NEW already exists (earlier run?); check it, then: sudo rm -rf $NEW"
[ ! -d /etc/systemd/system/trapster.service.d ] || die "drop-ins in /etc/systemd/system/trapster.service.d would override the new unit; review them first"

echo "== 1. Back up the current (root) service to $BACKUP"
mkdir -p "$BACKUP"
FRAG="$(systemctl show -p FragmentPath --value trapster)"
[ -n "$FRAG" ] && [ -f "$FRAG" ] || die "trapster.service not found"
cp -a "$FRAG" "$BACKUP/trapster.service.root"
echo "$FRAG" > "$BACKUP/unit-path.txt"
systemctl cat trapster > "$BACKUP/systemctl-cat.txt"
"$OLD/venv/bin/pip" freeze | grep -vE '^(-e |trapster)' > "$BACKUP/requirements.lock"
echo "  saved unit, package versions ($(wc -l < "$BACKUP/requirements.lock") packages)"

echo "== 2. Create the system user trapster (no login shell)"
if id trapster >/dev/null 2>&1; then
  echo "  already exists"
else
  useradd --system --user-group --home-dir /var/lib/trapster --no-create-home --shell /usr/sbin/nologin trapster
  echo "  created"
fi

echo "== 3. Copy the code to $NEW (old venv and config backups stay behind; Trapster keeps running)"
mkdir -p "$NEW"
tar -C "$OLD" --exclude=./venv --exclude='*.bak' --exclude='__pycache__' -cf - . | tar -C "$NEW" -xf -

echo "== 4. Build a new venv with the same package versions (needs internet via policy 2)"
python3 -m venv "$NEW/venv" || die "could not create a venv: sudo apt-get install -y python3-venv, then sudo rm -rf $NEW and run again"
"$NEW/venv/bin/pip" install --quiet -r "$BACKUP/requirements.lock" || die "pip install failed (internet? policy 2); Trapster still runs as before. sudo rm -rf $NEW and run again"
"$NEW/venv/bin/python" -m compileall -q "$NEW/main.py" "$NEW/trapster" >/dev/null

echo "== 5. Ownership: code read-only for trapster; only keys and certificates writable"
chown -R root:root "$NEW"
chmod -R u=rwX,go=rX "$NEW"
for d in "$NEW/trapster/data/ssh" "$NEW/trapster/data/ssl"; do
  mkdir -p "$d"
  chown -R trapster:trapster "$d"
  find "$d" -type d -exec chmod 700 {} +
  find "$d" -type f -exec chmod 600 {} +
done

echo "== 6. Stop the root service (honeypot offline from here until step 8)"
systemctl stop trapster

echo "== 7. Hand the event log to trapster (Alloy keeps read access)"
touch "$LOG"
chown trapster:trapster "$LOG"
chmod 640 "$LOG"
if id alloy >/dev/null 2>&1; then setfacl -m u:alloy:r "$LOG"; fi
install -o root -g root -m 0644 "$HERE/logrotate-trapster-community" /etc/logrotate.d/trapster-community

echo "== 8. Install the unprivileged unit and start"
install -o root -g root -m 0644 "$HERE/trapster.service" "$UNIT_DEST"
systemctl daemon-reload
systemctl enable --quiet trapster
systemctl start trapster
sleep 6

echo "== 9. Checks"
FAIL=0
systemctl is-active --quiet trapster || { echo "  FAIL: service not active (journalctl -u trapster -n 50)"; exit 1; }
PID="$(systemctl show -p MainPID --value trapster)"
RUNAS="$(ps -o user= -p "$PID" | tr -d ' ')"
echo "  process $PID runs as: $RUNAS"
[ "$RUNAS" = "trapster" ] || { echo "  FAIL: expected trapster"; FAIL=1; }
echo "  capabilities: $(grep -E '^CapEff' /proc/"$PID"/status) (0000000000000400 = only NET_BIND_SERVICE)"
grep -q '^CapEff:[[:space:]]*0000000000000400$' /proc/"$PID"/status || { echo "  FAIL: unexpected capability set"; FAIL=1; }
for p in $TCP_PORTS; do
  ss -tlnpH "sport = :$p" | grep -q "pid=$PID," || { echo "  FAIL: TCP $p not listening"; FAIL=1; }
done
for p in $UDP_PORTS; do
  ss -ulnpH "sport = :$p" | grep -q "pid=$PID," || { echo "  FAIL: UDP $p not listening"; FAIL=1; }
done
getfacl -p "$LOG" 2>/dev/null | grep -q '^user:alloy:r' || { echo "  FAIL: Alloy lost read access to $LOG"; FAIL=1; }

if [ "$FAIL" -eq 0 ]; then
  echo
  echo "OK: Trapster runs as trapster with only CAP_NET_BIND_SERVICE; 14 TCP + 2 UDP ports bound."
  echo "Backup: $BACKUP   Undo: sudo bash honeypot/rollback-root.sh"
else
  echo
  echo "Some checks failed. Logs: journalctl -u trapster -n 50 --no-pager"
  echo "Undo: sudo bash honeypot/rollback-root.sh"
  exit 1
fi
