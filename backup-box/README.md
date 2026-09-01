# backup-box Module

Provisions a remote, offsite backup box that lives on someone else's network
and holds **only ciphertext**.

This README is the design document for the whole backup system. The tunnel it
rides on is built by the generic `wg-hub` and `wg-peer` modules; those have
ordinary reference READMEs and link back here for *why* the backup network is
configured the way it is.

---

## Why This Exists (read this first if returning cold)

**The situation.** Offsite backups have historically been rsync to a remote
volume — one *mirror* volume and one *cumulative* volume. That works, and has
worked for years, but the remote copy is **plaintext**. Anyone with physical
access to that box can read everything: home directories, mail, the lot.

The new boxes go to friends and allies, but there is no guarantee they stay in
friendly hands. A house is sold, a business closes, a box gets scavenged. The
whole point of this project is that **it should not matter**.

**The design in one sentence.** The source host encrypts before anything
leaves the LAN; the remote box stores opaque blobs it has no key for and
cannot initiate a single connection back toward the LAN.

**What this buys, concretely:**

- A stolen box reveals nothing. Not filenames, not directory structure, not
  file sizes beyond coarse chunk boundaries.
- A *rooted, running* box still reveals nothing, because the repository
  password never exists on it.
- A rooted box cannot reach into the LAN, because it has no route there and
  the hub drops every connection it originates.
- A malicious box cannot destroy backup history, because the repository is
  served append-only.

