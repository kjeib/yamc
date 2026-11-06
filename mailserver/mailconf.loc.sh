#!/bin/bash
# mailconf.loc.sh - LOCAL-side helpers: find, validate and stage mail config
#
# SHARED between mailserver and mailgate. The real file lives in mailserver/;
# mailgate/mailconf.loc.sh is a symlink to it (same reasoning as wg-hub's
# wgnet.loc.sh: two copies of a validator drift).
#
# Kept NON-EXECUTABLE on purpose: yamc treats executable files in a module
# directory as subcommands.
#
# Each module has its own site config:
#   yamc.local/mailserver/mail.conf + aliases     the mail store   (mc_load_store)
#   yamc.local/mailgate/mailgate.conf             the gateway      (mc_load_gate)
# and both read the tunnel from yamc.local/wgnet/<MAIL_WGNET>.conf/.peers.
#
# A module reads the OTHER module's folder only for hand-offs and
# cross-checks (the cert-pull key; the gateway's public IP for SPF; that both
# agree on MAIL_HOSTNAME), never for its own settings. If the other folder is
# absent the module still works and says what it could not check.
#
# Resolution happens here because yamc.local exists only on this machine; the
# remote scripts get resolved values through $MOD_TMP/env and staged files.

mc_trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

mc_err() { echo "ERROR: $*"; }

# Read one variable from a config file without polluting this shell.
mc_peek() {   # mc_peek FILE VAR
  # shellcheck disable=SC1090
  ( . "$1" >/dev/null 2>&1; eval "printf '%s' \"\${$2:-}\"" )
}

# ---------------------------------------------------------------------------
# mc_find_dir MODULE FILE [OVERRIDE] - locate yamc.local/<MODULE>/ holding FILE
#   1. OVERRIDE (from -e mailconf_dir= / -e mailgate_dir=)
#   2. $RES_DIR, when it holds FILE (this module's own resource dir)
#   3. the <MODULE> sibling of $RES_BASE / $RES_DIR
#   4. $MOD_DIR/../../yamc.local/<MODULE>
# ---------------------------------------------------------------------------
mc_find_dir() {
  local mod="$1" file="$2" over="${3:-}" d
  if [ -n "$over" ]; then echo "$over"; return 0; fi
  if [ -n "${RES_DIR:-}" ] && [ -f "$RES_DIR/$file" ] \
     && [ "$(basename "$RES_DIR")" = "$mod" ]; then
    echo "$RES_DIR"; return 0
  fi
  for d in "${RES_BASE:-}" "${RES_DIR:-}"; do
    [ -n "$d" ] || continue
    d="$(dirname "$d")/$mod"
    [ -f "$d/$file" ] && { echo "$d"; return 0; }
  done
  d="$(cd "$MOD_DIR/../.." 2>/dev/null && pwd)/yamc.local/$mod"
  [ -f "$d/$file" ] && { echo "$d"; return 0; }
  return 1
}

# ---------------------------------------------------------------------------
# mc_wgnet CONF_DIR - load the tunnel network named by MAIL_WGNET.
# Sets MC_WGDIR, WG_IFACE, WG_SUBNET, WG_HUB_ADDR, WG_HUB_PORTS.
# ---------------------------------------------------------------------------
mc_wgnet() {
  local wgconf p
  MC_WGDIR="$(dirname "$1")/wgnet"
  wgconf="$MC_WGDIR/$MAIL_WGNET.conf"
  [ -f "$wgconf" ] || { mc_err "no tunnel network config: $wgconf"; return 1; }
  WG_IFACE=$(mc_peek "$wgconf" WG_IFACE)
  WG_SUBNET=$(mc_peek "$wgconf" WG_SUBNET)
  WG_HUB_ADDR=$(mc_peek "$wgconf" WG_HUB_ADDR)
  WG_HUB_PORTS=$(mc_peek "$wgconf" WG_HUB_PORTS)
  [ -n "$WG_IFACE" ] && [ -n "$WG_HUB_ADDR" ] && [ -n "$WG_SUBNET" ] || {
    mc_err "$wgconf lacks WG_IFACE, WG_SUBNET or WG_HUB_ADDR"; return 1; }

  # The hub must let the gateway reach exactly the mail ports. Missing ports
  # mean mail silently cannot arrive; no allowlist means the gateway reaches
  # every service on the store. Both are configuration errors.
  if [ -z "$WG_HUB_PORTS" ]; then
    mc_err "$wgconf has no WG_HUB_PORTS - the gateway could reach every service on the store."
    echo "       Set WG_HUB_PORTS=\"tcp:10025 tcp:10587 tcp:10993\" and re-run wg-hub."
    return 1
  fi
  for p in 10025 10587 10993; do
    case " $WG_HUB_PORTS " in *" tcp:$p "*) ;; *)
      mc_err "WG_HUB_PORTS in $wgconf lacks tcp:$p (needed by the mail path)"; return 1 ;;
    esac
  done
  return 0
}

