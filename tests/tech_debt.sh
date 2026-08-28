#!/usr/bin/env bash
set -Eeuo pipefail

# End-to-end tests for semantic technical-debt detection.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROJECT=$(mktemp -d /tmp/aftk-tech-debt-test-XXXXXX)

cleanup() {
  rm -rf "$PROJECT"
}
trap cleanup EXIT

cat > "$PROJECT/lakefile.toml" <<'EOF'
name = "tech_debt_test"
version = "0.1.0"
defaultTargets = ["TechDebtTest", "ExtraDebt", "debt_runner"]

[leanOptions]
weak.maxRecDepth = 2048
weak.techDebtTest.required = true

[[require]]
name = "aftk"
path = "aftk-dependency"

[[lean_lib]]
name = "TechDebtTest"

[[lean_lib]]
name = "ExtraDebt"

[[lean_exe]]
name = "debt_runner"
root = "DebtRunner"
EOF
ln -s "$ROOT" "$PROJECT/aftk-dependency"
cp "$ROOT/lean-toolchain" "$PROJECT/lean-toolchain"
mkdir -p "$PROJECT/TechDebtTest" "$PROJECT/ExtraDebt"
cat > "$PROJECT/TechDebtTest.lean" <<'EOF'
module
import TechDebtTest.Example
import TechDebtTest.Markers
import TechDebtTest.OptionRequired
EOF
cat > "$PROJECT/TechDebtTest/Dependency.lean" <<'EOF'
module

set_option maxHeartbeats 200000

def dependencyValue : Nat := 1
EOF
cat > "$PROJECT/TechDebtTest/Example.lean" <<'EOF'
module
import TechDebtTest.Dependency

set_option maxHeartbeats 1000000
set_option maxRecDepth 2000

theorem usesErw (a b : Nat) (h : a = b) : a = b := by
  erw [h]

macro "erewrite " rule:term : tactic => `(tactic| erw [$rule:term])

theorem usesErewrite (a b : Nat) (h : a = b) : a = b := by
  erewrite h

theorem usesOrdinaryRewrite (a b : Nat) (h : a = b) : a = b := by
  rw [h]

set_option maxHeartbeats 1000000 in
theorem scopedHeartbeat : True := by
  trivial

-- Comments mentioning `erw` or `set_option maxHeartbeats` are not findings.
EOF
cat > "$PROJECT/TechDebtTest/MarkerSupport.lean" <<'EOF'
module
public import Lean

public register_option backward.example : Bool := { defValue := true, descr := "test option" }
public register_option linter.flexible : Bool := { defValue := true, descr := "test option" }
public register_option linter.overlappingInstances : Bool := { defValue := true, descr := "test option" }
public register_option linter.auxLemma : Bool := { defValue := true, descr := "test option" }
public register_option linter.style.longFile : Nat := { defValue := 1000, descr := "test option" }
public register_option linter.style.setOption : Bool := { defValue := true, descr := "test option" }
public register_option techDebtTest.required : Bool := { defValue := false, descr := "test option" }

open Lean
open Lean.Parser.Tactic.Conv

elab "#require_option " optionName:ident : command => do
  unless (← getOptions).getBool optionName.getId false do
    throwError "required Lake option `{optionName.getId}` was not applied"

macro "conv_lhs" " => " convTac:conv : tactic => `(tactic| conv => lhs; $convTac)

public section

syntax (name := nolintAttr) "nolint " ident : attr
initialize Lean.registerBuiltinAttribute {
  name := `nolintAttr
  descr := "test attribute"
  add := fun _ _ _ => pure ()
}

syntax (name := otherAttr) "other_attribute " ident ident : attr
initialize Lean.registerBuiltinAttribute {
  name := `otherAttr
  descr := "test attribute whose arguments resemble technical-debt markers"
  add := fun _ _ _ => pure ()
}

