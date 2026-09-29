---
name: aftk
description: Use `lake exe aftk` in a Lean 4 project that depends on aftk — to inventory technical debt semantically (set_option overrides, erw, sorry, deprecated, axioms …) with stable per-finding keys, to answer "who depends on this declaration?" / "what could break if I change it?" with a declaration-level dependency graph and explicit per-query status, to iterate on a proof through a warm Lean worker (goals, in-memory probes) instead of cold re-elaboration, and to remove debt with checks beyond "it compiles" (build options, unchanged statements, nothing absorbing the removed step). Read this before running any aftk command.
---

# aftk — dependency analysis, technical debt, and a proof daemon for Lean projects

aftk is one Lake executable with three independent capabilities. Everything runs **from the
consuming project's root** through that project's Lake environment, which is how aftk learns the
project's source roots, built `.olean`s, dependencies and `[leanOptions]`:

| capability | commands | what it needs |
|---|---|---|
| technical-debt scan (elaborator info trees) | `tech-debt` | an up-to-date `lake build` of the scanned modules' imports |
| declaration dependency graph | `deps`, `rdeps` | built `.olean`s of the scope you name |
| persistent Lean worker daemon | `diagnostics`, `goals`, `probe`, `open`, `restart`, `close`, `gc`, `status`, `shutdown` | nothing extra; opening a file builds its stale imports first, as the editor does; state lives in `.lake/aftk/` |

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
lake exe aftk tech-debt --option 'linter.style.*' --jsonl package             # any option override
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
`<module>\t<declaration>`). Once a request reaches the daemon, a daemon command prints exactly one
JSON object, `{"ok":true,"result":…}` or `{"ok":false,"error":…}`, exit code 0 iff `ok`; a usage
error, a failed daemon start or a client-side timeout prints `error: …` on stderr, exits 1 and
prints no JSON. The daemon commands do not take `--jsonl`. Positions are **1-based** in line and
column. `diagnostics`/`open`/`restart`/`close` take a *file path*; `goals` and `probe` accept
either a module name or a `.lean` path. Relative paths resolve against the project root.

