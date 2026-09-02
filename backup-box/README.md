# backup-box Module

Provisions the storage volume and the encrypted repository service on an
offsite backup box.

> **Read [`BACKUP.md`](../BACKUP.md) first.** It is the design document for the
> whole system: threat model, why there is no full-disk encryption, how the
> isolation works, the deployment procedure and the restore runbook. This
> README covers only what this module does.

The box holds ciphertext and nothing else. The restic repository password
never exists here, so a stolen or rooted box reveals no file contents, no
filenames and no directory structure.

---

## Usage

```sh
yamc -h orion backup-box storage                       # report the disk plan
yamc -h orion -e yes=1 backup-box storage              # create the volume
yamc -h orion -e bk_users=uranus backup-box            # rest-server + repos
yamc -h orion backup-box status                        # tunnel, disk, service
yamc -h orion backup-box lockdown                      # egress policy - LAST
```

**Options precede the module name.** yamc parses with `getopts`, which stops at
the first non-option argument, so `backup-box -e yes=1` silently loses the flag.

Runs as root (`yamc.env` sets `YAMC_USER=root`).

## Subcommands

| Command | Does |
|---|---|
| `storage` | Claim unallocated volume-group space for the backup volume |
| `setup` | Install rest-server, create repositories and credentials |
| `lockdown` | Egress policy and service binding — run last, auto-reverts |
| `status` | Tunnel, storage, service, repositories, firewall state |

Egress policy is deliberately **not** part of `setup`: it is the step that can
lock you out, so it is separate and runs last.

## Parameters

| `-e` | Default | Meaning |
|---|---|---|
| `bk_users` | *(required by `setup`)* | rest-server users, one per source host |
| `bk_mount` | `/srv/backup` | Mount point for the repository volume |
| `bk_vg` | autodetected | Volume group (refuses if ambiguous) |
| `bk_lv` | `backup` | Logical volume name |
| `bk_size` | `100%FREE` | `lvcreate -l` argument |
| `bk_fstype` | `ext4` | Filesystem (ext4 gets `-m 0`) |
| `bk_iface` | `bk0` | Tunnel interface |
| `bk_addr` | from `bk_iface` | Bind address for rest-server |
| `bk_port` | `8000` | rest-server port |
| `yes` | — | `1` proceeds without prompting |
| `rsrv_url` / `rsrv_sha256` | from `rest-server.pin` | Override the pinned release; both or neither |

## rest-server

Ubuntu packages no build of rest-server under any name, so the module installs
a release tarball pinned in `rest-server.pin` — version, base URL, and a
sha256 per architecture, resolved from `dpkg --print-architecture`.

Those checksums came from the project's `SHA256SUMS`, whose detached signature
verified against Alexander Neumann's key fetched from `restic.net` — an
independent channel from GitHub, which is what makes the check mean anything.
The header of `rest-server.pin` documents how to update it without shortcutting
that step.

A download whose checksum does not match is refused, not installed.

The service runs `--append-only --private-repos`, bound to the tunnel address
only. Binding a wildcard address on a box in hostile territory would expose the
repository to the local network it is meant to be hidden from, so a missing
tunnel is a fatal error rather than a fallback.

**Credentials are generated on the box and printed once**, so no secret travels
inbound. They are printed the moment they are created rather than at the end of
the run — a later failure would otherwise leave the credential stored in
htpasswd but never displayed, and the next run reports it as already present.

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


---

## See Also

- [`BACKUP.md`](../BACKUP.md) — system design, threat model, runbooks
- [`wg-hub`](../wg-hub/README.md) / [`wg-peer`](../wg-peer/README.md) — the tunnel
