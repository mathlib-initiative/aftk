# Debt cleanup with aftk: checks and failure modes

Read this when running Workflow 5 of `SKILL.md`, or any sweep over many findings. The rules come
from a month-long cleanup of a large Mathlib-dependent library; most are here because ignoring
them produced a wrong verdict or a wasted fix at least once. Names are placeholders: `MyLib` for
your library, `MyLib.X`/`MyLib.Y` for its declarations, `Dep.X` for a dependency's declaration,
`X` for any of them. Sections 4 to 6, and the transparency parts of section 1, describe Lean's
behaviour rather than aftk's (`@[backward_defeq]` exists from Lean v4.31; the `.implicit` level,
the strict `@[defeq]` check at it and `with_implicit` are as of v4.33 — v4.31–v4.32 checked at
`.instances`); re-check them after a toolchain bump.

## Contents

1. Verdict tiers in detail
2. Statement hashes
3. Sweeps: controls, errors, attribution, triggers
4. Transparency flags, seams and the leave-one-out tag test
5. `rfl` lemmas that never fire
6. Measuring: heartbeats, kernel, build time
7. Counting
8. Bulk edits and agents
9. Upstream candidates

## 1. Verdict tiers in detail

A removal that compiles is a candidate. It can still be wrong in three independent ways: the
check used other options than the build, a statement changed while the file compiled, or
something else now does the removed step's work.

**Options.** `lake env lean File.lean` sets the search path and nothing else. The lakefile's
`[leanOptions]` (`maxSynthPendingDepth`, `weak.linter.*`, `autoImplicit`, …) are not applied, so
the check elaborates a different file from the one the build elaborates: removing
`set_option linter.X false` looks free because the linter is off, and an instance search that
needs a raised depth fails the baseline. aftk's `tech-debt` and daemon apply the options. Outside
aftk, `lake lean File.lean` builds the file's imports and elaborates it with the module's
`[leanOptions]` (and `moreLeanArgs`, but not `weakLeanArgs`). With `lake env lean`, take the
options from `lake setup-file <file>`, which prints them as JSON after building the file's
imports, and pass them as `-D name=value`. A baseline that fails is a harness bug, not a file to
skip. Compare warnings with the baseline by message: a new "unused `simp` argument" after a
removal often means a later step absorbed it.

**Build coverage.** After applying the edit, build the edited modules and every direct and
transitive importer in the workspace, including sibling libraries and executables. Alternatively,
build every relevant library and executable target explicitly; `lake build` alone covers only the
configured default targets. Declaration-level `rdeps` helps prioritize inspection but cannot
select a complete rebuild: it misses `example`s and other source elaboration uses. Statement
hashes cannot fill that gap, since attributes can change without changing a constant's type or
value. For example, these two files compile:

```lean
-- A.lean
@[implicit_reducible] def Hidden := Nat
```

```lean
-- B.lean
import A
example (n : Nat) : Hidden := by
  with_implicit exact n
```

Removing the attribute leaves `A` compiling with identical type/value hashes for `Hidden` and
no declaration-level dependents, but `B` fails. Include `B` through its module import edge.

**The absorber test.** `change`, `show … from`, `erw` and a transparency flag are visible
unfolding steps. Delete one and the proof may still compile, because a later `exact`, `rfl`,
`apply`, `refine`, `simpa` or term after `:=` now unfolds the same definitions at default
transparency. The debt moved; it was not paid. `with_implicit tacs` sets the ambient transparency
to `.implicit`, which unfolds only `@[reducible]`, `@[instance_reducible]` and
`@[implicit_reducible]` definitions. Tactics and nested term elaborators can override that
setting, so the outer wrapper alone does not establish tier 3. Call the original text O and the
edited one D. In both, wrap each later tactic that unifies against the goal in `with_implicit`:

- D fails where O passes: the edit moved unfolding into that tactic. Keep the debt.
- Both fail: accept only if the goals at that tactic are identical in O and D (goal identity,
  below).
- Both pass: check that the inner operations also respect the intended transparency. Use an
  operation-specific check in both texts, with a control that fails when unfolding a plain
  definition is required. If an inner operation cannot be checked, the result is inconclusive
  at tier 3; retain the item.

For a deleted `change T` or `show T` there is a direct test too: re-insert it in D as
`with_implicit change T`. If that elaborates, the step did only implicit-level work. This is
sufficient, not necessary.

