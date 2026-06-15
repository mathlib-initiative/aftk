#!/usr/bin/env bash
set -Eeuo pipefail

# End-to-end tests for the AFTK diagnostics daemon and its resource controls.
# These tests create temporary Lake projects and use the built aftk executable.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
AFTK_BIN=${AFTK_BIN:-"$ROOT/.lake/build/bin/aftk"}
TOOLCHAIN="$ROOT/lean-toolchain"

temps=()
cleanup() {
  local ec=$?
  for d in "${temps[@]:-}"; do
    if [[ -d "$d" ]]; then
      (cd "$d" && "$AFTK_BIN" shutdown --force >/dev/null 2>&1 || true)
      rm -rf "$d"
    fi
  done
  exit "$ec"
}
trap cleanup EXIT

if [[ ! -x "$AFTK_BIN" ]]; then
  (cd "$ROOT" && lake build aftk)
fi

make_project() {
  local dir
  dir=$(mktemp -d /tmp/aftk-test-XXXXXX)
  temps+=("$dir")
  cat > "$dir/lakefile.toml" <<'EOF'
name = "tmp"
version = "0.1.0"
defaultTargets = ["Tmp"]
[[lean_lib]]
name = "Tmp"
EOF
  cp "$TOOLCHAIN" "$dir/lean-toolchain"
  mkdir -p "$dir/Tmp"
  echo "$dir"
}

assert_json() {
  local file=$1
  local code=$2
  python3 - "$file" "$code" <<'PY'
import json, sys
path, code = sys.argv[1], sys.argv[2]
with open(path) as f:
    data = json.load(f)
ns = {'data': data}
exec(code, ns)
PY
}

exact_lean_worker_count() {
  python3 - <<'PY'
import subprocess
out = subprocess.run(['pgrep', '-f', 'lean --worker'], text=True, stdout=subprocess.PIPE).stdout.splitlines()
count = 0
for pid in out:
    ps = subprocess.run(['ps', '-p', pid, '-o', 'args='], text=True, stdout=subprocess.PIPE).stdout.strip().split()
    if len(ps) == 2 and ps[1] == '--worker' and (ps[0] == 'lean' or ps[0].endswith('/lean') or ps[0].endswith('/lean.exe')):
        count += 1
print(count)
PY
}

daemon_count_for_root() {
  local root=$1
  python3 - "$root" <<'PY'
import subprocess, sys
root = sys.argv[1]
out = subprocess.run(['pgrep', '-f', 'aftk daemon --project-root'], text=True, stdout=subprocess.PIPE).stdout.splitlines()
count = 0
for pid in out:
    ps = subprocess.run(['ps', '-p', pid, '-o', 'args='], text=True, stdout=subprocess.PIPE).stdout.strip().split()
    if len(ps) >= 4 and ps[1] == 'daemon' and '--project-root' in ps:
        i = ps.index('--project-root')
        if i + 1 < len(ps) and ps[i + 1] == root:
            count += 1
print(count)
PY
}

printf 'test: status does not auto-start unless requested\n'
p=$(make_project)
(cd "$p" && "$AFTK_BIN" status > status.json)
assert_json "$p/status.json" 'assert data["ok"]; assert data["result"]["status"] == "notRunning"'
[[ ! -f "$p/.lake/aftk/server.json" ]]
(cd "$p" && "$AFTK_BIN" status --start > status-start.json)
assert_json "$p/status-start.json" 'assert data["ok"]; assert data["result"]["openFileCount"] == 0'
[[ -f "$p/.lake/aftk/server.json" ]]
(cd "$p" && "$AFTK_BIN" shutdown >/dev/null)

printf 'test: basic diagnostics and status resource fields\n'
p=$(make_project)
cat > "$p/Tmp.lean" <<'EOF'
def x : Nat := 1
EOF
(cd "$p" && "$AFTK_BIN" diagnostics Tmp.lean --timeout-ms 20000 > diag.json)
(cd "$p" && "$AFTK_BIN" status > status.json)
assert_json "$p/diag.json" 'assert data["ok"]; assert data["result"]["diagnostics"] == []'
assert_json "$p/status.json" '
assert data["ok"]
r = data["result"]
assert r["openFileCount"] == 1
f = r["openFiles"][0]
assert "owner" not in f
assert "workerMemory" in f and f["workerMemory"]["rssKb"] > 0
assert "daemonMemory" in r and r["daemonMemory"]["rssKb"] > 0
assert "globalLeanWorkers" in r
assert r["resourceConfig"]["maxWorkersPerProject"] == 8
'
(cd "$p" && "$AFTK_BIN" shutdown >/dev/null)

