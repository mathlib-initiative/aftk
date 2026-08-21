module

public import Lean
public import AFTK.Server
public import AFTK.TechDebt

public section

namespace AFTK

open Lean

/-- Query direction for the dependency graph. -/
inductive QueryKind where
  /-- Declarations transitively used by the target declaration. -/
  | dependencies
  /-- Declarations that transitively use the target declaration. -/
  | dependents
  deriving Inhabited, BEq

namespace QueryKind

/-- Primary CLI command name for a query kind. -/
def command : QueryKind → String
  | .dependencies => "deps"
  | .dependents => "rdeps"

/-- One-line description for help text. -/
def description : QueryKind → String
  | .dependencies =>
      "Display declarations that are transitive dependencies of the target declaration."
  | .dependents =>
      "Display declarations that transitively depend on the target declaration."

/-- Alias list for help text. -/
def aliases : QueryKind → String
  | .dependencies => "dependencies, transitive-deps"
  | .dependents => "dependents, reverse-deps, transitive-rdeps"

end QueryKind

/-- Parse a subcommand name. -/
def parseQueryKind (cmd : String) : Option QueryKind :=
  match cmd with
  | "deps" | "dependencies" | "transitive-deps" => some .dependencies
  | "rdeps" | "dependents" | "reverse-deps" | "transitive-rdeps" => some .dependents
  | _ => none

/-- A module restriction pattern for output filtering. -/
inductive ModulePattern where
  /-- Match every module. -/
  | all
  /-- Match exactly one module. -/
  | exact (moduleName : Name)
  /-- Match a module prefix; `A.B.*` is represented as prefix `A.B`. -/
  | prefix (modulePrefix : Name)
  deriving Inhabited, BEq

namespace ModulePattern

/-- Parse a module pattern.

Accepted forms:
* `*` matches all modules.
* `A.B.C` matches exactly module `A.B.C`.
* `A.B.*` matches `A.B` and every module below it.
-/
def parse (raw : String) : Except String ModulePattern := do
  let s := raw.trimAscii.toString
  if s.isEmpty then
    throw "empty module pattern"
  else if s == "*" then
    return .all
  else if s.endsWith ".*" then
    let prefixString := (s.dropEnd 2).toString
    if prefixString.isEmpty then
      return .all
    else
      return .prefix prefixString.toName
  else if s.contains '*' then
    throw s!"invalid module pattern `{s}`; `*` is only supported as the whole pattern or as a final `.*`"
  else
    return .exact s.toName

/-- Test whether a module name is accepted by a pattern. -/
def accepts : ModulePattern → Name → Bool
  | .all, _ => true
  | .exact expected, moduleName => moduleName == expected
  | .prefix modulePrefix, moduleName => modulePrefix.isPrefixOf moduleName

end ModulePattern

/-- Output filter for module restrictions.  An empty pattern list means no restriction. -/
structure ModuleFilter where
  patterns : Array ModulePattern := #[]
  deriving Inhabited, BEq

namespace ModuleFilter

/-- Test whether a module is accepted by the filter. -/
def accepts (filter : ModuleFilter) (moduleName : Name) : Bool :=
  filter.patterns.isEmpty || filter.patterns.any (fun p => p.accepts moduleName)

end ModuleFilter

/-- Parsed options and positional arguments for a query command. -/
structure QueryConfig where
  moduleString : String
  declString : String
  filter : ModuleFilter := {}
  jsonl : Bool := false
  deriving Inhabited

/-- Convert an `Except String` into an `IO` action. -/
def exceptToIO : Except String α → IO α
  | .ok a => pure a
  | .error msg => throw <| IO.userError msg

/-- Parse a comma-separated list of module patterns. -/
def parsePatternList (raw : String) : Except String (Array ModulePattern) := do
  let mut patterns := #[]
  for part in raw.splitOn "," do
    patterns := patterns.push (← ModulePattern.parse part)
  return patterns

