---
name: aftk
description: Use `lake exe aftk` in a Lean 4 project that depends on aftk — to inventory technical debt semantically (set_option overrides, erw, sorry, deprecated, axioms …), to answer "who depends on this declaration?" / "is this safe to delete?" with a declaration-level dependency graph, and to iterate on a proof through a warm Lean worker (goals, in-memory probes) instead of cold re-elaboration. Read this before running any aftk command; the gotchas section is the part that saves time.
---

# aftk — dependency analysis, technical debt, and a proof daemon for Lean projects

aftk is one Lake executable with three independent capabilities. Everything runs **from the
consuming project's root** through that project's Lake environment:

| capability | commands | what it needs |
|---|---|---|
| technical-debt scan (elaborator info trees) | `tech-debt` | an up-to-date `lake build` of the scanned modules' imports |
| declaration dependency graph | `deps`, `rdeps` | built `.olean`s of the module you name |
| persistent Lean worker daemon | `diagnostics`, `goals`, `probe`, `open`, `restart`, `close`, `gc`, `status`, `shutdown` | nothing extra; state lives in `.lake/aftk/` |

The two helper scripts referenced below live in this skill's directory, not in the project:
`${CLAUDE_SKILL_DIR}/scripts/` (usually `.claude/skills/aftk/scripts/`). Run them with the project
root as the working directory — both refuse to run anywhere else.

Setup, if the project does not have it yet (then `lake exe aftk --help` builds it):

```toml
[[require]]
name = "aftk"
git = "https://github.com/mathlib-initiative/aftk"
rev = "main"
```

## Cheat-sheet

```bash
lake exe aftk --help                       # top level; `lake exe aftk help <cmd>` for each command
lake exe aftk tech-debt --all-markers --jsonl module A.B.C
lake exe aftk tech-debt --markers backwardOption,erw,sorry module A.B.C
lake exe aftk rdeps <RootModule> <Full.Decl.Name> --modules 'MyLib.*'      # who uses it (transitively)
lake exe aftk deps  <Module> <Full.Decl.Name> --modules 'MyLib.*'          # what it uses (transitively)
lake exe aftk diagnostics path/to/File.lean [--transient]                  # errors/warnings as JSON
lake exe aftk goals <A.B.C | path/to/File.lean> <line> <col>               # tactic/term goals (1-based)
printf '<replacement>' | lake exe aftk probe <A.B.C | path/to/File.lean> --range L1:C1-L2:C2 --stdin [--goals-at L:C]
lake exe aftk status; lake exe aftk gc; lake exe aftk shutdown
```

`tech-debt`, `deps` and `rdeps` print TSV by default (`tech-debt`:
`<file>:<line>:<col>\t<kind>\t<description>`; `deps`/`rdeps`: `<module>\t<declaration>`) and one
JSON object per result with `--jsonl`. The daemon commands (`diagnostics`, `goals`, `probe`,
`open`, `restart`, `close`, `gc`, `status`, `shutdown`) always print exactly one JSON response
object — `{"ok":true,"result":…}` or `{"ok":false,"error":…}`, exit code 0 iff `ok` — and reject
`--jsonl` as an unknown option. Positions are **1-based** in both line and column.
`diagnostics`/`open`/`restart`/`close` take a *file path*; `goals` and `probe` accept either a
module name (`A.B.C`) or a `.lean` path and resolve both to the same worker.

## Workflow 1 — inventory technical debt (whole library)

**Do not use `library`/`package` scope on a large library.** Those scopes elaborate every module
serially in one process with `leakEnv := true`, so memory grows by one environment per module
(observed: 22 GB after ~40 Mathlib-dependent modules) and the run aborts at the first module that
fails to elaborate. Use `module` scope, one process per module, in parallel:

```bash
"${CLAUDE_SKILL_DIR}"/scripts/scan_modules.sh MyLib 4 > findings.jsonl   # cwd = project root; 4 parallel workers
SCAN_ERR_DIR=scan-errors "${CLAUDE_SKILL_DIR}"/scripts/scan_modules.sh MyLib 4 backwardOption,erw > findings.jsonl
```

Per module this costs roughly 5–30 s (heavy files up to ~100 s) and ~2–3 GB, so 4-way parallelism
on a 30 GB machine is the practical ceiling. Every invocation must select markers (`--markers` or
`--all-markers`); `lake exe aftk help tech-debt` lists the 22 kinds. Modules that fail to
elaborate are listed on stderr with their first error line (the findings for those modules are
simply missing — see Gotcha 1).

