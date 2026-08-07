# Chrome Module

Install Google Chrome browser from Google's official repository.

## Usage

```bash
yamc -h hostname -u root chrome
```

Upgrade an existing install (apt package + optional wrappers from `yamc.local/chrome/`):

```bash
yamc -h hostname -u root chrome upgrade
```

## What It Does

1. Checks architecture (amd64 only)
2. Adds Google's GPG signing key (modern keyring method)
3. Adds Google's apt repository
4. Installs `google-chrome-stable`
5. Installs wrapper script (if configured) for NFS environments
6. Installs desktop entries so GUI and URL launches use the wrapper

## Features

- **Idempotent**: Safe to run multiple times
- **Modern keyring**: Uses `/usr/share/keyrings/` (not deprecated `apt-key`)
- **Auto-updates**: Repository enables future updates via `apt upgrade` or `yamc … chrome upgrade`
- **NFS wrapper**: Optional wrapper for systems with NFS-mounted home directories

## Requirements

- Ubuntu/Debian amd64 system
- Root access
- Internet connectivity

## NFS Home Directory Support

If your systems mount `/home` via NFS, Chrome's default behavior causes problems:
- **Performance**: Cache reads/writes over NFS are slow
- **Lock conflicts**: Chrome uses `SingletonLock` files that conflict across machines
- **Multi-machine**: Can't run Chrome on two machines sharing the same NFS home

### Wrapper Scripts

The module installs two wrappers in `yamc.local/chrome/`:

1. **`google-chrome`** - Main wrapper (installed as `/usr/local/bin/google-chrome`)
   - Intercepts ALL Chrome calls (CLI, GUI launchers, desktop files)
   - Takes precedence over `/usr/bin/google-chrome` via PATH
   - Stores profiles locally in `/var/tmp/chrome-$USER/`
   - Detects and reuses existing sessions on the same host
   - Cleans up stale locks from crashed Chrome instances

2. **`chrome`** - Convenience wrapper (installed as `/usr/local/bin/chrome`)
   - Simply calls `google-chrome` with all arguments
   - Shorter command for CLI use

### Wrapper Usage

```bash
# Normal launch (uses local profile) - all equivalent
chrome
google-chrome

# Named profiles for isolation
chrome -p work
chrome --profile personal

# Open a URL
chrome https://example.com
```

### Desktop Entries

A PATH-based wrapper is not enough on its own. The `.desktop` files that
`google-chrome-stable` installs into `/usr/share/applications/` hardcode:

```
Exec=/usr/bin/google-chrome-stable %U
```

so anything launching Chrome through the desktop-entry layer bypasses the wrapper.
That layer is how nearly all URL opening happens — `xdg-open`, `exo-open`, `gio`,
and `xdg-desktop-portal`, the last being the *only* way a confined snap (Ubuntu's
Thunderbird, for one) can open a link at all. A snap cannot even see
`/usr/local/bin`, so pointing it directly at the wrapper can never work.

The symptom on an NFS-home system: clicking a link starts Chrome with no
`--user-data-dir`, so it lands on `~/.config/google-chrome` (on NFS, often holding
a stale `SingletonLock` from another host) rather than the local profile the running
browser uses. The URL cannot be handed to the existing window, so you get either a
failed launch or a second browser.

This module therefore installs two shadowing entries in
`/usr/local/share/applications/`:

| File | Purpose |
|------|---------|
| `google-chrome.desktop` | Menu entry; carries legacy default-browser settings |
| `com.google.Chrome.desktop` | The application ID `xdg-desktop-portal` resolves (`NoDisplay=true` so the menu shows one Chrome) |

`/usr/local/share` precedes `/usr/share` in `XDG_DATA_DIRS`, so same-named files
shadow Google's by desktop ID. Because they live in `/usr/local`, they also survive
`google-chrome-stable` package upgrades, which rewrite `/usr/share/applications/`.
Both entries set `TryExec`, so if the wrapper is ever removed the system falls back
to Google's originals rather than breaking.

Generated from the `google-chrome.desktop` template in this module by
`desktop-entries.sh`, which `setup` and `upgrade` both source.

**GUI launchers** (application menu, desktop files) automatically use the wrapper too.

### Snap Applications and the Portal

For a snap such as Thunderbird to open links at all, the host needs
`xdg-desktop-portal` and a backend (`xdg-desktop-portal-gtk` on XFCE) installed.
Add these to your `packages desktop` list — they are not pulled in reliably.

Snap Thunderbird also needs its own handler setting changed once per user profile,
since by default it tries to exec a helper path it cannot see from inside the
sandbox. With Thunderbird closed, set both `http` and `https` in
`~/.thunderbird/<profile>/handlers.json` to `"action": 4` (useSystemDefault) so it
hands the URL to the portal instead.

### Tradeoff

With the wrapper, bookmarks and passwords are stored locally (lost on reboot).
Mitigate with:
- **Chrome Sync**: Sign in to sync bookmarks/passwords to Google account
- **Manual backup**: Periodically copy `Bookmarks` file from profile

## Notes

- Chrome is only available for 64-bit (amd64) systems
- Upgrade with yamc: `yamc -h HOST -u root chrome upgrade`, or `apt upgrade google-chrome-stable` on the host

## Alternative: Chromium

If you prefer the open-source Chromium browser:

```bash
# Via snap (recommended on Ubuntu)
snap install chromium

# Or via apt (may be older version)
apt install chromium-browser
```

This module specifically installs Google Chrome, not Chromium.

