#!/usr/bin/env bash
# Remove the packet-level scan sensor and restore the Alloy config from before setup-scan-sensor.sh.
# Usage: sudo bash honeypot/rollback-scan-sensor.sh [/root/scan-sensor-backup-YYYYmmdd-HHMMSS]
set -euo pipefail

ALLOY_DEST=/etc/alloy/config.alloy
die() { echo "STOP: $*" >&2; exit 1; }
trap 'echo "STOP: unexpected error on line $LINENO (exit $?)." >&2' ERR
[ "$(id -u)" -eq 0 ] || die "run with sudo"

# Default: the newest backup whose Alloy config has no sensor pipeline yet. If setup ran twice,
# the newest backup already contains the sensor, so it is skipped.
BACKUP="${1:-}"
if [ -z "$BACKUP" ]; then
  for d in $(ls -1d /root/scan-sensor-backup-* 2>/dev/null | sort -r); do
    if [ -f "$d/config.alloy" ] && ! grep -q 'loki.process "sensor"' "$d/config.alloy"; then BACKUP="$d"; break; fi
  done
fi
[ -n "$BACKUP" ] && [ -f "$BACKUP/config.alloy" ] || die "no backup with a pre-sensor config.alloy in /root/scan-sensor-backup-*"
echo "== Using backup $BACKUP"

echo "== 1. Stop the sensor and remove its table"
systemctl disable --now hp-scan-sensor 2>/dev/null || true
if nft list table inet hp_scan_sensor >/dev/null 2>&1; then nft delete table inet hp_scan_sensor; fi
echo "  table hp_scan_sensor: $(nft list table inet hp_scan_sensor >/dev/null 2>&1 && echo 'STILL PRESENT' || echo removed)"

echo "== 2. Remove the unit and the rules file"
rm -f /etc/systemd/system/hp-scan-sensor.service
rm -rf /etc/hp-scan-sensor
systemctl daemon-reload

echo "== 3. Restore the previous Alloy config"
install -o root -g alloy -m 0640 "$BACKUP/config.alloy" "$ALLOY_DEST"
systemctl restart alloy
sleep 5
systemctl is-active --quiet alloy || die "alloy did not start with the restored config: journalctl -u alloy -n 50 --no-pager"
echo "  alloy active"

echo "== 4. Left in place: alloy stays in the systemd-journal group (harmless: read-only access to logs)"

echo "== 5. Check Trapster"
systemctl is-active --quiet trapster && echo "  trapster active" || die "trapster is not active"
echo
echo "Scan sensor removed."
