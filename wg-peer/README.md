# wg-peer Module

Sets up the **spoke side** of a WireGuard network: a machine that dials out to a
hub, keeps the tunnel alive through NAT, and re-resolves the hub's address when
it changes.

Generic on purpose. Nothing here is specific to backups.

> **Why the backup network is configured the way it is** — threat model,
> isolation layers, why the peer gets a `/32` and nothing else — lives in
> [`BACKUP.md`](../BACKUP.md). This README covers
> mechanism only.

---

## Status

Built and in service on `orion`, dialling the `bkup` hub on `uranus`.

---

## Usage

```sh
yamc -h orion -e net=bkup wg-peer                 # report what it would do
yamc -h orion -e net=bkup -e yes=1 wg-peer        # do it
yamc -h orion -e net=bkup wg-peer status          # interface, handshake age
yamc wg-peer help
```

Runs as root (`yamc.env` sets `YAMC_USER=root`).

`-e net=NAME` is **required** — no default. `-e addr=10.9.9.2` assigns this
peer's tunnel address; without it the module reports the addresses already in
use and refuses to pick one.

Confirmation follows the same model as `wg-hub`: `-e yes=1`, or a prompt when a
terminal is available, or refusal when there is none.

---

## Configuration

Reads the **same** `yamc.local/wgnet/<net>.conf` as `wg-hub` — one
authoritative definition of the network, read from both ends. Resolution order
for that directory:

1. `-e wgnet_dir=/path`
2. `$RES_DIR/../wgnet`
3. `$MOD_DIR/../../yamc.local/wgnet`

From it this module uses `WG_IFACE`, `WG_HUB_ADDR`, `WG_HUB_PUBKEY`, and
`WG_ENDPOINT`. It does **not** read `LAN_POLICY` — policy is enforced at the
hub, and a peer that could opt itself into more access would defeat the point.

---

## What It Does

1. Install `wireguard-tools`.
2. **Generate the keypair on this machine**, `umask 077`, into
   `/etc/wireguard/<iface>.key`. The private key never leaves the box and is
   never transmitted anywhere — not to yamc, not into `yamc.local`.
3. Write `/etc/wireguard/<iface>.conf`:

   ```
   [Interface]
   Address    = 10.9.9.2/32
   PrivateKey = <this box's key>

   [Peer]
   PublicKey           = <hub public key>
   Endpoint            = bateman.cc:51822
   AllowedIPs          = 10.9.9.1/32
   PersistentKeepalive = 25
   ```

4. `systemctl enable --now wg-quick@<iface>`
5. Install the **endpoint re-resolve timer** (see below).
6. Print a ready-to-paste line for `yamc.local/wgnet/<net>.peers`:

   ```
   orion  | 10.9.9.2  | <this box's public key>  | 
   ```

   The module does **not** write to `yamc.local/` itself (`AGENTS.md`), so
   pasting that line is an explicit manual step by design.

### The two `/32`s

`Address` is a `/32` and `AllowedIPs` is a `/32` — the hub's address only. Not
the tunnel subnet, not the LAN, not `0.0.0.0/0`.

The consequence is that this machine's routing table contains **no route toward
the hub's LAN at all**. Combined with the matching `/32` in the hub's peer
stanza, isolation is structural on both ends rather than resting on a firewall
rule either side could get wrong.

`AllowedIPs = 0.0.0.0/0` would additionally route all of this machine's traffic
through the tunnel, which is correct for a laptop on hotel wifi and wrong for
everything this module is for.

---

## Endpoint Re-Resolution

`wg-quick` resolves the endpoint hostname **once**, when the interface comes
up. When a dynamic-DNS name changes address, the tunnel stays down until
something restarts the interface.

For an unattended box at a remote site this is a leading cause of the failure
that matters most: a tunnel that is quietly down, on a machine whose whole job
is to be reachable later.