/-- Add comma-separated module patterns to an accumulated pattern array. -/
def addPatternList (patterns : Array ModulePattern) (raw : String) : Except String (Array ModulePattern) := do
  return patterns ++ (← parsePatternList raw)

/-- Options that take one following value. -/
def isModuleFilterOption (arg : String) : Bool :=
  arg == "--module" || arg == "-m" || arg == "--in" || arg == "--only-module" || arg == "--modules"

/-- Parse query subcommand arguments.  `none` means the user requested command help. -/
partial def parseQueryArgsAux
    (args : List String) (positionals : Array String) (patterns : Array ModulePattern) (jsonl : Bool) : Except String (Option QueryConfig) := do
  match args with
  | [] =>
      if positionals.size == 2 then
        return some {
          moduleString := positionals[0]!
          declString := positionals[1]!
          filter := { patterns := patterns }
          jsonl := jsonl
        }
      else if positionals.size < 2 then
        throw "missing arguments: expected <module> <declaration>"
      else
        throw "too many positional arguments: expected <module> <declaration>"
  | arg :: rest =>
      if arg == "--help" || arg == "-h" || (arg == "help" && positionals.isEmpty && rest.isEmpty) then
        return none
      else if arg == "--jsonl" then
        parseQueryArgsAux rest positionals patterns true
      else if isModuleFilterOption arg then
        match rest with
        | [] => throw s!"missing value after `{arg}`"
        | value :: rest =>
            let patterns ← addPatternList patterns value
            parseQueryArgsAux rest positionals patterns jsonl
      else if arg.startsWith "--module=" then
        let patterns ← addPatternList patterns ((arg.drop "--module=".length).toString)
        parseQueryArgsAux rest positionals patterns jsonl
      else if arg.startsWith "--modules=" then
        let patterns ← addPatternList patterns ((arg.drop "--modules=".length).toString)
        parseQueryArgsAux rest positionals patterns jsonl
      else if arg.startsWith "--in=" then
        let patterns ← addPatternList patterns ((arg.drop "--in=".length).toString)
        parseQueryArgsAux rest positionals patterns jsonl
      else if arg.startsWith "--only-module=" then
        let patterns ← addPatternList patterns ((arg.drop "--only-module=".length).toString)
        parseQueryArgsAux rest positionals patterns jsonl
      else if arg.startsWith "-m=" then
        let patterns ← addPatternList patterns ((arg.drop "-m=".length).toString)
        parseQueryArgsAux rest positionals patterns jsonl
      else if arg.startsWith "-" then
        throw s!"unknown option `{arg}`"
      else
        parseQueryArgsAux rest (positionals.push arg) patterns jsonl

/-- Parse query subcommand arguments.  `none` means the user requested command help. -/
def parseQueryArgs (args : List String) : Except String (Option QueryConfig) :=
  parseQueryArgsAux args #[] #[] false

/-- Top-level CLI help text. -/
def topLevelHelp : String :=
"AFTK: dependency analysis for Lean declarations.

Usage:
  lake exe aftk deps [options] <module> <declaration>
  lake exe aftk rdeps [options] <module> <declaration>
  lake exe aftk tech-debt [options] [module <module>|library <library>|package [<package>]]
  lake exe aftk diagnostics [options] <file>
  lake exe aftk probe [options] <module-or-file>
  lake exe aftk goals [options] <module> <line> <column>
  lake exe aftk open [options] <file>
  lake exe aftk restart <file>
  lake exe aftk close <file>
  lake exe aftk close --idle
  lake exe aftk close --all
  lake exe aftk gc [--aggressive]
  lake exe aftk status
  lake exe aftk shutdown [--force|--all-projects]
  lake exe aftk help <command>
  lake exe aftk --help

