#!/usr/bin/env bash
# Email alerts for the honeypot: Grafana sends one email per attacker IP when Trapster logs events.
# Asks for the mail server settings, keeps the password out of the repo (in /etc/default/grafana-server,
# readable by root only), installs the alert rule, and restarts Grafana.
# Run from the cloned repo on log-server01:  sudo bash logserver/setup-email-alerts.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ENVFILE=/etc/default/grafana-server
RULE_SRC="$HERE/grafana/provisioning/alerting/trapster-alerts.yaml"
RULE_DEST=/etc/grafana/provisioning/alerting/trapster-alerts.yaml
BEGIN="# BEGIN honeypot email alerts"
END="# END honeypot email alerts"

die() { echo "STOP: $*" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -f "$RULE_SRC" ] || die "alert rule not found at $RULE_SRC"
systemctl show grafana-server -p EnvironmentFiles | grep -q "$ENVFILE" || die "grafana-server does not read $ENVFILE"

echo "== 1. Mail server settings (port 587 with STARTTLS; the lab's upstream provider blocks 465)"
read -rp "SMTP server host:port [smtp.gmail.com:587]: " SMTP_HOST
SMTP_HOST="${SMTP_HOST:-smtp.gmail.com:587}"
read -rp "SMTP login (full address): " SMTP_USER
read -rsp "SMTP password (app password, not shown): " SMTP_PASS; echo
read -rp "From address [$SMTP_USER]: " FROM
FROM="${FROM:-$SMTP_USER}"
read -rp "Send alerts to (comma-separated): " TO

for v in SMTP_HOST SMTP_USER SMTP_PASS FROM TO; do
  [ -n "${!v}" ] || die "$v is empty"
  case "${!v}" in *"'"*|*\\*|*"|"*|*"&"*) die "$v must not contain ' \\ | or &" ;; esac
done

echo "== 2. Can this server reach the mail server?"
H="${SMTP_HOST%:*}"; P="${SMTP_HOST##*:}"
IP4="$(getent ahostsv4 "$H" | awk 'NR==1{print $1}')"
if [ -n "$IP4" ] && timeout 6 bash -c "exec 3<>/dev/tcp/$IP4/$P" 2>/dev/null; then
  echo "  reached $H on port $P"
else
  echo "  WARNING: cannot reach $H:$P over IPv4. Check that policy 2 allows TCP $P (see README)."
  echo "  Continuing; alerts will be sent once the port is open."
fi

echo "== 3. Store the settings in $ENVFILE (root only)"
cp -a "$ENVFILE" "$ENVFILE.$(date +%Y%m%d-%H%M%S).bak"
sed -i "/^$BEGIN\$/,/^$END\$/d" "$ENVFILE"
{
  echo "$BEGIN"
  echo "GF_SMTP_ENABLED=true"
  echo "GF_SMTP_HOST='$SMTP_HOST'"
  # 465 is TLS from the start; any other port must upgrade with STARTTLS so the password never goes in clear
  [ "$P" = "465" ] || echo "GF_SMTP_STARTTLS_POLICY='MandatoryStartTLS'"
  echo "GF_SMTP_USER='$SMTP_USER'"
  echo "GF_SMTP_PASSWORD='$SMTP_PASS'"
  echo "GF_SMTP_FROM_ADDRESS='$FROM'"
  echo "GF_SMTP_FROM_NAME='Honeypot appliance'"
  echo "GF_SERVER_ROOT_URL='http://192.168.20.20:3000/'"
  echo "$END"
} >> "$ENVFILE"
chown root:root "$ENVFILE"
chmod 600 "$ENVFILE"
unset SMTP_PASS

echo "== 4. Install the alert rule, contact point and notification policy"
install -d -o root -g grafana -m 0755 "$(dirname "$RULE_DEST")"
sed "s|__ALERT_EMAIL__|$TO|" "$RULE_SRC" > "$RULE_DEST.tmp"
grep -q "addresses: $TO\$" "$RULE_DEST.tmp" || die "could not write the recipient into the rule"
install -o root -g grafana -m 0640 "$RULE_DEST.tmp" "$RULE_DEST"
rm -f "$RULE_DEST.tmp"

echo "== 5. Restart Grafana"
SINCE="$(date '+%Y-%m-%d %H:%M:%S')"
systemctl restart grafana-server
sleep 10
systemctl is-active grafana-server
printf 'Grafana health: '; curl -s http://127.0.0.1:3000/api/health | tr -d '\n'; echo
if journalctl -u grafana-server --since "$SINCE" --no-pager | grep -iE 'level=error.*(alert|provision|smtp)'; then
  echo "  The lines above are Grafana errors about alerting; fix them before testing."
  exit 1
fi

echo
echo "Done. Test end to end from Kali:"
echo "  curl -m 5 -s -o /dev/null http://192.168.20.10/alerttest"
echo "An email from '$FROM' to '$TO' should arrive within about 2 minutes."
echo "In Grafana: Alerting -> Alert rules -> Honeypot -> 'Honeypot touched' shows the state."