# mc_peer_addr NAME - the tunnel address of peer NAME in <MAIL_WGNET>.peers
mc_peer_addr() {
  local peers="$MC_WGDIR/$MAIL_WGNET.peers" n a
  [ -f "$peers" ] || return 1
  while IFS='|' read -r n a _; do
    n=$(mc_trim "$n"); a=$(mc_trim "$a")
    case "$n" in ""|\#*) continue ;; esac
    [ "$n" = "$1" ] && { echo "$a"; return 0; }
  done < "$peers"
  return 1
}

mc_num() {   # mc_num VAR... - each must be a whole number
  local v
  for v in "$@"; do
    [[ "${!v}" =~ ^[0-9]+$ ]] || { mc_err "$v must be a number"; return 1; }
  done
}

# ---------------------------------------------------------------------------
# mc_load_store - yamc.local/mailserver/mail.conf, the tunnel, and (if
# present) the gateway facts the store's DNS report needs.
# Sets MS_DIR, the mail.conf variables, the mc_wgnet variables, and
# GATE_PUBLIC_IP / OUTBOUND / RELAY_HOST / RELAY_DOMAINS from mailgate.conf
# (empty when there is no gateway config).
# ---------------------------------------------------------------------------
mc_load_store() {
  local v missing="" bad=0 a

  if ! MS_DIR="$(mc_find_dir mailserver mail.conf "${mailconf_dir:-}")"; then
    mc_err "cannot locate yamc.local/mailserver/mail.conf"
    echo "       Pass -e mailconf_dir=/path, or create it alongside your other"
    echo "       yamc.local resources."
    return 1
  fi
  echo "Mail store config from $MS_DIR/mail.conf"
  # shellcheck disable=SC1091
  source "$MS_DIR/mail.conf"

  for v in MAIL_HOSTNAME MAIL_WGNET GATE_TUNNEL_ADDR MAIL_DOMAINS POSTMASTER \
           LAN_NETWORKS DKIM_SELECTOR MESSAGE_SIZE_LIMIT SPAM_REJECT_SCORE; do
    [ -n "${!v:-}" ] || missing="$missing $v"
  done
  [ -z "$missing" ] || { mc_err "mail.conf is missing:$missing"; return 1; }

  [[ "$POSTMASTER" =~ ^[a-z0-9._-]+$ ]] || { mc_err "POSTMASTER '$POSTMASTER' is not a valid mailbox name"; return 1; }
  [[ "$DKIM_SELECTOR" =~ ^[a-z0-9-]+$ ]] || { mc_err "DKIM_SELECTOR '$DKIM_SELECTOR' is not valid"; return 1; }
  mc_num MESSAGE_SIZE_LIMIT SPAM_REJECT_SCORE || return 1
  for v in $MAIL_DOMAINS; do
    [[ "$v" =~ ^[a-z0-9.-]+\.[a-z]+$ ]] || { mc_err "MAIL_DOMAINS entry '$v' is not a domain"; bad=1; }
  done
  [ "$bad" -eq 0 ] || return 1

  mc_wgnet "$MS_DIR" || return 1

  # The tunnel subnet must never be trusted as a LAN: if PROXY handling broke,
  # every internet client would appear to come from it.
  case " $LAN_NETWORKS " in *" ${WG_SUBNET%.*}."*)
    mc_err "LAN_NETWORKS must not include the tunnel subnet $WG_SUBNET"; return 1 ;; esac

  if ! mc_peer_addr_any "$GATE_TUNNEL_ADDR"; then
    echo "NOTE: $GATE_TUNNEL_ADDR is not in $MAIL_WGNET.peers yet - the gateway's"
    echo "      wg-peer run records it there."
  fi

  # ---- gateway facts, for SPF and cross-checks -------------------------------
  GATE_PUBLIC_IP="" OUTBOUND="" RELAY_HOST="" RELAY_DOMAINS=""
  local gdir
  if gdir="$(mc_find_dir mailgate mailgate.conf "${mailgate_dir:-}")"; then
    GATE_PUBLIC_IP=$(mc_peek "$gdir/mailgate.conf" GATE_PUBLIC_IP)
    OUTBOUND=$(mc_peek "$gdir/mailgate.conf" OUTBOUND)
    RELAY_HOST=$(mc_peek "$gdir/mailgate.conf" RELAY_HOST)
    RELAY_DOMAINS=$(mc_peek "$gdir/mailgate.conf" RELAY_DOMAINS)
    a=$(mc_peek "$gdir/mailgate.conf" MAIL_HOSTNAME)
    [ "$a" = "$MAIL_HOSTNAME" ] || {
      mc_err "MAIL_HOSTNAME differs: '$MAIL_HOSTNAME' here, '$a' in $gdir/mailgate.conf"; return 1; }
  else
    echo "NOTE: no yamc.local/mailgate/mailgate.conf - the DNS report will take the"
    echo "      gateway address from DNS and cannot know about a relay."
  fi
  return 0
}