Commands:
  deps          Display declarations that are transitive dependencies of a declaration.
  rdeps         Display declarations that transitively depend on a declaration.
  tech-debt     Find technical debt in Lean modules, libraries, and packages.
  open          Warm up/open a Lean file worker in the project daemon.
  diagnostics   Elaborate a Lean file and print diagnostics as JSON.
  probe         Elaborate a temporary in-memory source replacement, then restore the file.
  goals        Return term/tactic goals at a 1-based module location.
  restart      Restart a file worker and reload imports/dependencies.
  close         Release file workers (`<file>`, `--idle`, or `--all`).
  gc            Run daemon resource cleanup now.
  status        Show daemon/resource status.
  shutdown      Stop project daemon(s) and workers.

Global options:
  -h, --help   Show help.  Each subcommand also accepts --help.

Dependency output:
  By default, deps/rdeps results are printed as tab-separated rows:
    <module>\t<declaration>
  deps/rdeps also support --jsonl for one JSON object per result.

Daemon output:
  diagnostics/probe/goals/open/close/gc/status/shutdown print one JSON response object.
  diagnostics/probe/goals support --transient/--close-after and --ttl-ms for resource management.

Notes:
  * Internal declarations are traversed but omitted from output.
  * Private declarations are included and printed with their user-facing names.
  * Module restrictions filter output only; traversal may still pass through other modules.
  * The diagnostics daemon is per Lake project root and stores metadata in .lake/aftk/.

Run `lake exe aftk <command> --help` for command-specific options and examples."

/-- Shared help for module output filters. -/
def moduleFilterHelp : String :=
"Options:
  -m, --module <pattern>        Restrict output to declarations from matching modules.
      --in <pattern>            Alias for --module.
      --only-module <pattern>   Alias for --module.
      --modules <patterns>      Comma-separated module patterns.  May be repeated.
      --jsonl                   Print each result as one JSON object per line.
  -h, --help                    Show this help.

Module patterns:
  *                  Match every module.
  A.B.C              Match exactly module A.B.C.
  A.B.*              Match A.B and every module whose prefix is A.B.

Multiple restrictions are ORed.  For example, `--modules 'Mathlib.Algebra.*,Mathlib.Order.*'`
keeps declarations from either module prefix.  Quote patterns containing `*` when using a shell.

For large imports such as Mathlib, module restrictions are strongly recommended for `rdeps`."

/-- Help text for a query subcommand. -/
def subcommandHelp (kind : QueryKind) : String :=
  s!"{kind.description}

Usage:
  lake exe aftk {kind.command} [options] <module> <declaration>

Aliases:
  {kind.aliases}

Arguments:
  <module>       Lean module to import before running the query, e.g. Mathlib.Data.Nat.Basic.
  <declaration>  Declaration to query, e.g. Nat.gcd.  Private declarations are resolved
                 using <module>'s private namespace.

{moduleFilterHelp}

Output:
  By default, tab-separated rows: <module>\\t<declaration>.
  With --jsonl, each row is a JSON object with `module` and `declaration` fields.

Examples:
  lake exe aftk {kind.command} Mathlib.Data.Nat.Basic Nat.gcd
  lake exe aftk {kind.command} Mathlib.Data.Nat.Basic Nat.gcd --module 'Mathlib.Algebra.*'
  lake exe aftk {kind.command} Mathlib.Data.Nat.Basic Nat.gcd --modules 'Mathlib.Algebra.*,Mathlib.Order.*'"

/-- The module associated with a declaration, if Lean recorded one. -/
def moduleOf? (env : Environment) (declName : Name) : Option Name := do
  let modIdx ← env.getModuleIdxFor? declName
  return env.header.modules[modIdx]!.module

/-- The module associated with a declaration, or `Name.anonymous` if none is recorded. -/
def moduleOfD (env : Environment) (declName : Name) : Name :=
  (moduleOf? env declName).getD Name.anonymous

/-- Test whether a declaration's module is accepted by an output filter. -/
def acceptedByFilter (env : Environment) (filter : ModuleFilter) (declName : Name) : Bool :=
  filter.accepts (moduleOfD env declName)

/--
Return true for declarations that should be shown to users.

