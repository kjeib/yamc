# NTP Module

Installs and configures chrony for time synchronization on **on-LAN hosts**,
pointing them at a local time server while keeping the distribution's public
pool as a fallback.

## Usage

```bash
# Configure (uses yamc.local/ntp/config.conf)
yamc -h hostname -u root ntp

# Report time state - works with chrony or timesyncd
yamc -h hostname -u root ntp status

# Undo the in-place edits made by older versions of this module
yamc -h hostname -u root ntp cleanup
```

## Scope: on-LAN hosts

This module is for hosts on your own network. A host that is **not** on the LAN
does not need it: Ubuntu ships `systemd-timesyncd` enabled by default, syncing
against `ntp.ubuntu.com` and honouring any NTP servers offered by DHCP. That is
accurate to well within what logging and apt's `Release`-file validity checks
require.

So for an off-LAN or minimal host — an offsite backup box, say — **skip this
module** rather than configuring it. `ntp status` still works there and will
report the timesyncd state.

## What It Does

1. Installs chrony if absent, noting that this **displaces systemd-timesyncd**
2. Backs up the packaged config to `/etc/chrony/chrony.conf.orig`
3. Ensures chrony's drop-in directories are enabled
4. Writes time sources to `/etc/chrony/sources.d/yamc.sources`
5. Optionally writes serving config to `/etc/chrony/conf.d/yamc-server.conf`
6. Reloads sources, or restarts if a restart is genuinely needed
7. Waits for actual synchronization and reports pass or fail

## Drop-in files, not edits

Configuration is written as drop-in files rather than by editing
`chrony.conf`:

| File | Contents |
|---|---|
| `/etc/chrony/sources.d/yamc.sources` | `server` / `pool` lines |
| `/etc/chrony/conf.d/yamc-server.conf` | `allow`, `local stratum` |

`allow` and `local stratum` are not source directives, so they cannot live in
`sources.d` — hence the split.

This matters because drop-ins are:

- **idempotent by construction** — write the file, done; no delete-then-append
  dance and no `grep -q` guards to get wrong
- **reversible** — delete the file
- **upgrade-safe** — a new packaged `chrony.conf` never collides with your edits
- **reloadable** — source changes apply via `chronyc reload sources` with no
  restart, so adding a server does not disturb the clock

Changes under `conf.d` do require a restart, since it is read only at startup.
The module tracks which kind of change it made and does the lesser of the two.

## Site Configuration

`yamc.local/ntp/config.conf`:

```bash
# Preferred local time servers (space-separated)
NTP_SERVERS="ntp1.example.com ntp2.example.com"

# Legacy singular form, still accepted
# NTP_SERVER=ntp.example.com

# Override the fallback pool. Normally leave unset - the pool already in
# chrony.conf is kept, which is what you want.
# NTP_POOL=pool.ntp.org

# Serve time to the network
# NTP_IS_SERVER=true
# NTP_ALLOW="192.168.0.0/16"     # required when NTP_IS_SERVER=true
# NTP_LOCAL_STRATUM=10
```

With no config file, the distribution's defaults are left alone.

`NTP_ALLOW` has no default and the module refuses to serve time without it. It
was previously hardcoded as `192.168.0.0/16` in the module script, which is site
data living in shared code — the thing `AGENTS.md` prohibits.

## Fallback behaviour

Local servers are configured with `prefer`, so they win whenever reachable and
your hosts agree with each other. The packaged `pool` line in `chrony.conf` is
left untouched and only comes into play when the local server is unreachable.

That is deliberate, and it is the main behavioural change from the previous
version of this module, which commented the pool lines out. Under the old
behaviour, a local NTP server that went down — or was simply being rebuilt —
left **every host on the LAN with no time source at all**, silently.

## Legacy cleanup — `ntp cleanup`

Hosts configured by the earlier version have `#pool` lines in `chrony.conf` and
a `server` line inserted in place.

This is a **separate, explicit subcommand** rather than something `setup` does
on your behalf. `setup` installs the intended configuration; it should not
carry a catalogue of preconceptions about how a host might already be broken.

```bash
yamc -h hostname -u root ntp cleanup
```

1. detects the commented pool lines — exits cleanly if there are none
2. copies the current config aside as `chrony.conf.yamc-legacy.<timestamp>`
3. restores `chrony.conf` from `chrony.conf.orig`
4. restarts chrony and confirms it came back

Nothing is destroyed; both the legacy copy and the original remain on disk.
If `chrony.conf.orig` is missing there is nothing safe to restore to, so it
stops and explains the manual fix rather than guessing which lines were the
module's.

**`setup` refuses to run on a host in this state.** Layering a drop-in on top
of the old edits would define the same server twice and leave the pool lines
still commented out, so it stops and points here. `ntp status` flags the state
too.

## Verification

The module runs `chronyc waitsync 10 0.1`, which blocks until the clock is
actually within tolerance and returns a meaningful exit status. The previous
`sleep 2; chronyc tracking` almost always printed `Leap status: Not
synchronised` — alarming, and not a check.

Manual inspection:

```bash
chronyc tracking      # current sync state
chronyc sources -v    # sources and their health
chronyc sourcestats   # stability over time
timedatectl           # system view, works without chrony
```

## Notes

- Chrony is preferred over ntpd on modern Ubuntu; installing it disables
  `systemd-timesyncd`, and the module reports the resulting state so the swap
  is not silent
- The module is idempotent — safe to run repeatedly
- Original config preserved as `/etc/chrony/chrony.conf.orig`