macro "#adaptation_note" : command =>
  `(command| theorem adaptationNoteCommandMarker : True := True.intro)
macro "#adaptation_note" : tactic => `(tactic| skip)
macro "#adaptation_note " value:term : term => `($value)

namespace Fin.CommRing
public def marker : Nat := 1
end Fin.CommRing

namespace Fin.NatCast
public def marker : Nat := 1
end Fin.NatCast

end
EOF
cat > "$PROJECT/TechDebtTest/OptionRequired.lean" <<'EOF'
module
import TechDebtTest.MarkerSupport
meta import TechDebtTest.MarkerSupport

#require_option techDebtTest.required

EOF
printf 'def lakeLibraryOptionsApplied : Nat := ' >> "$PROJECT/TechDebtTest/OptionRequired.lean"
for ((i = 0; i < 700; i++)); do printf 'Nat.succ (' >> "$PROJECT/TechDebtTest/OptionRequired.lean"; done
printf '0' >> "$PROJECT/TechDebtTest/OptionRequired.lean"
for ((i = 0; i < 700; i++)); do printf ')' >> "$PROJECT/TechDebtTest/OptionRequired.lean"; done
printf '\n' >> "$PROJECT/TechDebtTest/OptionRequired.lean"
cat > "$PROJECT/TechDebtTest/Markers.lean" <<'EOF'
module
import TechDebtTest.MarkerSupport
meta import TechDebtTest.MarkerSupport

set_option maxHeartbeats 1000 in
def heartbeatMarker : Nat := 1

set_option synthInstance.maxHeartbeats 1000 in
def synthHeartbeatMarker : Nat := 1

def recursionDepthMarker : Nat := set_option maxRecDepth 100 in 1

def backwardMarker : Nat := set_option backward.example false in 1

theorem flexibleMarker : True := by
  set_option linter.flexible false in
    trivial

set_option linter.overlappingInstances false in
def overlappingInstancesMarker : Nat := 1

set_option linter.auxLemma false in
def auxiliaryLemmaMarker : Nat := 1

set_option linter.deprecated false in
def deprecationLinterMarker : Nat := 1

set_option warning.simp.varHead false in
def simpVarHeadMarker : Nat := 1

set_option pp.universes true in
def developmentOptionMarker : Nat := 1

set_option linter.style.longFile 2000

section
unlock_limits
def unlockedMarker : Nat := 1
end

theorem simpInstancesMarker : True := by
  simp +instances

theorem dsimpInstancesMarker : True := by
  dsimp +instances

#adaptation_note

theorem tacticAdaptationMarker : True := by
  #adaptation_note
  trivial

def termAdaptationMarker : Nat := #adaptation_note 1

@[nolint simpNF]
def simpNFMarker : Nat := 1

def simpNFAttributeMarker : Nat := 1
attribute [nolint simpNF] simpNFAttributeMarker

@[expose] public section
def exposedMarker : Nat := 1
end

open Fin.CommRing in
def finCommRingMarker : Nat := marker

open Fin.NatCast in
def finNatCastMarker : Nat := marker

def sorryTermMarker : Nat := sorry

theorem admitTacticMarker : True := by
  admit

def replacement : Nat := 1

@[deprecated replacement (since := "2026-01-01")]
def oldReplacement : Nat := replacement

axiom axiomMarker : True

theorem erwMarker (a b : Nat) (h : a = b) : a = b := by
  erw [h]

theorem convErwMarker (a b : Nat) (h : a = b) : a + 0 = b := by
  conv_lhs => erw [Nat.add_zero]
  exact h

theorem multilineConvErwMarker (a b : Nat) (h : a = b) : a + 0 = b := by
  conv =>
    lhs
    erw [Nat.add_zero]
  exact h

set_option maxSynthPendingDepth 3 in
def synthesisPendingDepthMarker : Nat := 1

theorem unusedLinterMarker : True := by
  set_option linter.unusedSectionVars false in
    trivial

def autoImplicitMarker : Nat := set_option autoImplicit true in 1

set_option linter.unusedSimpArgs true in
def enabledUnusedLinterIsNotMarker : Nat := 1

def disabledAutoImplicitIsNotMarker : Nat := set_option autoImplicit false in 1

def relaxedAutoImplicitMarker : Nat := set_option relaxedAutoImplicit true in 1

theorem genericStyleTacticOption : True := by
  set_option linter.style.setOption false in
    trivial

def genericStyleTermOption : Nat := set_option linter.style.longFile 3000 in 1

-- Marker syntax inside quotations is data, not technical debt in this module.
macro "quoted_axiom" : command => `(command| axiom quoted : True)
macro "quoted_deprecated" : command => `(command| @[deprecated] def quoted : Nat := 0)
macro "quoted_sorry" : term => `(term| sorry)

/-- A declaration whose name is an attribute argument below. -/
def deprecated : Nat := 0

@[inherit_doc deprecated]
def current : Nat := deprecated

@[other_attribute nolint simpNF]
def unrelatedAttribute : Nat := 0

public section expose
def notExposed : Nat := 0
end expose

namespace Other
def Fin.CommRing : Nat := 0
def Fin.NatCast : Nat := 0
end Other

open Other (Fin.CommRing Fin.NatCast)
EOF
cat > "$PROJECT/ExtraDebt.lean" <<'EOF'
module
import ExtraDebt.Finding
EOF
cat > "$PROJECT/ExtraDebt/Finding.lean" <<'EOF'
module

