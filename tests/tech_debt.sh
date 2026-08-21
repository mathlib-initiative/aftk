#!/usr/bin/env bash
set -Eeuo pipefail

# End-to-end tests for semantic technical-debt detection.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AFTK_BIN=${AFTK_BIN:-"$ROOT/.lake/build/bin/aftk"}
PROJECT=$(mktemp -d /tmp/aftk-tech-debt-test-XXXXXX)

cleanup() {
  rm -rf "$PROJECT"
}
trap cleanup EXIT

if [[ ! -x "$AFTK_BIN" ]]; then
  (cd "$ROOT" && lake build aftk)
fi

cat > "$PROJECT/lakefile.toml" <<'EOF'
name = "tech_debt_test"
version = "0.1.0"
defaultTargets = ["TechDebtTest"]

[[lean_lib]]
name = "TechDebtTest"
EOF
cp "$ROOT/lean-toolchain" "$PROJECT/lean-toolchain"
mkdir -p "$PROJECT/TechDebtTest"
cat > "$PROJECT/TechDebtTest/Dependency.lean" <<'EOF'
module

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
(cd "$PROJECT" && lake build TechDebtTest.Dependency)

printf 'test: tech-debt finds semantic command and tactic occurrences\n'
(cd "$PROJECT" && "$AFTK_BIN" tech-debt --jsonl TechDebtTest.Example > findings.jsonl)
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

printf 'test: tech-debt default output and help\n'
(cd "$PROJECT" && "$AFTK_BIN" tech-debt TechDebtTest.Example > findings.tsv)
[[ "$(wc -l < "$PROJECT/findings.tsv")" -eq 3 ]]
grep -q $'Example.lean:4:1\tmaxHeartbeats\t' "$PROJECT/findings.tsv"
grep -q $'Example.lean:8:3\terw\t' "$PROJECT/findings.tsv"
"$AFTK_BIN" help tech-debt | grep -q 'Find technical debt'

printf 'all tech-debt tests passed\n'
