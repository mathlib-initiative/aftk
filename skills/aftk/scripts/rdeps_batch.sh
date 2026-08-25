#!/usr/bin/env bash
# Reverse dependencies for many declarations: one `aftk rdeps` per name, in parallel.
#
#   <skill-dir>/scripts/rdeps_batch.sh <RootModule> <outdir> [jobs] [module-pattern] < names.txt
#
#   <RootModule>      the module whose import closure is searched — name the LIBRARY ROOT
#                     (e.g. `MyLib`), otherwise dependents in importing modules are invisible
#   <outdir>          per input name: `<file>.tsv` (module \t declaration per row), `<file>.err`
#                     (stderr) and `<file>.rc` (exit status of `lake exe aftk`), where <file> is
#                     the name with `/` replaced by `∕` (U+2215) — `/` cannot be a file-name
#                     character (notation names such as `«term_/_»`)
#   [jobs]            parallel processes (default 3; each ~3 GB for a Mathlib-sized closure)
#   [module-pattern]  output filter, default 'RootModule.*'
#   stdin             fully qualified declaration names, one per line (blank lines dropped,
#                     trailing whitespace stripped — aftk does not trim names)
#
# Run with the Lake project root as the working directory.
#
# Afterwards, judge by the exit status in `.rc`, not by stderr: `.rc` = 0 with an EMPTY `.tsv`
# means the declaration has no dependents in the filtered modules (a leaf); `.rc` != 0 means aftk
# failed — almost always an unresolved name (`error: declaration … was not found`; nested
# namespace? private?) — resolve it from the environment and retry.
#
# Exit status: 0 when every name was processed (unresolved names are COUNTED in the summary, not
# fatal); 1 if some `.err` holds an error other than "was not found in the environment" (missing
# .olean, OOM-killed worker, …); 2 on usage errors.  Safe to call under `set -e`.
set -uo pipefail

ROOT=${1:?usage: rdeps_batch.sh <RootModule> <outdir> [jobs] [module-pattern] < names.txt}
OUT=${2:?usage: rdeps_batch.sh <RootModule> <outdir> [jobs] [module-pattern] < names.txt}
JOBS=${3:-3}
PATTERN=${4:-"$ROOT.*"}

# Must run at the Lake project root of a project that requires aftk; also builds `aftk` once if it
# is stale, so the parallel workers never race a Lake build (Lake has no build lock).
lake exe aftk --help > /dev/null \
  || { echo "cannot run 'lake exe aftk' here: run from the project root (lakefile.toml/lakefile.lean) of a project that requires aftk" >&2; exit 2; }
mkdir -p "$OUT"
export ROOT OUT PATTERN

one() {
  local n=$1 f=${1//\//∕}
  # aftk exits 1 for an unresolved name; that is a counted outcome (see the summary), so do not let
  # it reach xargs, which would turn one such name into exit 123 for the whole batch.
  lake exe aftk rdeps "$ROOT" "$n" --modules "$PATTERN" > "$OUT/$f.tsv" 2> "$OUT/$f.err"
  echo $? > "$OUT/$f.rc"
}
export -f one

# NUL-delimit the names: Lean names may contain `'`, which plain xargs treats as a quote — it stops
# at that line (`xargs: unmatched single quote`, exit 1) after running the earlier names, so every
# later name would be missing.  `xargs -d '\n'` also works but is a GNU extension.  -r: never run
# the worker with no argument.
sed -e 's/[[:space:]]*$//' -e '/^$/d' | tr '\n' '\0' \
  | xargs -0 -r -P "$JOBS" -n 1 bash -c 'one "$1"' one
xrc=$?
if (( xrc >= 124 )); then echo "xargs could not run the workers (exit $xrc)" >&2; exit "$xrc"; fi

total=0; leaves=0; unresolved=0; other=0
for rcf in "$OUT"/*.rc; do
  [[ -e "$rcf" ]] || break
  total=$(( total + 1 )); base=${rcf%.rc}
  if [[ $(cat "$rcf") == 0 ]]; then
    [[ -s "$base.tsv" ]] || leaves=$(( leaves + 1 ))
  elif grep -q "was not found in the environment" "$base.err"; then
    unresolved=$(( unresolved + 1 ))
  else
    other=$(( other + 1 )); echo "FAILED (not a name-resolution error): $(basename "$base"): $(grep -m1 -v '^$' "$base.err" || true)" >&2
  fi
done
echo "rdeps batch: $total names, $leaves leaves (no dependents), $unresolved unresolved names, $other other failures" >&2
(( other == 0 ))