theorem extraUsesErw (a b : Nat) (h : a = b) : a = b := by
  erw [h]
EOF
cat > "$PROJECT/DebtRunner.lean" <<'EOF'
module

set_option maxHeartbeats 300000

EOF
printf 'def lakeExecutableOptionsApplied : Nat := ' >> "$PROJECT/DebtRunner.lean"
for ((i = 0; i < 700; i++)); do printf 'Nat.succ (' >> "$PROJECT/DebtRunner.lean"; done
printf '0' >> "$PROJECT/DebtRunner.lean"
for ((i = 0; i < 700; i++)); do printf ')' >> "$PROJECT/DebtRunner.lean"; done
cat >> "$PROJECT/DebtRunner.lean" <<'EOF'

public def main : IO Unit := pure ()
EOF
cat > "$PROJECT/Orphan.lean" <<'EOF'
module

-- This file is deliberately outside every configured target.
set_option maxHeartbeats 400000
EOF
(cd "$PROJECT" && lake build)

printf 'test: tech-debt applies configured library and executable Lean options\n'
if (cd "$PROJECT" && lake env lean -DmaxRecDepth=512 TechDebtTest/OptionRequired.lean \
    > unconfigured-options.out 2>&1); then
  echo 'deep option fixture unexpectedly elaborated with the default recursion depth' >&2
  exit 1
fi
grep -q 'maximum recursion depth' "$PROJECT/unconfigured-options.out"
(cd "$PROJECT" && lake exe aftk tech-debt --jsonl --markers maxHeartbeats \
  module TechDebtTest.OptionRequired > configured-library-options.jsonl)
[[ ! -s "$PROJECT/configured-library-options.jsonl" ]]
(cd "$PROJECT" && lake exe aftk tech-debt --jsonl --markers maxHeartbeats \
  module DebtRunner > configured-executable-options.jsonl)
python3 - "$PROJECT/configured-executable-options.jsonl" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    findings = [json.loads(line) for line in stream if line.strip()]

assert [(finding["module"], finding["kind"]) for finding in findings] == [
    ("DebtRunner", "maxHeartbeats"),
], findings
PY

printf 'test: tech-debt finds every supported marker\n'
(cd "$PROJECT" && lake exe aftk tech-debt --jsonl --all-markers \
  module TechDebtTest.Markers > all-markers.jsonl)
python3 - "$PROJECT/all-markers.jsonl" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    findings = [json.loads(line) for line in stream if line.strip()]

assert [(finding["range"]["start"]["line"], finding["kind"]) for finding in findings] == [
    (5, "maxHeartbeats"),
    (8, "maxHeartbeats"),
    (11, "maxRecDepth"),
    (13, "backwardOption"),
    (16, "linterFlexible"),
    (19, "linterOverlappingInstances"),
    (22, "linterAuxLemma"),
    (25, "linterDeprecated"),
    (28, "simpVarHead"),
    (31, "developmentOption"),
    (34, "longFile"),
    (37, "unlockLimits"),
    (42, "simpInstances"),
    (45, "dsimpInstances"),
    (47, "adaptationNote"),
    (50, "adaptationNote"),
    (53, "adaptationNote"),
    (55, "simpNF"),
    (59, "simpNF"),
    (61, "exposePublic"),
    (65, "finCommRing"),
    (68, "finNatCast"),
    (71, "sorry"),
    (74, "sorry"),
    (78, "deprecated"),
    (81, "axiom"),
    (84, "erw"),
    (87, "erw"),
    (93, "erw"),
    (96, "maxSynthPendingDepth"),
    (100, "linterUnused"),
    (103, "autoImplicit"),
    (110, "autoImplicit"),
    (116, "longFile"),
], findings

option_findings = [
    finding for finding in findings
    if finding["kind"] in {
        "maxHeartbeats", "maxRecDepth", "maxSynthPendingDepth", "backwardOption",
        "linterFlexible", "linterOverlappingInstances", "linterAuxLemma",
        "linterDeprecated", "linterUnused", "autoImplicit", "simpVarHead",
        "developmentOption", "longFile",
    }
]
assert option_findings
assert all("detail" in finding and "scope" in finding for finding in option_findings)
assert all(
    "detail" not in finding and "scope" not in finding
    for finding in findings if finding not in option_findings
)
assert {
    (finding["range"]["start"]["line"], finding["detail"], finding["scope"])
    for finding in option_findings
} >= {
    (13, "backward.example false", "term"),
    (31, "pp.universes true", "command"),
    (96, "maxSynthPendingDepth 3", "command"),
    (100, "linter.unusedSectionVars false", "tactic"),
    (103, "autoImplicit true", "term"),
    (110, "relaxedAutoImplicit true", "term"),
}
PY

