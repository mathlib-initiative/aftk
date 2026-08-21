module

public import Lean.Elab.Frontend
public import AFTK.Server

public section

namespace AFTK.TechDebt

open Lean
open Lean.Elab

/-- A category of technical debt recognized by AFTK. -/
inductive Kind where
  /-- A command that overrides Lean's heartbeat limit. -/
  | maxHeartbeats
  /-- An invocation of Core Lean's `erw` tactic. -/
  | erw
  deriving Inhabited, BEq

namespace Kind

/-- Stable machine-readable name for a finding category. -/
def name : Kind → String
  | .maxHeartbeats => "maxHeartbeats"
  | .erw => "erw"

/-- Human-readable description of a finding category. -/
def description : Kind → String
  | .maxHeartbeats => "`set_option maxHeartbeats` override"
  | .erw => "Core Lean `erw` tactic invocation"

end Kind

/-- One technical-debt occurrence in a source module. Positions are 1-based. -/
structure Finding where
  moduleName : Name
  file : String
  kind : Kind
  start : Position
  stop : Position
  deriving Inhabited

/-- Parsed `tech-debt` command arguments. -/
structure Config where
  moduleString : String
  jsonl : Bool := false
  deriving Inhabited

/-- Help text for the `tech-debt` command. -/
def cliHelp : String :=
"Find technical debt in a Lean module using elaborator info trees.

Usage:
  lake exe aftk tech-debt [options] <module>

Arguments:
  <module>      Lean module to elaborate and inspect, e.g. Mathlib.Data.Nat.Basic.

Options:
  --jsonl       Print one JSON object per finding instead of tab-separated rows.
  -h, --help    Show this help.

Detected technical debt:
  * Commands that set `maxHeartbeats`.
  * Invocations of Core Lean's `erw` tactic.

Output:
  By default: <file>:<line>:<column>\t<kind>\t<description>.
  Positions are 1-based."

/-- Parse `tech-debt` command arguments. `none` means help was requested. -/
def parseArgs (args : List String) : Except String (Option Config) := do
  let rec go (args : List String) (jsonl : Bool) (module? : Option String) : Except String (Option Config) := do
    match args with
    | [] =>
        match module? with
        | some moduleString => return some { moduleString, jsonl }
        | none => throw "missing argument: expected <module>"
    | "--help" :: _ | "-h" :: _ => return none
    | "--jsonl" :: rest => go rest true module?
    | arg :: rest =>
        if arg.startsWith "-" then
          throw s!"unknown option `{arg}`"
        else if module?.isSome then
          throw s!"too many positional arguments: unexpected `{arg}`"
        else
          go rest jsonl (some arg)
  go args false none

/-- Resolve a module's Lean source file using the current Lake project's source search path. -/
def resolveModuleSource (moduleName : Name) : IO System.FilePath := do
  let root ← Server.findProjectRoot
  let searchPath ← Server.projectSrcSearchPath root
  match ← searchPath.findModuleWithExt "lean" moduleName with
  | some path => IO.FS.realPath path
  | none => throw <| IO.userError s!"could not find source for module `{moduleName}` in the project source search path"

/-- Add the current Lake project's compiled-module paths when AFTK is run directly. -/
def addProjectLeanSearchPath : IO Unit := do
  let root ← Server.findProjectRoot
  try
    let output ← IO.Process.output {
      cmd := "lake"
      args := #["env", "printenv", "LEAN_PATH"]
      cwd := some root
    }
    if output.exitCode == 0 then
      let raw := output.stdout.trimAscii.toString
      if !raw.isEmpty then
        let projectPath := System.SearchPath.parse raw
        let currentPath ← Lean.searchPathRef.get
        Lean.searchPathRef.set (projectPath ++ currentPath)
  catch _ =>
    pure ()

/-- Print elaboration errors and reject a module whose info trees are incomplete. -/
def ensureNoErrors (moduleName : Name) (messages : MessageLog) : IO Unit := do
  if messages.hasErrors then
    for message in messages.toList do
      if message.severity == .error then
        IO.eprintln (← message.toString)
    throw <| IO.userError s!"failed to elaborate module `{moduleName}`"

/-- Elaborate a source module and return its file map and completed info trees. -/
def moduleInfoTrees (moduleName : Name) (path : System.FilePath) : IO (FileMap × PersistentArray InfoTree) := do
  let input ← IO.FS.readFile path
  let inputCtx := Parser.mkInputContext input path.toString
  let (header, parserState, parseMessages) ← Parser.parseHeader inputCtx
  ensureNoErrors moduleName parseMessages
  let (env, headerMessages) ← Elab.processHeader header Options.empty parseMessages inputCtx
    (leakEnv := true) (mainModule := moduleName)
  ensureNoErrors moduleName headerMessages
  let commandState := Elab.Command.mkState env headerMessages Options.empty
  let state ← Elab.IO.processCommands inputCtx parserState commandState
  ensureNoErrors moduleName state.commandState.messages
  let infoState := state.commandState.infoState.substituteLazy.get
  return (inputCtx.fileMap, infoState.trees)

