# mailgate Module

The public front door for the site mail store ([`mailserver`](../mailserver/README.md)).
Runs on a host with a static public IP and correct reverse DNS. It holds **no
mail and no passwords**, so rebuilding it is just a re-run.

| Component | Role |
|-----------|------|
| HAProxy | Public `:25`, `:587`, `:993` → mail store over WireGuard. SMTP uses PROXY protocol v2 so the store sees real client addresses. IMAP is rate-limited per source IP here, because the store's IMAP server can't see them. |
| Postfix | **Outbound only.** Bound to the tunnel address and loopback, accepts only from the store, delivers directly (or via a relay). Not reachable from the internet. |
| certbot | The mail certificate, standalone on `:80`. Renewed by `certbot.timer`. |
| certpush | `/usr/local/sbin/mailgate-certpush`, the forced command for the store's pull key (`from=` the store, `restrict`). |
| nftables | Own table `inet mailgate`, default deny: 22, 25, 80, 587, 993, ICMP. Loaded by `mailgate-firewall.service`. |

Site design: `yamc.local/mailserver/README.md`.

## Status

Written 2026-11-05; reworked the same day for one-run-per-module deployment
(own config folder, tunnel address from the peer table). Dry-run (report mode)
verified against kjeib.com; **not yet applied**.

## Usage

```sh
yamc -h kjeib.com mailgate [-e yes=1]    # report, then converge
yamc -h kjeib.com mailgate status        # services, firewall, tunnel, cert, queue, bounces
yamc -h kjeib.com mailgate test          # outbound 25, PTR, listeners, open-relay check; sends no mail
```

As a machine role, with its tunnel peer: `yamc.local/profiles/mailgate`
(`wg-peer -e net=mail`, then `mailgate`), run with yamcity. Build order for
both hosts: `yamc.local/mailserver/README.md`, "Build and deploy".

## Preflight (refuses to change anything if any fail)

- The host owns `GATE_PUBLIC_IP`.
- Ports 80/25/587/993 are free, or held by this module's own HAProxy/Postfix.
- `ufw` isn't active (this module owns the firewall).
- Every name in `CERT_NAMES` resolves to `GATE_PUBLIC_IP`.

## Configuration

`yamc.local/mailgate/mailgate.conf`. The store has its own folder
(`yamc.local/mailserver/`); this module assumes it is configured, and reads
from it only the store's `certpull.pub`. It refuses if the two disagree on
`MAIL_HOSTNAME` or on the gateway's tunnel address.

This host's tunnel address is not configured here: it is this host's line in
`yamc.local/wgnet/<MAIL_WGNET>.peers`, which its `wg-peer` run records. So
`wg-peer` must run first; until then setup refuses and says so.

Outbound modes:

| `OUTBOUND` | `RELAY_DOMAINS` | Result |
|------------|-----------------|--------|
| `direct` | empty | Everything delivered directly as `GATE_HELO` |
| `direct` | `outlook.com ...` | Those domains via `RELAY_HOST`, the rest direct |
| `relay` | — | Everything via `RELAY_HOST` |

Relay credentials go in `yamc.local/mailgate/relay.secret`
(`RELAY_USER=`, `RELAY_PASS=`). `yamc.local/.gitignore` excludes it, and
setup.loc warns if git tracks it anyway.

## Lockout safety

The firewall is a single atomic nft transaction that accepts established
connections and port 22, so the SSH session running it survives. To remove it:
`systemctl disable --now mailgate-firewall` (its `ExecStop` deletes the table).
