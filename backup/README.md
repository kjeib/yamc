# backup Module

The restic client, on the **source** host — the machine that holds the files.

> **Read [`BACKUP.md`](../BACKUP.md) first.** It is the design document for the
> whole system. This README covers only what this module does.

The source encrypts before anything leaves the LAN. It is the only place the
repository passwords exist. The other half, [`backup-box`](../backup-box/README.md),
runs `rest-server` on the machine that stores the blobs — that box never runs
restic and holds no key.

---

## Status

Built and installed on `uranus`, with the **schedule deliberately off**.
`uranus` is being prepared ahead of taking over from `sun` and does not hold
the real home directories yet.

## Usage

```sh
yamc -h uranus -e bk_pass='<rest-server password>' backup   # first time
yamc -h uranus backup init                                  # create repos
yamc -h uranus backup run home                              # back up now
yamc -h uranus backup status                                # freshness alarm
yamc -h uranus backup enable                                # start the schedule
```

**Options precede the module name** — yamc's `getopts` stops at the first
non-option argument.

## Subcommands

| Command | Does |
|---|---|
| `setup` | Install restic, write config and excludes, install the crontab |
| `init` | Create the repositories on the box |
| `run [repo]` | Back up now, regardless of the schedule |
| `check [repo]` | Verify integrity; `-e data=1` adds a rotating 1/52 data slice |
| `snapshots [repo]` | List what is stored |
| `status` | Configuration, schedule, and last success per repository |
| `env <repo>` | Print export lines for driving restic by hand |
| `enable` / `disable` | Turn the cron schedule on or off |

## Two different secrets

Conflating these is the classic mistake:

| | Who knows it | Consequence if lost |
|---|---|---|
| **rest-server password** | the box, and this host | Re-issue it from `backup-box` |
| **repository password** | **this host only** | **Every byte is unrecoverable** |

The second is generated here, printed once, and stored `0600` in
`/etc/restic/<repo>.pass`. It never reaches the box — that is the whole point,
and it means losing this host *and* these files at the same time destroys the
backups. Keep a copy somewhere that survives losing this machine.

## Configuration

`yamc.local/backup/`:

| File | Contents |
|---|---|
| `backup.conf` | Master switch, box address, rate limit, staleness threshold |
| `repos.tab` | `repo \| cron h:m \| retention` |
| `<repo>.paths` | What to back up |
| `<repo>.exclude` | What to leave out |

Four repositories, mirroring the targets of the old `diskback` script:
`home`, `mail`, `media`, `root`. The paths and excludes are ported from it
verbatim; suggested additions are present but commented out, so nothing was
silently changed.

**Get the excludes right before seeding.** Seeding is the multi-week step, and
correcting it afterwards means `prune` against an append-only server.

## The master switch

`BACKUP_ENABLED="no"` installs the crontab with every entry commented out.
Backing up an incomplete copy over a good one is worse than not backing up, so
this stays off until `uranus` really is the live source.

`backup enable` / `backup disable` flip the installed crontab. `backup run`
ignores the switch entirely, so seeding and testing work meanwhile.

## What replaced the `BACKUP` sentinel

The old `diskback` refused to run unless a `BACKUP` marker file existed on the
remote volume, because rsyncing into an empty mountpoint quietly *succeeds*.
The same hazard exists here, so the runner checks `restic cat config` before
every backup and treats an unreachable repository as an **error**, never a
silent no-op.

## No `restore` subcommand

By choice. Restores are rare, varied and consequential — better done
deliberately with the real tool than through a wrapper that hides which flags
were used. What a wrapper usefully saves is retyping the repository URL and
password file, so `backup env <repo>` prints exactly that, lists the commands
worth knowing (`dump`, `find`, `mount`, `restore`), and gets out of the way.

`restic mount` is the closest equivalent to walking the old cumulative volume:
every snapshot as a browsable directory tree, decrypted here, with the box
still seeing only ciphertext.

## Verification

An encrypted repository is opaque — a silently failed backup looks exactly like
a working one. `backup status` reports last success per repository and exits
non-zero if any is stale, which is what replaces eyeballing an rsync mirror.

It runs on the **source**, deliberately. A backup box must never report its own
health: a compromised or wedged box is precisely the one that will claim to be
fine.

## Prune

Not a subcommand yet. Retention is recorded in `repos.tab`, but
`forget --prune` cannot run against an append-only server — it needs a window
in which append-only is relaxed on the box, then restored. Quarterly and
deliberate; the append-only guarantee is worth more than the disk space.

## See Also

- [`BACKUP.md`](../BACKUP.md) — system design, threat model, runbooks
- [`backup-box`](../backup-box/README.md) — the storage side