/-- Return the `set_option maxHeartbeats` syntax nested in a command, if present. -/
partial def maxHeartbeatsCommandSyntax? (stx : Syntax) : Option Syntax :=
  if stx.isOfKind ``Lean.Parser.Command.set_option then
    if stx.getNumArgs > 1 && stx[1].isIdent && stx[1].getId.eraseMacroScopes == `maxHeartbeats then
      some stx
    else
      none
  else if stx.isOfKind ``Lean.Parser.Command.in && stx.getNumArgs > 0 then
    maxHeartbeatsCommandSyntax? stx[0]
  else
    none

/-- True for the source syntax node generated by Core Lean's `erw` parser. -/
def isCoreErwSyntax (stx : Syntax) : Bool :=
  stx.isOfKind `Lean.Parser.Tactic.tacticErw___ &&
    match (stx.getArgs[0]? : Option Syntax) with
    | some (Syntax.atom _ "erw") => true
    | _ => false

/-- Build a finding from syntax that has a canonical source range. -/
def findingOfSyntax? (moduleName : Name) (file : String) (fileMap : FileMap)
    (kind : Kind) (stx : Syntax) : Option Finding := do
  let range ← stx.getRange? (canonicalOnly := true)
  let start := fileMap.toPosition range.start
  let stop := fileMap.toPosition range.stop
  return {
    moduleName
    file
    kind
    start := { start with column := start.column + 1 }
    stop := { stop with column := stop.column + 1 }
  }

/-- Collect findings from one info tree. -/
partial def collectTree (moduleName : Name) (file : String) (fileMap : FileMap)
    (tree : InfoTree) (findings : Array Finding) : Array Finding :=
  match tree with
  | .context _ tree => collectTree moduleName file fileMap tree findings
  | .hole _ => findings
  | .node info children =>
      let findings :=
        match info with
        | .ofCommandInfo commandInfo =>
            match maxHeartbeatsCommandSyntax? commandInfo.stx with
            | some stx =>
                match findingOfSyntax? moduleName file fileMap .maxHeartbeats stx with
                | some finding => findings.push finding
                | none => findings
            | none => findings
        | .ofTacticInfo tacticInfo =>
            if isCoreErwSyntax tacticInfo.stx then
                match findingOfSyntax? moduleName file fileMap .erw tacticInfo.stx with
                | some finding => findings.push finding
                | none => findings
            else
              findings
        | _ => findings
      children.foldl (fun findings child => collectTree moduleName file fileMap child findings) findings

/-- True when two findings describe the same source occurrence. -/
def Finding.sameOccurrence (a b : Finding) : Bool :=
  a.kind == b.kind && a.start == b.start && a.stop == b.stop

/-- Remove duplicate nodes introduced by nested tactic/command info while preserving source order. -/
def deduplicate (findings : Array Finding) : Array Finding := Id.run do
  let mut out := #[]
  for finding in findings do
    unless out.any (·.sameOccurrence finding) do
      out := out.push finding
  return out

/-- Sort findings by source position and then category for stable output. -/
def lessForOutput (a b : Finding) : Bool :=
  if a.start.line != b.start.line then
    a.start.line < b.start.line
  else if a.start.column != b.start.column then
    a.start.column < b.start.column
  else
    a.kind.name < b.kind.name

/-- Find all recognized technical debt in a module. -/
def find (moduleName : Name) : IO (Array Finding) := do
  addProjectLeanSearchPath
  let path ← resolveModuleSource moduleName
  let (fileMap, trees) ← moduleInfoTrees moduleName path
  let mut findings := #[]
  for tree in trees do
    findings := collectTree moduleName path.toString fileMap tree findings
  return (deduplicate findings).qsort lessForOutput

/-- Render a finding as a tab-separated row. -/
def formatFinding (finding : Finding) : String :=
  s!"{finding.file}:{finding.start.line}:{finding.start.column}\t{finding.kind.name}\t{finding.kind.description}"

/-- Render a finding as a compact JSON object. -/
def formatFindingJsonLine (finding : Finding) : String :=
  Json.compress <| Json.mkObj [
    ("module", toString finding.moduleName),
    ("file", finding.file),
    ("kind", finding.kind.name),
    ("description", finding.kind.description),
    ("range", Json.mkObj [
      ("start", Json.mkObj [("line", finding.start.line), ("column", finding.start.column)]),
      ("end", Json.mkObj [("line", finding.stop.line), ("column", finding.stop.column)])])]

/-- Run the `tech-debt` command. -/
def run (config : Config) : IO Unit := do
  let findings ← find config.moduleString.toName
  for finding in findings do
    if config.jsonl then
      IO.println (formatFindingJsonLine finding)
    else
      IO.println (formatFinding finding)

end AFTK.TechDebt