**What it costs.** The remote copy stops being browsable *on the remote box*.
You browse it from `uranus` instead, over the tunnel, through a FUSE mount
(see [Restore Runbook](#restore-runbook)). Functionally the same as walking the
cumulative volume today; mechanically different, and the difference matters on
the day you need it. Practice it before you need it.

---

## Current State (2026-08-18)

| Thing | Status |
|---|---|
| Design agreed | **Done** — this document |
| Router forwards UDP 51822 → uranus | **Done** |
| Pre-build audit of uranus | **Done** — no `wg+` rules; wg-easy is `10.8.0.0/24`, no overlap; `ip_forward=1` as expected |
| `wg-hub` / `wg-peer` modules | **Done** — built, and `wg-hub` run against uranus |
| `bk0` hub on uranus | **Up** — `10.9.9.1/24`, port 51822, input + forward chains active, 0 peers |
| `yamc.local/wgnet/bkup.{conf,peers}` | **Done** — hub public key recorded |
| `backup-box storage` on orion | **Done** — 2.6 TB at `/srv/backup` |
| `wg-peer` on orion | **NOT DONE** — orion has no tunnel; it is LAN-only |
| `backup-box setup` (rest-server) | **NOT DONE** — refuses until the tunnel is up |
| Isolation proven from the peer side | **NOT DONE** — mandatory, step 9 |
| Reboot test on orion | **NOT DONE** — mandatory before shipping |
| Tunnel test from a foreign network | **NOT DONE** — mandatory before shipping |
| `backup` (source-side client) | **DEFERRED** — see [Why the client is deferred](#why-the-client-is-deferred) |
| Existing rsync mirror/cumulative | **Still running, do not decommission** |

**2026-08-18 — a hole that was open and is now closed.** The hub policy had only
a `forward` chain. Traffic from the tunnel aimed at one of the hub's *own*
addresses traverses `INPUT`, never `FORWARD`, and neither side's `AllowedIPs`
constrains the destination — so a rooted peer could have reached every service
on `uranus:192.168.2.27` while the forward policy looked correct. `wg-hub` now
writes an input chain too, and `wg-peer status` probes both paths. This is why
step 9 exists: the design has to be *tested* from the peer, not inferred from
the hub's config.

---

## Pre-Build Audit of uranus

**Completed 2026-08-18 — results in Current State above.** Kept for the next
host that hosts a network. Two of these can silently defeat the isolation.

**1. Wildcard forward rules.** WireGuard PostUp examples very commonly use the
`wg+` interface wildcard:

```
iptables -A FORWARD -i wg+ -j ACCEPT
```

`wg+` matches **any** interface whose name starts with `wg`. If wg-easy has
installed such a rule on the host, it would forward backup-tunnel traffic
straight into the LAN — punching exactly the hole this design exists to
prevent, before we write a single rule of our own.

```sh
iptables-save | grep -E 'wg\+|FORWARD'
nft list ruleset | less
```

This is why the backup interface is named **`bk0`, not `wgbk`** — so no
wildcard rule we didn't write can ever match it. Cheap insurance, and the
reason the name looks odd.

**2. Forwarding is already on.** `net.ipv4.ip_forward` is almost certainly `1`,
because wg-easy needs it. So isolation **cannot** rest on forwarding being
globally disabled — it must come from explicit rules verified to take effect.

```sh
sysctl net.ipv4.ip_forward
```

**3. Subnet overlap.** Confirm wg-easy's subnet (commonly `10.8.0.0/24`) does
not overlap the `10.9.9.0/24` planned here. An overlap produces routing
behavior that looks intermittent rather than broken — the worst kind.

**4. Docker's chains.** Docker inserts its own chains and rules. Our rules must
live in a clearly named separate chain and be **verified to actually take
effect** alongside them. This only bites in `route:` policy mode, which is
another reason to start with `LAN_POLICY="none"`.

---

## Topology

```
        LAN 192.168.2.0/24                    hostile / friendly-but-unknown
   ┌──────────────────────────┐                  ┌──────────────────────┐
   │                          │                  │                      │
   │  uranus  192.168.2.27    │                  │   orion              │
   │  ┌────────────────────┐  │                  │                      │
   │  │ wg-easy (docker)   │  │  road warriors   │   bk0  10.9.9.2      │
   │  │ wg0 :51820         │◄─┼──── phone,       │   ▲                  │
   │  │ LAN access: FULL   │  │     laptop       │   │                  │
   │  └────────────────────┘  │                  │   │ dials out,       │
   │      (left alone)        │                  │   │ keepalive        │
   │  ┌────────────────────┐  │                  │   │                  │
   │  │ bk0 (host) :51822  │◄─┼──────────────────┼───┘                  │
   │  │ 10.9.9.1           │  │  bateman.cc      │                      │
   │  │ LAN access: NONE   │  │                  │   rest-server        │
   │  └────────────────────┘  │                  │   bound 10.9.9.2:8000│
   │         │                │                  │   --append-only      │
   │  restic client ──────────┼──── ciphertext ──┼──►  /srv/backup      │
   │  (holds the password)    │       only       │   (no key, ever)     │
   └──────────────────────────┘                  └──────────────────────┘
```

**Two WireGuard instances, deliberately.** `wg-easy` keeps doing road-warrior
duty with LAN access, untouched. `bk0` is a separate, plain `wg-quick` instance
on the host with a different port, a different subnet, and no LAN routing at
all. See [Rejected Alternatives](#rejected-alternatives) for why the backup
boxes are not peers on `wg0`, and why wg-easy is not being replaced yet.

---

## Threat Model

Three different adversaries. They do not have the same answer.

| Adversary | What they get | What stops them |
|---|---|---|
| Box stolen, powered off | Opaque restic pack files | restic encryption — password never on the box |
| Box rooted, running | Same ciphertext, plus revocable credentials | restic encryption + isolation layers below |
| Box rooted, destructive | Ability to try to delete history | `--append-only` + the parallel rsync copy |

**Explicitly out of scope.** Physical tampering that backdoors the box is not
prevented. It does not need to be: no plaintext ever transits that machine, so
a fully backdoored box still learns nothing about file contents.

**The one residual risk, stated plainly.** A rooted `orion` controls a
rest-server that the source *voluntarily connects to*. The remaining attack
path is not network routing — it is the restic client on the source parsing
hostile responses. Narrow, but non-zero. Mitigations: keep restic current, and
do not run the client as root if the data can be read without it.

---

## Why There Is No Full-Disk Encryption

Deliberate decision, reached after considering it. Recorded here so it is not
relitigated.

**What LUKS would protect is already protected.** The repository on that disk
is AES-256 with a Poly1305 MAC, and the password never exists on the box.
Pulling the drive and reading it elsewhere yields opaque pack files under
`data/00/`, `data/01/` — no filenames, no structure, no sizes worth having.

**What is on the box and not inside the repository:**

- the box's WireGuard private key
- SSH host keys and `authorized_keys`
- the rest-server htpasswd hashes
- system logs (backup timing, source hostname — metadata only)

Every one of those is **revocable**, and none exposes a byte of data. The
WireGuard key in particular buys an attacker a tunnel to a dead-end `/32` with
no forwarding.

**Against that:** a box in someone else's house that cannot come back from a
power outage without a human typing a passphrase. That is the exact failure
mode that produces a silently dead backup and an awkward phone call. The cost
exceeds the benefit.

**What replaces it:**

1. **The box is disposable.** No user data, no keys reused from any other
   machine, no unique secrets. Assume it will be compromised; nothing on it
   may be of value except revocable credentials.
2. **Revocation is a documented one-command operation** — see
   [Revocation Runbook](#revocation-runbook). Worth more than FDE.
3. **`--append-only` matters more, not less.** With confidentiality handled by
   restic, a compromised box's only remaining power is destructive.

Note that the keyfile-on-boot-partition variant is *worse* than either option:
it stops only the attacker restic already stops, while adding moving parts.

---

## Isolation: Why the Box Cannot Reach the LAN

Five layers. The first two are structural; the rest are defence in depth.

**1. `AllowedIPs` on the hub, pinned to a `/32`.**
WireGuard drops packets whose source address is not in that peer's
`AllowedIPs` *before decryption*. `orion` cannot spoof a LAN address. This is
cryptographic routing, not a filter — the only way to break it is to write the
wrong value, which makes that single line the most important in the entire
configuration.

**2. `AllowedIPs` on the box, also a `/32`** — just the hub's tunnel address.
Not the LAN subnet, not `0.0.0.0/0`. `orion`'s own routing table then contains
no route toward the LAN at all. Independent structural block on the far side.

**3. Hub forward policy.** Governed by `LAN_POLICY` (below). With `none` —
where this starts — there is no forwarding for `bk0` at all. With `route:<host>`
it is established/related only, to exactly one host.

**4. Egress default-deny on the box.** Outbound permitted only to the tunnel
endpoint, DNS, NTP, and package mirrors. A rooted attacker removes this; it
stops accidental leakage and non-root compromise.

**5. Service binding.** `rest-server` binds `10.9.9.2:8000` and `sshd` binds
the tunnel address — neither is reachable from the friend's LAN at all.

**The structural reason this holds.** The source always initiates; the box
never needs to. So *"drop all new connections originating from the backup
tunnel"* is a policy with **zero exceptions** — there is no hole to poke for
legitimate traffic. Most VPN designs leak because they need bidirectional
initiation. This one does not.

> **Do not erode this.** A future convenience — "just let the box reach the
> internal package mirror" — reintroduces the class of hole this design exists
> to avoid.

---

## Modules

The tunnel machinery is **generic**. Nothing about a WireGuard hub or spoke is
backup-specific, so it does not carry a backup name.

| Module | Host | Job |
|---|---|---|
| `wg-hub` | `uranus` | Peer sync and forward policy for one WireGuard network |
| `wg-peer` | `orion` | Dial-out peer config, keepalive, endpoint re-resolve |
| `backup-box` | `orion` | Storage volume, rest-server, egress policy |
| `backup` | source | restic client, schedule, checks, restore wrappers — **deferred** |

`backup-box` is about storage and the repository service. It *uses* the tunnel;
it does not own it.

The same `wg-hub` will eventually serve a `mob` network when wg-easy is
retired — same code, different config, different policy. That is the point of
keeping it generic.

### Why the client is deferred

`sun` is very old. That likely means no systemd, possibly a FUSE version too
old for `restic mount`, and uncertain `sshfs`/`sftp-server` support for yamc
itself. None of that is worth fighting on a machine already scheduled for
replacement by `uranus`.

So the first build runs **entirely on `uranus` and `orion`**, with `uranus` as
both hub and source (`LAN_POLICY="none"`). `sun` keeps its existing rsync
mirror, untouched, throughout — which is the parallel-running safety the
migration wanted anyway.

When `uranus` takes over mail, the client module gets written and nothing about
the topology changes.

Bonus: restic is a single static Go binary, so when it *is* pointed at an old
host, it will almost certainly just run — no dependency archaeology.

### Planned subfunctions

| Command | Does |
|---|---|
| `wg-hub -e net=bkup` | Bootstrap the interface if absent, then sync peers and apply policy |
| `wg-hub -e net=bkup status` | Interface, peers, handshake ages |
| `wg-hub help` | Usage **and the exact manual equivalent** |
| `wg-peer -e net=bkup` | Peer config, keepalive, re-resolve timer; emits the peer line |
| `backup-box storage` | Report or create the backup LV and mount |
| `backup-box` | rest-server, repositories, credentials |
| `backup-box lockdown` | Egress policy and service binding — deliberate, last |
| `backup-box status` | Tunnel, service, disk usage, repositories |

Egress policy is **not** part of `setup`. It is the step that can lock you out,
so it is a separate, deliberate subcommand run last — see the
[Deployment Procedure](#deployment-procedure).

---

## Configuration Files

Site data lives in `yamc.local/wgnet/`, one directory per site rather than one
per module — because the peer table is needed by **both** `wg-hub` and
`wg-peer` and must have a single authoritative home. This follows the
`cluster.conf` precedent already used by `accounts` and `pwsync`.

```
yamc.local/wgnet/
├── bkup.conf      # interface, port, subnet, endpoint, policy
├── bkup.peers     # the peer table
├── mob.conf       # later, when wg-easy is retired
└── mob.peers
```

Both modules take `-e net=bkup`.

### `yamc.local/wgnet/bkup.conf`

```sh
# Backup network. Separate from wg-easy's wg0 in every respect.

WG_IFACE="bk0"                  # NOT wg* — must not match a `wg+` wildcard rule
WG_PORT="51822"                 # 51821 is the wg-easy UI; do not reuse
WG_SUBNET="10.9.9.0/24"         # verify no overlap with wg-easy
WG_HUB_ADDR="10.9.9.1"
WG_HUB_PUBKEY="<uranus bk0 public key>"
WG_ENDPOINT="bateman.cc:51822"  # what the boxes dial

# LAN access policy. REQUIRED — there is no default and no fallback.
# Both modules refuse to run if this is unset or unrecognised.
#
#   none          no forwarding at all; the tunnel terminates on the hub
#   route:<host>  forward to exactly one LAN host, established/related only
#   full          full LAN access (what the mob network will use)
#
LAN_POLICY="none"
```

**`LAN_POLICY` is fail-closed by design.** Because `wg-hub` is shared with the
mobile network later, a feature added for `mob` could otherwise misfire on
`bkup`. An unset or unrecognised value must be a hard error, never a
permissive default. This is the single most security-relevant line in the
module.

Moving the backup source off `uranus` later is one line: `LAN_POLICY="route:sun"`.
When `uranus` replaces `sun`, it stays `none` and we are done.

### `yamc.local/wgnet/bkup.peers`

Pipe-delimited, same convention as `nfs-client/mounts.conf`:

```
# name | tunnel addr | public key | notes
orion  | 10.9.9.2    | <pubkey>   | first box, location TBD
```

**Private keys are generated on each box and never leave it.** The public key
comes back for pasting — `wg-peer` prints a ready-to-paste line. The module
will *not* write to `yamc.local/` on its own (`AGENTS.md`), so this is an
explicit manual step by design.

### Multiple boxes

Many peers on one listening port is the normal WireGuard case — the hub
demultiplexes by **cryptographic identity, not source address**, and learns each
peer's endpoint from its most recent authenticated packet. wg-easy already does
this with your phone and laptop. Nothing special is needed.

What does matter is that the peer table is correct:

- **Unique keypair per box**, generated on the box.
- **Unique tunnel address per box**, and therefore unique `AllowedIPs`.
- `wg-hub` must **validate the table for duplicate addresses and refuse**.
  WireGuard does not error on overlapping `AllowedIPs`; it silently reassigns
  the address to whichever peer was configured last.

Boxes cannot see each other — each has `AllowedIPs` = the hub `/32` only. That
is intentional; there is no box-to-box replication in this design.

---

## Hub Setup

`wg-hub` automates the whole thing — bootstrap and peer management — but it
touches networking on your main server, so **it reports before it acts**:

```sh
yamc -h uranus -e net=bkup wg-hub            # report: shows exactly what it would do
yamc -h uranus -e net=bkup -e yes=1 wg-hub   # act
```

Without `-e yes=1` it prints the plan and, if it has a terminal, prompts. With
no terminal — under `yamcity` — it refuses rather than assuming. See
[Confirmation model](#confirmation-model).

**`wg-hub help` prints the exact manual equivalent**, so the automated path is
never the only way to understand what happened. The short version, for the
initial bootstrap:

```sh
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
```

Put the resulting public key into `bkup.conf` as `WG_HUB_PUBKEY`. The router
already forwards UDP 51822 → 192.168.2.27.

**Peer management is the operation that recurs** — every box added, and more
importantly every box revoked. Revocation under stress should be one command,
not hand-editing a config file while annoyed. `wg-hub` uses the right primitive:

```sh
wg syncconf bk0 <(wg-quick strip bk0)
```

`wg syncconf` updates peers on a **live interface without tearing it down**, and
*removes* peers absent from the new config — which is precisely revocation
semantics. Adding or revoking one box never disturbs the others.

---

## Confirmation Model

Every subcommand that changes something destructive or lockout-prone follows
the same rule, implemented once in `backup-box/common.sh` as `bk_confirm`:

| Situation | Behaviour |
|---|---|
| `-e yes=1` given | Proceed without asking |
| Terminal available | Print the plan, then prompt |
| No terminal (e.g. `yamcity`) | Print the plan, **refuse**, exit non-zero |

The plan is always printed *before* the gate, so the report and the action are
the same code path — there is no separate dry-run implementation that can drift
out of sync with what actually runs.

Why not simply prompt always: `yamcity` runs modules with stdin redirected from
`/dev/null`, so a prompt there would either hang or silently read EOF and
proceed. Refusing without a terminal is the only safe default. yamc invokes the
remote script with `ssh -t`, so an interactive run does get a real terminal.

---

## Storage Layout

The Ubuntu installer's defaults leave most of a large disk unallocated. On
`orion`:

```
/dev/mapper/ubuntu--vg-ubuntu--lv   98G   ← root LV
/dev/sda2                           2.0G  ← /boot
                                    ~2.9T ← free extents in ubuntu-vg
```

That free space is the point of the machine, so the module has to claim it.

**Design: a separate LV, not an extension of root.**

| Why | |
|---|---|
| Isolation | A runaway repository fills its own filesystem, not `/`, so the box stays reachable and diagnosable |
| Mount options | `noexec,nodev,nosuid` on a volume that holds nothing but opaque blobs |
| Lifecycle | Resize, replace, or wipe the backup volume without touching the OS |

**Defaults** (all overridable with `-e`):

| Variable | Default | Meaning |
|---|---|---|
| `bk_vg` | autodetected, else `ubuntu-vg` | Volume group to carve from |
| `bk_lv` | `backup` | Logical volume name |
| `bk_size` | `100%FREE` | Size passed to `lvcreate -l` |
| `bk_mount` | `/srv/backup` | Mount point |
| `bk_fstype` | `ext4` | Filesystem |

Notes on the defaults:

- **`ext4 -m 0`.** ext4 reserves 5% for root by default — 145 GB on a 2.9 TB
  volume, for a filesystem root never writes to. Reserve zero.
- **`100%FREE`** leaves no room for LVM snapshots. Set `bk_size=95%FREE` if you
  ever want them; not needed for this design.
- Mounted from `/etc/fstab` **by UUID**, never by device path.

### Safety rules for the storage subfunction

This is the only part of the system that can destroy data, so it is
deliberately timid:

1. **Reports by default, acts only on explicit opt-in.** Running
   `backup-box storage` with no confirmation flag prints what it *would* do
   and exits.
2. **Refuses if `bk_lv` already exists.** No implicit reuse, no implicit
   `mkfs`.
3. **`mkfs` only ever runs on an LV this script just created**, in the same
   invocation. Never on a pre-existing device, never on a path supplied by a
   variable.
4. **Never extends, resizes, or touches the root LV** or any LV it did not
   create.
5. **Refuses and reports** on anything unexpected — no LVM, no free extents,
   multiple candidate VGs. It does not get clever.

---

## Repository Layout and Retention

**Split by data class, not one giant repository.** At terabyte scale the
binding constraint on restic is index memory on the *client*, roughly
proportional to blob count — and maildirs are pathological, being millions of
tiny files. Splitting keeps index pressure and prune cost off the high-value
data, and lets a documents restore finish without touching 2 TB of photos.

| Repo | Content | Churn | Retention |
|---|---|---|---|
| `docs` | home dirs, minus media | high | `--keep-daily 14 --keep-weekly 8 --keep-monthly 24` |
| `mail` | selected maildirs | high, tiny files | `--keep-daily 14 --keep-weekly 8 --keep-monthly 24` |
| `media` | photos, video, archives | near zero | `--keep-last 3 --keep-monthly 6` |

`docs` and `mail` are the replacement for the *cumulative* volume. The latest
snapshot in each is the replacement for the *mirror*.

On the box:

```
/srv/backup/repos/<source-host>/<repo>
```

One rest-server user per source host, with `--private-repos` so a user can
only reach paths under its own name. Repositories are created with
`--repository-version 2` for zstd compression.

> **Verify at build time:** the exact path semantics of `--private-repos`
> (whether sub-repositories nest under the user prefix as written above)
> against the rest-server version actually installed. The intent is one
> credential per source host with no cross-access; confirm the flag delivers it
> before relying on it.

**Exclude lists live in `yamc.local/backup/<repo>.exclude`.** These matter more
than any code in this project: caches, `.cache`, `node_modules`, browser
profiles, VM images, and `.thumbnails` are the difference between terabytes and
tens of terabytes.

---

## Deployment Procedure

Order matters. Steps 10–13 are the ones people skip and regret.

**Options precede the module name** — yamc's `getopts` stops at the first
non-option argument, so `wg-hub -e net=bkup` silently loses the setting.

1. **Audit the hub host** — [Pre-Build Audit](#pre-build-audit-of-uranus).
2. **Set up the hub** — `yamc -h uranus -e net=bkup wg-hub` (reports and
   prompts), then `-e yes=1`.
3. **Record the hub key** — `yamc -h uranus -e net=bkup -e save=1 wg-hub key`.
   Peers cannot be built until `WG_HUB_PUBKEY` is in `<net>.conf`.
4. **Build Ubuntu to the basic profile** — `timezone`, `pref`, `upgrade`,
   `packages`, `system base`. Skip `ntp`: `systemd-timesyncd` is adequate and
   the module would point the box at a LAN server it cannot reach.
5. `yamc init -h orion -u kyle`
6. `yamc -h orion backup-box storage` — reports first, then `-e yes=1`.
7. `yamc -h orion -e net=bkup -e addr=10.9.9.2 wg-peer` — generates the box's
   keypair locally and brings the interface up. **No handshake yet is correct**;
   the hub does not have the key.
8. `yamc -h orion -e net=bkup -e save=1 wg-peer key` — records the peer line.
9. `yamc -h uranus -e net=bkup -e yes=1 wg-hub` — syncs it live. Confirm with
   `yamc -h orion -e net=bkup wg-peer status`; handshake under ~3 minutes.
10. **Give the hub SSH access to the box.** `yamc init` ran from your
    workstation, so only *its* key is on the box. With `LAN_POLICY=none` the
    hub is the only machine that can reach the box once it leaves the LAN.
    Install the hub's key, and accept the box's host key at its tunnel address
    **only after comparing fingerprints against the known-good LAN path**:

    ```sh
    ssh root@BOX 'for f in /etc/ssh/ssh_host_*_key.pub; do ssh-keygen -lf "$f"; done'
    ssh root@HUB 'ssh-keyscan -T5 10.9.9.2 | ssh-keygen -lf -'   # must match
    ```

    Then prove tunnel-only management: from the hub, reach the box at its
    tunnel address without touching its LAN name.

11. **Prove the isolation** — `yamc -h orion -e net=bkup wg-peer probe`. Both
    targets must report `blocked (correct)`. This tests the assertion the whole
    design rests on, across two different paths — a LAN host beyond the hub
    (forward chain) and the hub's own LAN address (input chain). A config can
    pass one and fail the other; that was a real hole here until 2026-08-18.
    Run it on the bench, where a failure is cheapest to fix.
    **A reachable probe means the box does not ship.**

12. `yamc -h orion -e bk_users=uranus backup-box` — rest-server and
    repositories. Prints the credential **once**; store it before continuing.
    Then `restic init` each repository from the source.

13. **Seed on the LAN, at LAN speed.** Terabytes over a residential uplink is
    not a first run, it is a month.

14. **Reboot test.** Confirm the box returns with `/srv/backup` mounted. You
    edited `fstab` on a machine that is about to become unreachable; `mount -a`
    is not the same test.

15. **Foreign-network test.** Tether the box to a phone hotspot and confirm the
    tunnel comes up unattended and a real incremental backup completes. Without
    this, the first genuine test of dial-out happens somewhere you cannot reach.

16. **Ship it**, then verify from home — tunnel, a backup, a restore of one file.

17. `yamc -h orion backup-box lockdown` — egress policy. Applies with an
    automatic revert after 60 seconds; re-run with `-e permanent=1` once you
    have confirmed you still have access.

18. **Leave the rsync mirror running** until you have restored something real
    from restic. Do not decommission on faith.

> **Lockout warning.** Steps 5–16 need SSH over the LAN. Step 17 removes that.
> Run it last, and only after step 16 proves the tunnel works from the box's
> final location. The auto-revert exists because this step is where a mistake
> costs you a phone call to your friend.

---

## Verification and Alerting

**This is not optional, it is the point.**

Today you can look at the rsync mirror and see that it looks right. An
encrypted repository is opaque: **a silently failed backup looks exactly like a
working one.** Moving to restic without the checks below makes your backups
*less* trustworthy, not more.

| Check | Cadence | Runs on |
|---|---|---|
| Record last-success timestamp per repo | every run | source |
| **Alarm if any repo is stale** | daily | **source, never the box** |
| `restic check` (structure only) | weekly | source |
| `restic check --read-data-subset=1/52` | weekly | source |
| `restic forget --prune` | quarterly, maintenance window | source |
| **Real restore drill** | twice a year | you |

Two things worth spelling out:

- **The box must never report its own health.** A compromised or wedged box is
  exactly the one that will claim to be fine.
- **`--read-data` reads the entire repository** — at this scale, terabytes over
  the tunnel. `--read-data-subset=1/52` weekly cycles the whole repository in a
  year at 2% of the cost per run.

**Pruning and append-only interact.** `forget --prune` cannot run against an
append-only server. It needs a maintenance window in which append-only is
relaxed, then restored. Quarterly, deliberate, never automatic — the
append-only guarantee is worth more than the disk space.

---

## Restore Runbook

**Grabbing a deleted file** — the case that actually happens:

```sh
restic -r rest:http://10.9.9.2:8000/uranus/docs mount /mnt/restore
# browse /mnt/restore/snapshots/<date>/... and copy the file out
fusermount -u /mnt/restore
```

Read-only FUSE tree, every snapshot as a directory. Functionally what walking
the cumulative volume gives you today.

The mount runs on the **source**, not on the box, and reads over the tunnel.
Decryption happens on the trusted machine. First mount of a multi-TB repository
takes a while to load metadata, and restic keeps a local metadata cache — size
for several GB.

For "where did that file go", `restic find` and `restic dump` are usually
faster than mounting.

**Full loss** — matches how you have always actually recovered: build the new
machine first, then restore data onto it.

```sh
restic -r <repo> snapshots
restic -r <repo> restore <snapshot-id> --target / --include /home/kyle
```

No bare-metal restore is designed for, because you have never wanted one.

**If `uranus` is gone too**, the repository password is the single point of
failure. It must exist somewhere that survives the house: password manager,
plus an offline copy. **A backup you cannot decrypt is not a backup.**

---

## Revocation Runbook

If a box is stolen, sold, scavenged, or merely suspect:

1. Delete its line from `yamc.local/wgnet/bkup.peers`.
2. `yamc -h uranus -e net=bkup wg-hub` — `wg syncconf` removes the peer from
   the live interface; its key is now inert. Other boxes are undisturbed.
3. Rotate the rest-server credential for that source host.
4. Assume its SSH host key is public; remove it from `known_hosts`.

Nothing else is required, because nothing else on the box was worth anything.
That property is the design, not an accident — see
[Why There Is No Full-Disk Encryption](#why-there-is-no-full-disk-encryption).

---

## Rejected Alternatives

Recorded so they are not revisited.

**Tailscale / Headscale.** Their value is NAT hole-punching and key
distribution at scale. Home already has an open port at a DDNS name, so there
is nothing to punch, and this is three peers, not three hundred. Headscale
would add TLS, a database, and an upgrade treadmill to the machine remote
access depends on. Plain WireGuard is less software and no control plane.
*Also note:* headscale could not have shared port 51820 anyway — it is an
HTTPS coordination server that never carries WireGuard data.

**Adding backup boxes as peers on `wg-easy`'s `wg0`.** Two reasons. `wg-easy`
owns `wg0.conf`/`wg0.json` and clobbers hand-edited peers, so yamc cannot
manage them. And that instance is *built* to grant LAN access — correct for a
phone, exactly wrong for a box in someone else's house.

**One interface with per-peer `AllowedIPs` for both roles.** Isolation would
depend on getting per-peer details right on an interface designed to grant LAN
access. Two interfaces make the policy difference **structural** rather than a
per-peer detail. Keep them separate even after wg-easy is retired.

**Replacing wg-easy now.** Its real weaknesses are known: it holds *client*
private keys server-side (a proper deployment never sees them), it needs
`NET_ADMIN`/`SYS_MODULE` so the container is not a security boundary, and a web
UI is attack surface native WireGuard does not have. None of that is urgent,
and re-platforming remote access *while* building a backup system means a
failure leaves you unsure which change caused it — using the very access you
just changed. `bk0` is the pilot; migrate mobile later, as a third interface,
with confidence.

**`backup-hub` as a module name.** Nothing in it was backup-specific. Generic
`wg-hub` + `wg-peer` serve the future `mob` network with the same code and a
different policy.

**A VPS relay or rendezvous.** Only earns its keep when the disaster destroys
the hub — house fire, box unreachable at a friend's place. The honest counter
is that physical retrieval is fine in that scenario and faster than restoring
terabytes over the internet anyway. If it is ever wanted, the cheap version is
an autossh reverse tunnel, *not* headscale: one systemd unit, no control plane,
and it grants the box no network reach at all. Phase 2, if ever.

**LUKS on the box.** See
[Why There Is No Full-Disk Encryption](#why-there-is-no-full-disk-encryption).

**restic over the sftp backend.** Simpler — no extra daemon, reuses `sshd` —
but gives up `--append-only`, which is the only thing standing between a rooted
box and your backup history. Not worth the saving.

**One giant repository.** Index memory on the client is proportional to blob
count; maildirs are millions of tiny files. Splitting by data class also keeps
prune cost off the high-value repositories.

**rsync + gocryptfs, or rclone crypt.** Preserves the "it's just files" feel,
but rclone crypt re-uploads whole files on change (fatal for maildirs and large
files), and neither gives deduplication, snapshot history, or append-only. The
mirror-vs-zero-knowledge tension they try to resolve is better resolved by
`restic mount`, which puts the browsable view on the trusted machine where it
belongs.

**borg.** A genuinely close call — comparable encryption, better compression
ratios. Loses on operational fit: one source per repository, repository locking
friction, and a server-side install requiring SSH access where rest-server
needs only HTTP over the tunnel.

---

## Accepted Limitations

- **`sshd` binds the tunnel address only.** If the tunnel becomes
  unrecoverable, the box needs physical attention from your friend, or a
  rebuild. Accepted because the box is disposable by design. The deferred VPS
  reverse tunnel would remove this if it ever becomes annoying.
- **`wg-quick` resolves its endpoint once, at interface start.** When
  `bateman.cc` changes address the box stays down until something restarts the
  interface. This is a classic silent-backup-failure cause and needs a
  re-resolve timer on the box — `wireguard-tools` ships a `reresolve-dns`
  example; verify its path on Ubuntu 24.04 at build time.
- **Metadata leaks.** Total repository size, backup timing, and coarse chunk
  sizes are visible to anyone holding the box. Contents are not.
- **No bare-metal restore.** By choice — it has never been how recovery has
  actually been done here.