We use `Lean.Meta.allowCompletion`, which rejects internal implementation details such as matcher
cores, no-confusion helpers, auxiliary recursors, blacklisted declarations, and names with internal
underscore components.  Importantly, it does *not* reject declarations merely because they are
private; private names are handled separately by Lean's module-private name encoding.
-/
def shouldDisplay (env : Environment) (declName : Name) : Bool :=
  Lean.Meta.allowCompletion env declName && !(privateToUserName declName).isInternalDetail

/-- Declarations directly referenced by `declName`'s type/value. -/
def directDependencies (env : Environment) (declName : Name) : Array Name := Id.run do
  let some info := env.find? declName | return #[]
  let mut deps := #[]
  for dep in info.getUsedConstantsAsSet do
    if (env.find? dep).isSome then
      deps := deps.push dep
  return deps

/-- Direct modules matching an output filter.  Empty filter means all imported modules. -/
def modulesMatchingFilter (env : Environment) (filter : ModuleFilter) : Array Name := Id.run do
  let mut modules := #[]
  for mod in env.header.modules do
    if filter.accepts mod.module then
      modules := modules.push mod.module
  return modules

/-- Transitive closure of module imports, including the roots. -/
partial def moduleImportClosure (env : Environment) (roots : Array Name) : NameHashSet :=
  let rec go (todo : List Name) (seen : NameHashSet) : NameHashSet :=
    match todo with
    | [] => seen
    | moduleName :: rest =>
      if seen.contains moduleName then
        go rest seen
      else
        let seen := seen.insert moduleName
        let imports :=
          match env.getModuleIdx? moduleName with
          | some idx => env.header.moduleData[idx]!.imports.map (·.module) |>.toList
          | none => []
        go (imports ++ rest) seen
  go roots.toList {}

/-- Direct reverse module-import map: `A ↦ #[B, ...]` when `B` directly imports `A`. -/
def reverseModuleImportMap (env : Environment) : Std.HashMap Name (Array Name) := Id.run do
  let mut reverse : Std.HashMap Name (Array Name) := {}
  for _h : idx in [0:env.header.modules.size] do
    let moduleName := env.header.modules[idx].module
    for imp in env.header.moduleData[idx]!.imports do
      let importers := match reverse.get? imp.module with
        | some importers => importers
        | none => #[]
      reverse := reverse.insert imp.module (importers.push moduleName)
  return reverse

/-- Transitive closure of modules that import the roots, directly or indirectly, including roots. -/
partial def moduleReverseImportClosure (env : Environment) (roots : Array Name) : NameHashSet :=
  let reverse := reverseModuleImportMap env
  let rec go (todo : List Name) (seen : NameHashSet) : NameHashSet :=
    match todo with
    | [] => seen
    | moduleName :: rest =>
      if seen.contains moduleName then
        go rest seen
      else
        let seen := seen.insert moduleName
        let importers :=
          match reverse.get? moduleName with
          | some importers => importers.toList
          | none => []
        go (importers ++ rest) seen
  go roots.toList {}

/--
Modules whose constants may lie on a reverse-dependency path to the requested output modules.

A declaration in output module `O` can only depend on a target in module `T` through modules that
are both imported by `O` and import `T`.  Intersecting these two module closures avoids scanning
large unrelated parts of Mathlib for filtered reverse queries.
-/
def relevantModulesForOutput (env : Environment) (target : Name) (filter : ModuleFilter) : Option NameHashSet := do
  let targetModule ← moduleOf? env target
  let importersOfTarget := moduleReverseImportClosure env #[targetModule]
  if filter.patterns.isEmpty then
    some importersOfTarget
  else
    let outputImportClosure := moduleImportClosure env (modulesMatchingFilter env filter)
    some <| NameHashSet.filter (fun moduleName => outputImportClosure.contains moduleName) importersOfTarget

/-- Reverse adjacency map for the direct dependency graph. -/
abbrev ReverseDependencyMap := Std.HashMap Name (Array Name)

