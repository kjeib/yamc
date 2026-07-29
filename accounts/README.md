# Accounts Module

Provisions site groups and user accounts from a static roster in
`yamc.local/accounts/`.

Everything root does **to** accounts lives here. The unprivileged command
users run to change their own password lives in the **`pwsync`** module. The
split is by privilege and audience, not by topic — the same line Unix draws
between `useradd` and `passwd`.

---

## Why This Exists (read this first if returning cold)

**The situation.** Users log in to several sub-servers. `/home` is NFS-mounted
from the file server, so home directories are shared, but each host keeps its
own `/etc/passwd` and `/etc/shadow`. Historically user identity came from
**LDAP on `sun`** (Fedora, 389-DS). The new Ubuntu boxes (`aries`, `orion`)
are not LDAP clients and never will be — LDAP is being decommissioned.

**Two problems fall out of that:**

1. *Who exists?* New hosts don't know about the users. → **this module.**
2. *Passwords diverge.* Each host has its own `/etc/shadow`, so a password
   change on one host leaves the others stale. → **the `pwsync` module.**

**Why a static roster rather than querying LDAP at provisioning time.** LDAP
is going away. A provisioning path that depends on it would break the day
`sun` is retired — and would break silently. So the directory was queried
**once** (2026-07-28), written to `yamc.local/accounts/*.conf`, and those
files are now the source of truth. `adduser` remains only for pulling in a
straggler while the directory is still up.

**Why passwords could not be migrated.** LDAP stores `{SSHA}` (salted SHA-1,
the 389-DS default). That is not a `crypt(3)` format — Linux `/etc/shadow`
accepts DES, `$1$`, `$2`, `$5$`, `$6$`, `$y$`, and there is no conversion
from SSHA without the plaintext. So every account starts **locked** and
everyone needs a new password once. `setpass` + `pwsync` makes that one
action per person rather than one per host.

> **This supersedes the csync2 plan** described in
> `yamc.local/mailserver/README.md` and listed as a TODO in
> `yamc.local/STATUS.md`. csync2 would have synced whole `/etc/shadow` files
> between hosts; it was rejected because it cannot filter by user (it syncs
> whole files, clobbering per-host system accounts) and because `pwsync`
> needs no daemon, no shared key, and no root access. Ignore the csync2
> entries in those documents.

---

## Current State (2026-07-28)

| Thing | Status |
|---|---|
| Roster harvested from live LDAP | **Done** — `users.conf`, `groups.conf` |
| `accounts` module built | **Done** — dry-run tested on `aries` only |
| `accounts` actually applied to a host | **NOT DONE** — never run for real |
| `pwsync` module built | **Done** |
| `pwsync` deployed | **Done** — working on `aries` and `orion` |
| `accounts` added to `profiles/subserver` | **NOT DONE** — see Profile Ordering |
| LDAP on `sun` | Still running; no longer authoritative for anything |

**Cluster is `aries orion`** (`yamc.local/cluster.conf`). `uranus` is not in
it yet.

**The roster is 7 users, deliberately fewer than LDAP had.** LDAP also
carried `helen` (1020), `khang` (1051), and `jannis` (1052); they were
dropped on purpose. The harvest was not incomplete. If you want them back,
their LDAP entries are still queryable via `adduser` while `sun` lives.

**`family` (1700) and `friends` (1800) are currently memberless** and own
nothing under `/home`. They came across from LDAP. Harmless to keep, safe to
delete. `bateman` (1500) is the one that matters — it group-owns five
directories under `/home` including `/home/media`.

### Next steps when you pick this back up

```bash
ACCT_DRYRUN=1 yamc.local/bin/accounts-cluster-deploy   # 1. review
yamc.local/bin/accounts-cluster-deploy                 # 2. apply
yamc.local/bin/accounts-cluster-setpass julee          # 3. per person
#    then have them log in and run: pwsync
```

Then add `accounts` to `yamc.local/profiles/subserver`, after `nfs-client`.

---

## Usage

```bash
# Provision one host / the whole cluster
yamc -h aries -u root accounts
yamc.local/bin/accounts-cluster-deploy

# Preview without changing anything
ACCT_DRYRUN=1 yamc.local/bin/accounts-cluster-deploy

# Groups only, or a subset of users
yamc -h aries -u root -e ACCT_GROUPS_ONLY=1 accounts
yamc -h aries -u root -e ACCT_USERS="julee,mia" accounts

# Give someone a password
yamc -h aries -u root accounts setpass julee     # random, printed once
yamc.local/bin/accounts-cluster-setpass julee    # same one, every host

# Pull in a straggler still only in LDAP
yamc -h aries -u root accounts adduser someone
```

## The Roster