Reading the result: a finding is `{module, file, kind, description, range}`; for `set_option`
markers the range is the `set_option <name> <value>` node itself. For a command-level
`set_option … in <decl>` it ends at the option value (e.g. `72:1`–`72:32` for
`set_option maxHeartbeats 400000 in` even though the wrapped `def` runs to line 88), not at the
end of the wrapped declaration; only the tactic/term forms `set_option … in <tac>` span the
wrapped tactic/term (e.g. `319:5`–`320:47`), because their syntax node includes the `in` tail.
Either way `range.start.line` is the flag's own line — convenient for joining with line-based
tools; do not use `range.end` to find the extent of a wrapped declaration. Findings are
de-duplicated by (module, kind, start) and sorted.

## Workflow 2 — "who depends on this?" / leaf detection

`rdeps` answers at **declaration** level (it follows `getUsedConstantsAsSet` over type *and*
value, so a lemma used inside a proof term counts), which is far more precise than "which files
import this file".

```bash
lake exe aftk rdeps MyLib MyLib.Foo.bar --modules 'MyLib.*'
```

- **Name the library's root module** (`MyLib`, the file that imports everything), not the module
  that defines the declaration. aftk builds its environment by importing exactly the module you
  name, so `rdeps MyLib.Foo bar` can only see dependents *inside* `MyLib.Foo`'s import closure —
  which never includes the modules that import it.
- **Empty output with exit 0 means no dependents in the filtered modules** — a leaf *within the
  named root's import closure*. If other libraries in the workspace import `MyLib`, they are
  downstream of it and therefore outside `MyLib`'s closure: no `--modules` pattern (including
  `'*'`) can surface them, because `--modules` only filters what was imported. Re-run with *that*
  library's root as the first argument (`rdeps OtherLib MyLib.Foo.bar --modules 'OtherLib.*'`)
  before treating the declaration as safe to restructure or delete.
- Give the **fully qualified** name; resolve nested namespaces from the environment rather than
  guessing (a 6-line `run_cmd` over `env.constants` that suffix-matches the short name is reliable;
  textual `namespace`/`end` tracking is not). An unresolved name is
  `error: declaration … was not found in the environment of module …`, exit 1.
- Each query re-imports the environment (~3–4 s and ~3 GB for a Mathlib-sized closure); batch
  with `"${CLAUDE_SKILL_DIR}"/scripts/rdeps_batch.sh` (cwd = project root), which is safe for
  names containing `'`: plain `xargs` treats a prime as a quote, stops at that line with
  `xargs: unmatched single quote` (exit 1) after having run the names before it, so every later
  name is missing from results that otherwise look complete.

## Workflow 3 — iterate on a proof without editing the file

```bash
lake exe aftk diagnostics MyLib/Foo.lean          # first call starts the daemon + a worker (≈15 s)
lake exe aftk goals MyLib.Foo 53 3                # what is the goal at the start of this tactic?
E=$(sed -n '61p' MyLib/Foo.lean | python3 -c 'import sys;print(len(sys.stdin.buffer.read().decode().rstrip("\n").encode("utf-16-le"))//2 + 1)')
printf 'simp [h]' | lake exe aftk probe MyLib.Foo --range 61:3-61:$E --stdin --goals-at 61:3
printf 'simp [h]\n' | lake exe aftk probe MyLib.Foo --range 61:3-62:1 --stdin   # same, without column arithmetic
```

`probe` replaces a **1-based, end-exclusive** range in the worker's in-memory copy, elaborates,
reports `accepted` (no error diagnostics), the diagnostics and optional goals, and restores the
file — it never writes to disk, and requests on the same file are serialised. Subsequent calls are
~1 s. The range end must lie within the line (`invalid probe range end` otherwise). **Daemon
columns are UTF-16 code units** (as in LSP): bash `${#L}` counts code points (bytes under
`LC_ALL=C`), so on lines containing non-BMP symbols (`𝟙`, `𝓝`, `𝕜`, …) `${#L}+1` is one short per
symbol and the tail of the line is silently left in place (surfacing as `accepted: false` with a
spurious `unexpected token` error). Compute the UTF-16 length as above, or replace up to the start
of the next line and end the replacement with a newline. `accepted` is inside `result`; the outer
`ok` only says the daemon protocol succeeded. (`tech-debt` columns, by contrast, are Unicode code
points.)

