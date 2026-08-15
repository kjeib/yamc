# wg-peer Module

Sets up the **spoke side** of a WireGuard network: a machine that dials out to a
hub, keeps the tunnel alive through NAT, and re-resolves the hub's address when
it changes.

Generic on purpose. Nothing here is specific to backups.

> **Why the backup network is configured the way it is** — threat model,
> isolation layers, why the peer gets a `/32` and nothing else — lives in
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
yamc -h orion wg-peer -e net=bkup                 # report what it would do
yamc -h orion wg-peer -e net=bkup -e yes=1        # do it
yamc -h orion wg-peer -e net=bkup status          # interface, handshake age
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
