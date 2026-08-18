#!/bin/bash
# wg-peer/wgnet.loc.sh - LOCAL-side helpers: find and validate the network config
#
# Kept NON-EXECUTABLE on purpose (same reason as accounts/common.sh): yamc
# treats executable files in a module directory as subcommands.
#
# Sourced by: setup.loc, status.loc
#
# Site data lives in yamc.local/wgnet/ rather than a per-module resource
# directory, because wg-hub and wg-peer must read the SAME peer table and it
# needs one authoritative home. This resolution has to happen locally: on the
# remote side MOD_DIR is an sshfs mount and yamc.local does not exist at all.

# ---------------------------------------------------------------------------
# wgnet_dir - locate yamc.local/wgnet/
#   1. -e wgnet_dir=/path        explicit override
#   2. $RES_DIR/../wgnet         when yamc resolved a resource directory
#   3. $MOD_DIR/../../yamc.local/wgnet   yamc's own sibling convention
# ---------------------------------------------------------------------------
wgnet_find_dir() {
  local d
  if [ -n "${wgnet_dir:-}" ]; then
    echo "$wgnet_dir"; return 0
  fi
  if [ -n "${RES_DIR:-}" ]; then
    d="$(dirname "$RES_DIR")/wgnet"
    [ -d "$d" ] && { echo "$d"; return 0; }
  fi
  d="$(cd "$MOD_DIR/../.." 2>/dev/null && pwd)/yamc.local/wgnet"
  [ -d "$d" ] && { echo "$d"; return 0; }
  return 1
}

# ---------------------------------------------------------------------------
# wgnet_load NET - source <net>.conf and validate it. Sets WGNET_DIR.
# ---------------------------------------------------------------------------
wgnet_load() {
  local net="$1"

  if [ -z "$net" ]; then
    echo "ERROR: no network specified. Use -e net=<name>."
    echo "       There is no default: the wrong one would apply a mobile"
    echo "       network's policy to a backup network, or vice versa."
    return 1
  fi

  if ! WGNET_DIR="$(wgnet_find_dir)"; then
    echo "ERROR: cannot locate yamc.local/wgnet/."
    echo "       Pass -e wgnet_dir=/path, or create it alongside your other"
    echo "       yamc.local resources."
    return 1
  fi

  local conf="$WGNET_DIR/$net.conf"
  if [ ! -f "$conf" ]; then
    echo "ERROR: no such network: $conf"
    echo "Networks defined in $WGNET_DIR:"
    find "$WGNET_DIR" -maxdepth 1 -name '*.conf' -printf '  %f\n' 2>/dev/null \
      | sed 's/\.conf$//' || echo "  (none)"
    return 1
  fi

  echo "Network '$net' from $conf"
  # shellcheck disable=SC1090
  source "$conf"

  local missing=""
  for v in WG_IFACE WG_PORT WG_SUBNET WG_HUB_ADDR; do
    [ -n "${!v}" ] || missing="$missing $v"
  done
  if [ -n "$missing" ]; then
    echo "ERROR: $conf is missing:$missing"
    return 1
  fi

  # ---- The wg+ hazard -----------------------------------------------------
  # Firewall snippets very commonly use the 'wg+' interface wildcard, which
  # matches any name starting with 'wg'. On a host already running another
  # WireGuard instance such a rule would silently apply to this interface too.
  case "$WG_IFACE" in
    wg*)
      echo "ERROR: WG_IFACE='$WG_IFACE' begins with 'wg'."
      echo "       Firewall rules elsewhere on the host may use the 'wg+'"
      echo "       wildcard and would then match this interface, granting"
      echo "       forwarding this module never wrote. Choose a name that"
      echo "       cannot be matched that way, e.g. 'bk0'."
      return 1
      ;;
  esac

  # ---- LAN_POLICY is fail-closed -----------------------------------------
  # No default and no fallback. Because this module is shared across networks,
  # a permissive default is how a backup network would eventually get loosened
  # by a change made for a mobile one.
  case "${LAN_POLICY:-}" in
    none|full) ;;
    route:*)
      [ -n "${LAN_POLICY#route:}" ] || {
        echo "ERROR: LAN_POLICY='route:' names no host."; return 1; }
      ;;
    "")
      echo "ERROR: LAN_POLICY is not set in $conf."
      echo "       There is deliberately no default. Set one of:"
      echo "         none          tunnel terminates on the hub, no forwarding"
      echo "         route:<host>  forward to exactly one LAN host"
      echo "         full          full LAN access"
      return 1
      ;;
    *)
      echo "ERROR: LAN_POLICY='$LAN_POLICY' is not recognised."
      echo "       Use: none | route:<host> | full"
      return 1
      ;;
  esac

  return 0
}

# ---------------------------------------------------------------------------
# wgnet_peers NET OUTFILE - validate <net>.peers and stage it.
#
# Format: name | tunnel addr | public key | notes
#
# Duplicate addresses are FATAL. WireGuard does not error on overlapping
# AllowedIPs - it silently reassigns the address to whichever peer was
# configured last, sending one box's traffic to another.
# ---------------------------------------------------------------------------
wgnet_peers() {
  local net="$1" out="$2"
  local src="$WGNET_DIR/$net.peers"
  local n=0 bad=0
  local -a seen_names=() seen_addrs=()

  : > "$out"

  if [ ! -f "$src" ]; then
    echo "No peer table ($src) - the interface will have no peers yet."
    return 0
  fi

  while IFS='|' read -r name addr key notes; do
    name=$(echo "$name" | xargs); addr=$(echo "$addr" | xargs)
    key=$(echo "$key"  | xargs); notes=$(echo "$notes" | xargs)
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac

    if [ -z "$addr" ] || [ -z "$key" ]; then
      echo "  ERROR: peer '$name' is missing an address or public key"; bad=1; continue
    fi
    if ! [[ "$key" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
      echo "  ERROR: peer '$name' public key is not a valid WireGuard key"; bad=1; continue
    fi
    for s in "${seen_names[@]}"; do
      [ "$s" = "$name" ] && { echo "  ERROR: duplicate peer name '$name'"; bad=1; }
    done
    for s in "${seen_addrs[@]}"; do
      [ "$s" = "$addr" ] && {
        echo "  ERROR: duplicate address '$addr' (peer '$name')"
        echo "         WireGuard would silently give it to whichever peer is"
        echo "         configured last, misrouting the other one."
        bad=1; }
    done

    seen_names+=("$name"); seen_addrs+=("$addr")
    echo "$name|$addr|$key|$notes" >> "$out"
    n=$((n + 1))
    echo "  peer: $name -> $addr/32${notes:+  ($notes)}"
  done < "$src"

  [ "$bad" -eq 0 ] || { echo "ERROR: peer table has errors; refusing to continue."; return 1; }
  echo "Peers: $n"
  return 0
}
