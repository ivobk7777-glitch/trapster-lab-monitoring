#!/usr/bin/env bash
# Reinstall the honeypot alert rules after a change in the repo, without asking for the SMTP
# password again. The recipients are read from the installed file and kept; the mail settings in
# /etc/default/grafana-server are not touched. First install: setup-email-alerts.sh.
# Run from the cloned repo on log-server01:  sudo bash logserver/update-alert-rules.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RULE_SRC="$HERE/grafana/provisioning/alerting/trapster-alerts.yaml"
RULE_DEST=/etc/grafana/provisioning/alerting/trapster-alerts.yaml
BAK="$RULE_DEST.$(date +%Y%m%d-%H%M%S).bak"

die() { echo "STOP: $*" >&2; exit 1; }
trap 'echo "STOP: unexpected error on line $LINENO (exit $?)." >&2' ERR

echo "== 1. Preflight"
[ "$(id -u)" -eq 0 ] || die "run with sudo"
[ -f "$RULE_SRC" ] || die "alert rules not found at $RULE_SRC (git pull?)"
[ -f "$RULE_DEST" ] || die "no installed rules at $RULE_DEST: run sudo bash logserver/setup-email-alerts.sh first"

echo "== 2. Keep the current recipients"
TO="$(grep -m1 -E '^[[:space:]]*addresses:' "$RULE_DEST" | sed -E 's/^[[:space:]]*addresses:[[:space:]]*//; s/[[:space:]]+$//' || true)"
[ -n "$TO" ] || die "no recipients in $RULE_DEST: run setup-email-alerts.sh"
[ "$TO" != "__ALERT_EMAIL__" ] || die "recipients were never set: run setup-email-alerts.sh"
case "$TO" in *"'"*|*\\*|*"|"*|*"&"*) die "recipients contain ' \\ | or &: run setup-email-alerts.sh" ;; esac
N="$(printf '%s' "$TO" | tr ',;' '\n\n' | grep -c '@' || true)"
echo "  recipients kept ($N address(es))"   # the address itself is not printed

echo "== 3. Install the new rules (backup: $BAK)"
cp -a "$RULE_DEST" "$BAK"
sed "s|__ALERT_EMAIL__|$TO|" "$RULE_SRC" > "$RULE_DEST.tmp"
grep -qF "addresses: $TO" "$RULE_DEST.tmp" || { rm -f "$RULE_DEST.tmp"; die "could not write the recipients into the rules"; }
install -o root -g grafana -m 0640 "$RULE_DEST.tmp" "$RULE_DEST"
rm -f "$RULE_DEST.tmp"
echo "  rules in file: $(grep -cE '^[[:space:]]*- uid: trapster-' "$RULE_DEST")"

restart_and_check() {
  local since; since="$(date '+%Y-%m-%d %H:%M:%S')"
  systemctl restart grafana-server
  sleep 10
  systemctl is-active --quiet grafana-server || return 1
  printf '  Grafana health: '; curl -s http://127.0.0.1:3000/api/health | tr -d '\n'; echo
  if journalctl -u grafana-server --since "$since" --no-pager | grep -iE 'level=error.*(alert|provision)'; then
    return 1
  fi
  return 0
}

echo "== 4. Restart Grafana"
if ! restart_and_check; then
  echo "  Grafana reported the errors above (or did not start). Restoring the previous rules."
  install -o root -g grafana -m 0640 "$BAK" "$RULE_DEST"
  restart_and_check || true
  die "new rules rejected; previous rules restored"
fi

echo
echo "Done. In Grafana: Alerting -> Alert rules -> Honeypot -> honeypot lists both rules:"
echo "  'Honeypot touched' and 'Honeypot scanned (packet level)'."
