#!/usr/bin/env bash
# Undo setup-unprivileged.sh: restore the root service that runs from /home/labadmin.
# /opt/trapster-community and the trapster user are left in place.
# Usage: sudo bash honeypot/rollback-root.sh [/root/trapster-backup-YYYYmmdd-HHMMSS]
set -euo pipefail

LOG=/var/log/trapster-community.log
NEW_UNIT=/etc/systemd/system/trapster.service

die() { echo "STOP: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"

BACKUP="${1:-$(ls -1d /root/trapster-backup-* 2>/dev/null | sort | tail -n 1)}"
[ -n "$BACKUP" ] && [ -f "$BACKUP/trapster.service.root" ] || die "no backup found in /root/trapster-backup-*"
OLD_UNIT="$(cat "$BACKUP/unit-path.txt")"
echo "== Using backup $BACKUP"

systemctl stop trapster || true
[ "$OLD_UNIT" = "$NEW_UNIT" ] || rm -f "$NEW_UNIT"
cp -a "$BACKUP/trapster.service.root" "$OLD_UNIT"

chown root:root "$LOG"
chmod 644 "$LOG"
if id alloy >/dev/null 2>&1; then setfacl -m u:alloy:r "$LOG"; fi

systemctl daemon-reload
systemctl start trapster
sleep 5
systemctl is-active trapster
PID="$(systemctl show -p MainPID --value trapster)"
echo "process $PID runs as: $(ps -o user= -p "$PID")"