printf 'test: tech-debt selects arbitrary options by exact name or namespace\n'
(cd "$PROJECT" && lake exe aftk tech-debt --jsonl --option linter.style.* \
  module TechDebtTest.Markers > style-options.jsonl)
python3 - "$PROJECT/style-options.jsonl" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    findings = [json.loads(line) for line in stream if line.strip()]

assert [
    (finding["range"]["start"]["line"], finding["kind"], finding["detail"], finding["scope"])
    for finding in findings
] == [
    (34, "option", "linter.style.longFile 2000", "command"),
    (113, "option", "linter.style.setOption false", "tactic"),
    (116, "option", "linter.style.longFile 3000", "term"),
], findings
PY

(cd "$PROJECT" && lake exe aftk tech-debt --jsonl \
  --option linter.style.setOption --option=linter.style.setOption \
  module TechDebtTest.Markers > exact-option.jsonl)
python3 - "$PROJECT/exact-option.jsonl" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    findings = [json.loads(line) for line in stream if line.strip()]

assert [(finding["range"]["start"]["line"], finding["detail"]) for finding in findings] == [
    (113, "linter.style.setOption false"),
], findings
PY

(cd "$PROJECT" && lake exe aftk tech-debt --jsonl --markers longFile \
  --option linter.style.longFile module TechDebtTest.Markers > built-in-and-option.jsonl)
python3 - "$PROJECT/built-in-and-option.jsonl" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    findings = [json.loads(line) for line in stream if line.strip()]

assert [(finding["range"]["start"]["line"], finding["kind"]) for finding in findings] == [
    (34, "longFile"),
    (34, "option"),
    (116, "longFile"),
    (116, "option"),
], findings
PY

printf 'test: tech-debt validates option selectors\n'
if (cd "$PROJECT" && lake exe aftk tech-debt --option= module TechDebtTest.Markers \
    > empty-option.out 2> empty-option.err); then
  echo 'tech-debt unexpectedly accepted an empty option selector' >&2
  exit 1
fi
grep -q 'option selectors must not be empty' "$PROJECT/empty-option.err"
if (cd "$PROJECT" && lake exe aftk tech-debt --option 'linter.*.invalid' \
    module TechDebtTest.Markers > invalid-option.out 2> invalid-option.err); then
  echo 'tech-debt unexpectedly accepted a misplaced option wildcard' >&2
  exit 1
fi
grep -q 'invalid option selector' "$PROJECT/invalid-option.err"

printf 'test: tech-debt finds tactic- and conv-mode core erw syntax\n'
(cd "$PROJECT" && lake exe aftk tech-debt --jsonl --markers erw \
  module TechDebtTest.Markers > erw-markers.jsonl)
python3 - "$PROJECT/erw-markers.jsonl" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    findings = [json.loads(line) for line in stream if line.strip()]

assert [(finding["range"]["start"]["line"], finding["kind"]) for finding in findings] == [
    (84, "erw"),
    (87, "erw"),
    (93, "erw"),
], findings
PY

printf 'test: tech-debt requires an explicit, valid marker selection\n'
if (cd "$PROJECT" && lake exe aftk tech-debt module TechDebtTest.Markers \
    > missing-markers.out 2> missing-markers.err); then
  echo 'tech-debt unexpectedly accepted a missing marker selection' >&2
  exit 1
fi
grep -q 'missing marker selection' "$PROJECT/missing-markers.err"
if (cd "$PROJECT" && lake exe aftk tech-debt --markers notAMarker \
    module TechDebtTest.Markers > unknown-marker.out 2> unknown-marker.err); then
  echo 'tech-debt unexpectedly accepted an unknown marker' >&2
  exit 1
fi
grep -q 'unknown technical-debt marker' "$PROJECT/unknown-marker.err"

printf 'test: tech-debt filters and deduplicates explicit marker selections\n'
(cd "$PROJECT" && lake exe aftk tech-debt --jsonl --markers sorry \
  --markers=erw,sorry module TechDebtTest.Markers > selected-markers.jsonl)
python3 - "$PROJECT/selected-markers.jsonl" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    findings = [json.loads(line) for line in stream if line.strip()]

assert [(finding["range"]["start"]["line"], finding["kind"]) for finding in findings] == [
    (71, "sorry"),
    (74, "sorry"),
    (84, "erw"),
    (87, "erw"),
    (93, "erw"),
], findings
PY

