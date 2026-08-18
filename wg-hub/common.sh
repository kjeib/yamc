#!/bin/bash
# wg-hub/common.sh - remote-side helpers
#
# Kept NON-EXECUTABLE on purpose: yamc treats executable files in a module
# directory as subcommands.
#
# Sourced by: setup, status

WG_DIR="/etc/wireguard"
WG_CONF="$WG_DIR/${WG_IFACE}.conf"
WG_KEY="$WG_DIR/${WG_IFACE}.key"
WG_PUB="$WG_DIR/${WG_IFACE}.pub"
WG_NFT="$WG_DIR/${WG_IFACE}.nft"
NFT_TABLE="wgnet_${WGNET_NAME}"

wg_banner() {
  echo "===================================================================="
  echo "wg-hub $1 - network '${WGNET_NAME}' on $(hostname) as $(whoami)"
  echo "===================================================================="
}

wg_die() { echo "ERROR: $*" >&2; exit 1; }

wg_need_root() {
  [ "$(id -u)" -eq 0 ] || wg_die "Must run as root (yamc.env sets YAMC_USER=root; an explicit -u overrides it)"
}

wg_run() { printf '    +'; printf ' %q' "$@"; printf '\n'; "$@"; }

# ---------------------------------------------------------------------------
# wg_gate "description" - report-then-confirm.
#   -e yes=1     proceed
#   TTY          prompt; declining exits 0 (a decision, not a failure)
#   no TTY       refuse and exit 1 (yamcity redirects stdin from /dev/null, so
#                a prompt there would read EOF and silently proceed)
# ---------------------------------------------------------------------------
wg_gate() {
  local what="$1" reply

  if [ "${yes:-0}" = "1" ]; then
    echo; echo "-e yes=1 given - proceeding without prompting."
    return 0
  fi

  if [ -t 0 ]; then
    echo
    read -r -p "Proceed to $what? [y/N] " reply
    case "$reply" in
      [yY]|[yY][eE][sS]) return 0 ;;
    esac
    echo "Aborted at your request. Nothing was changed."
    exit 0
  fi

  echo
  echo "REPORT ONLY - nothing has been changed."
  echo "No terminal available to prompt. To proceed, re-run with:  -e yes=1"
  exit 1
}

# Seconds since a peer's last handshake, or empty if never.
wg_handshake_age() {
  local iface="$1" key="$2" last now
  last=$(wg show "$iface" latest-handshakes 2>/dev/null | awk -v k="$key" '$1==k{print $2}')
  [ -n "$last" ] && [ "$last" != "0" ] || return 1
  now=$(date +%s)
  echo $(( now - last ))
}