Traps:

- *A flag blinds the test.* Under `set_option backward.isDefEq.respectTransparency false`,
  implicit arguments unify at default transparency whatever `with_implicit` says. Inside a
  flagged declaration, test each tactic as
  `set_option backward.isDefEq.respectTransparency true in with_implicit <tac>`. For `erw → rw`,
  run both under the forced flag: if `erw` passes and `rw` fails, the flag absorbed the `e`; if
  `erw` fails too, the step is entangled with the flag. Keep it in both cases.
- *`erw` sets `.default` in its own configuration*, so `with_implicit erw …` restricts nothing.
  Test the demoted `rw` in context. Conversely, `with_implicit rw` can match where plain `rw`
  fails, so compile the unwrapped text as well.
- *Term elaboration can pass through the outer wrapper.* Both of these proofs compile on
  Lean v4.33 with the flag forced on:

  ```lean
  def hiddenNat : Nat := 0

  set_option backward.isDefEq.respectTransparency true in
  example : hiddenNat = 0 := by
    change 0 = 0
    with_implicit exact (show _ from rfl)

  set_option backward.isDefEq.respectTransparency true in
  example : hiddenNat = 0 := by
    with_implicit exact (show _ from rfl)
  ```

  The retained term absorbs the deleted `change`. Replacing the final tactic with
  `with_implicit rfl` passes in O and fails in D, exposing the unfolding. Use this tactic-level
  check for term `rfl`; passing `with_implicit exact …` alone is insufficient. These are test
  variants, not repairs to the proposed edit.

**No repairs.** An edit that needs a new `exact`, a `have h : a = b := rfl` restating an equation
for a later `rw`, or a type ascription has moved the debt. A tool or agent that proposes removals
should propose only deletions, flag deletions and `erw → rw`, and report everything else as a
seam to fix (§4). In one cleanup a large share of the removals that compiled failed this tier,
and most `erw → rw` demotions inside flagged declarations did.

**Goal identity.** aftk's `goals` and `--goals-at` return pretty-printed text: proofs and deep
subterms print as `⋯` and instance paths are hidden, so equal printouts prove nothing. Compare
hashes: a `run_tac` in the probed text can log the `Expr.hash` of the instantiated target and of
each hypothesis type, and the value comes back in the probe's diagnostics. When the two goals
come from separate elaborations, close over the local context first (`mkForallFVars`), because
free-variable ids differ. To see the intermediate goal of a rewrite that closes the goal, split
`erw [..]` into `rewrite (transparency := .default) [..]` followed by
`try (with_reducible rfl)` (and a `rw [..]` into `rewrite [..]` followed by
`try (with_reducible rfl)`).

## 2. Statement hashes

A declaration can compile without its flag while its statement elaborates differently: a lemma
generated by `@[simps]` or a similar attribute comes out in another form, or a coercion takes
another path. Only a downstream `rw` notices, sometimes several files away. Before and after
each batch, hash every constant of the edited modules from the built environment, both its type
and its proof-erased value.

- Hash `Expr`s, not `pp.all` strings: pretty-printing elides deep subterms as `⋯`.
- Iterate each module's `constNames` in `env.header.moduleData`. They include private names and
  generated constants (`_proof_N`, `.eq_N`, `congr_simp`). Check that your walk sees them; one
  home-made walk missed every `.eq_N`.
- Print how many constants were hashed, and run the hash twice to show that it is deterministic.

Classify generated constants before calling a difference drift. `simp only` creates
`congr_simp` lemmas on demand; `rw [f]` materialises `f.eq_1` where `unfold f` does not; a
deleted `simp` proof drops its `_simp_1_*` auxiliaries; `_proof_N` constants renumber. An edit
to a proof embedded in a statement changes the raw type hash but not the proof-erased one, and
that change is legitimate. Any other change rejects the removal. When drift breaks a consumer,
fix the lemma whose statement the failing pattern mentions, not the consumer.

## 3. Sweeps: controls, errors, attribution, triggers

**Controls.** Before trusting a harness (a sweep script, a `probe` loop, a regex over
diagnostics), show it one input that must fail and one that must pass. The original declaration
without its flag must fail, or time out at the default budget; the unedited file must be clean.
A check that is true by construction proves nothing: local attributes never leak through
`import`, so test their scoping inside the file. A `#lint` that reports on 0 declarations
scanned nothing.

