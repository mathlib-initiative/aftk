# aftk

AFTK provides the `aftk` Lake executable for dependency analysis of Lean declarations, technical-debt detection, and fast daemon-backed diagnostics for Lean files. Add AFTK as a dependency of the Lean project you want to inspect:

```toml
[[require]]
name = "aftk"
git = "https://github.com/mathlib-initiative/aftk"
rev = "main"
```

Then run AFTK through that project's Lake environment. This gives AFTK the project's source paths, compiled modules, dependencies, and Lake configuration:

```bash
lake exe aftk deps [options] <module> <declaration>
lake exe aftk rdeps [options] <module> <declaration>
lake exe aftk tech-debt [options] [module <module>|library <library>|package [<package>]]

lake exe aftk diagnostics [options] <file>
lake exe aftk probe [options] <module-or-file>
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

`probe` temporarily replaces an end-exclusive, 1-based source range in the worker's in-memory document, waits for Lean diagnostics, optionally queries goals, and restores the current file from disk before returning. Replacement text can be passed safely through standard input:

```bash
printf 'by\n  assumption' | lake exe aftk probe A.B.C \
  --range 42:15-44:8 --stdin --goals-at 43:3
```

The JSON result contains `accepted`, candidate diagnostics, optional tactic/term goals, and `restored`. `accepted` means that Lean produced no error diagnostics; it is independent of the outer daemon-protocol `ok` field. Probes never write the replacement to disk, and requests for the same file are serialized so diagnostics and goal queries cannot observe a temporary candidate.

The daemon tracks each worker's import closure and local project source imports. If a tracked dependency changes on disk, the next `diagnostics`, `probe`, or `goals` call restarts the affected worker before elaborating. `open` is an optional warmup hint. `restart` reloads one file worker and its imports/dependencies. `close` releases one file worker. `--transient` / `--close-after` runs diagnostics/probe/goals and releases the worker immediately.

Resource management is built in for multi-agent use:

| Environment variable | Default | Meaning |
|---|---:|---|
| `AFTK_MAX_WORKERS_PER_PROJECT` | `8` | Per-project worker cap; LRU non-busy workers are evicted before opening more. |
| `AFTK_GLOBAL_MAX_WORKERS` | `50` | Global cap on this effective user's `lean --worker` processes; new opens are rejected if local eviction cannot get under the cap. |
| `AFTK_WORKER_IDLE_MS` | `600000` | Idle-worker TTL before automatic close. |
| `AFTK_DAEMON_IDLE_MS` | `300000` | Empty daemon TTL before automatic exit. |
| `AFTK_DEFAULT_LEASE_MS` | unset | Default lease for workers opened without `--ttl-ms`. |
| `AFTK_MEMORY_SOFT_LIMIT_MIB/GIB` | unset | Soft PSS cap across this effective user's Lean workers; local LRU workers are evicted opportunistically. |
| `AFTK_MEMORY_HARD_LIMIT_MIB/GIB` | unset | Hard PSS cap across this effective user's Lean workers; new opens are rejected if over budget. |
| `AFTK_WORKER_MEMORY_ESTIMATE_MIB` | `6500` | Estimated memory cost of a new Mathlib-heavy worker for hard-limit checks. |

`status` reports worker count, lease metadata, per-worker RSS/PSS, daemon memory, and effective-user-wide Lean-worker memory. `gc` closes expired/idle workers now; `close --all` closes all non-busy workers. `shutdown` stops the project daemon and all workers; `shutdown --all-projects` stops all discoverable AFTK daemons owned by the current effective user. Daemon metadata is stored in `.lake/aftk/server.json`.

Run `lake exe aftk --help` or `lake exe aftk <command> --help` for full help.

For large imports such as Mathlib, prefer using module filters with `rdeps`.

## Technical-debt detection

`tech-debt` elaborates Lean modules, traverses their info trees, and reports configured technical-debt markers with 1-based source locations. Every invocation must select findings explicitly with `--markers`, `--all-markers`, or `--option`; there are no default markers.

```bash
lake exe aftk tech-debt --markers maxHeartbeats,erw module A.B.C
lake exe aftk tech-debt --all-markers library MyLibrary
lake exe aftk tech-debt --markers sorry,axiom package my_package
lake exe aftk tech-debt --markers deprecated                 # root package
lake exe aftk tech-debt --markers simpNF A.B.C --jsonl       # module shorthand
lake exe aftk tech-debt --option linter.style.* module A.B.C
lake exe aftk tech-debt --jobs 2 --all-markers library MyLibrary
```

`--markers` accepts a comma-separated list and may be repeated. Supported marker names are `maxHeartbeats`, `maxRecDepth`, `maxSynthPendingDepth`, `unlockLimits`, `backwardOption`, `linterFlexible`, `linterOverlappingInstances`, `linterAuxLemma`, `linterDeprecated`, `linterUnused`, `autoImplicit`, `simpVarHead`, `developmentOption`, `longFile`, `erw`, `simpInstances`, `dsimpInstances`, `adaptationNote`, `simpNF`, `exposePublic`, `finCommRing`, `finNatCast`, `sorry`, `deprecated`, and `axiom`. Run `lake exe aftk help tech-debt` for their descriptions.

`--option` may also be repeated. It accepts either an exact option name or a namespace ending in `.*`; for example, `--option linter.style.*` selects every `set_option` under `linter.style`. These findings use kind `option`. A matching override can produce both its built-in marker and `option` when both selections are requested.

Library scans use Lake's `modules` facet, so they follow the library's configured roots and local
imports. Package scans combine those facet results for every Lean library in the package and add
the root module of each configured Lean executable. Multi-module scans run each module in an
isolated process so completed imports are released, with bounded concurrency controlled by
`--jobs <n>` (default 1). Findings and module failures are emitted in deterministic module order.
An incomplete scan exits nonzero after retaining findings from successful modules; use
`--allow-partial` to explicitly accept partial success.

The default output is tab-separated:

```text
<file>:<line>:<column>\t<kind>\t<description>[\t<detail>]
```

Every option-derived finding includes its reprinted name and value as `detail`. JSONL output also includes its syntactic `scope` (`command`, `term`, or `tactic`); non-option findings omit both fields.
JSONL records have `type` set to `finding` or `error`. Error records include the failed `module`,
the `phase` (`source-resolution`, `parse`, `header`, `elaboration`, or `internal`), and a
`diagnostic`. In the default text format, module failures are written to standard error.