If a tracked import changes on disk the daemon restarts the worker on the next call; `--refresh`
forces it. Use `--transient` for one-off checks so the worker is released; `status` shows per-worker
RSS/PSS; `shutdown` when done. A daemon left alone does exit on its own, but only once no worker
is open: a once-a-minute sweep closes idle workers after 10 min and exits the daemon when no
worker remains and 5 min have passed since the last request — so with a warm worker it lives
~10–11 min after the last call, with `--transient` ~5–6 min.

## Workflow 4 — cross-check a textual tracker

If the project already counts debt with regexes, run Workflow 1 and reconcile by
`(file, line, kind)`. In practice the two agree exactly except where one of them has a bug — the
cross-check is how you find those. Known asymmetries:

- aftk sees `set_option … in <tactic>` on **one line** (a regex anchored on `in$` will not);
- aftk does **not** count `erw` in `conv` mode (`conv_rhs => erw […]`, `slice_lhs … => erw […]`):
  it matches only `Lean.Parser.Tactic.tacticErw___`, and the conv `erw` is a separate macro
  (`Init/Conv.lean`);
- aftk has no marker for `maxSynthPendingDepth`, `linter.unused*`, or arbitrary options. It
  recognises only: `maxHeartbeats` / `synthInstance.maxHeartbeats` (→ `maxHeartbeats`),
  `maxRecDepth`, any `backward.*` (→ `backwardOption`), `linter.style.longFile` (→ `longFile`);
  `linter.flexible`, `linter.overlappingInstances`, `linter.auxLemma`, `linter.deprecated`,
  `warning.simp.varHead` **only when set to `false`**; and `pp.*` / `debug.*` / `trace.*` /
  `profiler.*` **only when not set to `false`** (→ `developmentOption`). So
  `set_option linter.deprecated true` and `set_option pp.all false` are not findings, and a
  tracker that counts every `set_option` line will over-count relative to aftk on exactly those.
  (`unlockLimits` is the `unlock_limits` command, not a `set_option`.)

## Gotchas (each of these cost real time)

1. **`tech-debt` elaborates with `Options.empty`.** The workspace's `[leanOptions]`
   (`maxSynthPendingDepth`, linter sets, `autoImplicit`, …) are *not* applied. A module that
   only elaborates with those options fails under aftk and its findings are missing. There is no
   `-D` pass-through today; note such modules in your results.
2. **`library`/`package` scope: memory leak + abort-on-first-error.** See Workflow 1.
3. **`rdeps` sees only the named module's import closure.** Name the root module; sibling
   libraries that import yours need their own root named. See Workflow 2.
4. **Conv-mode `erw` is not a finding.** See Workflow 4.
5. **`probe --range` is end-exclusive, must stay inside the line, and counts UTF-16 units.**
   See Workflow 3.
6. **File path vs module name:** `diagnostics`/`open`/`restart`/`close` need a file path;
   `goals`/`probe` take either.
7. **Batching declaration names through `xargs` needs NUL delimiters** (`tr '\n' '\0' | xargs -0`)
   because `'` in Lean names is a quote character to plain xargs; `xargs -d '\n'` also works but
   is GNU-only. Use `-r` so an empty list does not run the worker once with no argument.
8. **Killing aftk/lean processes:** match on the binary path or use `pkill -x lean`; a `pkill -f`
   pattern that also appears in the calling shell's own command line kills that shell.
9. **Memory budget:** a warm worker is ~2 GB RSS for a small file (when `AFTK_MEMORY_HARD_LIMIT_*`
   is set, the daemon budgets 6500 MiB ≈ 6.3 GiB of PSS per new worker); `rdeps` ~3 GB; one
   `tech-debt` module scan 2–3 GB. Plan parallelism from `free -g`, and use `status`/`gc`/
   `close --all` to reclaim.

## Resource controls

`AFTK_MAX_WORKERS_PER_PROJECT` (8), `AFTK_GLOBAL_MAX_WORKERS` (50), `AFTK_WORKER_IDLE_MS`
(600000), `AFTK_DAEMON_IDLE_MS` (300000), `AFTK_MEMORY_SOFT_LIMIT_{MIB,GIB}`,
`AFTK_MEMORY_HARD_LIMIT_{MIB,GIB}`, `AFTK_WORKER_MEMORY_ESTIMATE_MIB` (6500),
`AFTK_DEFAULT_LEASE_MS`. `status` prints the effective configuration. Daemon metadata:
`.lake/aftk/server.json`. `shutdown --all-projects` (alias `--all`) stops every aftk daemon it can
discover host-wide with `pgrep -f` — there is no per-user filter; on a single-user machine that is
simply all of your daemons.
