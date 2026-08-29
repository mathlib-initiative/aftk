---
name: aftk
description: Use `lake exe aftk` in a Lean 4 project that depends on aftk — to inventory technical debt semantically (set_option overrides, erw, sorry, deprecated, axioms …) with stable per-finding keys, to answer "who depends on this declaration?" / "is this safe to delete?" with a declaration-level dependency graph and explicit per-query status, and to iterate on a proof through a warm Lean worker (goals, in-memory probes) instead of cold re-elaboration. Read this before running any aftk command.
---

# aftk — dependency analysis, technical debt, and a proof daemon for Lean projects

aftk is one Lake executable with three independent capabilities. Everything runs **from the
consuming project's root** through that project's Lake environment, which is how aftk learns the
project's source roots, built `.olean`s, dependencies and `[leanOptions]`:

| capability | commands | what it needs |
|---|---|---|
| technical-debt scan (elaborator info trees) | `tech-debt` | an up-to-date `lake build` of the scanned modules' imports |
| declaration dependency graph | `deps`, `rdeps` | built `.olean`s of the scope you name |
| persistent Lean worker daemon | `diagnostics`, `goals`, `probe`, `open`, `restart`, `close`, `gc`, `status`, `shutdown` | nothing extra; state lives in `.lake/aftk/` |

Setup, if the project does not have it yet (then `lake exe aftk --help` builds it):

```toml
[[require]]
name = "aftk"
git = "https://github.com/mathlib-initiative/aftk"
rev = "main"
```

## Cheat-sheet

```bash
lake exe aftk --help                                  # `lake exe aftk help <cmd>` for each command
lake exe aftk tech-debt --jobs 4 --all-markers --jsonl library MyLib          # whole library
lake exe aftk tech-debt --markers backwardOption,erw,sorry module A.B.C       # one module
lake exe aftk tech-debt --option 'linter.style.*' --jsonl package .           # any option override
lake exe aftk rdeps library MyLib Full.Decl.Name --jsonl                      # who uses it (transitively)
printf '%s\n' A.b C.d | lake exe aftk rdeps library MyLib --stdin --jsonl     # many, one environment
lake exe aftk deps  module A.B.C Full.Decl.Name --modules 'MyLib.*'           # what it uses
lake exe aftk diagnostics path/to/File.lean [--transient]                     # errors/warnings as JSON
lake exe aftk goals <A.B.C | path/to/File.lean> <line> <col>                  # tactic/term goals (1-based)
printf '<replacement>' | lake exe aftk probe <A.B.C | path/to/File.lean> --line 61 --stdin [--goals-at 61:3]
lake exe aftk status; lake exe aftk gc; lake exe aftk shutdown
```

`tech-debt`, `deps` and `rdeps` print TSV by default and one JSON object per line with `--jsonl`
(`tech-debt`: `<file>:<line>:<col>\t<kind>\t<description>[\t<detail>]`; `deps`/`rdeps`:
`<module>\t<declaration>`). The daemon commands always print exactly one JSON response object —
`{"ok":true,"result":…}` or `{"ok":false,"error":…}`, exit code 0 iff `ok` — and do not take
`--jsonl`. Positions are **1-based** in line and column. `diagnostics`/`open`/`restart`/`close`
take a *file path*; `goals` and `probe` accept either a module name or a `.lean` path.