/-- Test whether a module is in the optional set of modules to scan. -/
def shouldScanModuleForReverse (modules? : Option NameHashSet) (moduleName : Name) : Bool :=
  match modules? with
  | none => true
  | some modules => modules.contains moduleName

/-- Build a reverse adjacency map, optionally scanning only constants from selected modules. -/
def reverseDependencyMap (env : Environment) (modules? : Option NameHashSet) : ReverseDependencyMap := Id.run do
  let mut reverse : ReverseDependencyMap := {}
  for _h : idx in [0:env.header.modules.size] do
    let moduleName := env.header.modules[idx].module
    if shouldScanModuleForReverse modules? moduleName then
      for info in env.header.moduleData[idx]!.constants do
        let declName := info.name
        for dep in info.getUsedConstantsAsSet do
          if (env.find? dep).isSome then
            let parents := match reverse.get? dep with
              | some parents => parents
              | none => #[]
            reverse := reverse.insert dep (parents.push declName)
  return reverse

/-- Names directly depending on `declName`, according to a precomputed reverse map. -/
def directDependents (reverse : ReverseDependencyMap) (declName : Name) : Array Name :=
  match reverse.get? declName with
  | some parents => parents
  | none => #[]

/--
Transitive closure from the direct successors of `start`, including internal nodes for traversal.
The starting declaration is pre-marked as seen, so self-loops such as inductive declarations using
themselves do not reprocess the target or appear in the reachable array.
-/
partial def reachableFrom (start : Name) (successors : Name → Array Name) : Array Name :=
  let rec go (todo : List Name) (seen : NameHashSet) (out : Array Name) : Array Name :=
    match todo with
    | [] => out
    | declName :: rest =>
      if seen.contains declName then
        go rest seen out
      else
        let seen := seen.insert declName
        go ((successors declName).toList ++ rest) seen (out.push declName)
  go (successors start).toList (({} : NameHashSet).insert start) #[]

/-- Cached state for dependency extraction in filtered reverse dependency queries. -/
structure DependsState where
  directDeps : Std.HashMap Name (Array Name) := {}
  deriving Inhabited

/-- Direct dependencies with per-query caching, since extracting them from proof terms can be costly. -/
def directDependenciesCached (env : Environment) (declName : Name) : StateM DependsState (Array Name) := do
  match (← get).directDeps.get? declName with
  | some deps => return deps
  | none =>
      let deps := directDependencies env declName
      modify fun s => { s with directDeps := s.directDeps.insert declName deps }
      return deps

/-- Displayable declarations accepted by the output filter. -/
def outputCandidates (env : Environment) (target : Name) (filter : ModuleFilter) : Array Name := Id.run do
  let mut out := #[]
  for _h : idx in [0:env.header.modules.size] do
    let moduleName := env.header.modules[idx].module
    if filter.accepts moduleName then
      for info in env.header.moduleData[idx]!.constants do
        let declName := info.name
        if declName != target && shouldDisplay env declName then
          out := out.push declName
  return out


/-- Forward dependency closure from multiple roots, with cached direct dependencies. -/
partial def forwardClosureFrom (env : Environment) (roots : Array Name) : StateM DependsState (Array Name) := do
  let rec go (todo : List Name) (seen : NameHashSet) (out : Array Name) : StateM DependsState (Array Name) := do
    match todo with
    | [] => return out
    | declName :: rest =>
      if seen.contains declName then
        go rest seen out
      else
        let seen := seen.insert declName
        let deps ← directDependenciesCached env declName
        go (deps.toList ++ rest) seen (out.push declName)
  go roots.toList {} #[]

/-- Build a reverse dependency map by scanning only the given forward-closure nodes. -/
def reverseDependencyMapFromNodes (env : Environment) (nodes : Array Name) : StateM DependsState ReverseDependencyMap := do
  let mut reverse : ReverseDependencyMap := {}
  for declName in nodes do
    for dep in (← directDependenciesCached env declName) do
      let parents := match reverse.get? dep with
        | some parents => parents
        | none => #[]
      reverse := reverse.insert dep (parents.push declName)
  return reverse