**Render variants that parse.** An `erw → rw` replacement keeps the tactic's width (`rw ` with a
trailing space), so later columns stay put. A multi-line `change` re-inserted after
`with_implicit ` needs its continuation lines shifted right, or joined onto one line. Blank a
removed line instead of deleting it, so that line numbers and aftk ranges stay put. A variant
that does not parse is *no verdict*.

**Errors run in both directions.**

| error | effect | guard |
|---|---|---|
| a flag or a later closer absorbs the step | false "removable" | the absorber test, flag forced on (§1) |
| prose matched as syntax (a docstring line starting with `change`) | false "removable" | aftk's info-tree findings, or a token scan that masks comments |
| the edit trips a style linter (line length, say) | false "load-bearing" | render edits style-neutral |
| one error blamed on every flag of a declaration | false "load-bearing" | retest each rejection on its own |
| a regex on `error: ` misses coded errors such as `error(lean.unknownIdentifier): …` | wrong verdicts | count by `severity` (aftk's `diagnostics` JSON has it) |

A flag and the tactics after it are coupled. Removing `respectTransparency false` can make a
trailing `rfl` dead ("no goals", because `simp` now closes the goal), and restoring the flag can
make a deleted `rfl` necessary again. Keep or revert both halves together.

**Screen cheaply, then test singly.** Strip a whole class at once, then test the survivors one
at a time. A `set_option … in` covers only its own declaration, so for such flags stripping all
of them tests each one, unless a stripped declaration's error or statement drift cascades into a
later one in the same file; retest those one at a time, in file order. For items inside
declarations that already error, append a renamed copy of each declaration, attributes
stripped, with exactly one item removed; one compile then tests every item in its original
context.

**"Freed by X" needs a tree that differs only by X.** Before crediting a dependency bump, an
upstream fix, a new tag or an instance-priority change with freeing debt, run the same check in
a second built tree without X. Items that pass in both trees were dead all along; in one cleanup,
every item "freed" by a routine bump also passed before it. After an instance-priority change
the same text can elaborate to different instances, so compile both texts in both trees.

**Sweep when the cause moves, not on a calendar.** Debt dies silently. An `@[implicit_reducible]`
tag or an upstream fix can free flags, `erw` and `change` in every declaration that depends on
the tagged definition. After one lands, re-sweep every class in the dependents `rdeps` lists. A
class nobody has swept, often `change` because aftk does not report it, still holds dead items.

## 4. Transparency flags, seams and the leave-one-out tag test

By default Lean checks implicit arguments, instance arguments and the types of metavariable
assignments at `.implicit` transparency, which unfolds `@[reducible]`, `@[instance_reducible]`
and `@[implicit_reducible]` definitions but not a plain `def`.
`set_option backward.isDefEq.respectTransparency false` raises those checks to `.default` for the
whole declaration. So each such flag sits where a plain `def` separates two spellings of one
object; call that `def` a *seam*. Because the flag covers the whole declaration, it hides which
step needs which constant. `erw`, `change`, `show … from` and `id (α := …)` are the same seam,
visible at one site. aftk reports the flag (`backwardOption`) and `erw`, not the other three.

**Find the seam by compiling, not by reading.**

1. In a scratch tree, strip every flag in the file and run `diagnostics` once.
2. Group the errors by declaration, counting by `severity`.
3. For a failing declaration, insert a candidate line such as
   `attribute [local implicit_reducible] MyLib.X MyLib.Y in` above it with `probe --at L:1`, and
   run leave-one-out over the names. `accepted` covers the whole file, so judge each variant by
   the errors inside that declaration's range.
4. Promote the survivors that are your own definitions to `@[implicit_reducible]` on the `def`
   itself, then run the full build.

`attribute [local reducible] X` is rejected; use `implicit_reducible`. A constant from a
dependency takes only the `local` form (a global one fails with "has not been defined in this
file"), so that local line is an upstream candidate (§9). A tag is not always enough, and
tagging a recursive definition is a separate decision.

**Name the seam per step.** `set_option diagnostics true` lists the declarations a step unfolded
(lower `diagnostics.threshold` to see rare ones). For the minimal set, re-run the step under
`with_implicit` with local tags on the candidates, leaving one out at a time, with the flag
forced on. The set says what to write: an API or equation lemma for those constants, or a tag.
After the fix, probe the *next* tactic; a larger set there means the fix only moved the seam. To
test whether an `rfl` relies on default transparency, use the *tactic* `rfl` under
`with_implicit`: a term-mode `rfl` inside `exact` can pass where the tactic fails.

**`erw` specifics.** `erw` is `rw` whose pattern matching runs at default transparency, so each
call marks a place where a lemma's statement and the goal disagree syntactically. Fixes, in order
of preference: restate the lemma in the goal's spelling; add a lemma at the junction; tag your
own `def` between the spellings; only then a scoped flag. An `erw` inside a `def` body builds a
*term*, so demoting it can change the definition: check its hash and its dependents. Accept or
reject demotions that are safe only together as a pair. A declaration-level
`set_option backward.isDefEq.respectTransparency true in` shadows a file-level `false`.

**Tags are debt too.** A global `@[implicit_reducible]` changes unfolding in every downstream
file, where it can break a proof that worked by accident, and a tag in a low-level file rebuilds
every importer. Run leave-one-out over existing tags too; dead ones turn up. Report every new
tag, flag or unusual `simp` configuration at the top of a summary as debt added.

**Fix at the root, bottom-up.** `set_option` does not propagate through `import`, but its cause
lives in an upstream definition that downstream files keep paying for. Fix the lowest dependency
level first, and within a level order by per-declaration blast radius from `rdeps`. Bundle each
seam fix with the flags it frees. Prevent new seams by giving each object one spelling: state the
API in the spelling its maps produce, and let another spelling appear only in a one-line
corollary. A named `abbrev` for yet another spelling adds a seam.

## 5. `rfl` lemmas that never fire

A generated `rfl` lemma (an equation lemma, one from `@[simps]` or a similar attribute) is tagged
`@[defeq]` only if its two sides are defeq at `.implicit` transparency; otherwise it gets only
`@[backward_defeq]`, which `dsimp` ignores unless `backward.defeqAttrib.useBackward` is set. A
hand-written body of exactly `:= rfl` is tagged by a more lenient path; `(rfl)`, `by rfl` and
`Eq.refl _` are not tagged. Many of Mathlib's own generated lemmas are backward-only, so expect
this in any Mathlib-dependent project.

`simp` rewrites in dependent positions only through `dsimp`, so the symptom is "this simp
argument is unused", not an error. Plain `rw` then fails with "motive is not type correct", and
Mathlib's `rw! (castMode := .all)` works by inserting casts (the default mode casts only proofs).
A `useBackward` flag therefore carries lemmas nobody can see;
`set_option trace.Meta.Tactic.simp.backwardDefEq true` lists the ones it used.

The real fix is at the definition: `@[implicit_reducible]` where it is defined (next to `@[simps]`
if that generates the lemmas) makes those `rfl` lemmas `@[defeq]` whose sides then agree at
`.implicit` (usually most of them). Downstream you cannot do this, because `defeq` is a global
tag that only the defining module can set. What remains downstream (`rw! (castMode := .all)`, a
named `:= rfl` twin checked with `by with_implicit rfl`, or the `useBackward` flag) is a
workaround and an upstream candidate (§9).

**Indexing.** `simp [c]` indexes `c`'s left-hand side deeply, down to implicit type arguments,
so a goal that spells those types differently never retrieves it. `simp [c _]` acts as a
per-lemma `no_index`; `simp -index` drops indexing for the whole set and can be very slow. Both
are workarounds to track, not fixes. A clean `#lint only simpNF` does not prove that a `@[simp]`
lemma fires: run `simp` on its own left-hand side.

## 6. Measuring: heartbeats, kernel, build time

**Budgets come from pass/fail compiles of the final text.** Size or retire a `maxHeartbeats`
override by bisecting `set_option maxHeartbeats N in` on the declaration's final text. `N` is in
thousands of raw heartbeats and `0` means unlimited. Drop an override only if the text passes at
150000, 75 % of the default 200000, so that ordinary upstream drift does not bring it straight
back. A budget measured on a draft goes stale: re-measure after the last edit, and update every
comment that cites it.

**Profiles compare texts; they are not budgets.** `trace.profiler` with
`trace.profiler.useHeartbeats` counts tracing overhead, so a profiled run can time out at the
default on a declaration whose plain compile passes at 75 % of it. A theorem's proof elaborates
asynchronously, so its cost sits in a separate `[Elab.async]` node: read it as well as the
command's root, and keep `trace.profiler.threshold` below the proof's cost. Keep elaboration,
kernel and linter costs apart. The "before" number for a fix is the new text with only that fix
reverted.

**Before raising a budget, look for a spelling problem.** A `?m` where a coercion or a universe
should be is the usual culprit. A coercion left as a metavariable in a structure instance's field
types can turn a proof-irrelevance check into a `whnf` explosion; one type ascription fixes it.
An unpinned spare universe parameter creates postponed level problems such as `max u ?v =?= u`,
and Lean caches an `isDefEq` result only when the check added no postponed level constraint, so
every comparison that touches the spare universe is redone. Diagnose with `pp.universes` or
`trace.Meta.isLevelDefEq.stuck`, and pin every universe parameter. During a dependency bump, a
heartbeat timeout in `whnf` or `isDefEq` is usually a type mismatch the unifier cannot refute:
raise the limit only to read the real error.

**Kernel cost is its own class.** A module can spend its time in the kernel while elaboration
stays flat; such a file barely responds to elaboration savings. Localise the cost in a scratch
copy: split the proof into standalone theorems, or turn a step into an `axiom` to bound its
share. Fixes that worked: prove the fact once at a generality where both spellings are cheap to
compare, and rewrite with equation lemmas stated in the target spelling instead of unfolding. A
structural refactor can move cost into the kernel (a structure's recursor, `noConfusion` and
`sizeOf` each re-check its fields), so measure the kernel separately after one. In one cleanup,
kernel heartbeats were deterministic from run to run, and a twin theorem under
`set_option maxHeartbeats N in` turned a dependency-only probe into a pass/fail bisection.

**Build time is an experiment.** On a many-core machine, cold-build wall time is the import
graph's critical path; on a few-core runner it is roughly CPU time ÷ cores. CPU time is the
total work. On a many-core machine, removing debt off the critical path buys robustness, not
speed. Build each commit in its own clone, at least three cold builds per commit in alternating
order, on an idle machine; measure the run-to-run spread first, treat smaller steps as noise, and
compare user CPU. Times taken while agents compile are not evidence. Confirm a suspect with a
swap test (replace only it in an otherwise identical clone), and time the intermediate commits of
a branch that also bumps the toolchain.

## 7. Counting

**Which overrides count at which value.** `maxHeartbeats` (with `synthInstance.maxHeartbeats`),
`maxRecDepth`, `maxSynthPendingDepth`, `backward.*` and `linter.style.longFile` count at any
value. `linter.flexible`, `linter.overlappingInstances`, `linter.auxLemma`, `linter.deprecated`,
`linter.unused*` and `warning.simp.varHead` count only when set to `false`; no other `linter.*`
option is a built-in finding. `autoImplicit`/`relaxedAutoImplicit` count only when `true`, and
`debug/pp/profiler/trace.*` unless `false`. `simpInstances`/`dsimpInstances` match only
`+instances` on `simp`/`dsimp`. Only syntax written in the source counts.

**One unit.** aftk counts `erw` per call; a tracker that counts rewrite rules will not match, so
compare calls with calls. Units also change under you: scoping one file-level `set_option` into
per-declaration `set_option … in` lines raises the line count while the debt falls. When the
unit changes, recompute every historical row under the new rule, and headline a shape metric
(such as "no file-level flags") until the trend is comparable again.

**Diff by `key`, additions first.** Keep every scan's JSONL, partitioned by `keyVersion`. After
a bump, a campaign or an agent batch, list new keys first and report each added flag, tag or
override with its declaration and why it was unavoidable. Flags added to get a bump green are
debt added: once the tree is green, retest each one. Renames change keys, so pair the removals
and additions of renamed declarations by hand.

**Compare warnings with a documented target, by message.** "Same warnings as last time" passes
forever once a regression is in the baseline, for example a linter change that arrives with a
dependency bump. List a cold build's warnings by message and account for each against the target
the project writes down. Record a deferred fix next to the documented target when you defer it,
not only in a PR description.

**Coverage and numbers.** Beyond the coverage line of `SKILL.md` gotcha 2: a script that drops
a whole `rdeps` batch on a nonzero exit loses every resolved name because a few were
`unresolved`. Compare projects by density (findings per thousand lines), not raw count. Never
hand-type a number a tool computes: link the generated output, derive history by recomputing
past commits, name items instead of counting them, and check each entry against the tree when
you write it.

## 8. Bulk edits and agents

**Let the compiler scope flags.** To turn a file-level `set_option` into per-declaration lines,
remove it, rebuild, re-add `set_option … in` only where the compiler objects, and iterate until
nothing changes. Placement traps: `set_option … in` goes above a declaration's docstring (between
docstring and declaration it is a parse error); above a `/-! … -/` block it binds to that block
and does nothing for the next declaration.

**Anchor scripted edits on the construct, never on a line.** Lean proofs repeat shapes, so an
edit keyed on a line number, a first match, a backwards walk from an error or a substring can hit
another, working, site. Anchor on aftk findings (`declarations` plus `range`) from a scan of
exactly the text you edit. Generate every candidate from the frozen original plus a set of
removals, and never let a transform read its own output. Before a home-made parser judges
anything, run it on a nasty sample: a docstring whose last line is a `-- … -/` comment, a
docstring line that starts with a tactic name, `/-` inside prose, a comment between a docstring
and its declaration, a one-line `set_option … in rw […]`, and one input it must reject. Compile
each rule on one site before fanning it out; one wrong rule is replicated at every site.

**Some fixes change statements.** Clearing an unused-section-variable warning means `omit … in`,
and omitting a named hypothesis changes the declaration's explicit arity, shifting every
positional caller. Weakening an instance binder or dropping an unused argument changes the
statement too. Keep such fixes out of unattended sweeps, or gate them on a statement hash that is
expected to change. Never clear a linter finding with `set_option linter.X false`.

**Throttle Lean machine-wide.** Several agents that each run parallel compiles can exhaust memory
although each brief was safe alone. Route every compile through one shared slot pool (a `flock`
wrapper with a few slots, which is also the place to add the build's `-D` options), count aftk's
`--jobs` workers and open daemon workers against it, and forbid `&`, `xargs -P` and backgrounded
compiles in agent briefs. Measure one check before sizing a fan-out.

**One build per workspace, no pattern kills, verdicts from the log.** Two concurrent
`lake build`s in one workspace overwrite each other's `.olean`s. Record the PID of every build
you start, stop only those, and never use a `pkill` pattern: it can match your own shell and
other sessions' Lean. Killing a `timeout … lake build` wrapper leaves `lake` running. For aftk's
daemon and workers, use `close`, `gc` or `shutdown`, never a signal. `lake build … | grep`
returns grep's status; read the log's final verdict line instead. A session restart can leave
compiles behind: save each finished result to a file and use unique scratch paths per run.

**Pair every fixer with a skeptic.** A second agent, in its own clone, re-measures every number,
redoes the `with_implicit` tests and rebuilds a file with only the accepted edits. Review scripts
and tracker prose as well as Lean, and diff each agent's output for unreported edits. Tell fixers
to repair only the failing step; "left unchanged" is a good outcome.

## 9. Upstream candidates

**Harvest from the code.** Every `attribute [local implicit_reducible] Dep.X`, or other local
attribute on a dependency's constant, is a candidate to tag `Dep.X` where it is defined. So is
every project declaration inside a dependency's namespace, and every workaround aimed at a
dependency's lemma (`rw!` or `simp [c _]` around a backward-only `@[simp]` lemma, a universe
pin). For each, record the exact change, the upstream file and what it retires downstream.

**Check each candidate against upstream, by name and by file.** Search upstream master and open
*and draft* PRs by name, then scan the file lists of open PRs for the candidate's target file;
that finds a PR that rewrites the statements there. A hit turns a proposal into a review or a
coordination. If you keep a local copy of the change until it lands, give it the declaration
names the open PR uses. Re-check PR states when the list is reviewed, not only when it is
gathered, and keep the durable content (change, file, what it retires) apart from the volatile
status. Read the upstream file's TODOs and recent PRs first: they may ask for a refactor, or for
API lemmas instead of a tag.

**An upstream report stands alone.** It imports only the dependency and runs both ways against
the pinned version: as is, showing the error or the flag it needs, and with the change emulated
by an `attribute [local …]` line, compiling clean. Say which downstream hand-written bridges will
stop compiling once it lands. Leave out every reference to the consuming project.
