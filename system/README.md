# system - Generic System File Deployment Module

Deploys system configuration files from `yamc.local/system/<layer>/` to the
remote system, applies sed edits, and runs post-deployment hooks.

## Layers

Configuration is organised into **additive layers**. Each file belongs to
exactly one layer, and a host receives the union of the layers it asks for:

```bash
yamc -h hostname -u root system                    # 'base' (the default)
yamc -h hostname -u root system base desktop       # several at once
```

Layers are named by **what must be true for their contents to do anything**,
which makes membership self-evident when adding a file:

| Layer | Precondition |
|---|---|
| `base` | A POSIX shell. Safe on any host, headless included. |
| `desktop` | X11 / XFCE |
| `fleet` | The LAN, with other hosts reachable |
| `pki` | You want the site CA trusted here |
| `sshpolicy` | You accept the `sshd_config` relaxation it applies |

**Why layers rather than profiles.** yamc profiles (`system.foo`) are
standalone — LOCAL.md is explicit that there is no inheritance from the base.
Overlapping profiles would therefore mean duplicated copies of the same file
that drift apart. Layers compose instead, so nothing is ever duplicated. This
mirrors how the `packages` module takes list names.

A minimal or untrusted host — an offsite backup box, say — takes `base` alone
and picks up nothing that assumes a desktop, the LAN, or your trust anchors.

## Directory Structure

```
yamc.local/system/
├── base/
│   ├── etc/                     # Files to COPY (mirrors filesystem)
│   │   ├── issue
│   │   └── profile.d/
│   │       ├── local.sh
│   │       └── umask.sh
│   ├── usr/local/bin/timetest
│   ├── __edits__/               # Sed scripts to apply
│   │   ├── bashrc.sed
│   │   └── keyboard.sed
│   └── __hooks__/               # Post-deploy scripts
│       └── keyboard.sh
├── desktop/
│   ├── etc/X11/xorg.conf.d/00-keyboard.conf
│   ├── etc/profile.d/desktop.sh
│   ├── usr/local/bin/{libreoffice,become,xloads}
│   └── __hooks__/{firefox-wm-integration.sh,xfce-snap-launchers.sh}
├── fleet/
│   └── usr/local/bin/{wake,susp}
├── pki/
│   ├── usr/local/share/ca-certificates/site.crt
│   └── __hooks__/ca-certificates.sh
└── sshpolicy/
    ├── __edits__/sshd.sed
    └── __hooks__/sshd.sh
```

Each layer has its own optional `__edits__/` and `__hooks__/`. Staged files are
prefixed with the layer name internally, so two layers may both ship an
`sshd.sed` without one clobbering the other.

### Backward compatibility

A pre-layer tree — files sitting directly under `yamc.local/system/` with no
layer directories — is detected and treated as a single layer, with a notice.
Existing resource trees keep working un-migrated.

## Usage

```bash
yamc -h hostname -u root system [layer ...]
```

## File Copies

Files in `yamc.local/system/<layer>/` (excluding `__*__` directories) are copied
to the same path on the remote system. Directory structure is preserved.

**Permissions:**
- Files in `*/bin/*`, `*/sbin/*`, or `*.sh` → mode 755
- All other files → mode 644
- All files owned by root:root

## Sed Edits

Place `.sed` files in `yamc.local/system/__edits__/`. Each file must have a
`#@target:` header on the first line specifying the file to edit:

```bash
# sshd.sed
#@target: /etc/ssh/sshd_config

# Add AcceptEnv for EDITOR
/AcceptEnv EDITOR_OVERRIDE/d
$ a AcceptEnv EDITOR_OVERRIDE
$ a PermitUserEnvironment yes
```

The sed commands are applied to the target file. Original is backed up to `.orig`.

## Hooks

Place executable scripts in `yamc.local/system/__hooks__/`. They run after all
copies and edits are complete. Use for service restarts, etc.

```bash
# __hooks__/sshd.sh
#!/bin/bash
systemctl restart sshd
```

## Examples

### Global Shell Configuration

```
yamc.local/system/
└── etc/
    └── profile.d/
        └── local.sh     # Custom aliases, PATH, etc.
```

### Keyboard: Caps Lock → Ctrl

```
yamc.local/system/
└── etc/
    └── X11/
        └── xorg.conf.d/
            └── 90-caps-ctrl.conf
```

### SSH Customization

```
yamc.local/system/
├── __edits__/
│   └── sshd.sed         # #@target: /etc/ssh/sshd_config
└── __hooks__/
    └── sshd.sh          # systemctl restart sshd
```

## Examples

### Keyboard Remapping (CapsLock → Control)

Keyboard remapping configuration for both GUI and console:

**For X11/GUI sessions:**
```
yamc.local/system/etc/X11/xorg.conf.d/00-keyboard.conf
```

**For console (text mode):**
```
yamc.local/system/__edits__/keyboard.sed        # Edits /etc/default/keyboard
yamc.local/system/__hooks__/keyboard.sh         # Applies with setupcon
```

### Shell Environment for GUI Terminals

By default, GUI-launched terminals (xterm, etc.) don't source `/etc/profile.d/` scripts.
This causes aliases and environment from `/etc/profile.d/local.sh` to be missing.

**Fix:**
```
yamc.local/system/__edits__/bashrc.sed          # Makes /etc/bash.bashrc source profile.d/
```

This ensures non-login shells (GUI terminals) get the same environment as login shells (SSH).

### LibreOffice NFS-Safe Wrapper

For systems with NFS-mounted home directories, LibreOffice has locking conflicts across machines.

**Solution:**
```
yamc.local/system/usr/local/bin/libreoffice    # Wrapper intercepts all LO calls
yamc.local/system/etc/profile.d/local.sh       # Aliases: writer, calc, etc.
```

The wrapper is installed as `/usr/local/bin/libreoffice` (takes precedence over `/usr/bin/libreoffice`)
and redirects all LibreOffice instances to use a local profile in `/var/tmp/`, avoiding NFS locks.
This works for both CLI launches and GUI menu launches.

## Notes

- Edits are applied after copies, so you can copy a base file and then edit it
- Hooks run in alphabetical order
- Target files for edits must already exist on the system
- Backups are only created once (won't overwrite `.orig` on re-run)

## Caution: Idempotent Sed Scripts

To ensure the module can be run multiple times safely, **always delete before appending**
in your sed scripts:

```bash
#@target: /etc/some/config

# GOOD: Delete existing lines first, then append
/MyCustomSetting/d
$ a\
MyCustomSetting=value

# BAD: Just appending will add duplicate lines on each run
$ a\
MyCustomSetting=value
```

The pattern `delete → append` ensures running the module twice produces the same result.

