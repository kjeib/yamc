# YAMC Agent Instructions

Context for AI agents working on the YAMC codebase.

## Quick Reference

| Document | Content |
|----------|---------|
| [README.md](README.md) | Full documentation, usage, architecture |
| [LOCAL.md](LOCAL.md) | Local resources and profiles (`-p`, `-r` flags, `RES_DIR`) |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Module development guide, patterns, debugging |
| [BACKUP.md](BACKUP.md) | Offsite encrypted backup: design, threat model, runbooks |

## Key Files

| File | Purpose |
|------|---------|
| `yamc` | Main script - SSH, SSHFS mounting, module execution |
| `yamcity` | Batch automation from profile files |
| `install.sh` | System-wide installer |

## Target Platform

- **Primary**: Ubuntu (Noble 24.04)
- **Secondary**: Other Debian-based distributions
- **NOT**: Fedora/RHEL - do not assume their paths or commands

### Ubuntu Service Paths

| Service | Config Dir | Data Dir | Service Name |
|---------|------------|----------|--------------|
| BIND | `/etc/bind/` | `/var/lib/bind/` | `bind9` |
| PostgreSQL | `/etc/postgresql/` | `/var/lib/postgresql/` | `postgresql` |
| Docker | `/etc/docker/` | `/var/lib/docker/` | `docker` |

Use `apt-get`, not `dnf` or `yum`.

## Environment Variables

Scripts receive these variables (see [README.md](README.md#environment-variables) and [LOCAL.md](LOCAL.md#available-to-scripts) for details):

**Module variables**: `MOD_DIR`, `MOD_TMP`, `ssh_user`, `tgt_host`

**Resource variables**: `RES_DIR`, `RES_BASE`, `res_profile`

## Code Style

- `#!/bin/bash` and `set -e` at script start
- Quote variables: `"$variable"`
- Lowercase for user params: `$domain`, `$version`
- UPPERCASE for constants: `BIND_CONF_DIR`

See [CONTRIBUTING.md](CONTRIBUTING.md#variable-naming-conventions) for full conventions.

## Module Structure

```
module/
├── setup            # Remote script (required)
├── setup.loc        # Local prep (optional)
├── edit             # Subfunction (optional)
├── edit.loc         # Local edit (optional)
└── README.md        # Documentation
```

See [CONTRIBUTING.md](CONTRIBUTING.md#module-development-process) for development guide.

## What to Avoid

- Don't hardcode hostnames, IPs, or domain names in module scripts
- Don't put private configs in yamc repo (use `yamc.local/`)
- Don't assume Fedora/RHEL paths
- Don't modify `yamc.local/` files without user consent
- Don't create modules without `setup` script
