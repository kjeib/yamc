#!/bin/bash
# mailgate/common.sh - remote-side helpers
#
# Kept NON-EXECUTABLE on purpose: yamc treats executable files in a module
# directory as subcommands. A deliberate copy of the matching helpers in
# mailserver/common.sh: on the remote side only this module's directory is
# mounted, so a cross-module symlink would dangle.

MG_ETC="/etc/mailgate"
MG_NFT="$MG_ETC/firewall.nft"
MG_CERTPUSH="/usr/local/sbin/mailgate-certpush"
MG_AUTH_KEYS="/root/.ssh/authorized_keys"

mg_banner() {
  echo "===================================================================="
  echo "mailgate $1 on $(hostname) as $(whoami)"
  echo "===================================================================="
}

mg_die() { echo "ERROR: $*" >&2; exit 1; }

mg_need_root() {
  [ "$(id -u)" -eq 0 ] || mg_die "Must run as root (yamc.env sets YAMC_USER=root; an explicit -u overrides it)"
}

mg_run() { printf '    +'; printf ' %q' "$@"; printf '\n'; "$@"; }

# Report-then-confirm, same contract as wg-hub and mailserver.
mg_gate() {
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

# mg_put DST MODE OWNER:GROUP < content  - write only if different.
# Returns 0 if written, 1 if unchanged.
mg_put() {
  local dst="$1" mode="$2" owner="${3:-root:root}" tmp
  tmp=$(mktemp)
  cat > "$tmp"
  if [ -f "$dst" ] && cmp -s "$tmp" "$dst"; then
    rm -f "$tmp"; chmod "$mode" "$dst"; chown "$owner" "$dst"
    return 1
  fi
  install -D -m "$mode" -o "${owner%%:*}" -g "${owner##*:}" "$tmp" "$dst"
  rm -f "$tmp"
  echo "    wrote $dst"
  return 0
}

mg_pkgs_missing() {
  local p
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || printf '%s ' "$p"
  done
}

# Names of processes listening on TCP port $1 (any address), one per line.
mg_port_owners() {
  ss -ltnpH "( sport = :$1 )" 2>/dev/null | grep -o 'users:(("[^"]*"' | cut -d'"' -f2 | sort -u
}

mg_cert_days() {
  local end
  end=$(openssl x509 -enddate -noout -in "$1" 2>/dev/null | cut -d= -f2)
  [ -n "$end" ] || return 1
  echo $(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
}
