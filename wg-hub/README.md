# wg-hub Module

Sets up and maintains the **hub side** of a WireGuard network: the interface,
the peer table, and the LAN access policy.

Generic on purpose. Nothing here is specific to backups — the same module is
intended to serve a mobile/road-warrior network later, with the same code and a
different config.

> **Why the backup network is configured the way it is** — threat model,
> isolation layers, why `LAN_POLICY=none` — lives in
> [`backup-box/README.md`](../backup-box/README.md). This README covers
> mechanism only.

---

## Status

**Scripts not yet written.** This directory currently holds documentation only,
which is why it has no `setup` script (contrary to `AGENTS.md`). The design was
reviewed first, deliberately.

---

## Usage

```sh
yamc -h uranus -e net=bkup wg-hub                 # report what it would do
yamc -h uranus -e net=bkup -e yes=1 wg-hub        # do it
yamc -h uranus -e net=bkup wg-hub status          # interface, peers, handshakes
yamc wg-hub help                                  # usage + the manual equivalent
```

Runs as root (`yamc.env` sets `YAMC_USER=root`).

`-e net=NAME` selects which network to operate on and is **required** — there
is no default, because the wrong default here means applying a backup network's
policy to a mobile one or vice versa.

### Confirmation

This module changes networking on a machine you reach *over* the network, so it
reports before it acts:

| Situation | Behaviour |
|---|---|
| `-e yes=1` given | Proceed without asking |
| Terminal available | Print the plan, then prompt |
| No terminal (`yamcity`) | Print the plan, refuse, exit non-zero |

The plan is printed by the same code path that performs the work, so a report
cannot drift out of sync with the action.

---

## Configuration

Site data lives in `yamc.local/wgnet/`, **not** in a per-module resource
directory, because `wg-hub` and `wg-peer` must read the *same* peer table and it
needs a single authoritative home. This follows the shared-`cluster.conf`
precedent used by `accounts` and `pwsync`.

```
yamc.local/wgnet/
├── bkup.conf      # interface, port, subnet, endpoint, policy
├── bkup.peers     # the peer table
├── mob.conf       # later, when wg-easy is retired
└── mob.peers
```

Resolution order for that directory:

1. `-e wgnet_dir=/path` — explicit override
2. `$RES_DIR/../wgnet` — when yamc resolved a resource directory
3. `$MOD_DIR/../../yamc.local/wgnet` — yamc's own sibling convention

Hard error if `<net>.conf` is not found. It does not guess.

### `<net>.conf`

```sh
WG_IFACE="bk0"                  # NOT wg* — see "Interface naming" below
WG_PORT="51822"
WG_SUBNET="10.9.9.0/24"
WG_HUB_ADDR="10.9.9.1"
WG_HUB_PUBKEY="<filled in after bootstrap>"
WG_ENDPOINT="bateman.cc:51822"  # what peers dial

# LAN access policy. REQUIRED — no default, no fallback.
#   none          no forwarding at all; the tunnel terminates on the hub
#   route:<host>  forward to exactly one LAN host, established/related only
#   full          full LAN access
LAN_POLICY="none"
```

**`LAN_POLICY` is fail-closed.** An unset or unrecognised value is a hard
error, never a permissive default. Because this module is shared across
networks, a feature added for a mobile network could otherwise silently loosen
a backup network. This is the most security-relevant line in the module.

### `<net>.peers`

Pipe-delimited, same convention as `nfs-client/mounts.conf`:

```
# name | tunnel addr | public key | notes
orion  | 10.9.9.2    | <pubkey>   | first box
```

Peer private keys are generated on each peer by `wg-peer` and never leave it.
Only public keys appear here.

**The module validates and refuses on duplicate addresses.** WireGuard does not
error on overlapping `AllowedIPs` — it silently reassigns the address to
whichever peer was configured last, which would send one box's traffic to
another. This check is not optional politeness.

---

## Interface Naming

**Do not name the interface `wg*`.** WireGuard PostUp examples very commonly
use the `wg+` wildcard:

```
iptables -A FORWARD -i wg+ -j ACCEPT
```

`wg+` matches any interface whose name begins with `wg`. On a host that already
runs another WireGuard instance — wg-easy, for example — such a rule would
apply to a new `wgfoo` interface too, granting forwarding that was never
intended and that no rule in this module wrote.

Hence `bk0`, not `wgbk`. The name looks odd for exactly this reason.

---

## What It Does

**Bootstrap** (only when the interface does not yet exist):

1. Install `wireguard-tools`
2. Generate the hub keypair with `umask 077`, into `/etc/wireguard/<iface>.key`
   and `.pub`
3. Write `/etc/wireguard/<iface>.conf` — `Address`, `ListenPort`, `PrivateKey`
4. `systemctl enable --now wg-quick@<iface>`
5. Print the public key for pasting into `<net>.conf` as `WG_HUB_PUBKEY`

**Peer sync** (every run):

1. Read and validate `<net>.peers` — duplicate addresses are fatal
2. Render peer stanzas into the interface config, each with `AllowedIPs` pinned
   to a single `/32`
3. Apply to the **live** interface:

   ```sh
   wg syncconf <iface> <(wg-quick strip <iface>)
   ```

`wg syncconf` updates peers without tearing the interface down, and *removes*
peers absent from the config — which is exactly revocation. Adding or revoking
one peer never disturbs the others.

**Policy** (every run), from `LAN_POLICY`:

| Value | Effect |
|---|---|
| `none` | No forwarding rules at all for this interface |
| `route:<host>` | Forward to that one host; `established,related` only in reverse |
| `full` | Forward to the LAN |

Rules go in a **named table of their own** so they are auditable and cannot be
confused with Docker's chains or another WireGuard instance's.

---

## Manual Equivalent

`wg-hub help` prints this, so the automated path is never the only way to
understand what happened.

```sh
# --- bootstrap, once ---
apt-get install wireguard-tools
umask 077
wg genkey | tee /etc/wireguard/bk0.key | wg pubkey > /etc/wireguard/bk0.pub

cat > /etc/wireguard/bk0.conf <<'EOF'
[Interface]
Address    = 10.9.9.1/24
ListenPort = 51822
PrivateKey = <contents of bk0.key>
# LAN_POLICY=none: no PostUp, no forwarding, no nftables rules
EOF

systemctl enable --now wg-quick@bk0

# --- add or revoke a peer ---
# edit the [Peer] stanzas in /etc/wireguard/bk0.conf, then:
wg syncconf bk0 <(wg-quick strip bk0)

# --- inspect ---
wg show bk0
```

A peer stanza:

```
[Peer]
# orion
PublicKey  = <peer public key>
AllowedIPs = 10.9.9.2/32
```

`AllowedIPs` **must** be a single `/32`. WireGuard drops packets whose source
address is not in a peer's `AllowedIPs` before decryption, so this line is what
makes address spoofing structurally impossible rather than merely filtered.

---

## Before First Use

Audit the host — see
[Pre-Build Audit](../backup-box/README.md#pre-build-audit-of-uranus). On a host
already running another WireGuard instance, check for `wg+` wildcard rules,
confirm `net.ipv4.ip_forward` is already on (so isolation cannot rest on it
being off), and confirm the new subnet does not overlap an existing one.

---

## See Also

- [`wg-peer`](../wg-peer/README.md) — the spoke side
- [`backup-box`](../backup-box/README.md) — the system design and threat model