**Scopes.** `tech-debt` and `rdeps` take an explicit scope: `module <M>` (one module),
`library <L>` (the Lake library's `modules` facet — follows custom `roots`/`srcDir`), or
`package [<P>]` (`package .` = the root package). Prefer `library`/`package` over naming an
umbrella module by hand.

## Workflow 1 — inventory technical debt (whole library)

```bash
lake exe aftk tech-debt --jobs 4 --all-markers --jsonl library MyLib > findings.jsonl
```

Every invocation must select findings: `--markers <list>` (repeatable), `--all-markers` (all 25
built-in kinds; `lake exe aftk help tech-debt` lists them), and/or `--option <name|prefix.*>`
(repeatable) for arbitrary `set_option` overrides, which get kind `option`. Multi-module scans
run **each module in an isolated child process**, so memory is bounded (≈2–3 GB per worker for a
Mathlib-sized import closure — pick `--jobs` from `free -g`), and the module's effective Lake
`[leanOptions]` are applied, `weak.*` ones included. Output is deterministic in module order.

A module that fails to elaborate does not abort the scan: its findings are missing and a JSONL
record with `"type":"error"` names the module, the `phase` (`source-resolution`, `parse`,
`header`, `elaboration`, `internal`) and a `diagnostic`; the command then **exits nonzero**.
Pass `--allow-partial` only when you have decided that a partial inventory is acceptable, and
still read the error records. Findings from successful modules are always retained.

Scheduling note: modules are processed in batches of `--jobs`, and a batch waits for its slowest
member before the next starts; with per-module times ranging from ~5 s to ~100 s the effective
concurrency is below `--jobs`. Measured: a 155-module Mathlib-dependent library, `--jobs 4`,
**20 min wall** (667 findings, 0 module failures).

**Reading a finding** (`"type":"finding"`): `module`, `file`, `kind`, `description`, a 1-based
`range`, and

- `declarations` — the source-facing enclosing declaration(s); `[]` for module-level findings,
  usually one name, several for wrapped/grouped commands;
- `key` + `keyVersion` — a **semantic identity** built from module, declarations, kind, option
  detail and an ordinal among equivalent occurrences. It survives unrelated line movement and
  unrelated insertions; renaming the owning declaration changes it. **Persist `key`, not
  `(file, line)`**, and partition stored state by `keyVersion`;
- for `set_option`-derived kinds: `detail` (reprinted `name value`), `optionName`, `optionValue`,
  and `scope` ∈ {`command`, `term`, `tactic`} — a file-level flag vs a `set_option … in` on one
  declaration vs one inside a proof. Non-option findings omit these.

The `range` of a command-level `set_option … in <decl>` covers only `set_option <name> <value>`;
the tactic/term forms span the wrapped tactic/term. Do not use `range.end` to find a wrapped
declaration's extent — use `declarations`.

## Workflow 2 — "who depends on this?" / leaf detection

`rdeps` answers at **declaration** level (it follows `getUsedConstantsAsSet` over type *and*
value, so a lemma used inside a proof term counts) — far more precise than "which files import
this file".

```bash
lake exe aftk rdeps library MyLib MyLib.Foo.bar --modules 'MyLib.*' --jsonl
printf '%s\n' MyLib.Foo.bar "MyLib.Foo.baz'" | lake exe aftk rdeps library MyLib --stdin --jsonl
```

- **Batch with `--stdin --jsonl`.** The environment, lookup index and reverse graph are built
  once and reused: 460 declarations against a 155-module Mathlib-dependent library took **5 s**
  total, versus ~4 s *each* as separate invocations. Names go one per line; primes and Unicode
  are fine.
- **Every query gets an explicit `status`**: `ok` (with `results`, `resultCount`,
  `moduleCount`), `leaf` (resolved, **no dependents in the scope**), `unresolved` (with
  `candidates`), or `error`. Empty output never means "leaf" in scoped JSONL mode. Any
  `unresolved`/`error` makes the command exit nonzero after emitting all records; add
  `--allow-partial` only when that is the intended contract.
- **A leaf is a leaf within the scope you named.** `library MyLib` covers MyLib's own modules;
  a sibling library that imports MyLib is outside it — query `library OtherLib` (or
  `package …`) too before treating a declaration as safe to delete.
- **Name resolution.** Give the fully qualified name. `--resolve-suffix` matches a whole-name-
  component suffix and accepts a unique match (ambiguity fails with sorted candidates); a failed
  exact lookup also lists up to 20 candidates. `--defined-in <module>` disambiguates private
  declarations, and a result row's `module` + `declaration` round-trip into
  `--defined-in <module> <declaration>`.
- The single-target form `rdeps library MyLib Decl` (or `module`, `package .`) prints TSV rows
  and exits 0 with no rows for a leaf.

## Workflow 3 — iterate on a proof without editing the file

```bash
lake exe aftk diagnostics MyLib/Foo.lean          # first call starts the daemon + a worker (≈15 s)
lake exe aftk goals MyLib.Foo 53 3                # what is the goal at the start of this tactic?
printf '  simp [h]' | lake exe aftk probe MyLib.Foo --line 61 --stdin --goals-at 61:3     # replace one line
printf '  exact h' | lake exe aftk probe MyLib.Foo --lines 61:63 --stdin                  # replace a block
printf 'simp' | lake exe aftk probe MyLib.Foo --to-eol 61:3 --stdin                      # from a column to EOL
```

`probe` replaces text in the worker's in-memory copy, elaborates, reports `accepted` (no error
diagnostics), the diagnostics and optional goals, and restores the file — it never writes to
disk (verify with `git status` if in doubt), and requests on the same file are serialised.
Subsequent calls take about a second. Use `--line N` / `--lines A:B` (inclusive, terminators
preserved) for whole-line edits; `--to-eol L:C` and `--range L:C-L:C` (end-exclusive) take
**UTF-16 columns** as in LSP, so on a line containing `𝟙`-style symbols do not derive a column
from a shell string length — prefer the line selectors. `accepted` is inside `result`; the outer
`ok` only says the daemon protocol succeeded.

