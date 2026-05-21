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

- [ ] **New hostless dispatch path** in `yamc` (like `init`): `yamc help [module]` does not require `-h`, SSH, SFTP, or `run_module` remote execution
- [ ] **Resolve resources root** (`-r`, `YAMC_RESOURCES`, or sibling `yamc.local/`) before invoking module help
- [ ] **`run_module_help(module)`** helper:
  - [ ] Set `RES_DIR` / `RES_BASE` using existing profile logic (`-p` if passed)
  - [ ] If `$MOD_DIR/help.loc` exists → source it locally (preferred)
  - [ ] Else if `$MOD_DIR/help` exists and is local-only → run or source per convention
  - [ ] Else → **fallback help**: list executable subfunctions (`setup`, `upgrade`, …) and `*.loc` peers; print 1–2 usage lines each; optional one-line pointer to `yamc/<module>/README.md`
- [ ] **Aggregate `yamc help` (no module arg)**:
  - [ ] Enumerate `yamc.local/<module>/` directories (sorted)
  - [ ] Intersect with installed modules under `yamc/` (skip stray dirs)
  - [ ] Handle profile dirs consistently (e.g. `dhcp.master/` → report as `dhcp` or list profiles — pick one rule and document)
  - [ ] Print section headers (`=== dhcp ===`); suppress noisy `[INFO]` during aggregate (or `YAMC_QUIET`)
  - [ ] Footer optional: hosts from `~/.yamc/*.env` (“initialized hosts”) — not primary content
- [ ] **Parse order / collisions**:
  - [ ] Ensure `help` is recognized before “unknown subfunc → setup arg” fallback
  - [ ] Document in main `show_usage()` and `yamc/README.md`
- [ ] **Tests / smoke** (manual checklist): `yamc help`, `yamc help dhcp`, `yamc help nonexistent`, module without `help.loc`

### Phase 2 — Module help contract

- [ ] Document **help.loc contract** in `yamc/README.md` (and short note in `CONTRIBUTING.md`):
  - Local only; reads `$RES_DIR`; prints site-specific facts + suggested `yamc -h …` commands
  - Keep output short (no full config dumps)
  - Cross-link: site layout in help; subcommand syntax in help or fallback
- [ ] **Fallback content rules** for modules without `help.loc`:
  - Subfunction list from filesystem scan
  - Generic example: `yamc -h <host> [-u root] <module> [subfunction]`
- [ ] Decide whether **`yamc help <module>`** runs for modules **without** `yamc.local/` (recommend: yes — README/fallback only; aggregate still yamc.local-only)

### Phase 3 — `dhcp` help processor

- [ ] Add `yamc/dhcp/help.loc` (local-only)
- [ ] Print **`DHCP_SERVERS`** from `yamc.local/dhcp/cluster.conf` (source of truth)
- [ ] List key files: `hosts.conf`, `dhcpd.conf`, `cluster.conf`
- [ ] **Actionable one-liners** (from site workflow):
  - `yamc -h mp14 -u root dhcp watch` / mp16
  - `dhcp-cluster-edit`, `dhcp-cluster-deploy` (if present in `yamc.local/bin/`)
  - `yamc -h <server> -u root dhcp deploy`
- [ ] Note redundant pair mp14/mp16 if relevant
- [ ] Optional: `yamc/dhcp/README.md` — add “Help: `yamc help dhcp`” line (no duplicate cluster list in README long-term)

### Phase 4 — `bind9` help processor

- [ ] Add `yamc/bind9/help.loc` (local-only)
- [ ] Print **`DNS_SERVERS`** from `yamc.local/bind9/cluster.conf` (or equivalent)
- [ ] List zones / key paths under `yamc.local/bind9/` (zones dir, `named.conf` snippet path)
- [ ] **Actionable one-liners**: deploy command, which hosts run bind, common `yamc -h … bind9` invocations
- [ ] Align wording with `yamc.local/bind9/README.md`; avoid duplicating full zone tables in help output
- [ ] Optional: README cross-link to `yamc help bind9`

### Phase 5 — Polish (later)

- [ ] **`yamc help --list`**: module names only
- [ ] **`yamc <module> help`** alias to `yamc help <module>`
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