`yamc.local/accounts/groups.conf` — `name:gid`

```
bateman:1500
kids:1600
audio:-
```

A gid of `-` means **a distribution system group: never create it, only add
members**. This exists because LDAP carries legacy Fedora GIDs that collide
with Ubuntu's:

| Group | LDAP | Ubuntu |
|---|---|---|
| `audio` | 63 | **29** |
| `lp` | 7 | 7 (matches, but by luck) |

Creating `audio` with GID 63 would shadow the distribution group and break
device permissions. **Do not "fix" these entries to numeric GIDs.**

`yamc.local/accounts/users.conf` — `user:uid:gid:gecos:home:shell:groups`

```
mia:1005:1005:Amelia Bateman:/home/mia:/bin/bash:kids,audio,lp
```

Group membership lives here rather than in `groups.conf`, so adding a person
is one line. `gecos` may not contain a colon.

**UIDs are pinned.** `/home` is NFS-shared, so a user with a different UID on
one host cannot read their own files there. This is the single most important
invariant in this module.

## Safety Properties

**Home directories are never created** (`useradd -M`). `/home` is NFS-mounted
and already holds the users' files; letting `useradd` skeleton it would
scribble dotfiles into a populated home.

**The UID guard.** Before creating an account, the existing home directory is
stat'd and compared to the roster:

- **UID mismatch → hard failure.** The account could not read its own files.
  Override with `-e ACCT_FORCE=1` only if you are certain.
- **GID mismatch → warning only.** A home directory group-owned by a shared
  group is normal. `/home/mia` is `1005:1500` while mia's primary group is
  `1005`, and that is fine. *An earlier version failed on this and was
  wrong* — do not tighten it back.

**Accounts are created locked.** See the SSHA explanation above. Use
`setpass`, then have the user run `pwsync`.

**Existing accounts are never renumbered.** If a user or group already exists
with different numbers, the module reports and refuses rather than guessing.

## setpass

By default the **remote host generates** a random password and prints it
once, so no secret travels inbound. `-e ACCT_PROMPT=1` collects one on the
control host instead, handing it over through a file in the mounted module
tmp directory — deliberately **not** via `-e`, because yamc builds remote env
vars into the ssh command line where they would show in the remote process
list.

`accounts-cluster-setpass` prompts by default, so the user gets the *same*
password everywhere (per-host random passwords would be useless to them).

It serves both bootstrap and repair: for a host where `pwsync` reported
`FAILED` (genuine drift), run `setpass` there and have the user re-run
`pwsync` to converge.

## LDAP

Directory: `ldaps://ldap.batemans.org` (= `sun`, 192.168.2.10), base
`dc=batemans,dc=org`, users under `ou=People`, groups under `ou=Group`.
Anonymous bind reads everything except `userPassword`, which is all this
module needs.

`sun` itself has `ldapsearch` installed, so a manual query needs no local
tooling:

```bash
ssh sun "ldapsearch -xLLL -H ldap://localhost -b 'dc=batemans,dc=org' \
  '(objectClass=posixAccount)' uid uidNumber gidNumber homeDirectory loginShell gecos"
```

When `sun` goes away, delete `yamc.local/accounts/ldap.conf` and the
`adduser`/`adduser.loc` scripts — nothing else depends on them.

**Beware the stale LDIF.** `setup-copy/snap/site.batemans/ldap/batemans.ldif`
is a 2011 export carrying the *pre-renumbering* UIDs (kyle=500, group
bateman=500). The live directory and the live NFS tree both use the 1000/1500
scheme. That file is historical — do not provision from it. (It also contains
the LDAP Manager password in `old/ldap.cfg`.)

## Configuration

| File | Purpose |
|---|---|
| `yamc.local/cluster.conf` | `CLUSTER_HOSTS`, shared with `pwsync` |
| `yamc.local/accounts/groups.conf` | Group roster |
| `yamc.local/accounts/users.conf` | User roster |
| `yamc.local/accounts/ldap.conf` | `adduser` only; delete when LDAP dies |

## Profile Ordering

`accounts` must run **after `nfs-client`** in a build profile. The UID guard
stats `/home/<user>`, which is meaningless before the NFS mount exists —
without it, every user falls through to "cannot cross-check identity" and the
guard silently stops protecting you.

## Notes

- `common.sh` holds the guard and the create logic so `setup` and `adduser`
  cannot drift apart. It is intentionally **non-executable**: yamc discovers
  subcommands by scanning for executable files, and an executable helper
  would appear as a bogus `accounts common.sh` subcommand.
- Accounts present on NFS but not in the roster — `guest` (1030), `dba`
  (1100), `postgres` (111) — are not managed here and are left alone.
