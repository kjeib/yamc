# xfce - XFCE Desktop Configuration Module

Configures an Ubuntu system for graphical boot with XFCE desktop environment.

## Prerequisites

- Ubuntu system with XFCE packages installed
- Run `yamc -h host -u root packages desktop` first to install packages
- Root access

## What This Module Does

1. **Installs lightdm-gtk-greeter** - Correct greeter for XFCE (not unity-greeter)
2. **Configures LightDM** - Sets `greeter-session=lightdm-gtk-greeter` and `user-session=xfce`
3. **Sets graphical.target** - System boots to GUI instead of text console
4. **Enables lightdm** - Display manager starts on boot
5. **Installs gdmflexiserver** - Helper script for screen lock (if provided in yamc.local)
6. **Enforces a single screen locker** - Installs the chosen locker and removes the others, so light-locker and xfce4-screensaver cannot both end up running
7. **Configures PAM** - Ensures gnome-keyring unlocks on login

## Usage

### Standard Setup (after packages)

```bash
# First install packages
yamc -h workstation -u root packages desktop

# Then configure graphical boot
yamc -h workstation -u root xfce
```

### In yamcity Profile

```bash
# yamc.local/profiles/workstation
-u root packages desktop
-u root xfce
-u root chrome
-u root cups
```

## Optional: gdmflexiserver Helper

If you want a screen lock + user switch helper (useful for multi-user systems),
create `yamc.local/xfce/gdmflexiserver`:

```bash
#!/bin/sh
# Lock screen and show login greeter for user switching
xflock4  # XFCE's built-in lock, or use xscreensaver-command -lock
dm-tool switch-to-greeter
```

This will be installed to `/usr/local/bin/gdmflexiserver`.

## Optional: Choosing the Screen Locker

The module installs one locker and removes the others, defaulting to
`xfce4-screensaver`. To choose a different one, put its package name on a
single line in `yamc.local/xfce/locker`:

```bash
echo xfce4-screensaver > yamc.local/xfce/locker
```

Recognized alternatives: `xfce4-screensaver`, `light-locker`, `xscreensaver`,
`gnome-screensaver`, `mate-screensaver`. The keeper is installed before the
others are removed, so a typo aborts the run rather than leaving the host
without any locker.

## Notes

- This module does NOT start lightdm immediately (would disconnect SSH session)
- Reboot the system or run `systemctl start lightdm` manually
- XFCE session will be available in lightdm's session selector

## Troubleshooting

### "Session ubuntu is not available" / Login fails

This happens if the wrong greeter or session is configured. Fix:
```bash
# Verify xfce session exists
ls /usr/share/xsessions/

# Check/create the config
cat /etc/lightdm/lightdm.conf.d/50-xfce.conf
# Should contain:
# [Seat:*]
# greeter-session=lightdm-gtk-greeter
# user-session=xfce

# Re-run the module to fix
yamc -h host -u root xfce
```

### Black screen after boot

Check if lightdm is running:
```bash
systemctl status lightdm
```

Check Xorg logs:
```bash
cat /var/log/Xorg.0.log | grep EE
```

### Wrong display manager

If another DM (gdm3) was installed, reconfigure:
```bash
dpkg-reconfigure lightdm
```

### Wrong greeter (unity-greeter instead of gtk-greeter)

```bash
apt install lightdm-gtk-greeter
# Then re-run xfce module to configure it
```

### Screen lock not working, or unlock takes 10-20 seconds

Usually means more than one locker is installed. `xfce4-session` *Recommends*
`light-locker | xfce4-screensaver | xscreensaver | gnome-screensaver |
mate-screensaver`, and apt satisfies that with the first alternative, so
light-locker arrives alongside whichever locker was actually requested. Both
autostart from `/etc/xdg/autostart`, and because both `.desktop` files carry
`NoDisplay=true`, neither appears in Settings > Session and Startup.

Check what is installed and what is running:
```bash
dpkg -l | grep -E 'light-locker|screensaver'
ps -ef | grep -E 'light-locker|screensaver' | grep -v grep
```

Re-running this module removes every locker except the chosen one:
```bash
yamc -h host -u root xfce
```

A slow unlock specifically indicates light-locker won. It draws no lock screen;
it VT-switches to a throwaway lightdm greeter, so each unlock pays a greeter
session teardown (logind `UserStopDelaySec`, 10s by default) plus a full modeset
on every display. `xfce4-screensaver` locks in place on the running X server.

An already-running locker survives package removal until the user logs out.

### Screen locks but the monitors never sleep

Lock timeouts and DPMS are per-user xfconf settings and are not managed by this
module. Check them from within the user's own session:
```bash
xfconf-query -c xfce4-screensaver -p /lock/enabled
xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-off
xset q | grep -A2 DPMS
```

