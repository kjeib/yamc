#!/bin/bash
# backup-box/common.sh - shared helpers for the backup-box module
#
# Kept NON-EXECUTABLE on purpose (same reason as accounts/common.sh): yamc
# treats executable files in a module directory as subcommands, so an
# executable helper here would show up as a bogus 'backup-box common.sh'.
#
# Sourced by: storage, setup, lockdown, status

# ---------------------------------------------------------------------------
# Parameters (-e name=value) and their defaults.
# Lowercase = user-supplied, uppercase = resolved constant. See CONTRIBUTING.md.
# ---------------------------------------------------------------------------
BK_MOUNT="${bk_mount:-/srv/backup}"
BK_VG="${bk_vg:-}"                    # empty = autodetect, refuse if ambiguous
BK_LV="${bk_lv:-backup}"
BK_SIZE="${bk_size:-100%FREE}"
BK_FSTYPE="${bk_fstype:-ext4}"
BK_IFACE="${bk_iface:-bk0}"
BK_PORT="${bk_port:-8000}"
BK_ADDR="${bk_addr:-}"                # empty = read from BK_IFACE
BK_USERS="${bk_users:-}"              # space-separated rest-server users

BK_REPOS="$BK_MOUNT/repos"
BK_CONF_DIR="/etc/rest-server"
BK_HTPASSWD="$BK_CONF_DIR/htpasswd"
BK_UNIT="/etc/systemd/system/rest-server.service"
BK_SRV_USER="restsrv"
BK_NFT_TABLE="backup_box"
BK_NFT_FILE="/etc/nftables.d/backup-box.nft"

bk_banner() {
  echo "===================================================================="
  echo "backup-box $1 - $(hostname) as $(whoami)"
  echo "===================================================================="
}

bk_die() {
  echo "ERROR: $*" >&2
  exit 1
}

bk_need_root() {
  [ "$(id -u)" -eq 0 ] || bk_die "This script must be run as root (yamc.env sets YAMC_USER=root)"
}

# ---------------------------------------------------------------------------
# bk_confirm "description of the action"
#
# Report-then-confirm gate. Callers MUST print the full plan before calling
# this, so that the report and the action are the same code path and cannot
# drift apart.
#
#   -e yes=1     proceed without asking
#   TTY present  prompt
#   no TTY       refuse (yamcity runs modules with stdin from /dev/null, so a
#                prompt there would read EOF and silently proceed)
#
# Returns 0 to proceed, 1 to stop.
# ---------------------------------------------------------------------------
bk_confirm() {
  local what="$1" reply

  if [ "${yes:-0}" = "1" ]; then
    echo
    echo "-e yes=1 given - proceeding without prompting."
    return 0
  fi

  if [ -t 0 ]; then
    echo
    read -r -p "Proceed to $what? [y/N] " reply
    case "$reply" in
      [yY]|[yY][eE][sS]) return 0 ;;
    esac
    # Declining is a choice, not a failure. Return 2 so the caller can exit 0
    # and yamc does not report a scary "Remote script execution failed" for
    # what was a deliberate look-and-decline.
    echo "Aborted at your request. Nothing was changed."
    return 2
  fi

  echo
  echo "REPORT ONLY - nothing has been changed."
  echo "No terminal available to prompt for confirmation."
  echo "To proceed, re-run with:  -e yes=1"
  return 1
}

# ---------------------------------------------------------------------------
# bk_gate "description" - wrap bk_confirm with the right exit semantics.
#   declined at a prompt -> exit 0 (a decision was made, nothing failed)
#   no terminal          -> exit 1 (the requested work could not be done)
# ---------------------------------------------------------------------------
bk_gate() {
  local rc=0
  bk_confirm "$1" || rc=$?
  case "$rc" in
    0) return 0 ;;
    2) exit 0 ;;
    *) exit 1 ;;
  esac
}

# Echo a command, then run it.
bk_run() {
  printf '    +'; printf ' %q' "$@"; printf '\n'
  "$@"
}

# ---------------------------------------------------------------------------
# bk_tunnel_addr - the address services should bind to.
#
# Explicit -e bk_addr wins; otherwise read it off the tunnel interface. Empty
# output means the tunnel is not up, which callers treat as fatal: binding a
# repository service to a wildcard address on a box in hostile territory is
# exactly the mistake this design exists to avoid.
# ---------------------------------------------------------------------------
bk_tunnel_addr() {
  if [ -n "$BK_ADDR" ]; then
    echo "$BK_ADDR"
    return 0
  fi
  ip -4 -o addr show dev "$BK_IFACE" 2>/dev/null \
    | awk '{print $4}' | cut -d/ -f1 | head -n1
}

# Is BK_MOUNT a real, mounted filesystem?
bk_mount_ready() {
  mountpoint -q "$BK_MOUNT" 2>/dev/null
}
