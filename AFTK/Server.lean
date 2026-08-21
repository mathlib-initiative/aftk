module

public import Lean
public import Lean.Data.Lsp
public import Lean.Data.Lsp.Communication
public import Lean.Server.Utils
public import Std.Async.TCP

public section

namespace AFTK
namespace Server

open Lean
open Lean.Json
open Lean.JsonRpc
open Lean.Lsp
open System
open Std.Net

/-- Current AFTK daemon protocol version. -/
def protocolVersion : Nat := 4

/-- Metadata persisted by a daemon in `.lake/aftk/server.json`. -/
structure ServerMeta where
  protocolVersion : Nat
  projectRoot : String
  pid : Nat
  host : String
  port : Nat
  token : String
  startedAtMs : Nat
  lastSeenMs : Nat
  toolchain : String
  deriving FromJson, ToJson, Inhabited

/-- State of a Lean file worker process. -/
inductive WorkerStatus where
  | running
  | terminated (exitCode : UInt32)
  | crashed (message : String)
  deriving Inhabited, BEq

def workerStatusJson : WorkerStatus → Json
  | .running => "running"
  | .terminated code => Json.mkObj [("state", "terminated"), ("exitCode", code.toNat)]
  | .crashed msg => Json.mkObj [("state", "crashed"), ("message", msg)]

/-- Stdio configuration for Lean file workers. -/
def workerCfg : IO.Process.StdioConfig := {
  stdin := .piped
  stdout := .piped
  stderr := .piped
}

/-- Stdio configuration for the invisible AFTK daemon. -/
def daemonCfg : IO.Process.StdioConfig := {
  stdin := .null
  stdout := .null
  stderr := .null
}

/-- Error payload returned by the daemon protocol. -/
def errorObj (code message : String) : Json :=
  Json.mkObj [("code", code), ("message", message)]

def okResponse (result : Json) : Json :=
  Json.mkObj [("ok", true), ("result", result)]

def errorResponse (code message : String) : Json :=
  Json.mkObj [("ok", false), ("error", errorObj code message)]

/-- Convert an exception-producing `Except String` into `IO`. -/
def exceptToIO : Except String α → IO α
  | .ok a => pure a
  | .error e => throw <| IO.userError e

/-- True when `s` ends in `.lean`. -/
def isLeanFileName (s : String) : Bool :=
  s.endsWith ".lean"

/-- Simple substring test. -/
def containsSubstring (haystack needle : String) : Bool :=
  needle != "" && (haystack.splitOn needle).length > 1

/-- Hex-encode a byte. -/
def hexByte (b : UInt8) : String :=
  let digits := #["0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "a", "b", "c", "d", "e", "f"]
  let n := b.toNat
  let hi := n / 16
  let lo := n % 16
  digits[hi]! ++ digits[lo]!

/-- Generate a random capability token. -/
def randomToken : IO String := do
  let bytes ← IO.getRandomBytes 32
  let mut out := ""
  for b in bytes do
    out := out ++ hexByte b
  return out

/-- Read `lean-toolchain` if present. -/
def readToolchain (root : FilePath) : IO String := do
  let path := root / "lean-toolchain"
  if ← path.pathExists then
    return (← IO.FS.readFile path).trimAscii.toString
  else
    return ""

/-- Path to `.lake/aftk` inside a project root. -/
def aftkDir (root : FilePath) : FilePath :=
  root / ".lake" / "aftk"

/-- Path to daemon metadata. -/
def metaPath (root : FilePath) : FilePath :=
  aftkDir root / "server.json"

/-- Path to daemon startup lock. -/
def lockPath (root : FilePath) : FilePath :=
  aftkDir root / "server.lock"

/-- Path to daemon log. -/
def logPath (root : FilePath) : FilePath :=
  aftkDir root / "server.log"

/-- Best-effort file removal. -/
def removeFileIfExists (path : FilePath) : IO Unit := do
  if ← path.pathExists then
    try IO.FS.removeFile path catch _ => pure ()

/-- Best-effort directory removal. -/
def removeDirIfExists (path : FilePath) : IO Unit := do
  if ← path.pathExists then
    try IO.FS.removeDir path catch _ => pure ()

/-- Write metadata atomically. -/
def writeMeta (root : FilePath) (md : ServerMeta) : IO Unit := do
  IO.FS.createDirAll (aftkDir root)
  let path := metaPath root
  let tmp := aftkDir root / "server.json.tmp"
  IO.FS.writeFile tmp (Json.compress (toJson md))
  IO.FS.rename tmp path

/-- Read daemon metadata. -/
def readMeta (root : FilePath) : IO ServerMeta := do
  let raw ← IO.FS.readFile (metaPath root)
  exceptToIO <| Json.parse raw >>= fromJson?

/-- Convert a path to an absolute path without requiring the final file to already exist. -/
def absolutize (path : FilePath) : IO FilePath := do
  if path.isAbsolute then
    return path.normalize
  else
    return ((← IO.currentDir) / path).normalize

/-- Resolve an existing file to a real absolute path. -/
def realFilePath (path : FilePath) : IO FilePath := do
  IO.FS.realPath (← absolutize path)

/-- Find the nearest ancestor containing a Lake file, falling back to the current directory. -/
partial def findProjectRootFrom (start : FilePath) : IO FilePath := do
  let start ← IO.FS.realPath start
  let rec go (dir : FilePath) : IO FilePath := do
    if (← (dir / "lakefile.toml").pathExists) || (← (dir / "lakefile.lean").pathExists) then
      return dir
    else
      match dir.parent with
      | some parent =>
          if parent == dir then
            return start
          else
            go parent
      | none => return start
  go start

/-- Find the project root for a command, preferring a file's parent when one is supplied. -/
def findProjectRoot (file? : Option FilePath := none) : IO FilePath := do
  match file? with
  | some file =>
      let abs ← absolutize file
      let dir := abs.parent.getD (← IO.currentDir)
      findProjectRootFrom dir
  | none => findProjectRootFrom (← IO.currentDir)

/-- Locate the Lean worker executable, mirroring Lean's watchdog logic. -/
def findWorkerPath : IO FilePath := do
  if let some path := (← IO.getEnv "LEAN_WORKER_PATH") then
    return FilePath.mk path
  let sysroot ←
    if let some path := (← IO.getEnv "LEAN_SYSROOT") then
      pure (FilePath.mk path)
    else
      findSysroot
  return sysroot / "bin" / "lean" |>.addExtension FilePath.exeExtension

/-- Decode an optional JSON object field. -/
def getObjValAs? (α : Type) [FromJson α] (j : Json) (key : String) : Except String α :=
  j.getObjValAs? α key

/-- Extract a string field from protocol params. -/
def getStringField (j : Json) (key : String) : Except String String :=
  getObjValAs? String j key

/-- Extract an optional string field from protocol params. -/
def getStringField? (j : Json) (key : String) : Option String :=
  (j.getObjValAs? String key).toOption

/-- Extract an optional natural-number field from protocol params. -/
def getNatField? (j : Json) (key : String) : Option Nat :=
  (j.getObjValAs? Nat key).toOption

/-- Extract an optional boolean field from protocol params. -/
def getBoolField? (j : Json) (key : String) : Option Bool :=
  (j.getObjValAs? Bool key).toOption

/-- Resource-management configuration for one daemon. `0` worker limits mean unlimited. -/
structure ResourceConfig where
  workerIdleMs : Nat
  daemonIdleMs : Nat
  maxWorkersPerProject : Nat
  globalMaxWorkers : Nat
  memorySoftLimitKb? : Option Nat
  memoryHardLimitKb? : Option Nat
  workerMemoryEstimateKb : Nat
  defaultLeaseMs? : Option Nat
  deriving Inhabited, Repr

/-- Parse a natural-number environment variable. -/
def envNat? (name : String) : IO (Option Nat) := do
  match ← IO.getEnv name with
  | some s => return s.trimAscii.toString.toNat?
  | none => return none

/-- Parse a memory limit from `<prefix>_MIB` or `<prefix>_GIB`. -/
def envMemoryKb? (envPrefix : String) : IO (Option Nat) := do
  match ← envNat? (envPrefix ++ "_MIB") with
  | some mib => return some (mib * 1024)
  | none =>
      match ← envNat? (envPrefix ++ "_GIB") with
      | some gib => return some (gib * 1024 * 1024)
      | none => return none

/-- Read daemon resource configuration from the environment. -/
def readResourceConfig : IO ResourceConfig := do
  let workerIdleMs := (← envNat? "AFTK_WORKER_IDLE_MS").getD (10 * 60 * 1000)
  let daemonIdleMs := (← envNat? "AFTK_DAEMON_IDLE_MS").getD (5 * 60 * 1000)
  let maxWorkersPerProject := (← envNat? "AFTK_MAX_WORKERS_PER_PROJECT").getD 8
  let globalMaxWorkers := (← envNat? "AFTK_GLOBAL_MAX_WORKERS").getD 50
  let memorySoftLimitKb? ← envMemoryKb? "AFTK_MEMORY_SOFT_LIMIT"
  let memoryHardLimitKb? ← envMemoryKb? "AFTK_MEMORY_HARD_LIMIT"
  let workerMemoryEstimateKb := (← envNat? "AFTK_WORKER_MEMORY_ESTIMATE_MIB").getD 6500 * 1024
  let defaultLeaseMs? ← envNat? "AFTK_DEFAULT_LEASE_MS"
  return {
    workerIdleMs, daemonIdleMs, maxWorkersPerProject, globalMaxWorkers,
    memorySoftLimitKb?, memoryHardLimitKb?, workerMemoryEstimateKb, defaultLeaseMs?
  }

/-- JSON rendering for resource configuration. -/
def resourceConfigJson (cfg : ResourceConfig) : Json :=
  Json.mkObj [
    ("workerIdleMs", cfg.workerIdleMs),
    ("daemonIdleMs", cfg.daemonIdleMs),
    ("maxWorkersPerProject", cfg.maxWorkersPerProject),
    ("globalMaxWorkers", cfg.globalMaxWorkers),
    ("memorySoftLimitKb", cfg.memorySoftLimitKb?.map toJson |>.getD Json.null),
    ("memoryHardLimitKb", cfg.memoryHardLimitKb?.map toJson |>.getD Json.null),
    ("workerMemoryEstimateKb", cfg.workerMemoryEstimateKb),
    ("defaultLeaseMs", cfg.defaultLeaseMs?.map toJson |>.getD Json.null)]

/-- Memory footprint for a process as reported by Linux `/proc`. -/
structure ProcessMemory where
  rssKb : Nat
  pssKb : Nat
  privateKb : Nat
  swapKb : Nat
  deriving Inhabited, Repr

/-- Render process memory as JSON. -/
def processMemoryJson (m : ProcessMemory) : Json :=
  Json.mkObj [
    ("rssKb", m.rssKb),
    ("pssKb", m.pssKb),
    ("privateKb", m.privateKb),
    ("swapKb", m.swapKb)]

/-- Return the first natural-number token in a whitespace-separated string. -/
def firstNatToken? (s : String) : Option Nat := Id.run do
  for tok in s.splitOn " " do
    if let some n := tok.toNat? then
      return some n
  return none

/-- Read a `kB` value from a `/proc/*/smaps_rollup` line. -/
def procKbLine? (key line : String) : Option Nat :=
  if line.startsWith (key ++ ":") then
    firstNatToken? line
  else
    none

/-- Read process RSS/PSS/private/swap from `/proc/<pid>/smaps_rollup`. -/
def processMemory? (pid : Nat) : IO (Option ProcessMemory) := do
  let path := FilePath.mk s!"/proc/{pid}/smaps_rollup"
  try
    let raw ← IO.FS.readFile path
    let mut rss := 0
    let mut pss := 0
    let mut privateClean := 0
    let mut privateDirty := 0
    let mut swap := 0
    for line in raw.splitOn "\n" do
      if let some n := procKbLine? "Rss" line then rss := n
      if let some n := procKbLine? "Pss" line then pss := n
      if let some n := procKbLine? "Private_Clean" line then privateClean := n
      if let some n := procKbLine? "Private_Dirty" line then privateDirty := n
      if let some n := procKbLine? "Swap" line then swap := n
    return some { rssKb := rss, pssKb := pss, privateKb := privateClean + privateDirty, swapKb := swap }
  catch _ =>
    return none

