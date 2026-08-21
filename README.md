# aftk

AFTK provides the `aftk` Lake executable for dependency analysis of Lean declarations and fast, daemon-backed diagnostics for Lean files.

```bash
lake exe aftk deps [options] <module> <declaration>
lake exe aftk rdeps [options] <module> <declaration>
lake exe aftk tech-debt [options] [module <module>|library <library>|package [<package>]]

lake exe aftk diagnostics [options] <file>
lake exe aftk goals [options] <module> <line> <column>
lake exe aftk open [options] <file>
lake exe aftk restart <file>
lake exe aftk close <file>
lake exe aftk close --idle
lake exe aftk close --all
lake exe aftk gc [--aggressive]
lake exe aftk status
lake exe aftk shutdown [--force|--all-projects]
```

By default, both commands print tab-separated rows:

```text
<module>\t<declaration>
```

Use `--jsonl` to print one JSON object per result:

```json
{"module":"Mathlib...","declaration":"..."}
```

Use `--module` / `--modules` to restrict output to exact modules or module prefixes:

```bash
lake exe aftk deps Mathlib.Data.Nat.Basic Nat.gcd --module 'Mathlib.Algebra.*'
lake exe aftk rdeps Mathlib.Data.Nat.Basic Nat.gcd --modules 'Mathlib.Algebra.*,Mathlib.Order.*'
```

## File diagnostics daemon

`diagnostics` starts an invisible daemon for the current Lake project root if needed, auto-opens the file if needed, sends file changes to a persistent Lean worker, waits for Lean diagnostics, and prints one JSON response object.

```bash
lake exe aftk diagnostics A/B/C.lean
lake exe aftk diagnostics A/B/C.lean --refresh
lake exe aftk diagnostics A/B/C.lean --transient
lake exe aftk goals A.B.C 12 5
lake exe aftk goals A.B.C 12:5
lake exe aftk open --ttl-ms 600000 A/B/C.lean
```

`goals` uses the same daemon/worker lifecycle and returns both Lean LSP plain tactic goals (`tacticGoals`) and plain term goals (`termGoal`) at a 1-based line/column in the given module.

The daemon tracks each worker's import closure and local project source imports. If a tracked dependency changes on disk, the next `diagnostics` or `goals` call restarts the affected worker before elaborating. `open` is an optional warmup hint. `restart` reloads one file worker and its imports/dependencies. `close` releases one file worker. `--transient` / `--close-after` runs diagnostics/goals and releases the worker immediately.

Resource management is built in for multi-agent use:

| Environment variable | Default | Meaning |
|---|---:|---|
| `AFTK_MAX_WORKERS_PER_PROJECT` | `8` | Per-project worker cap; LRU non-busy workers are evicted before opening more. |
| `AFTK_GLOBAL_MAX_WORKERS` | `50` | Global cap on visible `lean --worker` processes; new opens are rejected if local eviction cannot get under the cap. |
| `AFTK_WORKER_IDLE_MS` | `600000` | Idle-worker TTL before automatic close. |
| `AFTK_DAEMON_IDLE_MS` | `300000` | Empty daemon TTL before automatic exit. |
| `AFTK_DEFAULT_LEASE_MS` | unset | Default lease for workers opened without `--ttl-ms`. |
| `AFTK_MEMORY_SOFT_LIMIT_MIB/GIB` | unset | Soft global Lean-worker PSS cap; local LRU workers are evicted opportunistically. |
| `AFTK_MEMORY_HARD_LIMIT_MIB/GIB` | unset | Hard global Lean-worker PSS cap; new opens are rejected if over budget. |
| `AFTK_WORKER_MEMORY_ESTIMATE_MIB` | `6500` | Estimated memory cost of a new Mathlib-heavy worker for hard-limit checks. |

`status` reports worker count, lease metadata, per-worker RSS/PSS, daemon memory, and global Lean-worker memory. `gc` closes expired/idle workers now; `close --all` closes all non-busy workers. `shutdown` stops the project daemon and all workers; `shutdown --all-projects` stops all discoverable AFTK daemons for the current user. Daemon metadata is stored in `.lake/aftk/server.json`.

Run `lake exe aftk --help` or `lake exe aftk <command> --help` for full help.

For large imports such as Mathlib, prefer using module filters with `rdeps`.

## Technical-debt detection

`tech-debt` elaborates Lean modules, traverses their info trees, and reports recognized technical
debt with 1-based source locations. It currently detects commands that set `maxHeartbeats` and
uses of Core Lean's `erw` tactic. Scans can target one module, one configured Lean library, or all
Lean targets in a package:

```bash
lake exe aftk tech-debt module A.B.C
lake exe aftk tech-debt library MyLibrary
lake exe aftk tech-debt package my_package
lake exe aftk tech-debt                 # root package
lake exe aftk tech-debt A.B.C --jsonl  # module compatibility shorthand
```

Library scans use Lake's `modules` facet, so they follow the library's configured roots and local
imports. Package scans combine those facet results for every Lean library in the package and add
the root module of each configured Lean executable.

The default output is tab-separated:

```text
<file>:<line>:<column>\t<kind>\t<description>
```
