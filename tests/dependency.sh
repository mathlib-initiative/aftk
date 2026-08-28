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
defaultTargets = ["Discovery"]

[[require]]
name = "aftk"
path = "aftk-dependency"

[[lean_lib]]
name = "Discovery"
EOF
ln -s "$ROOT" "$PROJECT/aftk-dependency"
cp "$ROOT/lean-toolchain" "$PROJECT/lean-toolchain"
mkdir -p "$PROJECT/Discovery"

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

lake env lean --run "$ROOT/tests/dependency_resolution.lean"
(cd "$PROJECT" && lake build)

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