So the module installs a periodic re-resolve. `wireguard-tools` ships a
`reresolve-dns` example for exactly this; **verify its path on the target
distribution at build time** rather than assuming.

The equivalent by hand:

```sh
wg set bk0 peer <hub pubkey> endpoint bateman.cc:51822
```

`PersistentKeepalive = 25` handles the other half of the problem — it keeps the
NAT mapping at the remote site open so the hub can reach back, and lets the hub
learn this peer's current source address.

---

## Proving the Isolation

```sh
yamc -h orion -e net=bkup wg-peer probe
```

The entire design rests on "a rooted box cannot reach past the hub." That is an
assertion about someone else's firewall, so it gets **tested**, not inferred.

Targets come from `<net>.conf` and exercise two different paths:

| Variable | Target | Tests |
|---|---|---|
| `WG_LAN_PROBE` | a LAN host beyond the hub | the hub's **forward** chain |
| `WG_HUB_LAN_ADDR` | the hub's own LAN address | the hub's **input** chain |

A configuration can pass one and fail the other — that is exactly what happened
here, and only the second caught it.

### Why the probe is active

Simply *trying* to reach a LAN address proves nothing. Routing sends only the
hub's `/32` through the tunnel, so such an attempt never touches the tunnel at
all: it succeeds on your own LAN for the wrong reason, and fails at a remote
site for the wrong reason. The second is the dangerous one — silent false
reassurance.

So the probe does what a rooted box would actually do: adds a `/32` route via
the tunnel, widens its own `AllowedIPs`, attempts the connection, and puts both
back. The revert is trapped, so it happens on error or interrupt too.

### Run it on the bench

A `/32` route via the tunnel outranks the connected LAN route, so the test is
valid while the box is still on your own network — and that is when a failure
is cheapest to fix. Expected:

```
  forward  path  192.168.2.154    blocked (correct)
  input    path  192.168.2.27     blocked (correct)
PASS - this box cannot reach past the hub on any tested path.
```

**Anything other than PASS and the box does not ship.**

---

## The Key Handoff

```sh
yamc -h orion -e net=bkup wg-peer key             # print the peer line
yamc -h orion -e net=bkup -e save=1 wg-peer key   # append it to <net>.peers
```

The private key is generated on the box and never leaves it. Only the public
half is read, and it is written to `yamc.local` **only** with `-e save=1` —
that flag is the consent `AGENTS.md` requires.

`-e force=1` replaces an existing line whose key has changed, which normally
means the box was rebuilt. Without it, a mismatch is refused rather than
silently overwritten.

After saving, sync it onto the hub:

```sh
yamc -h uranus -e net=bkup -e yes=1 wg-hub
```

---

## Manual Equivalent

`wg-peer help` prints this.

```sh
apt-get install wireguard-tools
umask 077
wg genkey | tee /etc/wireguard/bk0.key | wg pubkey > /etc/wireguard/bk0.pub

cat > /etc/wireguard/bk0.conf <<'EOF'
[Interface]
Address    = 10.9.9.2/32
PrivateKey = <contents of bk0.key>

[Peer]
PublicKey           = <hub public key>
Endpoint            = bateman.cc:51822
AllowedIPs          = 10.9.9.1/32
PersistentKeepalive = 25
EOF

systemctl enable --now wg-quick@bk0

# hand the public key to the hub operator:
cat /etc/wireguard/bk0.pub
```

Check it:

```sh
wg show bk0                    # 'latest handshake' should be under 2 minutes
ping -c1 10.9.9.1              # the hub, and nothing beyond it
```

---

## Interface Naming

Do not name the interface `wg*`. See
[wg-hub: Interface Naming](../wg-hub/README.md#interface-naming) — the `wg+`
wildcard in common firewall snippets is the reason, and it applies to both ends.

---

## See Also

- [`wg-hub`](../wg-hub/README.md) — the hub side
- [`backup-box`](../backup-box/README.md) — the system design and threat model
