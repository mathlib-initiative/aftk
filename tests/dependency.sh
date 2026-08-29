#!/usr/bin/env bash
set -Eeuo pipefail

# End-to-end tests for declaration discovery and defining-module-qualified queries.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PROJECT=$(mktemp -d /tmp/aftk-dependency-test-XXXXXX)

cleanup() {
  rm -rf "$PROJECT"
}
trap cleanup EXIT

cat > "$PROJECT/lakefile.toml" <<'EOF'
name = "dependency_test"
version = "0.1.0"
defaultTargets = ["Discovery", "SplitWorkspace", "DownstreamWorkspace"]

[[require]]
name = "aftk"
path = "aftk-dependency"

[[require]]
name = "config_dependency"
path = "config-dependency"

[[lean_lib]]
name = "Discovery"

[[lean_lib]]
name = "SplitWorkspace"
srcDir = "WorkspaceSource"
roots = ["Workspace.Core", "Workspace.Sibling", "Workspace.Leaf"]

[[lean_lib]]
name = "DownstreamWorkspace"
roots = ["Workspace.Downstream"]
EOF
ln -s "$ROOT" "$PROJECT/aftk-dependency"
cp "$ROOT/lean-toolchain" "$PROJECT/lean-toolchain"
mkdir -p "$PROJECT/Discovery" "$PROJECT/config-dependency"

# Loading a dependency configured by `lakefile.lean` imports Lean modules while resolving the
# workspace. Lean's import boundary resets the initializer-execution flag, so the later scoped
# dependency-graph import must restore that flag itself.
cat > "$PROJECT/config-dependency/lakefile.lean" <<'EOF'
import Lake

open Lake DSL

package config_dependency

lean_lib ConfigDependency
EOF
cat > "$PROJECT/config-dependency/ConfigDependency.lean" <<'EOF'
module

public section

def configDependencyValue : Nat := 1
EOF

cat > "$PROJECT/Discovery/A.lean" <<'EOF'
module

public section

namespace Alpha

def exactPublic : Nat := 1
def uniqueNeedle : Nat := exactPublic
def sharedPublic : Nat := 2
def tick' : Nat := exactPublic
def «quoted.name» : Nat := exactPublic

end Alpha

namespace PrivateFixture

private theorem sharedPrivate : True := True.intro
theorem usePrivateA : True := sharedPrivate

end PrivateFixture
EOF

for index in $(seq -w 0 24); do
  cat >> "$PROJECT/Discovery/A.lean" <<EOF