/-- Parse whitespace-separated process arguments from `ps`. Paths with spaces are not supported. -/
def processArgs? (pid : Nat) : IO (Option (List String)) := do
  try
    let out ← IO.Process.output { cmd := "ps", args := #["-p", toString pid, "-o", "args="] }
    if out.exitCode != 0 then
      return none
    let mut toks := []
    for tok in out.stdout.trimAscii.toString.splitOn " " do
      if !tok.isEmpty then
        toks := toks ++ [tok]
    return some toks
  catch _ => return none

/-- Recognize the exact Lean file-worker command shape. -/
def isLeanWorkerArgs : List String → Bool
  | exe :: ["--worker"] => exe == "lean" || exe.endsWith "/lean" || exe.endsWith "/lean.exe"
  | _ => false

/-- Best-effort list of all Lean worker PIDs owned by this user/session. -/
def leanWorkerPids : IO (Array Nat) := do
  try
    let out ← IO.Process.output { cmd := "pgrep", args := #["-f", "lean --worker"] }
    if out.exitCode != 0 then
      return #[]
    let mut pids := #[]
    for line in out.stdout.splitOn "\n" do
      if let some pid := line.trimAscii.toString.toNat? then
        if let some args ← processArgs? pid then
          if isLeanWorkerArgs args then
            pids := pids.push pid
    return pids
  catch _ =>
    return #[]

/-- Sum memory for all currently visible Lean workers. -/
def leanWorkersMemory : IO (Nat × ProcessMemory) := do
  let pids ← leanWorkerPids
  let mut count := 0
  let mut rss := 0
  let mut pss := 0
  let mut privateKb := 0
  let mut swap := 0
  for pid in pids do
    if let some mem ← processMemory? pid then
      count := count + 1
      rss := rss + mem.rssKb
      pss := pss + mem.pssKb
      privateKb := privateKb + mem.privateKb
      swap := swap + mem.swapKb
  return (count, { rssKb := rss, pssKb := pss, privateKb, swapKb := swap })

/-- Parse a dependency build mode option. -/
def parseBuildMode (s : String) : Except String DependencyBuildMode :=
  match s with
  | "always" => .ok .always
  | "once" => .ok .once
  | "never" => .ok .never
  | _ => .error s!"unknown dependencyBuildMode `{s}`"

/-- Render LSP diagnostic severity as text. -/
def severityString : DiagnosticSeverity → String
  | .error => "error"
  | .warning => "warning"
  | .information => "information"
  | .hint => "hint"

/-- Render LSP diagnostic code. -/
def diagnosticCodeJson : DiagnosticCode → Json
  | .int i => toJson i
  | .string s => toJson s

/-- Convert an LSP position to a 1-based agent-facing JSON object. -/
def positionJson1 (p : Lsp.Position) : Json :=
  Json.mkObj [("line", toJson (p.line + 1)), ("column", toJson (p.character + 1))]

/-- Convert a 1-based agent-facing line/column pair to an LSP position. -/
def lspPositionFromLineColumn (line column : Nat) : Except String Lsp.Position := do
  if line == 0 then
    throw "line must be >= 1"
  if column == 0 then
    throw "column must be >= 1"
  return { line := line - 1, character := column - 1 }

/-- Parse a positive natural number. -/
def parsePositiveNat (what raw : String) : Except String Nat := do
  let some n := raw.toNat? | throw s!"invalid {what} `{raw}`"
  if n == 0 then
    throw s!"{what} must be >= 1"
  return n

/-- Parse `line:column` or `line,column`, using 1-based numbers. -/
def parseLineColumnString (raw : String) : Except String (Nat × Nat) := do
  let sep := if raw.contains ':' then ":" else ","
  match raw.splitOn sep with
  | [line, column] =>
      let line ← parsePositiveNat "line" line
      let column ← parsePositiveNat "column" column
      return (line, column)
  | _ => throw s!"invalid location `{raw}`; expected <line>:<column>"

/-- Parse a 1-based `<start-line>:<start-column>-<end-line>:<end-column>` range. -/
def parseRangeString (raw : String) : Except String (Nat × Nat × Nat × Nat) := do
  match raw.splitOn "-" with
  | [start, stop] =>
      let (startLine, startColumn) ← parseLineColumnString start
      let (endLine, endColumn) ← parseLineColumnString stop
      return (startLine, startColumn, endLine, endColumn)
  | _ => throw s!"invalid range `{raw}`; expected <line>:<column>-<line>:<column>"

/-- Convert an LSP range to a 1-based agent-facing JSON object. -/
def rangeJson1 (r : Range) : Json :=
  Json.mkObj [("start", positionJson1 r.start), ("end", positionJson1 r.end)]

/-- Convert an LSP diagnostic to an agent-facing JSON object. -/
def diagnosticJson (file : String) (includeRaw : Bool) (d : Diagnostic) : Json :=
  let base : List (String × Json) := [
    ("file", file),
    ("range", rangeJson1 d.range),
    ("severity", d.severity?.map severityString |>.getD "information"),
    ("message", d.message),
    ("source", d.source?.getD "Lean 4")]
  let base := match d.code? with
    | some code => base ++ [("code", diagnosticCodeJson code)]
    | none => base
  let base := if includeRaw then base ++ [("raw", toJson d)] else base
  Json.mkObj base

/-- Convert a plain tactic-goal response to an agent-facing JSON object. -/
def plainGoalJson (g : PlainGoal) : Json :=
  Json.mkObj [("rendered", toJson g.rendered), ("goals", toJson g.goals)]

/-- Convert a plain term-goal response to an agent-facing JSON object. -/
def plainTermGoalJson (g : PlainTermGoal) : Json :=
  Json.mkObj [("goal", toJson g.goal), ("range", rangeJson1 g.range)]

/-- Configuration for a single Lean worker process. -/
structure LspWorker where
  uri : DocumentUri
  proc : IO.Process.Child workerCfg
  stdin : IO.FS.Stream
  stdout : IO.FS.Stream
  stderrTask : Task (Except IO.Error Unit)
  pendingRef : IO.Ref (Std.TreeMap RequestID (IO.Promise (Except String Json)))
  nextRequestIdRef : IO.Ref Nat
  latestDiagnosticsRef : IO.Ref (Option PublishDiagnosticsParams)
  importClosureRef : IO.Ref (Array DocumentUri)
  statusRef : IO.Ref WorkerStatus
  writeLock : Std.Mutex Unit

/-- Metadata snapshot for an imported source file. -/
structure ImportStamp where
  modified : IO.FS.SystemTime
  byteSize : UInt64
  deriving BEq, Repr

/-- An open file tracked by the daemon. -/
structure OpenFile where
  path : FilePath
  uri : DocumentUri
  versionRef : IO.Ref Nat
  lastTextRef : IO.Ref String
  worker : LspWorker
  importSnapshotRef : IO.Ref (Std.TreeMap String ImportStamp)
  staleRef : IO.Ref (Option String)
  lastUsedMsRef : IO.Ref Nat
  openedAtMs : Nat
  busyRef : IO.Ref Nat
  leaseExpiresMsRef : IO.Ref (Option Nat)
  operationLock : Std.Mutex Unit

/-- Daemon manager state. -/
structure Manager where
  projectRoot : FilePath
  config : ResourceConfig
  filesRef : IO.Ref (Std.TreeMap String OpenFile)
  lastRequestMsRef : IO.Ref Nat
  shutdownRef : IO.Ref Bool

/-- Wait until a child exits or a timeout expires. -/
partial def waitChildTimeout {cfg : IO.Process.StdioConfig}
    (child : IO.Process.Child cfg) (timeoutMs : Nat) : IO (Option UInt32) := do
  let start ← IO.monoMsNow
  let rec loop : IO (Option UInt32) := do
    if let some code ← child.tryWait then
      return some code
    let now ← IO.monoMsNow
    if now - start >= timeoutMs then
      return none
    IO.sleep 50
    loop
  loop

/-- Wait for an internal worker response promise. -/
partial def waitPromiseTimeout (p : IO.Promise (Except String Json)) (timeoutMs : Nat) : IO Json := do
  let task := p.result!
  let start ← IO.monoMsNow
  let rec loop : IO Json := do
    if ← IO.hasFinished task then
      exceptToIO task.get
    else
      let now ← IO.monoMsNow
      if now - start >= timeoutMs then
        throw <| IO.userError "timeout"
      IO.sleep 50
      loop
  loop

/-- Wait for an `IO.asTask` task with a timeout. -/
partial def waitIOTaskTimeout (task : Task (Except IO.Error α)) (timeoutMs : Nat) : IO α := do
  let start ← IO.monoMsNow
  let rec loop : IO α := do
    if ← IO.hasFinished task then
      match task.get with
      | .ok a => return a
      | .error e => throw e
    else
      let now ← IO.monoMsNow
      if now - start >= timeoutMs then
        throw <| IO.userError "timeout"
      IO.sleep 50
      loop
  loop

/-- Write an LSP message to a worker, serializing writes through a lock. -/
def LspWorker.writeMessage (w : LspWorker) (msg : JsonRpc.Message) : IO Unit := do
  w.writeLock.atomically do
    w.stdin.writeLspMessage msg

/-- Send an LSP notification to a worker. -/
def LspWorker.notify (w : LspWorker) (method : String) (params? : Option Json := none) : IO Unit := do
  let structured? := params?.bind (toStructured? · |>.toOption)
  w.writeMessage (.notification method structured?)

/-- Send an LSP request to a worker and register a pending response promise. -/
def LspWorker.request (w : LspWorker) (method : String) (params : Json) : IO (IO.Promise (Except String Json)) := do
  let idNat ← w.nextRequestIdRef.modifyGet fun n => (n, n + 1)
  let id : RequestID := RequestID.num idNat
  let promise ← IO.Promise.new
  w.pendingRef.modify (·.insert id promise)
  let structured? := (toStructured? params).toOption
  w.writeMessage (.request id method structured?)
  return promise

/-- Resolve and remove a pending worker response. -/
def LspWorker.resolvePending (w : LspWorker) (id : RequestID) (result : Except String Json) : IO Unit := do
  let promise? ← w.pendingRef.modifyGet fun pending =>
    (pending.get? id, pending.erase id)
  if let some promise := promise? then
    promise.resolve result

/-- Fail all pending worker responses. -/
def LspWorker.failAllPending (w : LspWorker) (message : String) : IO Unit := do
  let pending ← w.pendingRef.modifyGet fun pending => (pending, {})
  for (_, promise) in pending do
    promise.resolve (.error message)

/-- Drain worker stderr to daemon stderr/log. -/
partial def drainStderr (pref : String) (h : IO.FS.Handle) : IO Unit := do
  let rec loop : IO Unit := do
    let line ← h.getLine
    if line == "" then
      return
    else
      IO.eprintln s!"[{pref}] {line.trimAsciiEnd.toString}"
      loop
  try loop catch _ => pure ()

/-- Reader loop for a Lean worker. -/
partial def LspWorker.readerLoop (w : LspWorker) : IO Unit := do
  let rec loop : IO Unit := do
    let msg ← w.stdout.readLspMessage
    match msg with
    | .notification "textDocument/publishDiagnostics" (some params) =>
        match fromJson? (toJson params) with
        | .ok (p : PublishDiagnosticsParams) =>
            w.latestDiagnosticsRef.set (some p)
        | .error _ => pure ()
        loop
    | .notification "$/lean/importClosure" (some params) =>
        match fromJson? (toJson params) with
        | .ok (p : LeanImportClosureParams) =>
            w.importClosureRef.set p.importClosure
        | .error _ => pure ()
        loop
    | .response id result =>
        w.resolvePending id (.ok result)
        loop
    | .responseError id _ message _ =>
        w.resolvePending id (.error message)
        loop
    | .request id method _ =>
        -- We do not implement server requests from the Lean worker in AFTK's MVP.
        w.writeMessage (.responseError id .methodNotFound s!"AFTK does not handle worker request `{method}`" none)
        loop
    | _ => loop
  try
    loop
  catch e =>
    let code? ← try waitChildTimeout w.proc 1000 catch _ => pure none
    match code? with
    | some code =>
        w.statusRef.set (.terminated code)
        w.failAllPending s!"worker exited with code {code}"
    | none =>
        w.statusRef.set (.crashed e.toString)
        w.failAllPending s!"worker reader failed: {e}"

/-- Create minimal initialization params for a Lean worker. -/
def workerInitializeParams : InitializeParams := {
  processId? := none
  clientInfo? := none
  rootUri? := none
  initializationOptions? := some { hasWidgets? := some false, logCfg? := none }
  capabilities := { lean? := some { silentDiagnosticSupport? := some false, rpcWireFormat? := none } }
  trace := .off
  workspaceFolders? := none
}

/-- Start a Lean LSP worker for one file. -/
def startLspWorker (projectRoot path : FilePath) (text : String)
    (version : Nat) (buildMode : DependencyBuildMode) : IO LspWorker := do
  let workerPath ← findWorkerPath
  let uri := System.Uri.pathToUri path
  let child ← IO.Process.spawn {
    toStdioConfig := workerCfg
    cmd := workerPath.toString
    args := #["--worker"]
    cwd := some projectRoot
    setsid := true
  }
  let stdin := IO.FS.Stream.ofHandle child.stdin
  let stdout := IO.FS.Stream.ofHandle child.stdout
  let pendingRef ← IO.mkRef ({} : Std.TreeMap RequestID (IO.Promise (Except String Json)))
  let nextRequestIdRef ← IO.mkRef 1
  let latestDiagnosticsRef ← IO.mkRef none
  let importClosureRef ← IO.mkRef #[]
  let statusRef ← IO.mkRef WorkerStatus.running
  let writeLock ← Std.Mutex.new ()
  let stderrTask ← IO.asTask (drainStderr path.toString child.stderr)
  let w : LspWorker := {
    uri, proc := child, stdin, stdout, stderrTask,
    pendingRef, nextRequestIdRef, latestDiagnosticsRef, importClosureRef, statusRef, writeLock
  }
  -- The Lean worker consumes initialize and didOpen but does not answer initialize.
  w.writeMessage (.request 0 "initialize" ((toStructured? workerInitializeParams).toOption))
  let openParams : LeanDidOpenTextDocumentParams := {
    textDocument := { uri, languageId := "lean", version, text }
    dependencyBuildMode? := some buildMode
  }
  w.writeMessage (.notification "textDocument/didOpen" ((toStructured? openParams).toOption))
  discard <| IO.asTask (w.readerLoop)
  return w

/-- Stop a Lean worker gracefully, then kill if necessary. -/
def stopLspWorker (w : LspWorker) (timeoutMs : Nat := 2000) : IO Unit := do
  try
    w.writeMessage (.notification "exit" none)
  catch _ => pure ()
  let code? ← waitChildTimeout w.proc timeoutMs
  if code?.isNone then
    try w.proc.kill catch _ => pure ()
    discard <| waitChildTimeout w.proc 1000
  w.statusRef.set (.terminated (code?.getD 0))
  w.failAllPending "worker stopped"

/-- Construct a manager. -/
def Manager.new (projectRoot : FilePath) : IO Manager := do
  return {
    projectRoot
    config := ← readResourceConfig
    filesRef := ← IO.mkRef {}
    lastRequestMsRef := ← IO.mkRef (← IO.monoMsNow)
    shutdownRef := ← IO.mkRef false
  }

/-- Touch the daemon and an optional open file timestamp. -/
def Manager.touch (m : Manager) : IO Unit := do
  m.lastRequestMsRef.set (← IO.monoMsNow)

/-- Find an open file by canonical path string. -/
def Manager.getOpen? (m : Manager) (path : FilePath) : IO (Option OpenFile) := do
  return (← m.filesRef.get).get? path.toString

/-- Insert or replace an open file. -/
def Manager.insertOpen (m : Manager) (ofile : OpenFile) : IO Unit := do
  m.filesRef.modify (·.insert ofile.path.toString ofile)

/-- Erase an open file. -/
def Manager.eraseOpen (m : Manager) (path : FilePath) : IO (Option OpenFile) := do
  m.filesRef.modifyGet fun files =>
    (files.get? path.toString, files.erase path.toString)

/-- Convert a module name like `A.B.C` to `A/B/C.lean`. -/
def moduleToLeanPath (moduleName : String) : FilePath := Id.run do
  match moduleName.splitOn "." with
  | [] => FilePath.mk "" |>.addExtension "lean"
  | first :: rest =>
      let mut path : FilePath := FilePath.mk first
      for part in rest do
        path := path / part
      path.addExtension "lean"

/-- Resolve a module name as a source file under the project root. -/
def resolveLocalModule? (root : FilePath) (moduleName : String) : IO (Option FilePath) := do
  let path := root / moduleToLeanPath moduleName
  if ← path.pathExists then
    return some (← IO.FS.realPath path)
  return none

/-- Ask Lake for the project's source search path. This is needed when AFTK is run directly
rather than through `lake env`, especially for libraries with non-default `srcDir`s. -/
def lakeEnvSrcSearchPath? (root : FilePath) : IO (Option Lean.SearchPath) := do
  try
    let out ← IO.Process.output {
      cmd := "lake"
      args := #["env", "printenv", "LEAN_SRC_PATH"]
      cwd := some root
    }
    if out.exitCode != 0 then
      return none
    let raw := out.stdout.trimAscii.toString
    if raw.isEmpty then
      return none
    return some (System.SearchPath.parse raw)
  catch _ =>
    return none

/-- Source search path for resolving project module names. -/
def projectSrcSearchPath (root : FilePath) : IO Lean.SearchPath := do
  let inherited ← getSrcSearchPath
  let fallback : Lean.SearchPath := [root]
  match ← lakeEnvSrcSearchPath? root with
  | some lakePath => return lakePath ++ inherited ++ fallback
  | none => return inherited ++ fallback

/-- Heuristic for accepting a file path anywhere a module name is expected. -/
def looksLikeLeanFilePath (s : String) : Bool :=
  isLeanFileName s || containsSubstring s "/"

/-- Resolve a module name (or an explicit `.lean` path) to a source file. -/
def resolveModuleOrFile (root : FilePath) (moduleOrFile : String) : IO FilePath := do
  if looksLikeLeanFilePath moduleOrFile then
    return ← realFilePath (FilePath.mk moduleOrFile)
  if moduleOrFile.trimAscii.isEmpty then
    throw <| IO.userError "module name must not be empty"
  if let some path ← resolveLocalModule? root moduleOrFile then
    return path
  let modName := moduleOrFile.toName
  let sp ← projectSrcSearchPath root
  match ← sp.findModuleWithExt "lean" modName with
  | some path => IO.FS.realPath path
  | none =>
      throw <| IO.userError s!"could not find source for module `{moduleOrFile}` in project source search path"

/-- Crude import-line parser sufficient for source freshness tracking. -/
def parseImportModulesFromText (text : String) : Array String := Id.run do
  let mut out := #[]
  for line in text.splitOn "\n" do
    let line := line.trimAscii.toString
    let line :=
      if line.startsWith "public " then
        (line.drop "public ".length).toString.trimAscii.toString
      else
        line
    if line.startsWith "import " then
      let rest := (line.drop "import ".length).toString.trimAscii.toString
      match rest.splitOn " " with
      | mod :: _ =>
          if !mod.isEmpty then
            out := out.push mod
      | [] => pure ()
  out

/-- Recursively collect local project source imports of `path`. -/
partial def localImportClosure (root path : FilePath) : IO (Array FilePath) := do
  let rec go (todo : List FilePath) (seen : Std.HashSet String) (out : Array FilePath) : IO (Array FilePath) := do
    match todo with
    | [] => return out
    | path :: rest =>
        let path ← try IO.FS.realPath path catch _ => pure path
        let key := path.toString
        if seen.contains key then
          go rest seen out
        else
          let seen := seen.insert key
          let text ← try IO.FS.readFile path catch _ => pure ""
          let mut newTodo := rest
          for modName in parseImportModulesFromText text do
            if let some dep ← resolveLocalModule? root modName then
              newTodo := dep :: newTodo
          go newTodo seen (out.push path)
  -- Do not include the root file itself, only its imports.
  let text ← try IO.FS.readFile path catch _ => pure ""
  let mut todo := []
  for modName in parseImportModulesFromText text do
    if let some dep ← resolveLocalModule? root modName then
      todo := dep :: todo
  go todo {} #[]

/-- Convert a file URI to a real path string if possible. -/
def pathStringOfUri? (uri : DocumentUri) : IO (Option String) := do
  let some path := System.Uri.fileUriToPath? uri
    | return none
  try
    return some (← IO.FS.realPath path).toString
  catch _ =>
    return some (← absolutize path).toString

/-- Read the current stamp of a file path. -/
def importStamp? (path : FilePath) : IO (Option ImportStamp) := do
  try
    let md ← path.metadata
    return some { modified := md.modified, byteSize := md.byteSize }
  catch _ =>
    return none

/-- Wait briefly for the worker's import-closure notification. -/
partial def LspWorker.waitImportClosure (w : LspWorker) (timeoutMs : Nat := 2000) : IO (Array DocumentUri) := do
  let start ← IO.monoMsNow
  let rec loop : IO (Array DocumentUri) := do
    let imports ← w.importClosureRef.get
    if !imports.isEmpty then
      return imports
    let now ← IO.monoMsNow
    if now - start >= timeoutMs then
      return imports
    IO.sleep 50
    loop
  loop

/-- Snapshot source files in a worker's import closure and local project imports. -/
def OpenFile.currentImportSnapshot (root : FilePath) (ofile : OpenFile) : IO (Std.TreeMap String ImportStamp) := do
  let imports ← ofile.worker.waitImportClosure
  let mut snap : Std.TreeMap String ImportStamp := {}
  for uri in imports do
    if let some pathString ← pathStringOfUri? uri then
      if let some stamp ← importStamp? (FilePath.mk pathString) then
        snap := snap.insert pathString stamp
  for path in ← localImportClosure root ofile.path do
    let pathString := path.toString
    if let some stamp ← importStamp? path then
      snap := snap.insert pathString stamp
  return snap

/-- Update the stored import snapshot after successful diagnostics. -/
def OpenFile.updateImportSnapshot (root : FilePath) (ofile : OpenFile) : IO Unit := do
  ofile.importSnapshotRef.set (← ofile.currentImportSnapshot root)
  ofile.staleRef.set none

/-- Return a changed dependency path if any import snapshot entry is stale. -/
def OpenFile.changedDependency? (ofile : OpenFile) : IO (Option String) := do
  if let some stale ← ofile.staleRef.get then
    return some stale
  let old ← ofile.importSnapshotRef.get
  if old.isEmpty then
    return none
  for (pathString, oldStamp) in old do
    let stamp? ← importStamp? (FilePath.mk pathString)
    match stamp? with
    | some stamp =>
        if stamp != oldStamp then
          return some pathString
    | none =>
        return some pathString
  return none

/-- Mark open files whose import snapshots mention `changedPath` as stale. -/
def Manager.markDependentsStale (m : Manager) (changedPath : FilePath) : IO Unit := do
  let changed := changedPath.toString
  for (_, ofile) in ← m.filesRef.get do
    if ofile.path.toString != changed then
      let snap ← ofile.importSnapshotRef.get
      if snap.contains changed then
        ofile.staleRef.set (some changed)

/-- Whether an open file is currently protected by an active request. -/
def OpenFile.isBusy (ofile : OpenFile) : IO Bool := do
  return (← ofile.busyRef.get) > 0

/-- Serialize a semantic operation on one file and protect its worker from resource eviction. -/
def OpenFile.withOperation (ofile : OpenFile) (action : IO α) : IO α := do
  ofile.busyRef.modify (· + 1)
  try
    ofile.operationLock.atomically action
  finally
    ofile.busyRef.modify fun n => if n == 0 then 0 else n - 1

/-- Update optional lease metadata for an open file. -/
def OpenFile.updateLease (ofile : OpenFile) (ttlMs? : Option Nat := none) : IO Unit := do
  if let some ttlMs := ttlMs? then
    let now ← IO.monoMsNow
    ofile.leaseExpiresMsRef.set (some (now + ttlMs))

/-- Apply the default lease if neither caller nor existing file specified one. -/
def OpenFile.ensureDefaultLease (ofile : OpenFile) (cfg : ResourceConfig) : IO Unit := do
  if (← ofile.leaseExpiresMsRef.get).isNone then
    if let some ttlMs := cfg.defaultLeaseMs? then
      let now ← IO.monoMsNow
      ofile.leaseExpiresMsRef.set (some (now + ttlMs))

/-- True when the worker's lease has expired. -/
def OpenFile.leaseExpired (ofile : OpenFile) (now : Nat) : IO Bool := do
  match ← ofile.leaseExpiresMsRef.get with
  | some expires => return now >= expires
  | none => return false

/-- Close an already-open file by value, if it is still registered. -/
def Manager.closeOpenFile (m : Manager) (ofile : OpenFile) : IO Bool := do
  let erased? ← m.eraseOpen ofile.path
  match erased? with
  | none => return false
  | some erased =>
      try stopLspWorker erased.worker catch _ => pure ()
      return true

/-- Close idle or lease-expired workers. Returns how many were closed. -/
def Manager.closeIdleExpired (m : Manager) (aggressive : Bool := false) : IO Nat := do
  let now ← IO.monoMsNow
  let files ← m.filesRef.get
  let mut closed := 0
  for (_, ofile) in files do
    let busy ← ofile.isBusy
    if !busy then
      let last ← ofile.lastUsedMsRef.get
      let expired ← ofile.leaseExpired now
      if aggressive || expired || now - last >= m.config.workerIdleMs then
        if ← m.closeOpenFile ofile then
          closed := closed + 1
  return closed

/-- Close the least recently used non-busy worker, excluding an optional path. -/
def Manager.closeLRU (m : Manager) (protected? : Option String := none) : IO Bool := do
  let files ← m.filesRef.get
  let mut candidate? : Option (Nat × OpenFile) := none
  for (_, ofile) in files do
    if protected? != some ofile.path.toString then
      if !(← ofile.isBusy) then
        let last ← ofile.lastUsedMsRef.get
        match candidate? with
        | none => candidate? := some (last, ofile)
        | some (bestLast, _) =>
            if last < bestLast then
              candidate? := some (last, ofile)
  match candidate? with
  | none => return false
  | some (_, ofile) => m.closeOpenFile ofile

/-- Enforce the per-project worker cap by LRU eviction. -/
partial def Manager.enforceProjectWorkerLimit (m : Manager) (protected? : Option String := none) : IO Unit := do
  if m.config.maxWorkersPerProject == 0 then
    return
  let rec loop : IO Unit := do
    let count := (← m.filesRef.get).size
    if count < m.config.maxWorkersPerProject then
      return
    if ← m.closeLRU protected? then
      loop
    else
      throw <| IO.userError s!"resource limit reached: {count} project workers are active (AFTK_MAX_WORKERS_PER_PROJECT={m.config.maxWorkersPerProject})"
  loop

/-- Enforce the global Lean-worker cap by evicting local LRU workers or rejecting. -/
partial def Manager.enforceGlobalWorkerLimit (m : Manager) (protected? : Option String := none) : IO Unit := do
  if m.config.globalMaxWorkers == 0 then
    return
  let rec loop : IO Unit := do
    let count := (← leanWorkerPids).size
    if count < m.config.globalMaxWorkers then
      return
    if ← m.closeLRU protected? then
      loop
    else
      throw <| IO.userError s!"resource limit reached: {count} global Lean workers are active (AFTK_GLOBAL_MAX_WORKERS={m.config.globalMaxWorkers})"
  loop

/-- Enforce the optional hard memory cap for global Lean workers. -/
partial def Manager.enforceHardMemoryLimit (m : Manager) (protected? : Option String := none) : IO Unit := do
  match m.config.memoryHardLimitKb? with
  | none => return
  | some hardKb =>
      let rec loop : IO Unit := do
        let (_, mem) ← leanWorkersMemory
        if mem.pssKb + m.config.workerMemoryEstimateKb <= hardKb then
          return
        if ← m.closeLRU protected? then
          loop
        else
          throw <| IO.userError s!"resource limit reached: Lean worker PSS {mem.pssKb} KiB plus estimated new worker {m.config.workerMemoryEstimateKb} KiB exceeds AFTK_MEMORY_HARD_LIMIT ({hardKb} KiB)"
      loop

/-- Opportunistically evict local LRU workers when over the optional soft memory cap. -/
partial def Manager.enforceSoftMemoryLimit (m : Manager) (protected? : Option String := none) : IO Nat := do
  match m.config.memorySoftLimitKb? with
  | none => return 0
  | some softKb =>
      let rec loop (closed : Nat) : IO Nat := do
        let (_, mem) ← leanWorkersMemory
        if mem.pssKb <= softKb then
          return closed
        if ← m.closeLRU protected? then
          loop (closed + 1)
        else
          return closed
      loop 0

/-- Prepare to start one more worker: run GC, then enforce configured caps. -/
def Manager.prepareToStartWorker (m : Manager) (protected? : Option String := none) : IO Unit := do
  discard <| m.closeIdleExpired
  discard <| m.enforceSoftMemoryLimit protected?
  m.enforceProjectWorkerLimit protected?
  m.enforceGlobalWorkerLimit protected?
  m.enforceHardMemoryLimit protected?

/-- Open a file if needed. -/
def Manager.openFile (m : Manager) (file : String) (buildMode : DependencyBuildMode := .always)
    (ttlMs? : Option Nat := none) : IO Json := do
  m.touch
  let path ← realFilePath (FilePath.mk file)
  let text := (← IO.FS.readFile path).crlfToLf
  if let some ofile ← m.getOpen? path then
    ofile.lastUsedMsRef.set (← IO.monoMsNow)
    ofile.updateLease ttlMs?
    ofile.ensureDefaultLease m.config
    return Json.mkObj [("file", path.toString), ("uri", ofile.uri), ("version", ← ofile.versionRef.get), ("status", "open")]
  m.prepareToStartWorker (some path.toString)
  let version := 1
  let worker ← startLspWorker m.projectRoot path text version buildMode
  let now ← IO.monoMsNow
  let leaseTtl? := match ttlMs? with
    | some ttlMs => some ttlMs
    | none => m.config.defaultLeaseMs?
  let leaseExpires? := match leaseTtl? with
    | some ttlMs => some (now + ttlMs)
    | none => none
  let ofile : OpenFile := {
    path
    uri := worker.uri
    versionRef := ← IO.mkRef version
    lastTextRef := ← IO.mkRef text
    worker
    importSnapshotRef := ← IO.mkRef {}
    staleRef := ← IO.mkRef none
    lastUsedMsRef := ← IO.mkRef now
    openedAtMs := now
    busyRef := ← IO.mkRef 0
    leaseExpiresMsRef := ← IO.mkRef leaseExpires?
    operationLock := ← Std.Mutex.new ()
  }
  m.insertOpen ofile
  return Json.mkObj [("file", path.toString), ("uri", worker.uri), ("version", version), ("status", "open")]

/-- Restart an open file's worker, preserving daemon-level state. -/
def Manager.restartFile (m : Manager) (ofile : OpenFile) (text : String) : IO OpenFile := do
  try stopLspWorker ofile.worker 500 catch _ => pure ()
  discard <| m.eraseOpen ofile.path
  m.prepareToStartWorker (some ofile.path.toString)
  let version := 1
  let worker ← startLspWorker m.projectRoot ofile.path text version .always
  ofile.lastUsedMsRef.set (← IO.monoMsNow)
  let ofile' : OpenFile := {
    path := ofile.path
    uri := worker.uri
    versionRef := ← IO.mkRef version
    lastTextRef := ← IO.mkRef text
    worker
    importSnapshotRef := ← IO.mkRef {}
    staleRef := ← IO.mkRef none
    lastUsedMsRef := ofile.lastUsedMsRef
    openedAtMs := ofile.openedAtMs
    busyRef := ofile.busyRef
    leaseExpiresMsRef := ofile.leaseExpiresMsRef
    operationLock := ofile.operationLock
  }
  m.insertOpen ofile'
  return ofile'

/-- Ensure a file is open, auto-opening if needed. -/
def Manager.ensureOpen (m : Manager) (file : String) (ttlMs? : Option Nat := none) : IO OpenFile := do
  let path ← realFilePath (FilePath.mk file)
  if let some ofile ← m.getOpen? path then
    ofile.updateLease ttlMs?
    ofile.ensureDefaultLease m.config
    return ofile
  discard <| m.openFile file .always ttlMs?
  let some ofile ← m.getOpen? path
    | throw <| IO.userError "failed to open file"
  return ofile

/-- Replace the worker's in-memory document with a full text change and return its new version. -/
def OpenFile.sendFullTextChange (ofile : OpenFile) (text : String) : IO Nat := do
  let text := text.crlfToLf
  let version ← ofile.versionRef.modifyGet fun v => (v + 1, v + 1)
  let params : DidChangeTextDocumentParams := {
    textDocument := { uri := ofile.uri, version? := some version }
    contentChanges := #[.fullChange text]
  }
  ofile.worker.latestDiagnosticsRef.set none
  ofile.worker.writeMessage (.notification "textDocument/didChange" ((toStructured? params).toOption))
  ofile.lastTextRef.set text
  ofile.lastUsedMsRef.set (← IO.monoMsNow)
  return version

/-- Send full-document didChange if the file changed on disk. -/
def Manager.syncFileFromDisk (m : Manager) (ofile : OpenFile) : IO OpenFile := do
  let text := (← IO.FS.readFile ofile.path).crlfToLf
  let oldText ← ofile.lastTextRef.get
  if text == oldText then
    ofile.lastUsedMsRef.set (← IO.monoMsNow)
    return ofile
  discard <| ofile.sendFullTextChange text
  Manager.markDependentsStale m ofile.path
  return ofile

/-- Restart a file worker using the current file contents. -/
def Manager.restartFileFromDisk (m : Manager) (ofile : OpenFile) : IO OpenFile := do
  let text := (← IO.FS.readFile ofile.path).crlfToLf
  m.restartFile ofile text

/-- Restart before diagnostics if explicitly requested or if a tracked dependency is stale. -/
def Manager.maybeRestartForDiagnostics (m : Manager) (ofile : OpenFile) (refresh : Bool) : IO (OpenFile × Option String) := do
  if refresh then
    return (← m.restartFileFromDisk ofile, some "refresh")
  else
    match ← ofile.changedDependency? with
    | some dep => return (← m.restartFileFromDisk ofile, some s!"stale dependency: {dep}")
    | none => return (ofile, none)

/-- Wait until diagnostics for the open file's current version have been produced. -/
def OpenFile.waitForDiagnosticsVersion (ofile : OpenFile) (timeoutMs : Nat) : IO Nat := do
  let version ← ofile.versionRef.get
  let waitParams : WaitForDiagnosticsParams := { uri := ofile.uri, version }
  let promise ← ofile.worker.request "textDocument/waitForDiagnostics" (toJson waitParams)
  discard <| waitPromiseTimeout promise timeoutMs
  return version

/-- Plain tactic and term goals returned for one document position. -/
structure PlainGoalsResult where
  tacticGoal? : Option PlainGoal
  termGoal? : Option PlainTermGoal

/-- Query both plain-goal endpoints for an open file. -/
def OpenFile.queryPlainGoals (ofile : OpenFile) (pos : Lsp.Position)
    (timeoutMs : Nat) : IO PlainGoalsResult := do
  let posParams : TextDocumentPositionParams := {
    textDocument := { uri := ofile.uri }
    position := pos
  }
  let tacticParams : PlainGoalParams := { toTextDocumentPositionParams := posParams }
  let termParams : PlainTermGoalParams := { toTextDocumentPositionParams := posParams }
  let tacticPromise ← ofile.worker.request "$/lean/plainGoal" (toJson tacticParams)
  let termPromise ← ofile.worker.request "$/lean/plainTermGoal" (toJson termParams)
  let tacticJson ← waitPromiseTimeout tacticPromise timeoutMs
  let termJson ← waitPromiseTimeout termPromise timeoutMs
  return {
    tacticGoal? := ← exceptToIO <| fromJson? tacticJson
    termGoal? := ← exceptToIO <| fromJson? termJson
  }

/-- Diagnostics implementation; callers may wrap it with close-after cleanup. -/
partial def Manager.diagnosticsCore (m : Manager) (file : String) (timeoutMs : Nat := 30000) (includeRaw : Bool := false)
    (retry := true) (refresh := false) (ttlMs? : Option Nat := none) : IO Json := do
  m.touch
  let ofile ← m.ensureOpen file ttlMs?
  ofile.busyRef.modify (· + 1)
  try
    let ofile ← m.syncFileFromDisk ofile
    let restartResult ← m.maybeRestartForDiagnostics ofile refresh
    let ofile := restartResult.1
    let restartReason? := restartResult.2
    let version ← ofile.versionRef.get
    let status ← ofile.worker.statusRef.get
    match status with
    | .terminated 2 =>
        if retry then
          let ofile ← m.restartFileFromDisk ofile
          Manager.diagnosticsCore m ofile.path.toString timeoutMs includeRaw false false ttlMs?
        else
          throw <| IO.userError "worker requested restart after import/header change"
    | .terminated code =>
        throw <| IO.userError s!"worker exited with code {code}"
    | .crashed msg =>
        throw <| IO.userError msg
    | .running =>
        let waitParams : WaitForDiagnosticsParams := { uri := ofile.uri, version }
        let promise ← ofile.worker.request "textDocument/waitForDiagnostics" (toJson waitParams)
        try
          discard <| waitPromiseTimeout promise timeoutMs
        catch e =>
          let status ← ofile.worker.statusRef.get
          match status with
          | .terminated 2 =>
              if retry then
                let ofile ← m.restartFileFromDisk ofile
                return (← Manager.diagnosticsCore m ofile.path.toString timeoutMs includeRaw false false ttlMs?)
              else
                throw e
          | _ => throw e
        ofile.updateImportSnapshot m.projectRoot
        let diags? ← ofile.worker.latestDiagnosticsRef.get
        let diags := diags?.map (·.diagnostics) |>.getD #[]
        let fields := [
          ("file", toJson ofile.path.toString),
          ("uri", toJson ofile.uri),
          ("version", toJson version),
          ("diagnostics", toJson <| diags.map (diagnosticJson ofile.path.toString includeRaw))]
        let fields := match restartReason? with
          | some reason => fields ++ [("restarted", toJson true), ("restartReason", toJson reason)]
          | none => fields
        return Json.mkObj fields
  finally
    ofile.busyRef.modify fun n => if n == 0 then 0 else n - 1

/-- Request diagnostics for a file, auto-opening if needed. -/
partial def Manager.diagnostics (m : Manager) (file : String) (timeoutMs : Nat := 30000) (includeRaw : Bool := false)
    (retry := true) (refresh := false) (closeAfter := false) (ttlMs? : Option Nat := none) : IO Json := do
  let operationFile ← m.ensureOpen file ttlMs?
  try
    operationFile.withOperation <|
      Manager.diagnosticsCore m file timeoutMs includeRaw retry refresh ttlMs?
  finally
    if closeAfter then
      try
        let path ← try realFilePath (FilePath.mk file) catch _ => absolutize (FilePath.mk file)
        if let some ofile ← m.getOpen? path then
          discard <| m.closeOpenFile ofile
      catch _ => pure ()

/-- Query plain term and tactic goals at a 1-based source location in a module. -/
partial def Manager.goalsCore (m : Manager) (moduleName : String) (pos : Lsp.Position)
    (timeoutMs : Nat := 30000) (retry := true) (refresh := false) (ttlMs? : Option Nat := none) : IO Json := do
  m.touch
  let path ← resolveModuleOrFile m.projectRoot moduleName
  let ofile ← m.ensureOpen path.toString ttlMs?
  ofile.busyRef.modify (· + 1)
  try
    let ofile ← m.syncFileFromDisk ofile
    let restartResult ← m.maybeRestartForDiagnostics ofile refresh
    let ofile := restartResult.1
    let restartReason? := restartResult.2
    let status ← ofile.worker.statusRef.get
    match status with
    | .terminated 2 =>
        if retry then
          discard <| m.restartFileFromDisk ofile
          Manager.goalsCore m moduleName pos timeoutMs false false ttlMs?
        else
          throw <| IO.userError "worker requested restart after import/header change"
    | .terminated code =>
        throw <| IO.userError s!"worker exited with code {code}"
    | .crashed msg =>
        throw <| IO.userError msg
    | .running =>
        let version ← try
          ofile.waitForDiagnosticsVersion timeoutMs
        catch e =>
          let status ← ofile.worker.statusRef.get
          match status with
          | .terminated 2 =>
              if retry then
                discard <| m.restartFileFromDisk ofile
                return (← Manager.goalsCore m moduleName pos timeoutMs false false ttlMs?)
              else
                throw e
          | _ => throw e
        ofile.updateImportSnapshot m.projectRoot
        let goals ← ofile.queryPlainGoals pos timeoutMs
        let fields := [
          ("module", toJson moduleName),
          ("file", toJson ofile.path.toString),
          ("uri", toJson ofile.uri),
          ("version", toJson version),
          ("position", positionJson1 pos),
          ("tacticGoals", goals.tacticGoal?.map plainGoalJson |>.getD Json.null),
          ("termGoal", goals.termGoal?.map plainTermGoalJson |>.getD Json.null)]
        let fields := match restartReason? with
          | some reason => fields ++ [("restarted", toJson true), ("restartReason", toJson reason)]
          | none => fields
        return Json.mkObj fields
  finally
    ofile.busyRef.modify fun n => if n == 0 then 0 else n - 1

/-- Query goals for a module, auto-opening its source file if needed. -/
partial def Manager.goals (m : Manager) (moduleName : String) (line column : Nat) (timeoutMs : Nat := 30000)
    (retry := true) (refresh := false) (closeAfter := false) (ttlMs? : Option Nat := none) : IO Json := do
  let pos ← exceptToIO <| lspPositionFromLineColumn line column
  let path ← resolveModuleOrFile m.projectRoot moduleName
  let operationFile ← m.ensureOpen path.toString ttlMs?
  try
    operationFile.withOperation <|
      Manager.goalsCore m moduleName pos timeoutMs retry refresh ttlMs?
  finally
    if closeAfter then
      try
        if let some ofile ← m.getOpen? path then
          discard <| m.closeOpenFile ofile
      catch _ => pure ()

/-- True when an LSP position denotes an actual position in the document. -/
def validDocumentPosition (fileMap : FileMap) (pos : Lsp.Position) : Bool :=
  if pos.line >= fileMap.getLastLine then
    false
  else
    let offset := fileMap.lspPosToUtf8Pos pos
    let roundTrip := fileMap.utf8PosToLspPos offset
    roundTrip.line == pos.line && roundTrip.character == pos.character

/-- Validate a probe replacement range against the baseline document. -/
def validateProbeRange (fileMap : FileMap) (range : Lsp.Range) : Except String Unit := do
  unless validDocumentPosition fileMap range.start do
    throw s!"invalid probe range start {range.start.line + 1}:{range.start.character + 1}"
  unless validDocumentPosition fileMap range.«end» do
    throw s!"invalid probe range end {range.end.line + 1}:{range.end.character + 1}"
  let startOffset := fileMap.lspPosToUtf8Pos range.start
  let endOffset := fileMap.lspPosToUtf8Pos range.«end»
  if endOffset < startOffset then
    throw "probe range end precedes its start"

/-- Restore an open worker to the latest text on disk after a temporary probe. -/
def Manager.restoreAfterProbe (m : Manager) (path : FilePath) (timeoutMs : Nat) : IO Unit := do
  let some ofile ← m.getOpen? path
    | return
  let ofile ← match ← ofile.worker.statusRef.get with
    | .running => m.syncFileFromDisk ofile
    | .terminated _ | .crashed _ => m.restartFileFromDisk ofile
  discard <| ofile.waitForDiagnosticsVersion timeoutMs
  ofile.updateImportSnapshot m.projectRoot

/-- Apply a candidate replacement in memory, inspect it, and restore the source from disk. -/
def Manager.probeCore (m : Manager) (target : String) (replacementRange : Lsp.Range)
    (replacement : String) (goalsAt? : Option Lsp.Position) (timeoutMs : Nat := 30000)
    (includeRaw : Bool := false) (refresh := false) (ttlMs? : Option Nat := none) : IO Json := do
  m.touch
  let path ← resolveModuleOrFile m.projectRoot target
  let ofile ← m.ensureOpen path.toString ttlMs?
  let ofile ← m.syncFileFromDisk ofile
  let (ofile, _) ← m.maybeRestartForDiagnostics ofile refresh
  let baseline ← ofile.lastTextRef.get
  let baselineMap := baseline.toFileMap
  exceptToIO <| validateProbeRange baselineMap replacementRange
  let candidate := (Lean.Server.replaceLspRange baselineMap replacementRange replacement).source
  try
    let candidateVersion ← ofile.sendFullTextChange candidate
    let version ← ofile.waitForDiagnosticsVersion timeoutMs
    let status ← ofile.worker.statusRef.get
    match status with
    | .terminated 2 =>
        throw <| IO.userError "worker requested restart after probe changed an import or header"
    | .terminated code =>
        throw <| IO.userError s!"worker exited with code {code}"
    | .crashed msg =>
        throw <| IO.userError msg
    | .running =>
        let diags? ← ofile.worker.latestDiagnosticsRef.get
        let diags := diags?.map (·.diagnostics) |>.getD #[]
        let accepted := !diags.any fun d => d.severity? == some .error
        let mut fields : List (String × Json) := [
          ("target", target),
          ("file", ofile.path.toString),
          ("uri", ofile.uri),
          ("candidateVersion", candidateVersion),
          ("version", version),
          ("replacementRange", rangeJson1 replacementRange),
          ("accepted", accepted),
          ("diagnostics", toJson <| diags.map (diagnosticJson ofile.path.toString includeRaw)),
          ("restored", true)]
        if let some pos := goalsAt? then
          fields := fields ++ [("goalsPosition", positionJson1 pos)]
          try
            let goals ← ofile.queryPlainGoals pos timeoutMs
            fields := fields ++ [
              ("tacticGoals", goals.tacticGoal?.map plainGoalJson |>.getD Json.null),
              ("termGoal", goals.termGoal?.map plainTermGoalJson |>.getD Json.null)]
          catch e =>
            fields := fields ++ [
              ("tacticGoals", Json.null),
              ("termGoal", Json.null),
              ("goalError", e.toString)]
        return Json.mkObj fields
  finally
    m.restoreAfterProbe path timeoutMs

/-- Run a serialized probe transaction and optionally release its worker afterwards. -/
def Manager.probe (m : Manager) (target : String) (replacementRange : Lsp.Range)
    (replacement : String) (goalsAt? : Option Lsp.Position) (timeoutMs : Nat := 30000)
    (includeRaw := false) (refresh := false) (closeAfter := false)
    (ttlMs? : Option Nat := none) : IO Json := do
  let path ← resolveModuleOrFile m.projectRoot target
  let operationFile ← m.ensureOpen path.toString ttlMs?
  try
    operationFile.withOperation <|
      m.probeCore target replacementRange replacement goalsAt? timeoutMs includeRaw refresh ttlMs?
  finally
    if closeAfter then
      try
        if let some ofile ← m.getOpen? path then
          discard <| m.closeOpenFile ofile
      catch _ => pure ()

/-- Explicitly restart a file worker, opening the file if necessary. -/
def Manager.restartCommand (m : Manager) (file : String) : IO Json := do
  m.touch
  let path ← realFilePath (FilePath.mk file)
  let ofile : OpenFile ←
    match ← m.getOpen? path with
    | some ofile => m.restartFileFromDisk ofile
    | none =>
        let _ : Json ← m.openFile file .always
        let some ofile ← m.getOpen? path
          | throw <| IO.userError "failed to open file"
        pure (α := OpenFile) ofile
  return Json.mkObj [("file", ofile.path.toString), ("uri", ofile.uri), ("version", ← ofile.versionRef.get), ("status", "restarted")]

/-- Close an open file. -/
def Manager.closeFile (m : Manager) (file : String) : IO Json := do
  m.touch
  let path ← try realFilePath (FilePath.mk file) catch _ => absolutize (FilePath.mk file)
  let ofile? ← m.eraseOpen path
  match ofile? with
  | none => return Json.mkObj [("file", path.toString), ("status", "notOpen")]
  | some ofile =>
      stopLspWorker ofile.worker
      return Json.mkObj [("file", path.toString), ("status", "closed")]

/-- Return daemon status. -/
def Manager.status (m : Manager) : IO Json := do
  m.touch
  let files ← m.filesRef.get
  let mut arr := #[]
  for (_, ofile) in files do
    let stale? ← ofile.staleRef.get
    let importSnapshot ← ofile.importSnapshotRef.get
    let importCount := importSnapshot.size
    let mut importSample := #[]
    for (path, _) in importSnapshot do
      if importSample.size < 10 then
        importSample := importSample.push path
    let pid := ofile.worker.proc.pid.toNat
    let mem? ← processMemory? pid
    arr := arr.push <| Json.mkObj [
      ("file", ofile.path.toString),
      ("uri", ofile.uri),
      ("version", ← ofile.versionRef.get),
      ("worker", workerStatusJson (← ofile.worker.statusRef.get)),
      ("workerPid", pid),
      ("workerMemory", mem?.map processMemoryJson |>.getD Json.null),
      ("busy", ← ofile.busyRef.get),
      ("leaseExpiresMs", (← ofile.leaseExpiresMsRef.get).map toJson |>.getD Json.null),
      ("openedAtMs", ofile.openedAtMs),
      ("importsTracked", importCount),
      ("importsSample", toJson importSample),
      ("staleDependency", stale?.map toJson |>.getD Json.null),
      ("lastUsedMs", ← ofile.lastUsedMsRef.get)]
  let pid ← IO.Process.getPID
  let daemonMem? ← processMemory? pid.toNat
  let (globalWorkerCount, globalWorkerMem) ← leanWorkersMemory
  return Json.mkObj [
    ("projectRoot", m.projectRoot.toString),
    ("resourceConfig", resourceConfigJson m.config),
    ("openFiles", Json.arr arr),
    ("openFileCount", files.size),
    ("daemonPid", pid.toNat),
    ("daemonMemory", daemonMem?.map processMemoryJson |>.getD Json.null),
    ("globalLeanWorkers", globalWorkerCount),
    ("globalLeanWorkerMemory", processMemoryJson globalWorkerMem),
    ("lastRequestMs", ← m.lastRequestMsRef.get)]

/-- Gracefully shut down all open files. -/
def Manager.shutdown (m : Manager) : IO Unit := do
  m.shutdownRef.set true
  let files ← m.filesRef.modifyGet fun files => (files, {})
  for (_, ofile) in files do
    try stopLspWorker ofile.worker catch _ => pure ()

/-- Close all non-busy open files. -/
def Manager.closeAllNonBusy (m : Manager) : IO Nat := do
  let files ← m.filesRef.get
  let mut closed := 0
  for (_, ofile) in files do
    if !(← ofile.isBusy) then
      if ← m.closeOpenFile ofile then
        closed := closed + 1
  return closed

/-- Run resource cleanup now. -/
def Manager.gc (m : Manager) (aggressive : Bool := false) : IO Json := do
  m.touch
  let closedIdle ← m.closeIdleExpired aggressive
  let closedSoft ← m.enforceSoftMemoryLimit
  return Json.mkObj [
    ("closed", closedIdle + closedSoft),
    ("closedIdleExpired", closedIdle),
    ("closedForSoftMemory", closedSoft),
    ("status", "ok")]

/-- Close idle workers and optionally exit the daemon if idle. -/
partial def idleCleanupLoop (root : FilePath) (m : Manager) : IO Unit := do
  let rec loop : IO Unit := do
    IO.sleep 60000
    if ← m.shutdownRef.get then
      return
    let now ← IO.monoMsNow
    discard <| m.closeIdleExpired
    discard <| m.enforceSoftMemoryLimit
    let filesNow ← m.filesRef.get
    let lastReq ← m.lastRequestMsRef.get
    if filesNow.isEmpty && now - lastReq >= m.config.daemonIdleMs then
      Manager.shutdown m
      removeFileIfExists (metaPath root)
      removeDirIfExists (lockPath root)
      IO.Process.forceExit 0
    loop
  loop

/-- Handle one daemon protocol request. -/
def Manager.handle (m : Manager) (req : Json) : IO Json := do
  let method ← exceptToIO <| getStringField req "method"
  let params := (req.getObjVal? "params").toOption.getD (Json.mkObj [])
  try
    match method with
    | "open" =>
        let file ← exceptToIO <| getStringField params "file"
        let buildMode ← exceptToIO <| match getStringField? params "dependencyBuildMode" with
          | some s => parseBuildMode s
          | none => .ok .always
        let ttlMs? := getNatField? params "ttlMs"
        return okResponse (← m.openFile file buildMode ttlMs?)
    | "diagnostics" =>
        let file ← exceptToIO <| getStringField params "file"
        let timeoutMs := getNatField? params "timeoutMs" |>.getD 30000
        let includeRaw := getBoolField? params "includeRawLsp" |>.getD false
        let refresh := getBoolField? params "refresh" |>.getD false
        let closeAfter := (getBoolField? params "closeAfter" |>.getD false) || (getBoolField? params "transient" |>.getD false)
        let ttlMs? := getNatField? params "ttlMs"
        return okResponse (← m.diagnostics file timeoutMs includeRaw (refresh := refresh) (closeAfter := closeAfter) (ttlMs? := ttlMs?))
    | "probe" =>
        let target ← exceptToIO <| getStringField params "target"
        let replacement ← exceptToIO <| getStringField params "replacement"
        let startLine ← exceptToIO <| getObjValAs? Nat params "startLine"
        let startColumn ← exceptToIO <| getObjValAs? Nat params "startColumn"
        let endLine ← exceptToIO <| getObjValAs? Nat params "endLine"
        let endColumn ← exceptToIO <| getObjValAs? Nat params "endColumn"
        let replacementRange : Lsp.Range := {
          start := ← exceptToIO <| lspPositionFromLineColumn startLine startColumn
          «end» := ← exceptToIO <| lspPositionFromLineColumn endLine endColumn
        }
        let goalsAt? ← exceptToIO <| match getNatField? params "goalLine", getNatField? params "goalColumn" with
          | none, none => .ok none
          | some line, some column => some <$> lspPositionFromLineColumn line column
          | _, _ => .error "probe requires both goalLine and goalColumn"
        let timeoutMs := getNatField? params "timeoutMs" |>.getD 30000
        let includeRaw := getBoolField? params "includeRawLsp" |>.getD false
        let refresh := getBoolField? params "refresh" |>.getD false
        let closeAfter := (getBoolField? params "closeAfter" |>.getD false) ||
          (getBoolField? params "transient" |>.getD false)
        let ttlMs? := getNatField? params "ttlMs"
        return okResponse (← m.probe target replacementRange replacement goalsAt? timeoutMs
          includeRaw refresh closeAfter ttlMs?)
    | "goals" =>
        let moduleName ← exceptToIO <| getStringField params "module"
        let line ← exceptToIO <| getObjValAs? Nat params "line"
        let column ← exceptToIO <| getObjValAs? Nat params "column"
        let timeoutMs := getNatField? params "timeoutMs" |>.getD 30000
        let refresh := getBoolField? params "refresh" |>.getD false
        let closeAfter := (getBoolField? params "closeAfter" |>.getD false) || (getBoolField? params "transient" |>.getD false)
        let ttlMs? := getNatField? params "ttlMs"
        return okResponse (← m.goals moduleName line column timeoutMs (refresh := refresh) (closeAfter := closeAfter) (ttlMs? := ttlMs?))
    | "restart" | "refresh" =>
        let file ← exceptToIO <| getStringField params "file"
        return okResponse (← m.restartCommand file)
    | "close" =>
        let file ← exceptToIO <| getStringField params "file"
        return okResponse (← m.closeFile file)
    | "closeAll" =>
        return okResponse (Json.mkObj [("closed", ← m.closeAllNonBusy), ("status", "ok")])
    | "gc" =>
        let aggressive := getBoolField? params "aggressive" |>.getD false
        return okResponse (← m.gc aggressive)
    | "status" =>
        return okResponse (← m.status)
    | "shutdown" =>
        Manager.shutdown m
        return okResponse (Json.mkObj [("status", "shuttingDown")])
    | _ =>
        return errorResponse "badRequest" s!"unknown method `{method}`"
  catch e =>
    let msg := e.toString
    let code := if containsSubstring msg "resource limit reached" then "resourceLimit" else "ioError"
    return errorResponse code msg

/-- Find a newline byte in a byte array. -/
def findNewline? (bytes : ByteArray) : Option Nat := Id.run do
  for i in [0:bytes.size] do
    if bytes.get! i == 10 then
      return some i
  return none

/-- Read all bytes from a TCP client until EOF. -/
partial def tcpReadAll (client : Std.Async.TCP.Socket.Client) : IO ByteArray := do
  let rec loop (acc : ByteArray) : IO ByteArray := do
    let chunk? ← (client.recv? 4096).block
    match chunk? with
    | none => return acc
    | some chunk => loop (acc ++ chunk)
  loop ByteArray.empty

/-- Read one newline-terminated request from a TCP client. The newline is not included. -/
partial def tcpReadRequestLine (client : Std.Async.TCP.Socket.Client) : IO ByteArray := do
  let rec loop (acc : ByteArray) : IO ByteArray := do
    let chunk? ← (client.recv? 4096).block
    match chunk? with
    | none => return acc
    | some chunk =>
        match findNewline? chunk with
        | some i => return acc ++ chunk.extract 0 i
        | none => loop (acc ++ chunk)
  loop ByteArray.empty

/-- Send all bytes through a TCP client, bounding time spent on stale clients. -/
def tcpSendString (client : Std.Async.TCP.Socket.Client) (s : String) : IO Unit := do
  let task ← IO.asTask ((client.send s.toUTF8).block)
  discard <| waitIOTaskTimeout task 5000

/-- Handle a single TCP client connection. -/
def handleTcpClient (token : String) (m : Manager) (client : Std.Async.TCP.Socket.Client) : IO Unit := do
  let bytes ← tcpReadRequestLine client
  let response ← try
    let raw ← match String.fromUTF8? bytes with
      | some s => pure s
      | none => throw <| IO.userError "request was not valid UTF-8"
    let req ← exceptToIO <| Json.parse raw
    let reqToken ← exceptToIO <| getStringField req "token"
    if reqToken != token then
      pure <| errorResponse "unauthorized" "invalid daemon token"
    else
      m.handle req
  catch e =>
    pure <| errorResponse "badRequest" e.toString
  try
    tcpSendString client (Json.compress response ++ "\n")
  catch _ =>
    pure ()

/-- Run the daemon accept loop. -/
partial def runDaemon (root : FilePath) (token : String) : IO UInt32 := do
  IO.FS.createDirAll (aftkDir root)
  let logHandle ← IO.FS.Handle.mk (logPath root) IO.FS.Mode.append
  let _ ← IO.setStderr (IO.FS.Stream.ofHandle logHandle)
  let server ← Std.Async.TCP.Socket.Server.mk
  let addr : SocketAddress := SocketAddress.v4 { addr := IPv4Addr.ofParts 127 0 0 1, port := 0 }
  server.bind addr
  server.listen 64
  let sockName ← server.getSockName
  let port := sockName.port.toNat
  let now ← IO.monoMsNow
  let pid ← IO.Process.getPID
  let md : ServerMeta := {
    protocolVersion := protocolVersion
    projectRoot := root.toString
    pid := pid.toNat
    host := "127.0.0.1"
    port := port
    token := token
    startedAtMs := now
    lastSeenMs := now
    toolchain := ← readToolchain root
  }
  writeMeta root md
  let manager ← Manager.new root
  discard <| IO.asTask (idleCleanupLoop root manager)
  try
    let rec loop : IO Unit := do
      if ← manager.shutdownRef.get then
        return
      let client ← server.accept.block
      handleTcpClient token manager client
      if ← manager.shutdownRef.get then
        return
      loop
    loop
    Manager.shutdown manager
    removeFileIfExists (metaPath root)
    removeDirIfExists (lockPath root)
    return 0
  catch e =>
    IO.eprintln s!"daemon error: {e}"
    Manager.shutdown manager
    removeFileIfExists (metaPath root)
    removeDirIfExists (lockPath root)
    return 1

/-- Send one JSON request to a daemon described by metadata. -/
def sendToDaemon (md : ServerMeta) (method : String) (params : Json) (timeoutMs : Nat := 30000) : IO Json := do
  let client ← Std.Async.TCP.Socket.Client.mk
  let port : UInt16 := md.port.toUInt16
  let addr : SocketAddress := SocketAddress.v4 { addr := IPv4Addr.ofParts 127 0 0 1, port := port }
  (client.connect addr).block
  let req := Json.mkObj [("token", md.token), ("method", method), ("params", params)]
  tcpSendString client (Json.compress req ++ "\n")
  let task ← IO.asTask (tcpReadRequestLine client)
  let bytes ← waitIOTaskTimeout task timeoutMs
  let raw ← match String.fromUTF8? bytes with
    | some s => pure s
    | none => throw <| IO.userError "daemon response was not valid UTF-8"
  exceptToIO <| Json.parse raw

/-- Return true if metadata seems compatible with the current project. -/
def metaMatches (root : FilePath) (md : ServerMeta) : IO Bool := do
  let toolchain ← readToolchain root
  return md.protocolVersion == protocolVersion && md.projectRoot == root.toString && md.toolchain == toolchain

/-- Best-effort liveness check for a PID. -/
def pidAlive (pid : Nat) : IO Bool := do
  try
    let out ← IO.Process.output { cmd := "kill", args := #["-0", toString pid] }
    return out.exitCode == 0
  catch _ =>
    return false

/-- Reuse existing daemon metadata when the recorded process is alive.

We intentionally do not send a probe request here. The daemon handles one request at a time;
probing a busy daemon with a short timeout can create duplicate daemons under multi-agent load. -/
def tryExistingDaemon (root : FilePath) : IO (Option ServerMeta) := do
  if !(← (metaPath root).pathExists) then
    return none
  try
    let md ← readMeta root
    if !(← metaMatches root md) then
      removeFileIfExists (metaPath root)
      return none
    if ← pidAlive md.pid then
      return some md
    else
      removeFileIfExists (metaPath root)
      return none
  catch _ =>
    removeFileIfExists (metaPath root)
    return none

/-- Spawn the invisible daemon and wait until it is reachable. -/
def startDaemon (root : FilePath) : IO ServerMeta := do
  IO.FS.createDirAll (aftkDir root)
  let token ← randomToken
  let app ← IO.appPath
  let _child ← IO.Process.spawn {
    toStdioConfig := daemonCfg
    cmd := app.toString
    args := #["daemon", "--project-root", root.toString, "--token", token]
    cwd := some root
    setsid := true
  }
  for _ in [0:100] do
    if ← (metaPath root).pathExists then
      try
        let md ← readMeta root
        if md.token == token && (← metaMatches root md) then
          -- The daemon writes metadata only after binding its socket. Avoid an eager
          -- status probe here: if a startup probe times out before the accept loop
          -- reaches it, the stale client can waste daemon time later.
          return md
      catch _ => pure ()
    IO.sleep 100
  throw <| IO.userError "timed out waiting for aftk daemon to start"

/-- Get a daemon for the root, starting it if requested. -/
def getDaemon (root : FilePath) (startIfMissing : Bool) : IO (Option ServerMeta) := do
  if let some md ← tryExistingDaemon root then
    return some md
  if !startIfMissing then
    return none
  IO.FS.createDirAll (aftkDir root)
  let acquireLock : IO Bool := do
    try
      IO.FS.createDir (lockPath root)
      return true
    catch _ =>
      return false
  if ← acquireLock then
    try
      let md ← startDaemon root
      removeDirIfExists (lockPath root)
      return some md
    catch e =>
      removeDirIfExists (lockPath root)
      throw e
  else
    -- Another client may be starting the daemon. Wait briefly, then treat the lock as stale.
    for _ in [0:50] do
      if let some md ← tryExistingDaemon root then
        return some md
      IO.sleep 100
    removeDirIfExists (lockPath root)
    if ← acquireLock then
      try
        let md ← startDaemon root
        removeDirIfExists (lockPath root)
        return some md
      catch e =>
        removeDirIfExists (lockPath root)
        throw e
    else
      -- Last-resort retry without holding the lock; this should be rare and bounded by metadata checks.
      return some (← startDaemon root)

/-- Kill a process by PID using the platform `kill` command (POSIX best effort). -/
def killPid (pid : Nat) (signal : String) : IO Unit := do
  let out ← IO.Process.output {
    cmd := "kill"
    args := #[s!"-{signal}", toString pid]
  }
  if out.exitCode != 0 then
    throw <| IO.userError out.stderr

/-- Force shutdown using metadata when graceful shutdown failed. -/
def forceShutdown (root : FilePath) : IO Json := do
  if !(← (metaPath root).pathExists) then
    return Json.mkObj [("status", "notRunning")]
  let md ← readMeta root
  try killPid md.pid "TERM" catch _ => pure ()
  IO.sleep 500
  -- If still reachable, escalate.
  let stillRunning ← try
    discard <| sendToDaemon md "status" (Json.mkObj []) 500
    pure true
  catch _ => pure false
  if stillRunning then
    try killPid md.pid "KILL" catch _ => pure ()
  removeFileIfExists (metaPath root)
  removeDirIfExists (lockPath root)
  return Json.mkObj [("status", "forced"), ("pid", md.pid)]

/-- Return the argument following `flag`. -/
def argAfter? (flag : String) : List String → Option String
  | [] => none
  | x :: y :: rest => if x == flag then some y else argAfter? flag (y :: rest)
  | _ :: rest => argAfter? flag rest

/-- Best-effort list of AFTK daemon PIDs. -/
def aftkDaemonPids : IO (Array Nat) := do
  try
    let out ← IO.Process.output { cmd := "pgrep", args := #["-f", "aftk daemon --project-root"] }
    if out.exitCode != 0 then
      return #[]
    let mut pids := #[]
    for line in out.stdout.splitOn "\n" do
      if let some pid := line.trimAscii.toString.toNat? then
        pids := pids.push pid
    return pids
  catch _ => return #[]

/-- Recognize the exact daemon command shape. -/
def isAftkDaemonArgs : List String → Bool
  | _exe :: "daemon" :: _ => true
  | _ => false

/-- Gracefully shut down every discoverable AFTK project daemon for this user. -/
def shutdownAllDaemons : IO Json := do
  let pids ← aftkDaemonPids
  let mut arr := #[]
  for pid in pids do
    let args? ← processArgs? pid
    match args? with
    | none => arr := arr.push <| Json.mkObj [("pid", pid), ("status", "unknownArgs")]
    | some args =>
      if !isAftkDaemonArgs args then
        pure ()
      else
      match argAfter? "--project-root" args with
      | none =>
          arr := arr.push <| Json.mkObj [("pid", pid), ("status", "unknownProjectRoot")]
      | some rootString =>
        let root := FilePath.mk rootString
        let result ← try
          if ← (metaPath root).pathExists then
            let md ← readMeta root
            let resp ← sendToDaemon md "shutdown" (Json.mkObj []) 5000
            removeFileIfExists (metaPath root)
            removeDirIfExists (lockPath root)
            pure resp
          else
            try killPid pid "TERM" catch _ => pure ()
            pure <| okResponse (Json.mkObj [("status", "signaled")])
        catch e =>
          try killPid pid "TERM" catch _ => pure ()
          pure <| errorResponse "ioError" e.toString
        arr := arr.push <| Json.mkObj [("pid", pid), ("projectRoot", rootString), ("response", result)]
  return Json.mkObj [("status", "ok"), ("daemons", Json.arr arr)]

/-- Print JSON result to stdout. -/
def printJson (j : Json) : IO UInt32 := do
  IO.println (Json.compress j)
  return 0

/-- Extract result/error status from daemon response for CLI. -/
def printDaemonResponse (resp : Json) : IO UInt32 := do
  IO.println (Json.compress resp)
  match resp.getObjValAs? Bool "ok" with
  | .ok true => return 0
  | _ => return 1

/-- CLI help for server-backed commands. -/
def cliHelp : String :=
"AFTK daemon-backed Lean diagnostics.

Commands:
  open [options] <file>          Warm up/open a Lean file worker (open options precede file).
  diagnostics [options] <file>   Elaborate file and print diagnostics as JSON.
  probe [options] <module-or-file>
                                Temporarily replace a source range and elaborate it in memory.
  goals [options] <module> <line> <column>
                                Return term/tactic goals at a 1-based module location.
  restart <file>                 Restart a file worker and reload imports/dependencies.
  close <file>                   Release a file worker.
  close --idle                   Close idle/expired workers now.
  close --all                    Close all non-busy workers.
  gc [--aggressive]              Run daemon resource cleanup now.
  status [--start]               Show daemon/resource status for the current project.
  shutdown [--force|--all-projects] Stop project daemon(s) and workers.

Options:
  --timeout-ms <n>               Diagnostics/request timeout.
  --raw-lsp                      Include raw LSP diagnostics.
  --refresh                      Restart worker before diagnostics/probe/goals.
  --transient | --close-after    Close the worker after the request.
  --ttl-ms <n>                   Set/renew a worker lease.
  --dependency-build-mode <m>    always | once | never (open only).

Probe options:
  --range <l:c-l:c>              Replace this 1-based, end-exclusive source range.
  --at <line:column>             Insert at a 1-based source position.
  --stdin                        Read replacement text from standard input.
  --text <text>                  Use replacement text from one argument.
  --goals-at <line:column>       Also query tactic and term goals in the candidate.
"

/-- Parse an option with a following value. -/
def takeOptionValue (opt : String) : List String → Except String (String × List String)
  | value :: rest => .ok (value, rest)
  | [] => .error s!"missing value after {opt}"

/-- Parsed arguments for the `probe` command. Source positions remain 1-based here. -/
structure ProbeCliConfig where
  target : String
  startLine : Nat
  startColumn : Nat
  endLine : Nat
  endColumn : Nat
  goalsAt? : Option (Nat × Nat)
  replacement? : Option String
  readStdin : Bool
  timeoutMs : Nat
  includeRaw : Bool
  refresh : Bool
  closeAfter : Bool
  ttlMs? : Option Nat

/-- Run the transactional in-memory probe CLI command. -/
partial def runProbeCli (args : List String) : IO UInt32 := do
  let finalize (target? : Option String) (range? : Option (Nat × Nat × Nat × Nat))
      (goalsAt? : Option (Nat × Nat)) (replacement? : Option String) (readStdin : Bool)
      (timeoutMs : Nat) (includeRaw refresh closeAfter : Bool) (ttlMs? : Option Nat)
      : Except String ProbeCliConfig := do
    let some target := target? | throw "probe requires <module-or-file>"
    let some (startLine, startColumn, endLine, endColumn) := range?
      | throw "probe requires --range <line:column-line:column> or --at <line:column>"
    if readStdin && replacement?.isSome then
      throw "probe accepts exactly one of --stdin or --text"
    if !readStdin && replacement?.isNone then
      throw "probe requires replacement text via --stdin or --text"
    return {
      target, startLine, startColumn, endLine, endColumn, goalsAt?, replacement?, readStdin,
      timeoutMs, includeRaw, refresh, closeAfter, ttlMs?
    }
  let rec parse (args : List String) (target? : Option String)
      (range? : Option (Nat × Nat × Nat × Nat)) (goalsAt? : Option (Nat × Nat))
      (replacement? : Option String) (readStdin : Bool) (timeoutMs : Nat)
      (includeRaw refresh closeAfter : Bool) (ttlMs? : Option Nat)
      : Except String ProbeCliConfig := do
    match args with
    | [] =>
        finalize target? range? goalsAt? replacement? readStdin timeoutMs
          includeRaw refresh closeAfter ttlMs?
    | "--range" :: rest =>
        let (value, rest) ← takeOptionValue "--range" rest
        parse rest target? (some (← parseRangeString value)) goalsAt? replacement? readStdin
          timeoutMs includeRaw refresh closeAfter ttlMs?
    | "--at" :: rest =>
        let (value, rest) ← takeOptionValue "--at" rest
        let (line, column) ← parseLineColumnString value
        parse rest target? (some (line, column, line, column)) goalsAt? replacement? readStdin
          timeoutMs includeRaw refresh closeAfter ttlMs?
    | "--goals-at" :: rest =>
        let (value, rest) ← takeOptionValue "--goals-at" rest
        parse rest target? range? (some (← parseLineColumnString value)) replacement? readStdin
          timeoutMs includeRaw refresh closeAfter ttlMs?
    | "--stdin" :: rest =>
        parse rest target? range? goalsAt? replacement? true timeoutMs includeRaw refresh closeAfter ttlMs?
    | "--text" :: rest =>
        let (value, rest) ← takeOptionValue "--text" rest
        parse rest target? range? goalsAt? (some value) readStdin timeoutMs includeRaw refresh closeAfter ttlMs?
    | "--timeout-ms" :: rest =>
        let (value, rest) ← takeOptionValue "--timeout-ms" rest
        let some n := value.toNat? | throw s!"invalid timeout `{value}`"
        parse rest target? range? goalsAt? replacement? readStdin n includeRaw refresh closeAfter ttlMs?
    | "--raw-lsp" :: rest =>
        parse rest target? range? goalsAt? replacement? readStdin timeoutMs true refresh closeAfter ttlMs?
    | "--refresh" :: rest =>
        parse rest target? range? goalsAt? replacement? readStdin timeoutMs includeRaw true closeAfter ttlMs?
    | "--transient" :: rest | "--close-after" :: rest =>
        parse rest target? range? goalsAt? replacement? readStdin timeoutMs includeRaw refresh true ttlMs?
    | "--ttl-ms" :: rest =>
        let (value, rest) ← takeOptionValue "--ttl-ms" rest
        let some n := value.toNat? | throw s!"invalid ttl `{value}`"
        parse rest target? range? goalsAt? replacement? readStdin timeoutMs includeRaw refresh closeAfter (some n)
    | arg :: rest =>
        if arg.startsWith "--range=" then
          parse rest target? (some (← parseRangeString (arg.drop "--range=".length).toString))
            goalsAt? replacement? readStdin timeoutMs includeRaw refresh closeAfter ttlMs?
        else if arg.startsWith "--at=" then
          let (line, column) ← parseLineColumnString (arg.drop "--at=".length).toString
          parse rest target? (some (line, column, line, column)) goalsAt? replacement? readStdin
            timeoutMs includeRaw refresh closeAfter ttlMs?
        else if arg.startsWith "--goals-at=" then
          parse rest target? range? (some (← parseLineColumnString
            (arg.drop "--goals-at=".length).toString)) replacement? readStdin timeoutMs
            includeRaw refresh closeAfter ttlMs?
        else if arg.startsWith "-" then
          throw s!"unknown probe option `{arg}`"
        else if target?.isSome then
          throw s!"too many positional arguments: `{arg}`"
        else
          parse rest (some arg) range? goalsAt? replacement? readStdin timeoutMs
            includeRaw refresh closeAfter ttlMs?
  match parse args none none none none false 30000 false false false none with
  | .error e => IO.eprintln s!"error: {e}\n\n{cliHelp}"; return 1
  | .ok config =>
      let replacement ← if config.readStdin then (← IO.getStdin).readToEnd else pure config.replacement?.get!
      let root ← if looksLikeLeanFilePath config.target then
          findProjectRoot (some (FilePath.mk config.target))
        else
          findProjectRoot none
      let some md ← getDaemon root true | throw <| IO.userError "failed to start daemon"
      let mut fields : List (String × Json) := [
        ("target", config.target),
        ("replacement", replacement),
        ("startLine", config.startLine),
        ("startColumn", config.startColumn),
        ("endLine", config.endLine),
        ("endColumn", config.endColumn),
        ("timeoutMs", config.timeoutMs),
        ("includeRawLsp", config.includeRaw),
        ("refresh", config.refresh),
        ("closeAfter", config.closeAfter)]
      if let some (line, column) := config.goalsAt? then
        fields := fields ++ [("goalLine", toJson line), ("goalColumn", toJson column)]
      if let some ttlMs := config.ttlMs? then
        fields := fields ++ [("ttlMs", toJson ttlMs)]
      printDaemonResponse (← sendToDaemon md "probe" (Json.mkObj fields)
        (config.timeoutMs * 2 + 5000))

/-- Run the diagnostics CLI command. -/
partial def runDiagnosticsCli (args : List String) : IO UInt32 := do
  let rec parseDiagnostics (args : List String) (timeoutMs : Nat) (raw refresh closeAfter : Bool)
      (ttlMs? : Option Nat) (file? : Option String) : Except String (Nat × Bool × Bool × Bool × Option Nat × String) :=
    match args with
    | [] =>
        match file? with
        | some file => .ok (timeoutMs, raw, refresh, closeAfter, ttlMs?, file)
        | none => .error "diagnostics requires <file>"
    | "--timeout-ms" :: rest => do
        let (v, rest) ← takeOptionValue "--timeout-ms" rest
        let some n := v.toNat? | .error s!"invalid timeout `{v}`"
        parseDiagnostics rest n raw refresh closeAfter ttlMs? file?
    | "--raw-lsp" :: rest => parseDiagnostics rest timeoutMs true refresh closeAfter ttlMs? file?
    | "--refresh" :: rest => parseDiagnostics rest timeoutMs raw true closeAfter ttlMs? file?
    | "--transient" :: rest => parseDiagnostics rest timeoutMs raw refresh true ttlMs? file?
    | "--close-after" :: rest => parseDiagnostics rest timeoutMs raw refresh true ttlMs? file?
    | "--ttl-ms" :: rest => do
        let (v, rest) ← takeOptionValue "--ttl-ms" rest
        let some n := v.toNat? | .error s!"invalid ttl `{v}`"
        parseDiagnostics rest timeoutMs raw refresh closeAfter (some n) file?
    | arg :: rest =>
        if arg.startsWith "-" then
          .error s!"unknown diagnostics option `{arg}`"
        else if file?.isSome then
          .error s!"too many positional arguments: `{arg}`"
        else
          parseDiagnostics rest timeoutMs raw refresh closeAfter ttlMs? (some arg)
  match parseDiagnostics args 30000 false false false none none with
  | .error e => IO.eprintln s!"error: {e}\n\n{cliHelp}"; return 1
  | .ok (timeoutMs, raw, refresh, closeAfter, ttlMs?, file) =>
      let root ← findProjectRoot (some (FilePath.mk file))
      let some md ← getDaemon root true | throw <| IO.userError "failed to start daemon"
      let fields := match ttlMs? with
        | some ttlMs => [("ttlMs", toJson ttlMs)]
        | none => []
      let params := Json.mkObj (([("file", toJson file), ("timeoutMs", toJson timeoutMs), ("includeRawLsp", toJson raw), ("refresh", toJson refresh), ("closeAfter", toJson closeAfter)] : List (String × Json)) ++ fields)
      printDaemonResponse (← sendToDaemon md "diagnostics" params (timeoutMs + 5000))

/-- Run the goals CLI command. -/
partial def runGoalsCli (args : List String) : IO UInt32 := do
  let finalize (timeoutMs : Nat) (refresh closeAfter : Bool) (ttlMs? : Option Nat)
      (line? column? : Option Nat) (positionals : Array String) : Except String (Nat × Bool × Bool × Option Nat × String × Nat × Nat) := do
    match positionals.toList with
    | [moduleName] =>
        match line?, column? with
        | some line, some column => return (timeoutMs, refresh, closeAfter, ttlMs?, moduleName, line, column)
        | some _, none => throw "missing --column for goals location"
        | none, some _ => throw "missing --line for goals location"
        | none, none => throw "goals requires <module> <line> <column> or <module> <line>:<column>"
    | [moduleName, loc] =>
        if line?.isSome || column?.isSome then
          throw "do not combine positional location with --line/--column"
        let (line, column) ← parseLineColumnString loc
        return (timeoutMs, refresh, closeAfter, ttlMs?, moduleName, line, column)
    | [moduleName, lineRaw, columnRaw] =>
        if line?.isSome || column?.isSome then
          throw "do not combine positional location with --line/--column"
        let line ← parsePositiveNat "line" lineRaw
        let column ← parsePositiveNat "column" columnRaw
        return (timeoutMs, refresh, closeAfter, ttlMs?, moduleName, line, column)
    | [] => throw "goals requires <module> and a location"
    | _ => throw "too many positional arguments for goals"
  let rec parseGoals (args : List String) (timeoutMs : Nat) (refresh closeAfter : Bool)
      (ttlMs? : Option Nat) (line? column? : Option Nat) (positionals : Array String)
      : Except String (Nat × Bool × Bool × Option Nat × String × Nat × Nat) := do
    match args with
    | [] => finalize timeoutMs refresh closeAfter ttlMs? line? column? positionals
    | "--timeout-ms" :: rest => do
        let (v, rest) ← takeOptionValue "--timeout-ms" rest
        let some n := v.toNat? | .error s!"invalid timeout `{v}`"
        parseGoals rest n refresh closeAfter ttlMs? line? column? positionals
    | "--refresh" :: rest => parseGoals rest timeoutMs true closeAfter ttlMs? line? column? positionals
    | "--transient" :: rest => parseGoals rest timeoutMs refresh true ttlMs? line? column? positionals
    | "--close-after" :: rest => parseGoals rest timeoutMs refresh true ttlMs? line? column? positionals
    | "--ttl-ms" :: rest => do
        let (v, rest) ← takeOptionValue "--ttl-ms" rest
        let some n := v.toNat? | .error s!"invalid ttl `{v}`"
        parseGoals rest timeoutMs refresh closeAfter (some n) line? column? positionals
    | "--line" :: rest => do
        let (v, rest) ← takeOptionValue "--line" rest
        parseGoals rest timeoutMs refresh closeAfter ttlMs? (some (← parsePositiveNat "line" v)) column? positionals
    | "--column" :: rest => do
        let (v, rest) ← takeOptionValue "--column" rest
        parseGoals rest timeoutMs refresh closeAfter ttlMs? line? (some (← parsePositiveNat "column" v)) positionals
    | "--position" :: rest | "--pos" :: rest => do
        let (v, rest) ← takeOptionValue "--position" rest
        let (line, column) ← parseLineColumnString v
        parseGoals rest timeoutMs refresh closeAfter ttlMs? (some line) (some column) positionals
    | arg :: rest =>
        if arg.startsWith "--line=" then
          parseGoals rest timeoutMs refresh closeAfter ttlMs? (some (← parsePositiveNat "line" ((arg.drop "--line=".length).toString))) column? positionals
        else if arg.startsWith "--column=" then
          parseGoals rest timeoutMs refresh closeAfter ttlMs? line? (some (← parsePositiveNat "column" ((arg.drop "--column=".length).toString))) positionals
        else if arg.startsWith "--position=" then
          let (line, column) ← parseLineColumnString ((arg.drop "--position=".length).toString)
          parseGoals rest timeoutMs refresh closeAfter ttlMs? (some line) (some column) positionals
        else if arg.startsWith "--pos=" then
          let (line, column) ← parseLineColumnString ((arg.drop "--pos=".length).toString)
          parseGoals rest timeoutMs refresh closeAfter ttlMs? (some line) (some column) positionals
        else if arg.startsWith "-" then
          .error s!"unknown goals option `{arg}`"
        else
          parseGoals rest timeoutMs refresh closeAfter ttlMs? line? column? (positionals.push arg)
  match parseGoals args 30000 false false none none none #[] with
  | .error e => IO.eprintln s!"error: {e}\n\n{cliHelp}"; return 1
  | .ok (timeoutMs, refresh, closeAfter, ttlMs?, moduleName, line, column) =>
      let root ←
        if looksLikeLeanFilePath moduleName then
          findProjectRoot (some (FilePath.mk moduleName))
        else
          findProjectRoot none
      let some md ← getDaemon root true | throw <| IO.userError "failed to start daemon"
      let fields := match ttlMs? with
        | some ttlMs => [("ttlMs", toJson ttlMs)]
        | none => []
      let params := Json.mkObj (([("module", toJson moduleName), ("line", toJson line), ("column", toJson column),
        ("timeoutMs", toJson timeoutMs), ("refresh", toJson refresh), ("closeAfter", toJson closeAfter)] : List (String × Json)) ++ fields)
      printDaemonResponse (← sendToDaemon md "goals" params (timeoutMs + 5000))

/-- Run visible and hidden daemon-related CLI commands. -/
partial def runCli (cmd : String) (args : List String) : IO UInt32 := do
  if args == ["--help"] || args == ["-h"] || args == ["help"] then
    IO.println cliHelp
    return 0
  match cmd with
  | "daemon" =>
      let rec parseDaemon (args : List String) (root? token? : Option String) : Except String (String × String) :=
        match args with
        | [] =>
            match root?, token? with
            | some r, some t => .ok (r, t)
            | _, _ => .error "daemon requires --project-root and --token"
        | "--project-root" :: rest => do
            let (v, rest) ← takeOptionValue "--project-root" rest
            parseDaemon rest (some v) token?
        | "--token" :: rest => do
            let (v, rest) ← takeOptionValue "--token" rest
            parseDaemon rest root? (some v)
        | other :: _ => .error s!"unknown daemon option `{other}`"
      match parseDaemon args none none with
      | .error e => IO.eprintln e; return 1
      | .ok (root, token) =>
          let code ← runDaemon (FilePath.mk root) token
          IO.Process.forceExit code.toUInt8
  | "open" =>
      let rec parseOpen (args : List String) (mode : DependencyBuildMode) (ttlMs? : Option Nat) : Except String (DependencyBuildMode × Option Nat × String) :=
        match args with
        | [] => .error "open requires <file>"
        | [file] => .ok (mode, ttlMs?, file)
        | "--dependency-build-mode" :: rest => do
            let (v, rest) ← takeOptionValue "--dependency-build-mode" rest
            parseOpen rest (← parseBuildMode v) ttlMs?
        | "--ttl-ms" :: rest => do
            let (v, rest) ← takeOptionValue "--ttl-ms" rest
            let some n := v.toNat? | .error s!"invalid ttl `{v}`"
            parseOpen rest mode (some n)
        | other :: _ => .error s!"unknown open option or misplaced argument `{other}`; options must precede <file>"
      match parseOpen args .always none with
      | .error e => IO.eprintln s!"error: {e}\n\n{cliHelp}"; return 1
      | .ok (mode, ttlMs?, file) =>
          let root ← findProjectRoot (some (FilePath.mk file))
          let some md ← getDaemon root true | throw <| IO.userError "failed to start daemon"
          let modeStr := match mode with | .always => "always" | .once => "once" | .never => "never"
          let mut fields : List (String × Json) := [("file", toJson file), ("dependencyBuildMode", toJson modeStr)]
          if let some ttlMs := ttlMs? then fields := fields ++ [("ttlMs", toJson ttlMs)]
          printDaemonResponse (← sendToDaemon md "open" (Json.mkObj fields))
  | "diagnostics" =>
      runDiagnosticsCli args
  | "diag" =>
      runDiagnosticsCli args
  | "probe" =>
      runProbeCli args
  | "goals" | "goal" =>
      runGoalsCli args
  | "restart" | "refresh" =>
      match args with
      | [file] =>
          let root ← findProjectRoot (some (FilePath.mk file))
          let some md ← getDaemon root true | throw <| IO.userError "failed to start daemon"
          printDaemonResponse (← sendToDaemon md "restart" (Json.mkObj [("file", file)]))
      | _ => IO.eprintln s!"error: restart requires <file>\n\n{cliHelp}"; return 1
  | "close" =>
      match args with
      | ["--all"] =>
          let root ← findProjectRoot none
          match ← getDaemon root false with
          | none => printJson <| okResponse (Json.mkObj [("status", "notRunning"), ("projectRoot", root.toString)])
          | some md => printDaemonResponse (← sendToDaemon md "closeAll" (Json.mkObj []))
      | ["--idle"] =>
          let root ← findProjectRoot none
          match ← getDaemon root false with
          | none => printJson <| okResponse (Json.mkObj [("status", "notRunning"), ("projectRoot", root.toString)])
          | some md => printDaemonResponse (← sendToDaemon md "gc" (Json.mkObj []))
      | [file] =>
          let root ← findProjectRoot (some (FilePath.mk file))
          match ← getDaemon root false with
          | none => printJson <| okResponse (Json.mkObj [("file", file), ("status", "notRunning")])
          | some md => printDaemonResponse (← sendToDaemon md "close" (Json.mkObj [("file", file)]))
      | _ => IO.eprintln s!"error: close requires <file>, --idle, or --all\n\n{cliHelp}"; return 1
  | "gc" =>
      let aggressive := args.contains "--aggressive"
      if args.any (fun a => a != "--aggressive") then
        IO.eprintln s!"error: unknown gc option\n\n{cliHelp}"; return 1
      let root ← findProjectRoot none
      match ← getDaemon root false with
      | none => printJson <| okResponse (Json.mkObj [("status", "notRunning"), ("projectRoot", root.toString)])
      | some md => printDaemonResponse (← sendToDaemon md "gc" (Json.mkObj [("aggressive", aggressive)]))
  | "status" =>
      let startIfMissing := args.contains "--start"
      if args.any (fun a => a != "--start") then
        IO.eprintln s!"error: unknown status option\n\n{cliHelp}"; return 1
      let root ← findProjectRoot none
      match ← getDaemon root startIfMissing with
      | none => printJson <| okResponse (Json.mkObj [("status", "notRunning"), ("projectRoot", root.toString)])
      | some md => printDaemonResponse (← sendToDaemon md "status" (Json.mkObj []))
  | "shutdown" =>
      let force := args.contains "--force"
      let allProjects := args.contains "--all-projects" || args.contains "--all"
      if args.any (fun a => a != "--force" && a != "--all-projects" && a != "--all") then
        IO.eprintln s!"error: unknown shutdown option\n\n{cliHelp}"; return 1
      if allProjects then
        printJson <| okResponse (← shutdownAllDaemons)
      else
        let root ← findProjectRoot none
        if force then
          printJson <| okResponse (← forceShutdown root)
        else
          match ← getDaemon root false with
          | none => printJson <| okResponse (Json.mkObj [("status", "notRunning"), ("projectRoot", root.toString)])
          | some md =>
              let resp ← sendToDaemon md "shutdown" (Json.mkObj []) 5000
              removeFileIfExists (metaPath root)
              removeDirIfExists (lockPath root)
              printDaemonResponse resp
  | _ =>
      IO.eprintln cliHelp
      return 1

/-- True for top-level CLI commands handled by `AFTK.Server`. -/
def isCommand (cmd : String) : Bool :=
  cmd == "daemon" || cmd == "open" || cmd == "diagnostics" || cmd == "diag" ||
    cmd == "probe" || cmd == "goals" || cmd == "goal" || cmd == "restart" || cmd == "refresh" ||
    cmd == "close" || cmd == "gc" || cmd == "status" || cmd == "shutdown"

end Server
end AFTK