**Scopes.** `tech-debt` and `rdeps` take an explicit scope: `module <M>` (one module),
`library <L>` (the Lake library's `modules` facet — follows custom `roots`/`srcDir`), or
`package [<P>]`. The root package is spelled `tech-debt … package` (or no scope at all),
`rdeps … package . <decl>` for one query, and `rdeps … package --stdin --jsonl` for a batch;
`tech-debt … package .` fails. Prefer `library`/`package` over naming an umbrella module by hand.

## Workflow 1 — inventory technical debt (whole library)

```bash
lake exe aftk tech-debt --jobs 4 --all-markers --jsonl library MyLib > findings.jsonl
```

Every invocation must select findings: `--markers <list>` (repeatable), `--all-markers` (all 25
built-in kinds; `lake exe aftk help tech-debt` lists them), and/or `--option <name|prefix.*>`
(repeatable) for arbitrary `set_option` overrides, which get kind `option`. Multi-module scans
run **each module in an isolated child process**, so memory is bounded (≈2–3 GB per worker for a
Mathlib-sized import closure — pick `--jobs` from `free -g`), and the module's effective Lake
`[leanOptions]` are applied, `weak.*` ones included. `tech-debt` and the daemon do not apply
options passed through `moreLeanArgs` or `weakLeanArgs`; `lake build` does (and `lake lean`
passes `moreLeanArgs`). Output is deterministic in module order.

A module that fails to elaborate does not abort the scan: its findings are missing and a JSONL
record with `"type":"error"` names the module, the `phase` (`source-resolution`, `parse`,
`header`, `elaboration`, `internal`) and a `diagnostic`; the command then **exits nonzero**.
Pass `--allow-partial` only when you have decided that a partial inventory is acceptable, and
still read the error records. Findings from successful modules are always retained.

`--jobs` is a completion-driven bounded queue: at most `--jobs` module scans are in flight and a
slot is refilled the moment any scan finishes, so uneven module sizes (here ~5 s to ~100 s) do
not stall the others; output is still emitted in module order. Budget roughly
(sum of per-module times) / `--jobs`: a 155-module Mathlib-dependent library with `--jobs 4`
took **9 min** (667 findings, 0 module failures; 4 workers live in 39 of 48 ten-second
samples), and a second run produced byte-identical `key`s.

**Reading a finding** (`"type":"finding"`): `module`, `file`, `kind`, `description`, a 1-based
`range`, and

- `declarations` — the source-facing enclosing declaration(s); `[]` for module-level findings,
  usually one name, several for wrapped/grouped commands;
- `key` + `keyVersion` — a **semantic identity** built from module, declarations, kind, the
  override's name, value and `scope`, and an ordinal among equivalent occurrences. It survives
  line movement and unrelated insertions; renaming the owning declaration, changing an
  override's value or moving it between command, term and tactic scope, or inserting an
  equivalent occurrence earlier (in the same declaration, or anywhere in the module for a
  module-level finding) changes it. **Persist `key`, not `(file, line)`**, and partition stored
  state by `keyVersion`;
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
  once and reused: 460 declarations against a 155-module Mathlib-dependent library took **7 s**
  total in `library` scope (4.2 GB peak), versus ~4 s *each* as separate invocations. Names go
  one per line; primes and Unicode are fine here, but plain `xargs` stops at a name containing
  `'` and drops every later name.
- **Every query gets an explicit `status`**: `ok` (with `results`, `resultCount`,
  `moduleCount`), `leaf` (resolved, **no dependents in the scope**), `unresolved` (with
  `candidates`), or `error`. Empty output never means "leaf" in scoped JSONL mode. Any
  `unresolved`/`error` makes the command exit nonzero after emitting all records; add
  `--allow-partial` only when that is the intended contract.
- **A leaf is a leaf within the scope you named, and only for references stored in terms.**
  `library MyLib` covers MyLib's own modules; query a sibling library that imports MyLib too, and
  remember that consumers outside the workspace are invisible to every scope. The graph misses
  `example`s, `#check`/`#eval`, attribute commands naming `X` (`attribute [simp] X`,
  `@[deprecated X]`), `open … (X)`, and `simp [X]` arguments that `simp` did not use. A leaf is a
  candidate for cleanup, not evidence that an edit is safe. For cleanup or deletion, build the
  edited modules and all their direct and transitive importers in the workspace (Workflow 5).
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
printf 'attribute [local simp] MyLib.Foo.bar in\n' | lake exe aftk probe MyLib.Foo --at 58:1 --stdin  # insert above 58
```

`probe` applies one contiguous edit to the worker's in-memory copy, elaborates, reports
`accepted`, the diagnostics and optional goals, and restores the file — it never writes to
disk (verify with `git status` if in doubt). Use `--line N` / `--lines A:B` (inclusive,
terminators preserved) for whole-line edits; `--at L:C` inserts, and `--line N --text ''` blanks
a line. Diagnostic ranges and `--goals-at` use candidate coordinates (shift them after an
insertion); `replacementRange` is in the file's on-disk coordinates. `--at L:C`, `--to-eol L:C`
and `--range L:C-L:C` (end-exclusive) take **UTF-16 columns** as in LSP (gotcha 3), so on a line
containing `𝕜`-style symbols do not derive a column from a shell string length — prefer the
line selectors. `accepted` is inside `result`; the outer `ok` only says the daemon protocol
succeeded.

**`accepted` only means that the whole file has no error diagnostic.** It ignores new warnings
and is `false` for every candidate when the file already has an error (take a clean baseline
first, Workflow 5).

`goals` prints goals with subterms elided as `⋯`, so equal printouts do not prove equal goals;
to compare two goals, compare hashes ([references/debt-cleanup.md](references/debt-cleanup.md)
§1, "Goal identity").

Workers get the module's `[leanOptions]` from `lake setup-file`, as the editor does. One daemon
serves the project, one request at a time. A probe re-elaborates from the edit point to the end
of the file twice; raise `--timeout-ms` (default 30000) for slow files and for a first call that
builds. If a tracked import changes on disk the daemon restarts the worker on the next call;
`--refresh` forces it. `--transient` releases the worker after a one-off check. A daemon left
alone exits on its own once no worker is open (idle workers close after 10 min, the empty daemon
after 5 min, checked once a minute); use `close <file>`, `close --all`, `gc`, or `shutdown` to
reclaim memory deliberately. Process discovery, worker counting and `shutdown --all-projects` are
scoped to the current effective user and identity-checked — never `pkill` Lean processes by hand;
that also kills unrelated editors' workers.

## Workflow 4 — cross-check a textual tracker

If the project already counts debt with regexes, run Workflow 1 and reconcile by `key`, or by
`(file, range.start.line, kind)` for a one-off comparison. The two agree exactly only when they
count the same things in the same unit, and the cross-check is how you find bugs on either side
(on a 155-module library the first pass found one bug on each side; after fixing both, all 667
findings matched). aftk counts `erw` once per call (`erw [a, b]` is one finding), in tactic and
`conv` mode, and never counts syntax that a macro produced. Things a regex tends to miss that
aftk sees: `set_option … in <tactic>` on one line; term- and tactic-level overrides. Things a
regex tends to over-count: matches in comments and strings, and overrides that aftk reports only
at some values (see [references/debt-cleanup.md](references/debt-cleanup.md) §7).

## Workflow 5 — remove debt, not just count it

aftk finds debt; it does not decide whether a removal was clean. Grade each removal by the
strongest tier it passes, and call it removable only at tier 3.

```bash
lake exe aftk diagnostics MyLib/Foo.lean > base.json          # baseline: must have no error
lake exe aftk tech-debt --all-markers --jsonl module MyLib.Foo > before.jsonl  # same scope, before the edit
lake exe aftk probe MyLib.Foo --line 42 --text ''             # drop the `set_option … in` on line 42
printf '  rw [h]' | lake exe aftk probe MyLib.Foo --line 57 --stdin   # `erw [h]` → `rw [h]`
lake exe aftk rdeps library MyLib MyLib.Foo.bar --jsonl       # known term dependents to prioritize
lake exe aftk tech-debt --all-markers --jsonl module MyLib.Foo > after.jsonl   # after the edit
```

1. **Compiles.** The probe returns `accepted: true`.
2. **Compiles like the build, same warnings, same statements.** The probe runs under the
   module's `[leanOptions]`; a hand-run `lake env lean` does not (`lake lean` does, or pass them
   as `-D` flags). No warning may appear whose message is missing from `base.json`. Then apply
   the edit and build the edited modules plus all direct and transitive importers in the
   workspace, including sibling libraries and executable targets. Building every relevant
   library and executable target also covers this closure; default `lake build` targets may not.
   Use `rdeps` to prioritize checks, not to delimit this build: it misses source uses such as
   `example`s. Compare a hash of every constant's type and proof-erased value before and after;
   hashes do not cover attributes or all elaboration dependencies. aftk has no hash command,
   so this check is yours ([references/debt-cleanup.md](references/debt-cleanup.md) §1–§2).
3. **Nothing absorbs it.** A later `exact`, `rfl` or `simpa`, or the declaration's own
   `backward.isDefEq.respectTransparency false`, can now do the unfolding the deleted step did.
   In both texts, run each later tactic that unifies against the goal under `with_implicit`; in a
   flagged declaration use `set_option backward.isDefEq.respectTransparency true in
   with_implicit <tac>`. The edited text must not fail where the original passes. Passing the
   outer wrapper is only a screen: tactics and nested term elaborators can use their own
   transparency (`erw`, or `exact (show _ from rfl)`, for example). Check the inner operation in
   both texts with a control that fails when unfolding is required; for term `rfl`, test tactic
   `with_implicit rfl` at the same goal. If the inner operation cannot be checked, report the
   result as inconclusive at tier 3 and retain the item. Accept no repairs: an edit that needs
   a new `exact`, a `have … := rfl` or a type ascription moved the debt (§1).

- **Controls.** Show every harness one input that must fail and one that must pass before
  trusting it (reference §3).
- **Attribution.** To credit X (a dependency bump, an upstream fix, a new tag) with freeing an
  item, run the same check in a second built tree that differs only by X (§3).
- **Re-sweep when the cause moves.** After a new `@[implicit_reducible]` tag or an upstream fix
  lands, sweep every debt class again, including those aftk does not report (gotcha 7), in the
  declarations `rdeps` lists, because nothing reports the debt it freed (§3).
- **Additions first.** Diff `after.jsonl` with `before.jsonl` (same scope, same
  `--markers`/`--option` selection, same `keyVersion`) by `key`: keys only in `before.jsonl` are
  paid, keys only in `after.jsonl` are debt added, and every added flag, tag or override goes at
  the top of the report (§7).

Details and traps, including heartbeat budgets, `rfl` lemmas that never fire, build time,
counting, agents and upstream candidates: [references/debt-cleanup.md](references/debt-cleanup.md).

## Gotchas

1. **Scopes decide what is visible.** For `rdeps`, a dependent that lives in a module outside the
   named scope does not exist; for `tech-debt`, only modules in the scope are scanned. Name
   `library`/`package`, not a single module, unless you mean it.
2. **Exit status is part of the contract, and so is coverage.** Unresolved targets and failed
   modules exit nonzero by design; a wrapper that turns that into "success" hides incomplete
   analysis. Read the `status`/`type` fields, reach for `--allow-partial` consciously, and print
   the coverage (modules scanned, error records, per-status counts) next to every total.
3. **The daemon uses UTF-16 columns** (`goals <L> <C>`, `--goals-at`, `--at`, `--range`,
   `--to-eol`, returned ranges); `tech-debt` columns are code points. They differ on lines with
   characters outside the Basic Multilingual Plane (`𝕜`, `𝓝`, …). Prefer `--line`/`--lines`.
4. **The build must be current, and a scan describes the working tree.** `tech-debt`, `deps` and
   `rdeps` never build: `lake build` the affected modules after editing (the daemon tracks and
   restarts by itself). `tech-debt` reads each scanned module's *source from disk*, uncommitted
   edits included; to describe a commit, scan a separate built checkout of it.
5. **File path vs module name**: `diagnostics`/`open`/`restart`/`close` need a path; `goals`/`probe`
   accept either.
6. **Memory is a machine-wide budget**: ~2–3 GB per `tech-debt` worker or `rdeps` environment,
   ~2 GB per warm daemon worker (the daemon budgets 6500 MiB per new worker when a hard limit is
   set); `status` shows live PSS. Count other agents' compiles against the same budget.
7. **aftk does not report everything.** No marker covers `change`, tactic `show`, term
   `show … from`/`show … by`, `with_unfolding_all`, `rw!`, `unseal`, `native_decide`, any
   `simp`/`dsimp` configuration except their `+instances` (so `simp -index` is invisible),
   `attribute [local …] X in`, instance priorities, any attribute except `deprecated`,
   `nolint simpNF` and the `@[expose]` of `@[expose] public section` (so `@[implicit_reducible]`
   and `@[backward_defeq]` are invisible), or uses of axioms (`axiom` reports declarations).
   Other options appear only through `--option`. Track these with a scan that masks comments,
   and report new instances as debt added.

## Resource controls

`AFTK_MAX_WORKERS_PER_PROJECT` (8), `AFTK_GLOBAL_MAX_WORKERS` (50), `AFTK_WORKER_IDLE_MS`
(600000), `AFTK_DAEMON_IDLE_MS` (300000), `AFTK_MEMORY_SOFT_LIMIT_{MIB,GIB}`,
`AFTK_MEMORY_HARD_LIMIT_{MIB,GIB}`, `AFTK_WORKER_MEMORY_ESTIMATE_MIB` (6500),
`AFTK_DEFAULT_LEASE_MS` — all counted over the current effective user's Lean workers, and read
once when the daemon starts (set them on the first command, or `shutdown` first). `status`
prints the effective configuration; daemon metadata lives in `.lake/aftk/server.json`. For exact
behaviour, aftk's `tests/tech_debt.sh`, `tests/server.sh` and `tests/dependency.sh` are
executable examples, near-misses included.
