# mailserver Module

The site mail store: Postfix, Cyrus IMAP, SpamAssassin and OpenDKIM on the LAN
mail host. Its public front door is the [`mailgate`](../mailgate/README.md)
module on a host with a static public IP; the two are linked by a
[`wg-hub`](../wg-hub/README.md) / [`wg-peer`](../wg-peer/README.md) network.

```
internet ─► gateway (mailgate) ══ WireGuard ══► this host (mailserver)
            HAProxy 25/587/993                  Postfix 10025/10587 (PROXY), Cyrus 10993
            Postfix (outbound only) ◄────────── relayhost
```

Site-specific design, decisions and migration plan:
`yamc.local/mailserver/README.md`.

## Status

Written 2026-11-05; reworked the same day for one-run-per-module deployment
(own config folder, keys recorded automatically, certificate pulled without a
command). Dry-run (report mode) verified against uranus; **not yet applied**.

## Usage

```sh
yamc -h uranus mailserver [-e yes=1]          # report, then converge
yamc -h uranus mailserver status              # services, queue, cert expiry, DKIM, accounts
yamc -h uranus mailserver dns                 # DNS rows per domain + what DNS has now
yamc -h uranus mailserver user [NAME]         # list accounts / set a password
yamc -h uranus -e delete=1 mailserver user NAME
yamc -h uranus mailserver cert                # pull the TLS cert now (optional; the timer does it)
yamc -h uranus [-e save=1] mailserver key     # show / record the cert-pull key (setup does it)
```

Report-then-confirm like `wg-hub`: without `-e yes=1` it prints the plan and
prompts; with no terminal it stops after the report.

As a machine role, with its tunnel hub: `yamc.local/profiles/mailserver`
(`wg-hub -e net=mail`, then `mailserver`), run with yamcity.

Every run ends with a **STILL TO DO** list: DKIM records to publish, mailboxes
without a password, tunnel not up, certificate not yet pulled. `dns` and
`user` stay separate commands because they are operations (publishing at the
registrar, typing a password), not configuration.

## Configuration

`yamc.local/mailserver/`. The gateway has its own folder
(`yamc.local/mailgate/`); this module assumes it is configured.

| File | Purpose |
|------|---------|
| `mail.conf` | Public name, domains, LAN, the gateway's tunnel address, DKIM selector, limits |
| `aliases` | `address mailbox` table. Anything not listed is refused at SMTP time. Mailboxes must be local names: no forwarding to outside addresses. |
| `certpull.pub` | Recorded by every successful run (`setup.post.loc`); installed on the gateway by `mailgate` |

Tunnel addresses come from `yamc.local/wgnet/<MAIL_WGNET>.conf`. `setup.loc`
refuses a network without `WG_HUB_PORTS` covering 10025, 10587 and 10993.

From the gateway's folder it reads only `GATE_PUBLIC_IP`, `OUTBOUND` and
`RELAY_*` (for SPF in `dns`), and refuses if the two disagree on
`MAIL_HOSTNAME`. Without that folder, `dns` takes the address from DNS.

The loader `mailconf.loc.sh` is shared with `mailgate` by symlink (the
`wgnet.loc.sh` pattern), so validation can't drift between the two.

## What setup does

| Area | Result |
|------|--------|
| Packages | postfix, cyrus-imapd (+admin, clients), sasl2-bin, spamassassin/spamd/spamc, spamass-milter, opendkim, ssl-cert, swaks |
| Postfix | `myhostname` = public name. Virtual alias domains from `MAIL_DOMAINS`; delivery to Cyrus over LMTP. `relayhost` = gateway tunnel address. Milters: OpenDKIM, spamass-milter. All daemons unchrooted (absolute socket paths). |
| Listeners | `WG:10025` public MX (PROXY, no relay, known recipients only, Spamhaus filtered to real listings). `WG:10587` submission (PROXY, TLS + login). `:25` LAN (relay for `LAN_NETWORKS`). `:587` LAN submission. |
| Cyrus | Settings match sun's effective config (`altnamespace`, `unixhierarchysep`, hashed spool, `Spam`/`Spam-maybe` folders), so migrated mailboxes behave the same. Mailboxes are autocreated on first delivery with a default Sieve script that files `X-Spam-Flag: YES` into `Spam-maybe`. Extra `imapsgw` listener on `WG:10993`. POP3/NNTP off. |
| Auth | sasldb, realm = short hostname. Postfix (`smtpd_sasl_local_domain`) and Cyrus (`servername`) are set to agree. |
| DKIM | One 2048-bit key per domain per selector, generated only if missing. Signs mail from the LAN and from logged-in users (`milter_macro_daemon_name=ORIGINATING`). |
| Spam | spamd + spamass-milter: skips logged-in senders and the LAN, rejects at `SPAM_REJECT_SCORE` or above, otherwise adds headers. Per-user Bayes learning is not ported yet. |
| TLS | `/etc/mailserver/tls/`. Self-signed placeholder until the first pull. |
| Cert pull | ed25519 key, `/usr/local/sbin/mailserver-certpull`, hourly timer: tries every hour until the first real certificate (a not-ready gateway is "waiting", not a failure), then checks once a day. Setup also tries once when the tunnel is up. Installs only on change; state and expiry in `/var/lib/mailserver/cert.state`. Exits 2 (unit failed) under 21 days left. |
| Boot order | `net.ipv4.ip_nonlocal_bind=1`, so tunnel listeners start even before the tunnel. LAN mail never depends on it. |

Idempotent: files are compared before writing, the Postfix config is compared
before/after (`postconf -n -M -P`), and services restart only when their
config changed.

## Build and deploy

The order for both hosts, and the tunnel, is in the site README
(`yamc.local/mailserver/README.md`, "Build and deploy"). In short: store
role, gateway role, deploy the hub's peer table; then `dns` and `user`.

## Known gaps

- Per-user SpamAssassin Bayes learning from Spam folders (old `learnuser`) is not ported.
- Mailbox migration from sun is a separate, one-time procedure (planning README, Phase 3).
- Settings that depend on the installed Ubuntu packages (LMTP socket path,
  `cyrus.conf` layout, OpenDKIM unit generator) are read or handled at run
  time. Check the first real run's output carefully.