/--
Reverse-reachable declarations for filtered output by first computing the dependency closure of the
output candidates.  This is often much faster for small module filters than scanning every
declaration in all imported modules between the target and the output modules.
-/
def dependentReachableViaOutputClosure (env : Environment) (target : Name) (filter : ModuleFilter) : Array Name := Id.run do
  let compute : StateM DependsState (Array Name) := do
    let roots := outputCandidates env target filter
    let closure ← forwardClosureFrom env roots
    let reverse ← reverseDependencyMapFromNodes env closure
    return reachableFrom target (directDependents reverse)
  compute.run' {}

/-- Count constants in modules accepted by a filter, without inspecting dependency expressions. -/
def constantCountForFilter (env : Environment) (filter : ModuleFilter) : Nat := Id.run do
  let mut count := 0
  for _h : idx in [0:env.header.modules.size] do
    if filter.accepts env.header.modules[idx].module then
      count := count + env.header.moduleData[idx]!.constants.size
  return count

/-- Count constants in an optional module set, without inspecting dependency expressions. -/
def constantCountInModules (env : Environment) (modules? : Option NameHashSet) : Nat := Id.run do
  let mut count := 0
  for _h : idx in [0:env.header.modules.size] do
    let moduleName := env.header.modules[idx].module
    if shouldScanModuleForReverse modules? moduleName then
      count := count + env.header.moduleData[idx]!.constants.size
  return count

/--
Choose the reverse-map strategy for filtered `rdeps` when the module-pruned scan is likely smaller
than the forward closure of all output candidates.  Constant counts are a better approximation than
module counts because Mathlib modules vary greatly in size.
-/
def useReverseScanForFilteredRdeps (outputConstCount relevantConstCount : Nat) : Bool :=
  relevantConstCount <= outputConstCount * 4

/--
Resolve a user-facing declaration name in the environment of `moduleName`.

Public names are global, so we accept any public declaration available after importing
`moduleName`.  For private declarations, Lean encodes the declaring module in the name, so we use
`moduleName` to construct the private candidate.
-/
def resolveDeclaration (env : Environment) (moduleName rawDeclName : Name) : Except String Name := do
  if (env.find? rawDeclName).isSome then
    return rawDeclName
  let declName := privateToUserName rawDeclName
  let privateCandidate := mkPrivateNameCore moduleName declName
  if (env.find? privateCandidate).isSome then
    return privateCandidate
  if (env.find? declName).isSome then
    return declName
  throw s!"declaration `{declName}` was not found in the environment of module `{moduleName}`"

/-- Sort names for stable output by associated module, then by user-facing declaration name. -/
def lessForOutput (env : Environment) (a b : Name) : Bool :=
  match Name.cmp (moduleOfD env a) (moduleOfD env b) with
  | .lt => true
  | .gt => false
  | .eq =>
    match Name.cmp (privateToUserName a) (privateToUserName b) with
    | .lt => true
    | _ => false

/-- Keep only user-facing declarations accepted by the output filter, excluding the original target. -/
def displayableReachable
    (env : Environment) (target : Name) (filter : ModuleFilter) (reachable : Array Name) : Array Name := Id.run do
  let mut out := #[]
  for declName in reachable do
    if declName != target && acceptedByFilter env filter declName && shouldDisplay env declName then
      out := out.push declName
  return out.qsort (lessForOutput env)

/-- Format a declaration with its associated module as TSV. -/
def formatDeclaration (env : Environment) (declName : Name) : String :=
  s!"{moduleOfD env declName}\t{privateToUserName declName}"

/-- Format a declaration with its associated module as one compact JSON object. -/
def formatDeclarationJsonLine (env : Environment) (declName : Name) : String :=
  Json.compress <| Json.mkObj [
    ("module", s!"{moduleOfD env declName}"),
    ("declaration", s!"{privateToUserName declName}")
  ]