namespace Suggest${index}
def boundedNeedle : Nat := ${index#0}
end Suggest${index}
EOF
done

cat > "$PROJECT/Discovery/B.lean" <<'EOF'
module

public section

namespace Beta

def sharedPublic : Nat := 3

end Beta

namespace PrivateFixture

private theorem sharedPrivate : True := True.intro
theorem usePrivateB : True := sharedPrivate

end PrivateFixture
EOF

cat > "$PROJECT/Discovery.lean" <<'EOF'
module

public import Discovery.A
public import Discovery.B

public section

namespace RootFixture

theorem downstreamA : True := PrivateFixture.usePrivateA
def usesUnique : Nat := Alpha.uniqueNeedle
def usesTick : Nat := Alpha.tick'
def usesQuoted : Nat := Alpha.«quoted.name»

end RootFixture
EOF

# SplitWorkspace deliberately has no umbrella module. Its roots are only related by selected
# imports, while DownstreamWorkspace imports it from a second library in the same package.
mkdir -p "$PROJECT/WorkspaceSource/Workspace" "$PROJECT/Workspace"
cat > "$PROJECT/WorkspaceSource/Workspace/Core.lean" <<'EOF'
module

public section

namespace Workspace

def seed : Nat := 1
def leaf : Nat := 2
def tick' : Nat := seed

end Workspace
EOF
cat > "$PROJECT/WorkspaceSource/Workspace/Sibling.lean" <<'EOF'
module

public import Workspace.Core

public section

namespace Workspace

def siblingUser : Nat := seed
def tickUser : Nat := tick'

end Workspace
EOF
cat > "$PROJECT/WorkspaceSource/Workspace/Leaf.lean" <<'EOF'
module

public section

namespace Workspace

def independent : Nat := 3

end Workspace
EOF
cat > "$PROJECT/Workspace/Downstream.lean" <<'EOF'
module

public import Workspace.Sibling

public section

namespace Workspace

def downstreamUser : Nat := siblingUser + seed

end Workspace
EOF

lake env lean --run "$ROOT/tests/dependency_resolution.lean"
(cd "$PROJECT" && lake build)

printf 'test: explicit module scope reports a framed query status\n'
(cd "$PROJECT" && lake exe aftk rdeps module Workspace.Sibling Workspace.seed \
  --jsonl > module-scope.jsonl)
python3 - "$PROJECT/module-scope.jsonl" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as stream:
    row = json.load(stream)
assert row["type"] == "query"
assert row["query"] == "rdeps"
assert row["status"] == "ok"
assert row["scope"] == {
    "kind": "module", "name": "Workspace.Sibling", "modules": ["Workspace.Sibling"],
    "outputFilter": [],
}
assert [(item["module"], item["declaration"]) for item in row["results"]] == [
    ("Workspace.Core", "Workspace.tick'"),
    ("Workspace.Sibling", "Workspace.siblingUser"),
    ("Workspace.Sibling", "Workspace.tickUser"),
]
PY

printf 'test: library scope survives lakefile.lean loading and imports every configured root\n'
(cd "$PROJECT" && lake exe aftk rdeps library SplitWorkspace Workspace.seed \
  --jsonl > library-scope.jsonl)
python3 - "$PROJECT/library-scope.jsonl" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as stream:
    row = json.load(stream)
assert row["scope"] == {
    "kind": "library",
    "name": "SplitWorkspace",
    "modules": ["Workspace.Core", "Workspace.Leaf", "Workspace.Sibling"],
    "outputFilter": [],
}
assert row["status"] == "ok"
assert row["resultCount"] == 3
assert row["moduleCount"] == 2
assert [item["declaration"] for item in row["results"]] == [
    "Workspace.tick'", "Workspace.siblingUser", "Workspace.tickUser"
]
PY
(cd "$PROJECT" && lake exe aftk rdeps library SplitWorkspace Workspace.seed \
  --module Workspace.Sibling --jsonl > filtered-scope.jsonl)
python3 - "$PROJECT/filtered-scope.jsonl" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as stream:
    row = json.load(stream)
assert row["scope"]["outputFilter"] == ["Workspace.Sibling"]
assert row["moduleCount"] == 1
assert [item["declaration"] for item in row["results"]] == [
    "Workspace.siblingUser", "Workspace.tickUser"
]
PY

printf 'test: batch queries frame leaf, non-leaf, apostrophe, and unresolved targets\n'
if (cd "$PROJECT" && printf '%s\n' Workspace.seed Workspace.leaf "Workspace.tick'" Workspace.missing | \
    lake exe aftk rdeps library SplitWorkspace --stdin --jsonl > batch.jsonl); then
  echo 'mixed batch unexpectedly succeeded' >&2
  exit 1
fi
if (cd "$PROJECT" && printf '%s\n' Workspace.seed Workspace.leaf "Workspace.tick'" Workspace.missing | \
    lake exe aftk rdeps library SplitWorkspace --stdin --jsonl > batch-repeat.jsonl); then
  echo 'repeated mixed batch unexpectedly succeeded' >&2
  exit 1
fi
cmp "$PROJECT/batch.jsonl" "$PROJECT/batch-repeat.jsonl"
python3 - "$PROJECT/batch.jsonl" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as stream:
    rows = [json.loads(line) for line in stream if line.strip()]
assert [row["input"]["declaration"] for row in rows] == [
    "Workspace.seed", "Workspace.leaf", "Workspace.tick'", "Workspace.missing"
]
assert [row["status"] for row in rows] == ["ok", "leaf", "ok", "unresolved"]
assert [item["declaration"] for item in rows[0]["results"]] == [
    "Workspace.tick'", "Workspace.siblingUser", "Workspace.tickUser"
]
assert rows[1]["resultCount"] == rows[1]["moduleCount"] == 0
assert [item["declaration"] for item in rows[2]["results"]] == ["Workspace.tickUser"]
assert rows[3]["error"]["code"] == "declarationNotFound"
assert all(row["scope"] == rows[0]["scope"] for row in rows)
PY
(cd "$PROJECT" && printf '%s\n' Workspace.seed Workspace.missing | \
  lake exe aftk rdeps library SplitWorkspace --stdin --jsonl --allow-partial \
    > allowed-batch.jsonl)

printf 'test: package scope includes dependents from a second library\n'
(cd "$PROJECT" && printf '%s\n' Workspace.seed | \
  lake exe aftk rdeps package dependency_test --stdin --jsonl > package-scope.jsonl)
(cd "$PROJECT" && printf '%s\n' Workspace.seed | \
  lake exe aftk rdeps package --stdin --jsonl > root-package-scope.jsonl)
python3 - "$PROJECT/package-scope.jsonl" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as stream:
    row = json.load(stream)
assert row["scope"]["kind"] == "package"
assert row["scope"]["name"] == "dependency_test"
assert row["scope"]["modules"] == [
    "Discovery", "Discovery.A", "Discovery.B", "Workspace.Core",
    "Workspace.Downstream", "Workspace.Leaf", "Workspace.Sibling",
]
assert [(item["module"], item["declaration"]) for item in row["results"]] == [
    ("Workspace.Core", "Workspace.tick'"),
    ("Workspace.Downstream", "Workspace.downstreamUser"),
    ("Workspace.Sibling", "Workspace.siblingUser"),
    ("Workspace.Sibling", "Workspace.tickUser"),
]
assert row["resultCount"] == 4
assert row["moduleCount"] == 3
PY
python3 - "$PROJECT/package-scope.jsonl" "$PROJECT/root-package-scope.jsonl" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as stream:
    named = json.load(stream)
with open(sys.argv[2], encoding="utf-8") as stream:
    root = json.load(stream)
assert root["scope"]["name"] is None
assert root["scope"]["modules"] == named["scope"]["modules"]
assert root["status"] == named["status"]
assert root["results"] == named["results"]
PY

# Exact public lookup remains compatible, including apostrophes.
(cd "$PROJECT" && lake exe aftk rdeps Discovery Alpha.exactPublic \
  --module 'Discovery.*' > exact.tsv)
grep -Fqx $'Discovery.A\tAlpha.uniqueNeedle' "$PROJECT/exact.tsv"
(cd "$PROJECT" && lake exe aftk rdeps Discovery "Alpha.tick'" \
  --module Discovery > tick.tsv)
grep -Fqx $'Discovery\tRootFixture.usesTick' "$PROJECT/tick.tsv"
(cd "$PROJECT" && lake exe aftk rdeps Discovery 'Alpha.«quoted.name»' \
  --module Discovery > quoted.tsv)
grep -Fqx $'Discovery\tRootFixture.usesQuoted' "$PROJECT/quoted.tsv"

# Explicit suffix lookup accepts one component-wise unique result.
(cd "$PROJECT" && lake exe aftk rdeps Discovery uniqueNeedle --resolve-suffix \
  --module Discovery > unique.tsv)
grep -Fqx $'Discovery\tRootFixture.usesUnique' "$PROJECT/unique.tsv"

# Explicit suffix ambiguity is deterministic and structured.
if (cd "$PROJECT" && lake exe aftk rdeps Discovery sharedPublic --resolve-suffix \
    --jsonl > ambiguous.jsonl 2> ambiguous.err); then
  echo "ambiguous suffix unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -s "$PROJECT/ambiguous.err" ]]
python3 - "$PROJECT/ambiguous.jsonl" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
assert data["type"] == "error"
assert data["error"]["code"] == "ambiguousDeclaration"
assert data["requestedTarget"]["resolution"] == "suffix"
assert data["candidates"] == [
    {"definingModule": "Discovery.A", "declaration": "Alpha.sharedPublic"},
    {"definingModule": "Discovery.B", "declaration": "Beta.sharedPublic"},
]
PY

# Ordinary exact failure suggests the same candidates without silently choosing one.
if (cd "$PROJECT" && lake exe aftk rdeps Discovery sharedPublic \
    --jsonl > suggestions.jsonl 2> suggestions.err); then
  echo "short exact name unexpectedly succeeded" >&2
  exit 1
fi
[[ ! -s "$PROJECT/suggestions.err" ]]
python3 - "$PROJECT/suggestions.jsonl" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
assert data["error"]["code"] == "declarationNotFound"
assert data["candidateCount"] == 2
assert [item["declaration"] for item in data["candidates"]] == [
    "Alpha.sharedPublic", "Beta.sharedPublic"
]
PY

# A private result row can be fed back into a root-scope query without losing downstream users.
(cd "$PROJECT" && lake exe aftk deps Discovery.A PrivateFixture.usePrivateA \
  --module Discovery.A > private-deps.tsv)
private_row=$(grep -F $'Discovery.A\tPrivateFixture.sharedPrivate' "$PROJECT/private-deps.tsv")
IFS=$'\t' read -r defining_module private_declaration <<< "$private_row"
(cd "$PROJECT" && lake exe aftk rdeps Discovery "$private_declaration" \
  --defined-in "$defining_module" --modules 'Discovery.A,Discovery' > private-rdeps.tsv)
grep -Fqx $'Discovery.A\tPrivateFixture.usePrivateA' "$PROJECT/private-rdeps.tsv"
grep -Fqx $'Discovery\tRootFixture.downstreamA' "$PROJECT/private-rdeps.tsv"

# The equivalent private JSON result fields are directly reusable too.
(cd "$PROJECT" && lake exe aftk deps Discovery.A PrivateFixture.usePrivateA \
  --module Discovery.A --jsonl > private-deps.jsonl)
json_private_row=$(python3 - "$PROJECT/private-deps.jsonl" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as stream:
    rows = [json.loads(line) for line in stream if line.strip()]
assert len(rows) == 1
row = rows[0]
assert row["module"] == row["definingModule"] == "Discovery.A"
assert row["declaration"] == "PrivateFixture.sharedPrivate"
print(f'{row["definingModule"]}\t{row["declaration"]}')
PY
)
IFS=$'\t' read -r json_defining_module json_private_declaration <<< "$json_private_row"
(cd "$PROJECT" && lake exe aftk rdeps Discovery "$json_private_declaration" \
  --defined-in "$json_defining_module" --modules 'Discovery.A,Discovery' \
  > private-json-roundtrip.tsv)
cmp "$PROJECT/private-rdeps.tsv" "$PROJECT/private-json-roundtrip.tsv"

# JSON rows expose the imported scope, result module, and resolved private target separately.
(cd "$PROJECT" && lake exe aftk rdeps Discovery "$private_declaration" \
  --defined-in "$defining_module" --module Discovery --jsonl > private-rdeps.jsonl)
python3 - "$PROJECT/private-rdeps.jsonl" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as stream:
    rows = [json.loads(line) for line in stream if line.strip()]
assert len(rows) == 1
row = rows[0]
assert row["module"] == row["definingModule"] == "Discovery"
assert row["scopeModule"] == "Discovery"
assert row["target"] == {
    "definingModule": "Discovery.A",
    "declaration": "PrivateFixture.sharedPrivate",
}
PY

# Same-named private declarations require qualification; a wrong module is rejected clearly.
if (cd "$PROJECT" && lake exe aftk rdeps Discovery PrivateFixture.sharedPrivate \
    --jsonl > private-unqualified.jsonl); then
  echo "unqualified private target unexpectedly succeeded" >&2
  exit 1
fi
if (cd "$PROJECT" && lake exe aftk rdeps Discovery PrivateFixture.sharedPrivate \
    --defined-in Discovery --jsonl > private-wrong-module.jsonl); then
  echo "private target with wrong defining module unexpectedly succeeded" >&2
  exit 1
fi
python3 - "$PROJECT/private-unqualified.jsonl" "$PROJECT/private-wrong-module.jsonl" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as stream:
    unqualified = json.load(stream)
with open(sys.argv[2], encoding="utf-8") as stream:
    wrong = json.load(stream)
expected = [
    {"definingModule": "Discovery.A", "declaration": "PrivateFixture.sharedPrivate"},
    {"definingModule": "Discovery.B", "declaration": "PrivateFixture.sharedPrivate"},
]
assert unqualified["error"]["code"] == "declarationNotFound"
assert unqualified["candidates"] == expected
assert wrong["error"]["code"] == "wrongDefiningModule"
assert wrong["candidates"] == expected
PY

# Suggestions are capped, sorted, and repeatable even when many names share one suffix.
for run in 1 2; do
  if (cd "$PROJECT" && lake exe aftk rdeps Discovery boundedNeedle \
      --jsonl > "bounded-${run}.jsonl"); then
    echo "bounded suggestion query unexpectedly succeeded" >&2
    exit 1
  fi
done
cmp "$PROJECT/bounded-1.jsonl" "$PROJECT/bounded-2.jsonl"
python3 - "$PROJECT/bounded-1.jsonl" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
assert data["candidateCount"] == 25
assert data["truncated"] is True
assert len(data["candidates"]) == 20
assert data["candidates"][0]["declaration"] == "Suggest00.boundedNeedle"
assert data["candidates"][-1]["declaration"] == "Suggest19.boundedNeedle"
PY

# Suffix matching never degrades into rendered-string substring matching.
if (cd "$PROJECT" && lake exe aftk rdeps Discovery Needle --resolve-suffix \
    --jsonl > component-only.jsonl); then
  echo "partial name component unexpectedly matched" >&2
  exit 1
fi
python3 - "$PROJECT/component-only.jsonl" <<'PY'
import json, sys

with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
assert data["error"]["code"] == "declarationNotFound"
assert data["candidates"] == []
PY

echo "dependency resolution tests passed"