# true if ADDR is any peer's address in <MAIL_WGNET>.peers
mc_peer_addr_any() {
  local peers="$MC_WGDIR/$MAIL_WGNET.peers" n a
  [ -f "$peers" ] || return 1
  while IFS='|' read -r n a _; do
    n=$(mc_trim "$n"); a=$(mc_trim "$a")
    case "$n" in ""|\#*) continue ;; esac
    [ "$a" = "$1" ] && return 0
  done < "$peers"
  return 1
}

# ---------------------------------------------------------------------------
# mc_load_gate - yamc.local/mailgate/mailgate.conf and the tunnel.
# Sets MG_DIR, the mailgate.conf variables, the mc_wgnet variables,
# GATE_TUNNEL_ADDR (this host's line in <MAIL_WGNET>.peers) and MS_DIR (the
# store's folder, for the cert-pull key; empty if absent).
# ---------------------------------------------------------------------------
mc_load_gate() {
  local v missing="" peer a

  if ! MG_DIR="$(mc_find_dir mailgate mailgate.conf "${mailgate_dir:-}")"; then
    mc_err "cannot locate yamc.local/mailgate/mailgate.conf"
    echo "       Pass -e mailgate_dir=/path, or create it alongside your other"
    echo "       yamc.local resources."
    return 1
  fi
  echo "Gateway config from $MG_DIR/mailgate.conf"
  # shellcheck disable=SC1091
  source "$MG_DIR/mailgate.conf"
  CERT_NAMES="${CERT_NAMES:-$MAIL_HOSTNAME}"

  for v in MAIL_HOSTNAME GATE_PUBLIC_IP GATE_HELO MAIL_WGNET OUTBOUND \
           MESSAGE_SIZE_LIMIT IMAP_CONN_PER_MIN; do
    [ -n "${!v:-}" ] || missing="$missing $v"
  done
  [ -z "$missing" ] || { mc_err "mailgate.conf is missing:$missing"; return 1; }

  # The first certificate name is the certbot lineage name and must be the
  # public hostname, or the store would pull a cert that does not cover it.
  [ "${CERT_NAMES%% *}" = "$MAIL_HOSTNAME" ] || {
    mc_err "CERT_NAMES must start with MAIL_HOSTNAME ($MAIL_HOSTNAME)"; return 1; }

  case "$OUTBOUND" in
    direct) ;;
    relay)  [ -n "${RELAY_HOST:-}" ] || { mc_err "OUTBOUND=relay needs RELAY_HOST"; return 1; } ;;
    *)      mc_err "OUTBOUND='$OUTBOUND' - use direct or relay"; return 1 ;;
  esac
  if [ -n "${RELAY_DOMAINS:-}" ] && [ -z "${RELAY_HOST:-}" ]; then
    mc_err "RELAY_DOMAINS is set but RELAY_HOST is empty"; return 1
  fi
  mc_num MESSAGE_SIZE_LIMIT IMAP_CONN_PER_MIN || return 1

  mc_wgnet "$MG_DIR" || return 1

  # This host's tunnel address: its own line in the peer table, which its
  # wg-peer run records. One source of truth for the address.
  peer="${GATE_PEER_NAME:-${tgt_host%%.*}}"
  if ! GATE_TUNNEL_ADDR="$(mc_peer_addr "$peer")"; then
    mc_err "'$peer' has no line in $MC_WGDIR/$MAIL_WGNET.peers."
    echo "       Set up the tunnel first; its run records the line:"
    echo "         yamc -h $tgt_host -e net=$MAIL_WGNET -e addr=<address> wg-peer"
    echo "       (or set GATE_PEER_NAME in mailgate.conf if the peer is named differently)"
    return 1
  fi

  # ---- the store's folder: cert-pull key and cross-checks ----------------------
  MS_DIR=""
  if MS_DIR="$(mc_find_dir mailserver mail.conf "${mailconf_dir:-}")"; then
    a=$(mc_peek "$MS_DIR/mail.conf" MAIL_HOSTNAME)
    [ "$a" = "$MAIL_HOSTNAME" ] || {
      mc_err "MAIL_HOSTNAME differs: '$MAIL_HOSTNAME' here, '$a' in $MS_DIR/mail.conf"; return 1; }
    a=$(mc_peek "$MS_DIR/mail.conf" GATE_TUNNEL_ADDR)
    [ "$a" = "$GATE_TUNNEL_ADDR" ] || {
      mc_err "$MS_DIR/mail.conf sends outbound mail to GATE_TUNNEL_ADDR=$a,"
      echo "       but this gateway is $GATE_TUNNEL_ADDR in $MAIL_WGNET.peers"; return 1; }
    a=$(mc_peek "$MS_DIR/mail.conf" MESSAGE_SIZE_LIMIT)
    if [[ "$a" =~ ^[0-9]+$ ]] && [ "$a" -gt "$MESSAGE_SIZE_LIMIT" ]; then
      echo "NOTE: the store accepts $a-byte messages but this gateway only $MESSAGE_SIZE_LIMIT;"
      echo "      large outbound mail would bounce here."
    fi
  else
    MS_DIR=""
    echo "NOTE: no yamc.local/mailserver/mail.conf - cannot cross-check the store"
    echo "      or find its cert-pull key."
  fi
  return 0
}