printf 'test: tech-debt scans one module\n'
(cd "$PROJECT" && lake exe aftk tech-debt --jsonl --markers maxHeartbeats,erw \
  module TechDebtTest.Example > findings.jsonl)
python3 - "$PROJECT/findings.jsonl" "$PROJECT/TechDebtTest/Example.lean" <<'PY'
import json
import sys

output, expected_file = sys.argv[1:]
with open(output) as stream:
    findings = [json.loads(line) for line in stream if line.strip()]

assert len(findings) == 3, findings
assert [finding["kind"] for finding in findings] == [
    "maxHeartbeats", "erw", "maxHeartbeats"
]
assert [finding["range"]["start"] for finding in findings] == [
    {"line": 4, "column": 1},
    {"line": 8, "column": 3},
    {"line": 18, "column": 1},
]
assert all(finding["module"] == "TechDebtTest.Example" for finding in findings)
assert all(finding["file"] == expected_file for finding in findings)
PY

printf 'test: tech-debt scans one library through its modules facet\n'
(cd "$PROJECT" && lake exe aftk tech-debt --jsonl --markers maxHeartbeats,erw \
  library TechDebtTest > library.jsonl)
python3 - "$PROJECT/library.jsonl" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    findings = [json.loads(line) for line in stream if line.strip()]

assert [(finding["module"], finding["kind"]) for finding in findings] == [
    ("TechDebtTest.Dependency", "maxHeartbeats"),
    ("TechDebtTest.Example", "maxHeartbeats"),
    ("TechDebtTest.Example", "erw"),
    ("TechDebtTest.Example", "maxHeartbeats"),
    ("TechDebtTest.Markers", "maxHeartbeats"),
    ("TechDebtTest.Markers", "maxHeartbeats"),
    ("TechDebtTest.Markers", "erw"),
    ("TechDebtTest.Markers", "erw"),
    ("TechDebtTest.Markers", "erw"),
], findings
PY

printf 'test: tech-debt scans every configured target in the root package\n'
(cd "$PROJECT" && lake exe aftk tech-debt --jsonl --markers maxHeartbeats,erw > package.jsonl)
python3 - "$PROJECT/package.jsonl" <<'PY'
import json
import sys

with open(sys.argv[1]) as stream:
    findings = [json.loads(line) for line in stream if line.strip()]

assert [(finding["module"], finding["kind"]) for finding in findings] == [
    ("DebtRunner", "maxHeartbeats"),
    ("ExtraDebt.Finding", "erw"),
    ("TechDebtTest.Dependency", "maxHeartbeats"),
    ("TechDebtTest.Example", "maxHeartbeats"),
    ("TechDebtTest.Example", "erw"),
    ("TechDebtTest.Example", "maxHeartbeats"),
    ("TechDebtTest.Markers", "maxHeartbeats"),
    ("TechDebtTest.Markers", "maxHeartbeats"),
    ("TechDebtTest.Markers", "erw"),
    ("TechDebtTest.Markers", "erw"),
    ("TechDebtTest.Markers", "erw"),
], findings
assert all(finding["module"] != "Orphan" for finding in findings)
PY

printf 'test: tech-debt scans a named package\n'
(cd "$PROJECT" && lake exe aftk tech-debt --jsonl --markers maxHeartbeats,erw \
  package tech_debt_test > named-package.jsonl)
cmp "$PROJECT/package.jsonl" "$PROJECT/named-package.jsonl"

printf 'test: tech-debt compatibility syntax, default output, and help\n'
(cd "$PROJECT" && lake exe aftk tech-debt --markers maxHeartbeats,erw \
  TechDebtTest.Example > findings.tsv)
[[ "$(wc -l < "$PROJECT/findings.tsv")" -eq 3 ]]
grep -q $'Example.lean:4:1\tmaxHeartbeats\t' "$PROJECT/findings.tsv"
grep -q $'Example.lean:8:3\terw\t' "$PROJECT/findings.tsv"
python3 - "$PROJECT/findings.tsv" <<'PY'
import sys

with open(sys.argv[1]) as stream:
    rows = [line.rstrip("\n").split("\t") for line in stream]

assert [len(row) for row in rows] == [4, 3, 4], rows
assert rows[0][3] == "maxHeartbeats 1000000", rows
assert rows[2][3] == "maxHeartbeats 1000000", rows
PY
(cd "$PROJECT" && lake exe aftk help tech-debt) | grep -q 'Find technical debt'
(cd "$PROJECT" && lake exe aftk help tech-debt) | grep -q -- '--option <name>'

printf 'all tech-debt tests passed\n'
