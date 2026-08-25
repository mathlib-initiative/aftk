#!/usr/bin/env bash
# Scan every module of a Lean library with `aftk tech-debt`, one fresh process per module, in parallel.
#
#   <skill-dir>/scripts/scan_modules.sh <Library>|- [jobs] [markers]  > findings.jsonl
#
#   <Library>  library name AND root directory in the default Lake layout (<Lib>.lean + <Lib>/**/*.lean),
#              e.g. `MyLib`. A trailing `/` or leading `./` is tolerated. Libraries with a custom
#              srcDir/roots are not enumerated by this filesystem walk: pass `-` and feed module names
#              on stdin instead (one per line).
#   [jobs]     parallel processes (default 4; each needs ~2-3 GB for a Mathlib-sized import closure)
#   [markers]  comma-separated marker list, e.g. `backwardOption,erw,sorry` (default: all markers)
#
# Run with the Lake project root as the working directory.
#
# Why not `tech-debt library <Library>`: that scope elaborates all modules serially in ONE process
# with a leaked environment per module (memory grows without bound) and aborts on the first module
# that fails to elaborate.  Per-module processes are bounded, parallel, and keep going.
#
# Modules that fail to elaborate (e.g. because they need the workspace's `[leanOptions]`, which
# `tech-debt` does not apply) are listed on stderr at the end with the first line of their error;
# set SCAN_ERR_DIR=<dir> to keep each failed module's full stderr as <dir>/<module>.err (the work
# directory itself is removed on exit).  Exit status: 0 when every module was scanned, whether or
# not some failed to elaborate (they are reported, not fatal); 2 on usage errors.
set -euo pipefail

ARG=${1:?usage: scan_modules.sh <Library>|- [jobs] [markers]}
JOBS=${2:-4}
MARKERS=${3:-}
LIB=${ARG#./}; LIB=${LIB%/}
if [[ $ARG != - ]]; then
  [[ $LIB == /* || $LIB == ../* || $LIB == *..* ]] && { echo "give the library relative to the project root, e.g. MyLib" >&2; exit 2; }
  [[ -d "$LIB" || -f "$LIB.lean" ]] || { echo "no library directory or root file for '$LIB' here; run from the project root" >&2; exit 2; }
fi
ROOTMOD=${LIB//\//.}

# Must run at the Lake project root of a project that requires aftk.  This call also builds `aftk`
# once if it is stale, so the parallel workers below never start concurrent Lake builds (Lake has no
# build lock) and never see Lake log lines in their stderr.
lake exe aftk --help > /dev/null \
  || { echo "cannot run 'lake exe aftk' here: run from the project root (lakefile.toml/lakefile.lean) of a project that requires aftk" >&2; exit 2; }

WORK=$(mktemp -d "${TMPDIR:-/tmp}/aftk-scan-XXXXXX")
trap 'rm -rf "$WORK"' EXIT

# Enumerate modules.  Only walk the directory when it exists: a root-only library makes `find`
# exit 1, and under `set -eo pipefail` that would silently abort the whole script.
if [[ $ARG == - ]]; then
  sed -e 's/[[:space:]]*$//' -e '/^$/d' | sort > "$WORK/modules.txt"
else
  { [[ -f "$LIB.lean" ]] && echo "$ROOTMOD"
    if [[ -d "$LIB" ]]; then find "$LIB" -name '*.lean' | sed -e 's#\.lean$##' -e 's#/#.#g'; fi
    true; } | sort > "$WORK/modules.txt"
fi
if [[ ! -s "$WORK/modules.txt" ]]; then
  echo "no .lean modules found for '$LIB' (expected $LIB.lean and/or $LIB/**/*.lean)" >&2
  exit 2
fi

export WORK MARKERS
scan_one() {
  # Rebuild the option array here: arrays cannot be exported to the `bash -c` workers, and
  # `"${sel[@]}"` keeps a marker list containing spaces as ONE argument.
  local m=$1 sel=(--all-markers)
  [[ -n ${MARKERS:-} ]] && sel=(--markers "$MARKERS")
  if ! lake exe aftk tech-debt "${sel[@]}" --jsonl module "$m" > "$WORK/$m.jsonl" 2> "$WORK/$m.err"; then
    echo "$m" >> "$WORK/failed.txt"
  fi
}
export -f scan_one

# NUL-delimit the names: plain xargs treats `'` as a quote (`xargs -d` would do, but is GNU-only).
# -r: with no input xargs would otherwise run the worker once with no argument.
# The item arrives as $1; $0 is a label so bash error messages say `scan_one: ...`.
tr '\n' '\0' < "$WORK/modules.txt" | xargs -0 -r -P "$JOBS" -n 1 bash -c 'scan_one "$1"' scan_one

cat "$WORK"/*.jsonl
if [[ -s "$WORK/failed.txt" ]]; then
  echo "modules that failed to elaborate (findings missing), with the first line of each one's stderr:" >&2
  while IFS= read -r m; do
    first=$(grep -m1 -v '^$' "$WORK/$m.err" || true)
    printf '  %s: %s\n' "$m" "${first:-<no stderr output>}" >&2
    if [[ -n "${SCAN_ERR_DIR:-}" ]]; then mkdir -p "$SCAN_ERR_DIR"; cp "$WORK/$m.err" "$SCAN_ERR_DIR/$m.err"; fi
  done < "$WORK/failed.txt"
  [[ -n "${SCAN_ERR_DIR:-}" ]] && echo "full stderr of each failed module kept in $SCAN_ERR_DIR/<module>.err" >&2
  echo "a common cause is workspace [leanOptions] that tech-debt does not apply (it elaborates with Options.empty)" >&2
fi
