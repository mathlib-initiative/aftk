module

public import Lean.Elab.Frontend
public import AFTK.Server
public import Lake.Build.Infos
public import Lake.Build.Job.Monad
public import Lake.Build.Library
public import Lake.Build.Run
public import Lake.Load.Workspace

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

/-- The configured scope of a technical-debt scan. -/
inductive Scope where
  /-- Scan one Lean module. -/
  | module (moduleName : Name)
  /-- Scan every module in one configured Lake library. -/
  | library (libraryName : Name)
  /-- Scan every Lean target in a Lake package; `none` selects the root package. -/
  | package (packageName? : Option Name)
  deriving Inhabited

/-- Parsed `tech-debt` command arguments. -/
structure Config where
  scope : Scope
  jsonl : Bool := false
  deriving Inhabited

/-- Help text for the `tech-debt` command. -/
def cliHelp : String :=
"Find technical debt in Lean modules, libraries, and packages using elaborator info trees.

Usage:
  lake exe aftk tech-debt [options]
  lake exe aftk tech-debt [options] module <module>
  lake exe aftk tech-debt [options] library <library>
  lake exe aftk tech-debt [options] package [<package>]
  lake exe aftk tech-debt [options] <module>

Scopes:
  (no scope)                Scan the root Lake package.
  module <module>           Scan one Lean module.
  library <library>         Scan modules enumerated by the Lake library's `modules` facet.
  package [<package>]       Scan all configured Lean libraries and executables in a package.
  <module>                  Compatibility shorthand for `module <module>`.

Options:
  --jsonl       Print one JSON object per finding instead of tab-separated rows.
  -h, --help    Show this help.

Detected technical debt:
  * Commands that set `maxHeartbeats`.
  * Invocations of Core Lean's `erw` tactic.

Output:
  By default: <file>:<line>:<column>\t<kind>\t<description>.
  Positions are 1-based."

/-- Interpret positional arguments as a scan scope. -/
def parseScope (positionals : Array String) : Except String Scope := do
  match positionals.toList with
  | [] => return .package none
  | ["package"] => return .package none
  | ["package", packageName] => return .package (some packageName.toName)
  | ["module", moduleName] => return .module moduleName.toName
  | ["library", libraryName] => return .library libraryName.toName
  | [moduleName] => return .module moduleName.toName
  | "module" :: _ => throw "module scope expects exactly <module>"
  | "library" :: _ => throw "library scope expects exactly <library>"
  | "package" :: _ => throw "package scope accepts at most one <package>"
  | _ => throw "expected module <module>, library <library>, or package [<package>]"

/-- Parse `tech-debt` command arguments. `none` means help was requested. -/
def parseArgs (args : List String) : Except String (Option Config) := do
  let rec go (args : List String) (jsonl : Bool) (positionals : Array String) : Except String (Option Config) := do
    match args with
    | [] => return some { scope := ← parseScope positionals, jsonl }
    | "--help" :: _ | "-h" :: _ => return none
    | "--jsonl" :: rest => go rest true positionals
    | arg :: rest =>
        if arg.startsWith "-" then
          throw s!"unknown option `{arg}`"
        else
          go rest jsonl (positionals.push arg)
  go args false #[]

/-- Load the Lake workspace rooted at the current project. -/
def loadProjectWorkspace : IO Lake.Workspace := do
  let root ← Server.findProjectRoot
  let (elan?, lean?, lake?) ← Lake.findInstall?
  let some lean := lean?
    | throw <| IO.userError "could not locate the Lean installation"
  let lake := lake?.getD (Lake.LakeInstall.ofLean lean)
  let lakeEnv ← EIO.toIO (.userError ·) <| Lake.Env.compute lake lean elan?
  let workspace? ← (Lake.loadWorkspace {
    lakeEnv
    wsDir := root
    updateToolchain := false
  }).toBaseIO { outLv := .warning }
  let some workspace := workspace?
    | throw <| IO.userError s!"failed to load Lake workspace at `{root}`"
  return workspace

