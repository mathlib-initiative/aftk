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
lake exe aftk rdeps [options] library <library> <declaration>
lake exe aftk rdeps [options] package <package> <declaration>
lake exe aftk rdeps [options] library <library> --stdin --jsonl
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

The first positional module is the import scope used to build the dependency graph. To query a
private declaration from one of its imported submodules without shrinking that scope, pass the
defining module separately:

```bash
lake exe aftk rdeps Root Namespace.privateLemma --defined-in Defining.Submodule
```

This makes a result row's `<module>` and `<declaration>` fields directly reusable as
`--defined-in <module>` and `<declaration>`. Use `--resolve-suffix` for explicit component-wise
suffix discovery; a unique match is queried, while ambiguous matches fail with sorted candidates.
Failed exact lookups also suggest up to 20 candidates without selecting one.

JSONL result rows preserve `module` and `declaration` and add `definingModule`, `scopeModule`, and
a structured `target`. Lookup failures are emitted as a JSONL `error` record with a stable code,
the requested target, candidate count, truncation flag, and structured candidates.

Explicit query scopes remove the need for an umbrella source module. `module` imports one module;
`library` imports the modules returned by that Lake library's `modules` facet; and `package` imports
all library modules and executable roots configured for the package. This follows custom `roots`
and `srcDir` settings. Use `package . <declaration>` for a single query against the root package:

```bash
lake exe aftk rdeps module My.Module Namespace.target --jsonl
lake exe aftk rdeps library MyLibrary Namespace.target --jsonl
lake exe aftk rdeps package MyPackage Namespace.target --jsonl
lake exe aftk rdeps package . Namespace.target --jsonl
```

For many targets, `--stdin --jsonl` accepts one nonempty declaration name per line. The selected
environment is imported once, and declaration lookup and the reverse-dependency graph are reused:

```bash
printf '%s\n' Namespace.first "Namespace.name'" Namespace.missing | \
  lake exe aftk rdeps library MyLibrary --stdin --jsonl
```

Each output line is one complete query record with its input, exact scope/import roots, resolved
target, results, counts, and a `status` of `ok`, `leaf`, `unresolved`, or `error`. Input ordering and
result ordering are deterministic. Any unresolved/error query makes the command fail after all
records are emitted; `--allow-partial` opts into a successful exit for partial batches. Empty output
is therefore never used to represent a leaf in scoped JSONL mode.

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

`probe` temporarily replaces source text in the worker's in-memory document, waits for Lean diagnostics, optionally queries goals, and restores the current file from disk before returning. Replacement text can be passed safely through standard input. Explicit `--range` endpoints and `--to-eol` positions are 1-based and use LSP UTF-16 columns:

```bash
printf 'by\n  assumption' | lake exe aftk probe A.B.C \
  --range 42:15-44:8 --stdin --goals-at 43:3

printf '  exact h' | lake exe aftk probe A.B.C --line 61 --stdin
printf '  exact fun x => x' | lake exe aftk probe A.B.C --lines 61:63 --stdin
printf 'simp' | lake exe aftk probe A.B.C --to-eol 61:3 --stdin
```

`--line N` replaces that line's content without requiring its UTF-16 length and preserves its
line terminator. `--lines A:B` replaces lines `A` through `B` inclusive: separators inside the
block are replaced, while line `B`'s terminator is preserved. `--to-eol L:C` replaces from that
UTF-16 boundary through the line content and also preserves the terminator. These selectors are
mutually exclusive with one another and with `--range`/`--at`. A trailing terminator creates a
selectable final empty logical line. CRLF is normalized to LF inside the Lean worker, while the
on-disk file remains byte-for-byte untouched.

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

Every option-derived finding includes its reprinted name and value as `detail`. JSONL output also
includes separate `optionName` and `optionValue` fields and its syntactic `scope` (`command`,
`term`, or `tactic`); non-option findings omit those fields. The default TSV format is unchanged.

Every JSONL finding includes `declarations`, an array of source-facing enclosing declaration
names. Term and tactic findings normally have one owner. Wrapped or grouped commands can have
multiple owners, while module-level findings use an empty array. Private declarations are shown by
their user-facing name; the finding's `module` keeps that name unambiguous across modules.

`key` is a machine-readable semantic identity and `keyVersion` identifies its format (currently
version 1). Version-one keys are based on the module, declaration array (or module scope), kind,
structured marker detail, and an ordinal among equivalent occurrences in that declaration/scope.
They deliberately exclude file paths and source ranges, so unrelated line movement and inserting
an unrelated declaration do not change existing keys. Renaming an owning declaration or inserting
an equivalent earlier occurrence within the same declaration/scope can change a key. Consumers
should treat the key as opaque and partition persisted state by `keyVersion`.

JSONL records have `type` set to `finding` or `error`. Error records include the failed `module`,
the `phase` (`source-resolution`, `parse`, `header`, `elaboration`, or `internal`), and a
`diagnostic`. In the default text format, module failures are written to standard error.
