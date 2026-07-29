#!/bin/bash
# accounts/common.sh - shared helpers for the accounts module
#
# Kept NON-EXECUTABLE on purpose: yamc discovers subcommands by scanning the
# module directory for executable files, so an executable helper here would
# appear as a bogus 'accounts common.sh' subcommand.
#
# Sourced by: setup, adduser, setpass

ACCT_DRYRUN="${ACCT_DRYRUN:-0}"
ACCT_FORCE="${ACCT_FORCE:-0}"

# %q-quote so echoed commands are copy-pasteable (gecos contains spaces).
acct_run() {
  if [ "$ACCT_DRYRUN" = "1" ]; then
    printf '    [dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    printf '    +'; printf ' %q' "$@"; printf '\n'
    "$@"
  fi
}

# Strip comments and blank lines from a roster file.
acct_records() {
  sed -e 's/#.*//' -e 's/[[:space:]]*$//' -e '/^$/d' "$1"
}

# ---------------------------------------------------------------------------
# verify_identity USER WANT_UID WANT_GID HOME
#
# The home directory on NFS is the authority on numeric identity, because it
# is what determines whether the user can read their own files.
#
#   UID mismatch -> hard failure. The account would be unable to read its
#                   own home directory.
#   GID mismatch -> warning only. A home directory group-owned by a shared
#                   group (e.g. /home/mia is 1005:1500) is normal and does
#                   not affect the user's access.
#
# Returns 1 on a UID mismatch unless ACCT_FORCE=1.
# ---------------------------------------------------------------------------
verify_identity() {
  local user="$1" want_uid="$2" want_gid="$3" home="$4"
  local have_uid have_gid

  if [ ! -d "$home" ]; then
    echo "    note: $home does not exist here; cannot cross-check identity"
    return 0
  fi

  have_uid=$(stat -c %u "$home" 2>/dev/null)
  have_gid=$(stat -c %g "$home" 2>/dev/null)

  if [ "$have_gid" != "$want_gid" ]; then
    echo "    note: $home group is $have_gid, primary group is $want_gid (normal if shared)"
  fi

  if [ "$have_uid" != "$want_uid" ]; then
    echo "    *** UID MISMATCH for $user ***"
    echo "        roster says:   $want_uid"
    echo "        $home is owned by: $have_uid"
    echo "        Creating this account would leave $user unable to read"
    echo "        their own files. Fix the roster, or re-run with -e ACCT_FORCE=1."
    [ "$ACCT_FORCE" = "1" ] || return 1
    echo "        ACCT_FORCE=1 - proceeding anyway."
  fi

  return 0
}

# ---------------------------------------------------------------------------
# ensure_group NAME GID
#   GID of "-" means: must already exist locally; never create it.
# ---------------------------------------------------------------------------
ensure_group() {
  local name="$1" gid="$2" existing_gid existing_name

  if [ "$gid" = "-" ]; then
    if getent group "$name" >/dev/null 2>&1; then
      existing_gid=$(getent group "$name" | cut -d: -f3)
      echo "  $name: system group, exists locally as gid=$existing_gid (not touched)"
      return 0
    fi
    echo "  $name: SKIP - marked system-only but does not exist on this host"
    return 0
  fi

  if getent group "$gid" >/dev/null 2>&1; then
    existing_name=$(getent group "$gid" | cut -d: -f1)
    if [ "$existing_name" = "$name" ]; then
      echo "  $name: already exists with gid=$gid"
    else
      echo "  $name: CONFLICT - gid $gid is already used by '$existing_name'"
      return 1
    fi
    return 0
  fi

  if getent group "$name" >/dev/null 2>&1; then
    existing_gid=$(getent group "$name" | cut -d: -f3)
    echo "  $name: CONFLICT - exists with gid=$existing_gid, roster wants $gid"
    echo "        Refusing to renumber a group. Resolve by hand."
    return 1
  fi

  echo "  $name: creating with gid=$gid"
  acct_run groupadd -g "$gid" "$name"
}

# ---------------------------------------------------------------------------
# ensure_user USER UID GID GECOS HOME SHELL SUPPGROUPS
# ---------------------------------------------------------------------------
ensure_user() {
  local user="$1" uid="$2" gid="$3" gecos="$4" home="$5" shell="$6" supp="$7"
  local cur_uid cur_gid clash

  echo "  $user (uid=$uid gid=$gid):"

  verify_identity "$user" "$uid" "$gid" "$home" || return 1

  if getent passwd "$user" >/dev/null 2>&1; then
    cur_uid=$(getent passwd "$user" | cut -d: -f3)
    cur_gid=$(getent passwd "$user" | cut -d: -f4)
    if [ "$cur_uid" = "$uid" ] && [ "$cur_gid" = "$gid" ]; then
      echo "    exists with correct $cur_uid:$cur_gid"
    else
      echo "    ERROR: exists as $cur_uid:$cur_gid, roster says $uid:$gid"
      echo "           Refusing to renumber an existing account."
      return 1
    fi
  elif getent passwd "$uid" >/dev/null 2>&1; then
    clash=$(getent passwd "$uid" | cut -d: -f1)
    echo "    ERROR: uid $uid already taken by '$clash' on this host"
    return 1
  else
    if ! getent group "$gid" >/dev/null 2>&1; then
      if [ "$ACCT_DRYRUN" = "1" ]; then
        # In a real run the groups phase has already created it.
        echo "    (primary group gid=$gid would exist after the groups phase)"
      else
        echo "    ERROR: primary group gid=$gid does not exist - run groups first"
        return 1
      fi
    fi
    # -M: never create/skeleton the home dir (NFS, already populated)
    # -N: no auto user-group; the primary group is created from groups.conf
    acct_run useradd -u "$uid" -g "$gid" -c "$gecos" \
                     -d "$home" -s "$shell" -M -N "$user"
    # LDAP {SSHA} hashes are not a crypt(3) format and cannot be migrated,
    # so accounts start locked. Bootstrap with 'accounts setpass'.
    acct_run passwd -l "$user"
    echo "    created LOCKED (no password migrated) - use 'accounts setpass'"
  fi

  # Supplementary groups, additive and idempotent.
  if [ -n "$supp" ]; then
    local g
    for g in ${supp//,/ }; do
      if ! getent group "$g" >/dev/null 2>&1; then
        if [ "$ACCT_DRYRUN" = "1" ]; then
          echo "    (group '$g' would exist after the groups phase)"
        else
          echo "    SKIP group '$g' - does not exist on this host"
          continue
        fi
      fi
      if id -nG "$user" 2>/dev/null | tr ' ' '\n' | grep -qx "$g"; then
        continue
      fi
      acct_run usermod -aG "$g" "$user"
    done
  fi

  return 0
}
