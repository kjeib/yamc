# YAMC Development Status

Tracking cross-cutting yamc tooling work (public repo). Site-specific deployment status remains in `yamc.local/STATUS.md`.

---

## Refactor: Module `help` command

Planned work to add local, module-owned help and a top-level aggregator. Uses **`help`** (not `info`) as the subcommand name. Behavior matches the earlier “info mode” design: declarative site facts + usage, but exposed as **`help`**.

**CLI (target — do not overload `-h`, which is hostname today):**

```bash
yamc help              # all modules with yamc.local/<module>/ (aggregate)
yamc help dhcp         # one module
yamc help bind9
```

Optional symmetry: `yamc dhcp help` → same as `yamc help dhcp` (decide in implementation).

---

### Phase 1 — Generic yamc core

- [x] **New hostless dispatch path** in `yamc` (like `init`): `yamc help [module]` does not require `-h`, SSH, SFTP, or `run_module` remote execution
- [x] **Resolve resources root** (`-r`, `YAMC_RESOURCES`, or sibling `yamc.local/`) before invoking module help
- [x] **`run_module_help(module)`** helper:
  - [x] Set `RES_DIR` / `RES_BASE` using existing profile logic (`-p` if passed)
  - [x] If `$MOD_DIR/help.loc` exists → source it locally (preferred)
  - [x] Else → **fallback help**: list executable subfunctions (`setup`, `upgrade`, …) and `*.loc` peers; print module path, resources, README pointer
- [x] **Aggregate `yamc help` (no module arg)**:
  - [x] Enumerate `yamc.local/<module>/` directories (sorted)
  - [x] Intersect with installed modules under `yamc/` (skip stray dirs)
  - [x] Handle profile dirs consistently — `dhcp.master/` is reduced to base name `dhcp` and listed once
  - [x] Print section headers (`=== dhcp ===`); help path does not emit `[INFO]` lines
- [x] **Parse order / collisions**:
  - [x] `help` is recognized before any `module/subfunc` parsing (both as `yamc help …` and `yamc <module> help`)
  - [x] Documented in main `show_usage()` and `yamc/README.md`
- [x] **Tests / smoke**: `yamc help`, `yamc help dhcp`, `yamc help bind9`, `yamc help nonexistent`, `yamc help chrome` (no help.loc), `yamc dhcp help` (symmetric), `yamc -r <empty> help dhcp` (degraded)

### Phase 2 — Module help contract

- [x] Document **help.loc contract** in `yamc/README.md` (new "Module Help" section under Modules):
  - Local only; reads `$RES_DIR`; prints site facts + suggested commands
  - Keep output short (no full config dumps)
  - Inputs: `MOD_DIR`, `RES_DIR`, `RES_BASE`, `YAMC_MODULE`, `INSTALL_DIR`, `RESOURCES_ROOT`
- [x] **Fallback content rules** for modules without `help.loc`:
  - Subfunction list from filesystem scan (excludes `*.md`, `*.env`, `*.conf`, etc.)
  - Generic example: `yamc -h <host> [-u <user>] <module> [subcommand]`
- [x] **Decision**: `yamc help <module>` works for any installed module (with or without `yamc.local/`); aggregate is filtered to modules with `yamc.local/<module>/`

### Phase 3 — `dhcp` help processor

- [x] Added `yamc/dhcp/help.loc` (local-only, sourced under set -e tolerant)
- [x] Prints **`DHCP_SERVERS`** sourced from `yamc.local/dhcp/cluster.conf`
- [x] Lists key files: `cluster.conf`, `dhcpd.conf`, `hosts.conf`, `README.md` (only those present)
- [x] **Actionable one-liners** generated per server:
  - `yamc -h <s> -u root dhcp watch` for each cluster member
  - `yamc -h <first> -u root dhcp deploy`
  - `dhcp-cluster-edit` / `dhcp-cluster-deploy` (only when `yamc.local/bin/*` exists)
- [x] Notes redundant-pair behavior when ≥2 servers
- [ ] Optional: `yamc/dhcp/README.md` — add "Help: `yamc help dhcp`" line (deferred; README already comprehensive)

### Phase 4 — `bind9` help processor

- [x] Added `yamc/bind9/help.loc` (local-only)
- [x] Prints **`DNS_SERVERS`** from `yamc.local/bind9/cluster.conf`
- [x] Lists key paths: `cluster.conf`, `named.conf`, `named.local`, and zone file names under `zones/` (skips `*.bak`)
- [x] **Actionable one-liners** generated per server: watch + deploy
- [x] Cluster helper script suggestions (`bind9-cluster-edit`, `bind9-cluster-deploy`) when present
- [x] Zone-serial reminder appended
- [ ] Optional: README cross-link to `yamc help bind9` (deferred)

### Phase 5 — Polish (later)

- [ ] **`yamc help --list`**: module names only
- [x] **`yamc <module> help`** alias to `yamc help <module>` (implemented in dispatcher)
- [ ] **Run history** (separate effort): optional `~/.yamc/history.log` on successful module runs — not required for help v1
- [ ] **Live help** (`yamc -h mp14 bind9 help --live`): SSH probes — defer; avoid conflating with local help v1
- [ ] Additional modules with site config: `cups`, `nfs-client`, … — after dhcp/bind9 pattern is stable

---

## Design notes (locked for this refactor)

| Topic | Decision |
|-------|----------|
| Command name | **`help`**, not `info` |
| Host flag | **Keep `-h` = hostname**; do not use `-h dhcp` for help |
| Help vs site facts | **`help` includes site facts** for modules with `yamc.local` (mp14/mp16 style); no separate `info` command planned |
| Aggregate scope | **`yamc help`** → modules with `yamc.local/<module>/` only |
| Single module | **`yamc help dhcp`** → `help.loc` or generic fallback |
| Execution | **No SSH** for help path |
| Maintenance | **Single source**: `cluster.conf` etc. in help.loc; README points to `yamc help <module>` |

---

## Out of scope (this refactor)

- Changing existing module subfunction behavior (`setup`, `deploy`, `watch`, …)
- Remote “what is running on host” discovery (future `--live` if ever)
- Replacing `yamc.local/STATUS.md` host/module matrix (can shrink later if help is sufficient)