# ---------------------------------------------------------------------------
# mc_aliases OUTFILE - validate MS_DIR/aliases and write the full virtual
# table, including the automatic postmaster/abuse/root entries.
# Sets MC_MAILBOXES (space separated, unique).
# ---------------------------------------------------------------------------
mc_aliases() {
  local out="$1" src="$MS_DIR/aliases" addr box rest dom bad=0 d r
  local -A seen=() boxes=()
  : > "$out"
  [ -f "$src" ] || { mc_err "no aliases file: $src"; return 1; }

  while read -r addr box rest; do
    [ -z "$addr" ] && continue
    case "$addr" in \#*) continue ;; esac
    if [ -z "$box" ] || [ -n "$rest" ]; then
      mc_err "aliases: '$addr $box $rest' - expected exactly: address mailbox"; bad=1; continue
    fi
    addr="${addr,,}"
    dom="${addr#*@}"
    if [ "$dom" = "$addr" ]; then
      mc_err "aliases: '$addr' needs a domain"; bad=1; continue
    fi
    case " $MAIL_DOMAINS " in *" $dom "*) ;; *)
      mc_err "aliases: '$addr' - domain $dom is not in MAIL_DOMAINS"; bad=1; continue ;;
    esac
    if ! [[ "$box" =~ ^[a-z0-9._-]+$ ]]; then
      mc_err "aliases: mailbox '$box' must be a local mailbox name (no outside forwarding)"; bad=1; continue
    fi
    [ -n "${seen[$addr]:-}" ] && { mc_err "aliases: '$addr' listed twice"; bad=1; continue; }
    seen[$addr]=1; boxes[$box]=1
    printf '%-40s %s\n' "$addr" "$box" >> "$out"
  done < "$src"
  [ "$bad" -eq 0 ] || { echo "ERROR: aliases has errors; refusing to continue."; return 1; }

  # Role addresses every domain must have (RFC 2142), unless set explicitly.
  for d in $MAIL_DOMAINS; do
    for r in postmaster abuse; do
      [ -n "${seen[$r@$d]:-}" ] || printf '%-40s %s\n' "$r@$d" "$POSTMASTER" >> "$out"
    done
  done
  # Bare local names (root@uranus, cron mail) - only match local domains.
  for r in root postmaster abuse; do printf '%-40s %s\n' "$r" "$POSTMASTER" >> "$out"; done
  boxes[$POSTMASTER]=1

  MC_MAILBOXES="${!boxes[*]}"
  echo "Addresses: ${#seen[@]} listed, mailboxes: $MC_MAILBOXES"
  return 0
}

# ---------------------------------------------------------------------------
# mc_export VAR... - hand resolved values to the remote script.
# Values are written quoted; yamc turns each line into 'export LINE;'.
# ---------------------------------------------------------------------------
mc_export() {
  local v
  for v in "$@"; do
    printf '%s="%s"\n' "$v" "${!v:-}"
  done >> "$MOD_TMP/env"
}

MC_STORE_VARS="MAIL_HOSTNAME GATE_TUNNEL_ADDR MAIL_DOMAINS LAN_NETWORKS \
DKIM_SELECTOR MESSAGE_SIZE_LIMIT SPAM_REJECT_SCORE WG_IFACE WG_HUB_ADDR \
GATE_PUBLIC_IP OUTBOUND RELAY_HOST RELAY_DOMAINS"
MC_GATE_VARS="MAIL_HOSTNAME CERT_NAMES CERT_EMAIL GATE_PUBLIC_IP GATE_HELO \
GATE_TUNNEL_ADDR OUTBOUND RELAY_HOST RELAY_DOMAINS MESSAGE_SIZE_LIMIT \
IMAP_CONN_PER_MIN WG_IFACE WG_HUB_ADDR"