/-- Load `moduleName`, including private module data, so private declarations can participate. -/
def loadModuleEnvironment (moduleName : Name) : IO Environment := do
  let imports : Array Import := #[{ module := moduleName }]
  importModules imports Options.empty 0 (leakEnv := true) (loadExts := true) (level := .private)

/-- Run a dependency query and print the result. -/
def runQuery (kind : QueryKind) (config : QueryConfig) : IO Unit := do
  let moduleName := config.moduleString.toName
  let rawDeclName := config.declString.toName
  let env ← loadModuleEnvironment moduleName
  let target ← exceptToIO <| resolveDeclaration env moduleName rawDeclName
  let out :=
    match kind with
    | .dependencies =>
        let reachable := reachableFrom target (directDependencies env)
        displayableReachable env target config.filter reachable
    | .dependents =>
        let reachable :=
          if config.filter.patterns.isEmpty then
            let reverse := reverseDependencyMap env (relevantModulesForOutput env target config.filter)
            reachableFrom target (directDependents reverse)
          else
            match relevantModulesForOutput env target config.filter with
            | some relevantModules =>
                let outputConstCount := constantCountForFilter env config.filter
                let relevantConstCount := constantCountInModules env (some relevantModules)
                if useReverseScanForFilteredRdeps outputConstCount relevantConstCount then
                  let reverse := reverseDependencyMap env (some relevantModules)
                  reachableFrom target (directDependents reverse)
                else
                  dependentReachableViaOutputClosure env target config.filter
            | none =>
                dependentReachableViaOutputClosure env target config.filter
        displayableReachable env target config.filter reachable
  for declName in out do
    if config.jsonl then
      IO.println (formatDeclarationJsonLine env declName)
    else
      IO.println (formatDeclaration env declName)

/-- Safe part of the CLI entry point. -/
def run (args : List String) : IO UInt32 := do
  match args with
  | [] =>
      IO.println topLevelHelp
      return (0 : UInt32)
  | ["--help"] | ["-h"] | ["help"] =>
      IO.println topLevelHelp
      return (0 : UInt32)
  | ["help", cmd] =>
      match parseQueryKind cmd with
      | some kind =>
          IO.println (subcommandHelp kind)
          return (0 : UInt32)
      | none =>
          if cmd == "tech-debt" || cmd == "techdebt" then
            IO.println TechDebt.cliHelp
            return (0 : UInt32)
          else if Server.isCommand cmd then
            IO.println Server.cliHelp
            return (0 : UInt32)
          else
            IO.eprintln s!"unknown command `{cmd}`\n\n{topLevelHelp}"
            return (1 : UInt32)
  | cmd :: rest =>
      if cmd == "tech-debt" || cmd == "techdebt" then
        match TechDebt.parseArgs rest with
        | .ok none =>
            IO.println TechDebt.cliHelp
            return (0 : UInt32)
        | .ok (some config) =>
            TechDebt.run config
            return (0 : UInt32)
        | .error msg =>
            IO.eprintln s!"error: {msg}\n\n{TechDebt.cliHelp}"
            return (1 : UInt32)
      else if Server.isCommand cmd then
        Server.runCli cmd rest
      else
      match parseQueryKind cmd with
      | some kind =>
          match parseQueryArgs rest with
          | .ok none =>
              IO.println (subcommandHelp kind)
              return (0 : UInt32)
          | .ok (some config) =>
              runQuery kind config
              return (0 : UInt32)
          | .error msg =>
              IO.eprintln s!"error: {msg}\n\n{subcommandHelp kind}"
              return (1 : UInt32)
      | none =>
          IO.eprintln s!"unknown command `{cmd}`\n\n{topLevelHelp}"
          return (1 : UInt32)

/-- CLI entry point. -/
unsafe def main (args : List String) : IO UInt32 := do
  try
    initSearchPath (← findSysroot)
    -- Required because `importModules (loadExts := true)` initializes imported extensions.
    Lean.enableInitializersExecution
    run args
  catch e =>
    IO.eprintln s!"error: {e}"
    return (1 : UInt32)

end AFTK
