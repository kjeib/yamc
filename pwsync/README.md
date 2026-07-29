# Password Sync Module

Lets a user change their password on one host and have it propagate to every
other host in the cluster.

This module ships only the **unprivileged command users run**. Root-side
account work — creating users and groups, setting or resetting a password —
lives in the **`accounts`** module.

## Purpose

Users log in to several sub-servers that each keep their own `/etc/shadow`.
Without something like this, a password change on one host leaves the others
stale. `pwsync` closes that gap without introducing any new infrastructure.

> **Supersedes the csync2 plan.** `yamc.local/mailserver/README.md` and
> `yamc.local/STATUS.md` still describe syncing `/etc/shadow` between hosts
> with csync2. That approach was rejected: csync2 syncs *whole files* and
> cannot filter by user, so it would clobber each host's own system
> accounts, and it needs a daemon, a shared key, and root everywhere.
> `pwsync` needs none of those. Ignore the csync2 entries in those docs.
>
> **Companion module:** `accounts` creates the users and groups, and does
> root-side password work (`accounts setpass`). Read
> `yamc/accounts/README.md` for the migration context.

## Usage

```bash
# Deploy to one host / to the whole cluster
yamc -h hostname -u root pwsync
yamc.local/bin/pwsync-cluster-deploy
```

Then, as any user, on any host:

```bash
pwsync                # change password here and on all peers
pwsync --local-only   # change password here only
```

## Configuration

The host list comes from the shared `yamc.local/cluster.conf`:

```bash
CLUSTER_HOSTS="aries orion"
```

`yamc.local/pwsync/cluster.conf` can set `PWSYNC_HOSTS` to override it, but
only if password sync needs a different host set than the rest of the
cluster. The resolved list is installed to `/etc/pwsync.conf` on every host;
each host skips whichever entry matches its own short hostname.

**When the host list changes, redeploy to all hosts**, not just the new one —
existing hosts need the updated list before they will push to the new member.

### Per-user host lists

If a user has accounts on only some cluster hosts, they can create
`~/.pwsync-hosts`:

```
# hosts I actually have accounts on
aries orion
```

This overrides the cluster list for that user. Because it lives in their
NFS-mounted home, it applies on every host automatically. Without it, hosts
where they have no account are reported as `skipped` on every run — harmless
but noisy.

## How It Works

1. Prompts for current and new password (read from `/dev/tty`, never argv,
   so they never appear in the process table).
2. Optionally pre-checks quality with `pwscore`.
3. Runs `passwd` locally, feeding the three expected lines on stdin.
4. For each peer, runs `passwd` over SSH **as the user**, same three lines.
5. Reports per-host status.

If the local change fails — usually a wrong current password — no peers are
contacted at all.

### Two kinds of failure, deliberately distinguished

| Result | Meaning |
|---|---|
| `ok` | Password changed there |
| `skipped` | `ssh` exited 255 — host unreachable, or no account/key there |
| `FAILED` | Reached the host, but its `passwd` refused — **genuine drift** |

`ssh` exits 255 for its own failures and passes through the remote command's
status otherwise, which is what makes the distinction reliable. `skipped` is
expected in a fleet where not everyone has an account everywhere; `FAILED`
means the password there has diverged and needs admin repair.

## Why This Design

Setting hashes directly on remote hosts would need root there: distributing
keys, a `sudoers` rule, and a privileged receiving script. It would also mean
picking a hash format every host supports (yescrypt vs SHA-512 differ across
Ubuntu and Fedora), bypassing each host's `pam_pwquality`, and fixing up
password-aging fields by hand.

Running each host's own `passwd` avoids all of it:

- **No root, no sudo, no keys to manage.** Runs entirely as the user.
- **No hash portability problem.** Each host hashes with its own crypt.
- **Quality checks and aging stay native** to each host's PAM stack.
- **Every host independently verifies** the current password.

SSH to peers uses the user's own key. Because `/home` — and with it
`~/.ssh` — is NFS-mounted across all sub-servers, one key already works
everywhere with no distribution step.

`expect` is not used. `passwd` reads happily from a pipe, so `pwsync` feeds
it three lines rather than scraping prompts. That matters on a mixed fleet:
prompt *wording* varies across distros and locales, the number and order of
reads does not.

## Requirements

- SSH key authentication between hosts for each user (free via NFS `~/.ssh`)
- `libpwquality-tools` for `pwscore` — installed if available, optional
- The same username and UID on every host (provisioned by `accounts`)

## Limitations

**Drift is not self-healing.** If a password has already diverged on a host,
the current password will not authenticate there and that host stays stale.
`pwsync` reports it as `FAILED`, but cannot fix it — repairing it requires
exactly the privileged access this module avoids. Repair with:

```bash
yamc -h aries -u root accounts setpass USERNAME
```

**SSH uses `BatchMode`.** If a user has no working key to a peer, that peer
is `skipped` rather than prompting. This is deliberate: an interactive SSH
prompt would consume the piped current password and desync the exchange.

## Notes

- A user can only ever change their own password, which `passwd` enforces —
  so there is no allowlist to maintain.
- Email passwords (`sasldb2` on the mail server) are a separate store and are
  not touched by this module.
- The `pwsync` payload is intentionally non-executable in the module
  directory: yamc discovers subcommands by scanning for executable files.
  `setup` installs it with mode 0755.