If a tracked import changes on disk the daemon restarts the worker on the next call; `--refresh`
forces it. `--transient` releases the worker after a one-off check. A daemon left alone exits on
its own once no worker is open (idle workers close after 10 min, the empty daemon after 5 min,
checked once a minute); use `close <file>`, `close --all`, `gc`, or `shutdown` to reclaim memory
deliberately. Process discovery, worker counting and `shutdown --all-projects` are scoped to the
current effective user and identity-checked — never `pkill` Lean processes by hand; that also
kills unrelated editors' workers.

## Workflow 4 — cross-check a textual tracker

If the project already counts debt with regexes, run Workflow 1 and reconcile by `key`, or by
`(file, range.start.line, kind)` for a one-off comparison. In practice the two agree exactly
except where one has a bug — the cross-check is how you find those (on a 155-module library the
first pass found one bug on each side; after fixing both, all 667 findings matched). Things a regex tends to
miss that aftk sees: `set_option … in <tactic>` on one line; term- and tactic-level overrides.
Things a regex over-counts relative to aftk: `linter.*`/`warning.simp.varHead` set to `true`
(only `false` is a finding) and `pp/debug/trace/profiler.*` set to `false`.

## Gotchas

1. **Scopes decide what is visible.** For `rdeps`, a dependent that lives in a module outside the
   named scope does not exist; for `tech-debt`, only modules in the scope are scanned. Name
   `library`/`package`, not a single module, unless you mean it.
2. **Exit status is part of the contract.** Unresolved targets and failed modules exit nonzero by
   design; a wrapper that turns that into "success" hides incomplete analysis. Read the
   `status`/`type` fields, and reach for `--allow-partial` consciously.
3. **`probe` columns are UTF-16 code units** (`--range`, `--to-eol`, `--goals-at`); `tech-debt`
   columns are code points. Prefer `--line`/`--lines`.
4. **The build must be current.** `tech-debt` and `rdeps` read built `.olean`s; after editing
   sources, `lake build` the affected modules first (the daemon tracks and restarts by itself).
5. **File path vs module name**: `diagnostics`/`open`/`restart`/`close` need a path; `goals`/`probe`
   accept either.
6. **Memory**: ~2–3 GB per `tech-debt` worker or `rdeps` environment, ~2 GB per warm daemon
   worker (the daemon budgets 6500 MiB per new worker when a hard limit is set). Choose `--jobs`
   accordingly; `status` shows live PSS.

## Resource controls

`AFTK_MAX_WORKERS_PER_PROJECT` (8), `AFTK_GLOBAL_MAX_WORKERS` (50), `AFTK_WORKER_IDLE_MS`
(600000), `AFTK_DAEMON_IDLE_MS` (300000), `AFTK_MEMORY_SOFT_LIMIT_{MIB,GIB}`,
`AFTK_MEMORY_HARD_LIMIT_{MIB,GIB}`, `AFTK_WORKER_MEMORY_ESTIMATE_MIB` (6500),
`AFTK_DEFAULT_LEASE_MS` — all counted over the current effective user's Lean workers. `status`
prints the effective configuration; daemon metadata lives in `.lake/aftk/server.json`.
