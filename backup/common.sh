#!/bin/bash
# backup/common.sh - shared helpers for the backup client module
#
# Kept NON-EXECUTABLE on purpose: yamc treats executable files in a module
# directory as subcommands.
#
# Sourced by: setup, init, run, check, snapshots, env, enable, disable, status

BK_ETC="/etc/restic"
BK_STATE="/var/lib/restic"
BK_CRON="/etc/cron.d/yamc-backup"
BK_RUNNER="/usr/local/sbin/yamc-backup-run"

bk_banner() {
  echo "===================================================================="
  echo "backup $1 - $(hostname) as $(whoami)"
  echo "===================================================================="
}

bk_die() { echo "ERROR: $*" >&2; exit 1; }

bk_need_root() {
  [ "$(id -u)" -eq 0 ] || bk_die "Must run as root (yamc.env sets YAMC_USER=root)"
}

bk_run() { printf '    +'; printf ' %q' "$@"; printf '\n'; "$@"; }

# The repositories this host is configured for, from the staged table.
bk_repos() { awk -F'|' '{gsub(/ /,"",$1); print $1}' "$MOD_TMP/repos.tab" 2>/dev/null; }

# Load one repository's environment: RESTIC_REPOSITORY, RESTIC_PASSWORD_FILE
# and the rest-server credential. Returns 1 if it is not configured here.
bk_load() {
  local repo="$1"
  [ -f "$BK_ETC/$repo.env" ] || return 1
  set -a
  # shellcheck disable=SC1090
  source "$BK_ETC/$repo.env"
  set +a
  return 0
}

# ---------------------------------------------------------------------------
# bk_reachable REPO - refuse to proceed unless the repository really answers.
#
# The rsync-era diskback kept a BACKUP sentinel file on the volume and would
# not run unless it was there, because rsyncing into an empty mountpoint
# quietly "succeeds" and destroys nothing but achieves nothing. The restic
# equivalent is checking that the repository exists and unlocks: a repo that
# has vanished must be an error, never a silent no-op.
# ---------------------------------------------------------------------------
bk_reachable() {
  local repo="$1"
  restic cat config >/dev/null 2>&1 && return 0
  echo "  $repo: repository does not answer at $RESTIC_REPOSITORY"
  echo "     Is the tunnel up, and has 'backup init' been run?"
  return 1
}

# Where the last successful run is recorded, per repo.
bk_stamp() { echo "$BK_STATE/$1.last"; }