printf 'test: default diagnostics builds missing local dependencies\n'
p=$(make_project)
cat > "$p/Tmp/Dep.lean" <<'EOF'
def depValue : Nat := 41
EOF
cat > "$p/Tmp/Main.lean" <<'EOF'
import Tmp.Dep

def mainValue : Nat := depValue + 1
EOF
rm -rf "$p/.lake/build/lib/lean/Tmp" "$p/.lake/build/ir/Tmp"
(cd "$p" && "$AFTK_BIN" diagnostics Tmp/Main.lean --timeout-ms 30000 > diag.json)
assert_json "$p/diag.json" 'assert data["ok"]; assert data["result"]["diagnostics"] == []'
[[ -f "$p/.lake/build/lib/lean/Tmp/Dep.olean" ]]
(cd "$p" && "$AFTK_BIN" shutdown >/dev/null)

printf 'test: concurrent transient diagnostics share one daemon safely\n'
p=$(make_project)
for i in $(seq 1 8); do echo "def x$i : Nat := $i" > "$p/Tmp/F$i.lean"; done
(
  cd "$p"
  for i in $(seq 1 8); do
    ("$AFTK_BIN" diagnostics --transient "Tmp/F$i.lean" --timeout-ms 20000 > "out$i.json" 2> "err$i.log"; echo $? > "ec$i") &
  done
  wait
)
for i in $(seq 1 8); do
  [[ "$(cat "$p/ec$i")" == "0" ]]
  assert_json "$p/out$i.json" 'assert data["ok"]; assert data["result"]["diagnostics"] == []'
done
(cd "$p" && "$AFTK_BIN" status > status.json)
assert_json "$p/status.json" 'assert data["ok"]; assert data["result"]["openFileCount"] == 0'
[[ "$(daemon_count_for_root "$p")" == "1" ]]
(cd "$p" && "$AFTK_BIN" shutdown >/dev/null)

printf 'test: transient diagnostics closes the worker\n'
p=$(make_project)
echo 'def x : Nat := 1' > "$p/Tmp.lean"
(cd "$p" && "$AFTK_BIN" diagnostics --transient Tmp.lean --timeout-ms 20000 > diag.json)
(cd "$p" && "$AFTK_BIN" status > status.json)
assert_json "$p/status.json" 'assert data["ok"]; assert data["result"]["openFileCount"] == 0'
(cd "$p" && "$AFTK_BIN" shutdown >/dev/null)

printf 'test: lease expiration and gc\n'
p=$(make_project)
echo 'def x : Nat := 1' > "$p/Tmp.lean"
(cd "$p" && "$AFTK_BIN" open --ttl-ms 200 Tmp.lean > open.json)
sleep 0.5
(cd "$p" && "$AFTK_BIN" gc > gc.json)
(cd "$p" && "$AFTK_BIN" status > status.json)
assert_json "$p/gc.json" 'assert data["ok"]; assert data["result"]["closed"] >= 1'
assert_json "$p/status.json" 'assert data["ok"]; assert data["result"]["openFileCount"] == 0'
(cd "$p" && "$AFTK_BIN" shutdown >/dev/null)

printf 'test: per-project cap evicts local LRU worker\n'
p=$(make_project)
echo 'def a : Nat := 1' > "$p/Tmp/A.lean"
echo 'def b : Nat := 2' > "$p/Tmp/B.lean"
(cd "$p" && AFTK_MAX_WORKERS_PER_PROJECT=1 "$AFTK_BIN" open Tmp/A.lean >/dev/null)
(cd "$p" && AFTK_MAX_WORKERS_PER_PROJECT=1 "$AFTK_BIN" open Tmp/B.lean >/dev/null)
(cd "$p" && "$AFTK_BIN" status > status.json)
assert_json "$p/status.json" '
r = data["result"]
assert r["openFileCount"] == 1
assert r["openFiles"][0]["file"].endswith("Tmp/B.lean")
'
(cd "$p" && "$AFTK_BIN" shutdown >/dev/null)

