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
defaultTargets = ["TechDebtTest", "ExtraDebt", "debt_runner"]

[[lean_lib]]
name = "TechDebtTest"

[[lean_lib]]
name = "ExtraDebt"

[[lean_exe]]
name = "debt_runner"
root = "DebtRunner"
EOF
cp "$ROOT/lean-toolchain" "$PROJECT/lean-toolchain"
mkdir -p "$PROJECT/TechDebtTest" "$PROJECT/ExtraDebt"
cat > "$PROJECT/TechDebtTest.lean" <<'EOF'
module
import TechDebtTest.Example
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

public def main : IO Unit := pure ()
EOF
cat > "$PROJECT/Orphan.lean" <<'EOF'
module

-- This file is deliberately outside every configured target.
set_option maxHeartbeats 400000
EOF
(cd "$PROJECT" && lake build)

printf 'test: tech-debt scans one module\n'
(cd "$PROJECT" && "$AFTK_BIN" tech-debt --jsonl module TechDebtTest.Example > findings.jsonl)
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
(cd "$PROJECT" && "$AFTK_BIN" tech-debt --jsonl library TechDebtTest > library.jsonl)
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
], findings
PY

printf 'test: tech-debt scans every configured target in the root package\n'
(cd "$PROJECT" && "$AFTK_BIN" tech-debt --jsonl > package.jsonl)
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
], findings
assert all(finding["module"] != "Orphan" for finding in findings)
PY

printf 'test: tech-debt scans a named package\n'
(cd "$PROJECT" && "$AFTK_BIN" tech-debt --jsonl package tech_debt_test > named-package.jsonl)
cmp "$PROJECT/package.jsonl" "$PROJECT/named-package.jsonl"

printf 'test: tech-debt compatibility syntax, default output, and help\n'
(cd "$PROJECT" && "$AFTK_BIN" tech-debt TechDebtTest.Example > findings.tsv)
[[ "$(wc -l < "$PROJECT/findings.tsv")" -eq 3 ]]
grep -q $'Example.lean:4:1\tmaxHeartbeats\t' "$PROJECT/findings.tsv"
grep -q $'Example.lean:8:3\terw\t' "$PROJECT/findings.tsv"
"$AFTK_BIN" help tech-debt | grep -q 'Find technical debt'

printf 'all tech-debt tests passed\n'