/-- Fetch the modules belonging to configured Lake libraries through their `modules` facets. -/
def libraryModules (workspace : Lake.Workspace) (libraries : Array Lake.LeanLib) : IO (Array Name) :=
  workspace.runFetchM (cfg := { verbosity := .quiet }) do
    let mut moduleNames := #[]
    for library in libraries do
      let modules ← (← library.modules.fetch).await
      moduleNames := moduleNames ++ modules.map (·.name)
    return moduleNames

/-- Deduplicate and sort module names for deterministic package scans. -/
def normalizeModuleNames (moduleNames : Array Name) : Array Name := Id.run do
  let mut seen : NameHashSet := {}
  let mut result := #[]
  for moduleName in moduleNames do
    unless seen.contains moduleName do
      seen := seen.insert moduleName
      result := result.push moduleName
  return result.qsort fun a b => toString a < toString b

/-- Resolve a CLI scan scope to the modules configured in the current Lake workspace. -/
def modulesForScope (workspace : Lake.Workspace) (scope : Scope) : IO (Array Name) := do
  match scope with
  | .module moduleName =>
      return #[moduleName]
  | .library libraryName =>
      let some library := workspace.findLeanLib? libraryName
        | throw <| IO.userError s!"could not find Lean library `{libraryName}` in the Lake workspace"
      return normalizeModuleNames (← libraryModules workspace #[library])
  | .package packageName? =>
      let package ← match packageName? with
        | none => pure workspace.root
        | some packageName =>
            let some package := workspace.findPackageByName? packageName
              | throw <| IO.userError s!"could not find package `{packageName}` in the Lake workspace"
            pure package
      let libraryModuleNames ← libraryModules workspace package.leanLibs
      let executableModuleNames := package.leanExes.map (·.root.name)
      return normalizeModuleNames (libraryModuleNames ++ executableModuleNames)

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
  unsafe Lean.enableInitializersExecution
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
  a.moduleName == b.moduleName && a.kind == b.kind && a.start == b.start && a.stop == b.stop

/-- Remove duplicate nodes introduced by nested tactic/command info while preserving source order. -/
def deduplicate (findings : Array Finding) : Array Finding := Id.run do
  let mut out := #[]
  for finding in findings do
    unless out.any (·.sameOccurrence finding) do
      out := out.push finding
  return out

/-- Sort findings within a module by source position and then category. -/
def lessWithinModule (a b : Finding) : Bool :=
  if a.start.line != b.start.line then
    a.start.line < b.start.line
  else if a.start.column != b.start.column then
    a.start.column < b.start.column
  else
    a.kind.name < b.kind.name

/-- Find all recognized technical debt in one module. -/
def findModule (moduleName : Name) : IO (Array Finding) := do
  let path ← resolveModuleSource moduleName
  let (fileMap, trees) ← moduleInfoTrees moduleName path
  let mut findings := #[]
  for tree in trees do
    findings := collectTree moduleName path.toString fileMap tree findings
  return (deduplicate findings).qsort lessWithinModule

/-- Sort findings by module and source position for deterministic multi-module output. -/
def lessForOutput (a b : Finding) : Bool :=
  if a.moduleName != b.moduleName then
    toString a.moduleName < toString b.moduleName
  else
    lessWithinModule a b

/-- Find all recognized technical debt in a collection of modules. -/
def findModules (moduleNames : Array Name) : IO (Array Finding) := do
  addProjectLeanSearchPath
  let mut findings := #[]
  for moduleName in normalizeModuleNames moduleNames do
    findings := findings ++ (← findModule moduleName)
  return findings.qsort lessForOutput

/-- Find all recognized technical debt in a module. -/
def find (moduleName : Name) : IO (Array Finding) :=
  findModules #[moduleName]

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
  let workspace ← loadProjectWorkspace
  let moduleNames ← modulesForScope workspace config.scope
  let findings ← findModules moduleNames
  for finding in findings do
    if config.jsonl then
      IO.println (formatFindingJsonLine finding)
    else
      IO.println (formatFinding finding)

end AFTK.TechDebt