printf 'test: restart/stale dependency works with cap=1\n'
p=$(make_project)
cat > "$p/Tmp/A.lean" <<'EOF'
def a : Nat := 1
EOF
cat > "$p/Tmp/B.lean" <<'EOF'
import Tmp.A

def b : Nat := a + 1
EOF
(cd "$p" && AFTK_MAX_WORKERS_PER_PROJECT=1 "$AFTK_BIN" diagnostics Tmp/B.lean --timeout-ms 20000 >/dev/null)
(cd "$p" && "$AFTK_BIN" status > status1.json)
pid1=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["openFiles"][0]["workerPid"])' "$p/status1.json")
sleep 1
cat > "$p/Tmp/A.lean" <<'EOF'
def a : Nat := 2
EOF
(cd "$p" && AFTK_MAX_WORKERS_PER_PROJECT=1 "$AFTK_BIN" diagnostics Tmp/B.lean --timeout-ms 20000 > diag2.json)
(cd "$p" && "$AFTK_BIN" status > status2.json)
pid2=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["result"]["openFiles"][0]["workerPid"])' "$p/status2.json")
assert_json "$p/diag2.json" 'assert data["ok"]; assert data["result"].get("restarted") is True; assert "stale dependency" in data["result"].get("restartReason", "")'
[[ "$pid1" != "$pid2" ]]
(cd "$p" && "$AFTK_BIN" shutdown >/dev/null)

printf 'test: global worker cap rejects when local eviction cannot help\n'
base=$(exact_lean_worker_count)
cap=$((base + 1))
p1=$(make_project)
p2=$(make_project)
echo 'def x : Nat := 1' > "$p1/Tmp.lean"
echo 'def y : Nat := 2' > "$p2/Tmp.lean"
(cd "$p1" && AFTK_GLOBAL_MAX_WORKERS="$cap" "$AFTK_BIN" open Tmp.lean >/dev/null)
set +e
(cd "$p2" && AFTK_GLOBAL_MAX_WORKERS="$cap" "$AFTK_BIN" open Tmp.lean > open.json 2> open.err)
ec=$?
set -e
[[ "$ec" -eq 1 ]]
assert_json "$p2/open.json" 'assert data["ok"] is False; assert data["error"]["code"] == "resourceLimit"'
(cd "$p1" && "$AFTK_BIN" shutdown >/dev/null)
(cd "$p2" && "$AFTK_BIN" shutdown --force >/dev/null || true)

printf 'test: hard memory cap rejects before spawning a worker\n'
p=$(make_project)
echo 'def x : Nat := 1' > "$p/Tmp.lean"
set +e
(cd "$p" && AFTK_MEMORY_HARD_LIMIT_MIB=1 "$AFTK_BIN" open Tmp.lean > open.json 2> open.err)
ec=$?
set -e
[[ "$ec" -eq 1 ]]
assert_json "$p/open.json" 'assert data["ok"] is False; assert data["error"]["code"] == "resourceLimit"'
(cd "$p" && "$AFTK_BIN" shutdown --force >/dev/null || true)

printf 'test: owner option is not accepted\n'
p=$(make_project)
echo 'def x : Nat := 1' > "$p/Tmp.lean"
set +e
(cd "$p" && "$AFTK_BIN" open --owner agent Tmp.lean > open.json 2> open.err)
ec=$?
set -e
[[ "$ec" -eq 1 ]]
grep -q 'unknown open option' "$p/open.err"
(cd "$p" && "$AFTK_BIN" shutdown --force >/dev/null || true)

if [[ "${AFTK_TEST_ALL_PROJECTS:-0}" == "1" ]]; then
  printf 'test: shutdown --all-projects (opt-in; may stop unrelated AFTK daemons)\n'
  p1=$(make_project)
  p2=$(make_project)
  echo 'def x : Nat := 1' > "$p1/Tmp.lean"
  echo 'def y : Nat := 2' > "$p2/Tmp.lean"
  (cd "$p1" && "$AFTK_BIN" open Tmp.lean >/dev/null)
  (cd "$p2" && "$AFTK_BIN" open Tmp.lean >/dev/null)
  (cd "$p1" && "$AFTK_BIN" shutdown --all-projects > shutdown-all.json)
  assert_json "$p1/shutdown-all.json" 'assert data["ok"]; assert data["result"]["status"] == "ok"; assert len(data["result"]["daemons"]) >= 2'
fi

printf 'all server tests passed\n'
