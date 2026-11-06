#!/bin/bash
# mailserver/common.sh - remote-side helpers
#
# Kept NON-EXECUTABLE on purpose: yamc treats executable files in a module
# directory as subcommands. mailgate has its own copy: on the remote side only
# the module's own directory is mounted, so a cross-module symlink would dangle.

MS_ETC="/etc/mailserver"
MS_TLS="$MS_ETC/tls"
MS_STATE_DIR="/var/lib/mailserver"
MS_CONF="$MS_ETC/mailserver.conf"           # runtime config for installed scripts
MS_CERTPULL_KEY="/root/.ssh/mailserver-certpull"
MS_CERTPULL_BIN="/usr/local/sbin/mailserver-certpull"

ms_banner() {
  echo "===================================================================="
  echo "mailserver $1 on $(hostname) as $(whoami)"
  echo "===================================================================="
}

ms_die() { echo "ERROR: $*" >&2; exit 1; }

ms_need_root() {
  [ "$(id -u)" -eq 0 ] || ms_die "Must run as root (yamc.env sets YAMC_USER=root; an explicit -u overrides it)"
}

ms_run() { printf '    +'; printf ' %q' "$@"; printf '\n'; "$@"; }

# ms_gate "description" - report-then-confirm, same contract as wg-hub:
#   -e yes=1   proceed;  TTY   prompt;  no TTY   refuse (exit 1)
ms_gate() {
  local what="$1" reply
  if [ "${yes:-0}" = "1" ]; then
    echo; echo "-e yes=1 given - proceeding without prompting."; return 0
  fi
  if [ -t 0 ]; then
    echo
    read -r -p "Proceed to $what? [y/N] " reply
    case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; esac
    echo "Aborted at your request. Nothing was changed."; exit 0
  fi
  echo; echo "REPORT ONLY - nothing has been changed."
  echo "No terminal available to prompt. To proceed, re-run with:  -e yes=1"
  exit 1
}

# ms_put DST MODE OWNER:GROUP  < content
# Install stdin at DST only if it differs. Returns 0 if written, 1 if unchanged,
# so callers can do:  ms_put ... && CHANGED=1
ms_put() {
  local dst="$1" mode="$2" owner="${3:-root:root}" tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"
    chmod "$mode" "$dst"; chown "$owner" "$dst"
    return 1
  fi
  install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$dst"
  rm -f "$tmp"
  echo "    wrote $dst"
  return 0
}

# ms_kv_set FILE KEY VALUE - set 'key: value' (imapd.conf style), replacing
# the first occurrence and dropping duplicates. awk, not sed: values contain
# '|' and '/'. Returns 0 if the file changed.
ms_kv_set() {
  local file="$1" key="$2" value="$3" tmp
  tmp=$(mktemp)
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    index($0, k ":") == 1 { if (!done) { print k ": " v; done = 1 }; next }
    { print }
    END { if (!done) print k ": " v }' "$file" > "$tmp"
  if cmp -s "$tmp" "$file"; then rm -f "$tmp"; return 1; fi
  cat "$tmp" > "$file"; rm -f "$tmp"
  echo "    $file: $key: $value"
  return 0
}

# ms_pkgs_missing PKG... - print those not installed
ms_pkgs_missing() {
  local p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || printf '%s ' "$p"
  done
}

# Days until a certificate expires (negative if expired).
ms_cert_days() {
  local end
  end=$(openssl x509 -enddate -noout -in "$1" 2>/dev/null | cut -d= -f2) || return 1
  [ -n "$end" ] || return 1
  echo $(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
}
