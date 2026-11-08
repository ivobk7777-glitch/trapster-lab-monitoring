#!/usr/bin/env bash
# Deploy the expanded Trapster config to this honeypot VM (linux-server01).
# Backs up the current config, installs the repo copy, validates it, restarts the service.
# Run from the cloned repo:  sudo bash honeypot/deploy-config.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE/trapster.generated.conf"
DEST_DIR="/home/labadmin/trapster-community"
DEST="$DEST_DIR/trapster.generated.conf"

[ -f "$SRC" ] || { echo "Config not found at $SRC"; exit 1; }
[ -d "$DEST_DIR" ] || { echo "Trapster dir not found at $DEST_DIR"; exit 1; }

echo "== Validate the new config is well-formed JSON"
python3 -m json.tool "$SRC" > /dev/null && echo "  JSON OK"

echo "== Back up the current config"
if [ -f "$DEST" ]; then
  BK="$DEST.$(date +%Y%m%d-%H%M%S).bak"
  cp -a "$DEST" "$BK"
  echo "  saved $BK"
fi

echo "== Install the new config"
install -o labadmin -g labadmin -m 0644 "$SRC" "$DEST"

echo "== Restart Trapster"
systemctl restart trapster
sleep 4
systemctl is-active trapster

echo "== Listeners now bound on 192.168.20.10"
ss -tulpnH 2>/dev/null | grep -E 'python' | awk '{print $1, $5}' | sort -t: -k2 -n || true
echo
echo "Done. Expected ports: 21 22 23 53 80 161 389 443 636 873 1433 3306 3389 5432 5900."
echo "Watch events:  sudo tail -f /var/log/trapster-community.log"
echo "Roll back:     sudo cp <the .bak file> $DEST && sudo systemctl restart trapster"
