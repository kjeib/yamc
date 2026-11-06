#!/bin/bash
# mailserver-certpull - fetch the mail TLS certificate from the gateway and
# install it ONLY if it changed. Installed by yamc mailserver as
# /usr/local/sbin/mailserver-certpull; run by mailserver-certpull.timer and
# on demand by 'yamc -h <host> mailserver cert' (which passes -f).
#
# The timer fires hourly. Until a real certificate has been installed every
# run tries (so a new build picks the certificate up within the hour with no
# command); after that a run does nothing unless the last check is ~a day old.
#
# The gateway cannot push: the WireGuard hub's port allowlist forbids it
# opening connections to this host, by design. So this host pulls, over the
# tunnel, with a key the gateway restricts to one forced command that emits
# fullchain.pem + privkey.pem as a tar stream - no shell, no forwarding.
#
# Exit status: 0 ok (installed, unchanged, checked recently, or - before the
# first real certificate - gateway not ready yet), 1 fetch/validation failed
# (the installed cert is untouched), 2 installed cert expires within WARN_DAYS.
# A non-zero exit marks the systemd unit failed, which 'mailserver status'
# reports.

set -e -o pipefail
umask 077

CONF=/etc/mailserver/mailserver.conf
KEY=/root/.ssh/mailserver-certpull
KNOWN=/root/.ssh/known_hosts.mailgate
TLS=/etc/mailserver/tls
STATE=/var/lib/mailserver/cert.state
WARN_DAYS=21

# shellcheck disable=SC1090
. "$CONF"

log() { echo "mailserver-certpull: $*"; }
days_left() {
  local end
  end=$(openssl x509 -enddate -noout -in "$1" | cut -d= -f2)
  echo $(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
}
write_state() {   # write_state SOURCE CERTFILE
  local f="$1" c="$2"
  {
    echo "source=$f"
    echo "fingerprint=$(openssl x509 -noout -fingerprint -sha256 -in "$c" | cut -d= -f2)"
    echo "subject_names=$(openssl x509 -noout -ext subjectAltName -in "$c" 2>/dev/null | tail -n +2 | tr -d ' ')"
    echo "not_after=$(openssl x509 -enddate -noout -in "$c" | cut -d= -f2)"
    echo "days_left=$(days_left "$c")"
    echo "checked=$(date -Is)"
  } > "$STATE.tmp"
  mv "$STATE.tmp" "$STATE"
}

expiry_check() {
  local d
  d=$(days_left "$TLS/fullchain.pem")
  if [ "$d" -lt "$WARN_DAYS" ]; then
    log "WARNING: certificate has $d days left - renewal on the gateway is failing."
    log "         Check there:  certbot renew --dry-run"
    exit 2
  fi
}

FORCE=false
[ "${1:-}" = "-f" ] && FORCE=true
HAVE_REAL=false
grep -q '^source=gateway' "$STATE" 2>/dev/null && HAVE_REAL=true

# ---- daily once a real certificate is in place ------------------------------------
if [ "$FORCE" != true ] && [ "$HAVE_REAL" = true ]; then
  last=$(sed -n 's/^checked=//p' "$STATE")
  if [ -n "$last" ] && [ $(( $(date +%s) - $(date -d "$last" +%s) )) -lt 82800 ]; then
    expiry_check
    exit 0
  fi
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---- fetch ------------------------------------------------------------------
if ! ssh -i "$KEY" -o BatchMode=yes -o ConnectTimeout=20 \
       -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$KNOWN" \
       "root@$GATE_TUNNEL_ADDR" certpush | tar -C "$TMP" -xf - 2>"$TMP/err"; then
  if [ "$HAVE_REAL" != true ] && [ "$FORCE" != true ]; then
    # Nothing real installed yet: the gateway is simply not ready. Waiting,
    # not broken - try again next hour.
    log "gateway not ready yet; still on the placeholder certificate"
    exit 0
  fi
  log "FETCH FAILED from $GATE_TUNNEL_ADDR - installed certificate left as is"
  sed 's/^/  /' "$TMP/err" >&2 || true
  exit 1
fi
NEW_CERT="$TMP/fullchain.pem"
NEW_KEY="$TMP/privkey.pem"

# ---- validate before touching anything ---------------------------------------
[ -s "$NEW_CERT" ] && [ -s "$NEW_KEY" ] || { log "fetched bundle is incomplete"; exit 1; }
openssl x509 -noout -checkhost "$MAIL_HOSTNAME" -in "$NEW_CERT" | grep -q 'does match' \
  || { log "fetched certificate does not cover $MAIL_HOSTNAME"; exit 1; }
[ "$(openssl x509 -noout -pubkey -in "$NEW_CERT" | sha256sum)" = \
  "$(openssl pkey -pubout -in "$NEW_KEY" 2>/dev/null | sha256sum)" ] \
  || { log "fetched key does not match fetched certificate"; exit 1; }
[ "$(days_left "$NEW_CERT")" -ge 0 ] || { log "fetched certificate has EXPIRED"; exit 1; }

# ---- install only on change ----------------------------------------------------
NEW_FP=$(openssl x509 -noout -fingerprint -sha256 -in "$NEW_CERT")
OLD_FP=$(openssl x509 -noout -fingerprint -sha256 -in "$TLS/fullchain.pem" 2>/dev/null || true)

if [ "$NEW_FP" = "$OLD_FP" ]; then
  log "unchanged (${NEW_FP#*=})"
else
  install -m 644 -o root -g root     "$NEW_CERT" "$TLS/fullchain.pem.new"
  install -m 640 -o root -g ssl-cert "$NEW_KEY"  "$TLS/privkey.pem.new"
  mv "$TLS/privkey.pem.new"   "$TLS/privkey.pem"
  mv "$TLS/fullchain.pem.new" "$TLS/fullchain.pem"
  log "INSTALLED new certificate (${NEW_FP#*=})"
  systemctl reload postfix || true
  # imapd re-reads the certificate per process; restart so prefork children do too
  systemctl restart cyrus-imapd || true
fi
write_state gateway "$TLS/fullchain.pem"

log "expires $(openssl x509 -enddate -noout -in "$TLS/fullchain.pem" | cut -d= -f2) ($(days_left "$TLS/fullchain.pem") days)"
expiry_check
exit 0
