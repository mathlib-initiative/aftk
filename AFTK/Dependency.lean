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
  /-- Module that defined the target, independent of the module imported as the query scope. -/
  definedIn? : Option String := none
  /-- Resolve the declaration argument as a component-wise suffix instead of an exact name. -/
  resolveSuffix : Bool := false
  filter : ModuleFilter := {}
  jsonl : Bool := false
  deriving Inhabited

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
    (args : List String) (positionals : Array String) (patterns : Array ModulePattern)
    (definedIn? : Option String) (resolveSuffix jsonl : Bool) : Except String (Option QueryConfig) := do
  match args with
  | [] =>
      if positionals.size == 2 then
        return some {
          moduleString := positionals[0]!
          declString := positionals[1]!
          definedIn? := definedIn?
          resolveSuffix := resolveSuffix
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
        parseQueryArgsAux rest positionals patterns definedIn? resolveSuffix true
      else if arg == "--resolve-suffix" then
        parseQueryArgsAux rest positionals patterns definedIn? true jsonl
      else if arg == "--defined-in" then
        match rest with
        | [] => throw "missing value after `--defined-in`"
        | value :: rest =>
            if definedIn?.isSome then
              throw "`--defined-in` may only be specified once"
            else if value.trimAscii.isEmpty then
              throw "empty module name after `--defined-in`"
            else
              parseQueryArgsAux rest positionals patterns (some value) resolveSuffix jsonl
      else if arg.startsWith "--defined-in=" then
        if definedIn?.isSome then
          throw "`--defined-in` may only be specified once"
        else
          let value := (arg.drop "--defined-in=".length).toString
          if value.trimAscii.isEmpty then
            throw "empty module name after `--defined-in=`"
          else
            parseQueryArgsAux rest positionals patterns (some value) resolveSuffix jsonl
      else if isModuleFilterOption arg then
        match rest with
        | [] => throw s!"missing value after `{arg}`"
        | value :: rest =>
            let patterns ← addPatternList patterns value
            parseQueryArgsAux rest positionals patterns definedIn? resolveSuffix jsonl
      else if arg.startsWith "--module=" then
        let patterns ← addPatternList patterns ((arg.drop "--module=".length).toString)
        parseQueryArgsAux rest positionals patterns definedIn? resolveSuffix jsonl
      else if arg.startsWith "--modules=" then
        let patterns ← addPatternList patterns ((arg.drop "--modules=".length).toString)
        parseQueryArgsAux rest positionals patterns definedIn? resolveSuffix jsonl
      else if arg.startsWith "--in=" then
        let patterns ← addPatternList patterns ((arg.drop "--in=".length).toString)
        parseQueryArgsAux rest positionals patterns definedIn? resolveSuffix jsonl
      else if arg.startsWith "--only-module=" then
        let patterns ← addPatternList patterns ((arg.drop "--only-module=".length).toString)
        parseQueryArgsAux rest positionals patterns definedIn? resolveSuffix jsonl
      else if arg.startsWith "-m=" then
        let patterns ← addPatternList patterns ((arg.drop "-m=".length).toString)
        parseQueryArgsAux rest positionals patterns definedIn? resolveSuffix jsonl
      else if arg.startsWith "-" then
        throw s!"unknown option `{arg}`"
      else
        parseQueryArgsAux rest (positionals.push arg) patterns definedIn? resolveSuffix jsonl

/-- Parse query subcommand arguments.  `none` means the user requested command help. -/
def parseQueryArgs (args : List String) : Except String (Option QueryConfig) :=
  parseQueryArgsAux args #[] #[] none false false

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
  <declaration>  Declaration to query, e.g. Nat.gcd.

{moduleFilterHelp}

Target resolution:
      --defined-in <module>  Require the target to have been defined in this module.  This is
                             separate from the imported <module> query scope and makes private
                             declaration targets round-trippable.
      --resolve-suffix       Match <declaration> as a whole-name-component suffix.  A unique
                             match is accepted; ambiguity is reported with sorted candidates.

An exact lookup that fails also reports up to 20 suffix candidates without selecting one.

Output:
  By default, tab-separated rows: <module>\\t<declaration>.
  With --jsonl, rows additionally expose `definingModule` and the resolved query `target`.
  Lookup failures under --jsonl are structured error records with bounded `candidates`.

Examples:
  lake exe aftk {kind.command} Mathlib.Data.Nat.Basic Nat.gcd
  lake exe aftk {kind.command} Root Namespace.privateLemma --defined-in Defining.Submodule
  lake exe aftk {kind.command} Root privateLemma --resolve-suffix
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

/-- A declaration's internal identity plus its stable, user-facing target components. -/
structure ResolvedDeclaration where
  name : Name
  definingModule : Name
  declaration : Name
  deriving Inhabited, BEq

/-- A bounded resolution failure suitable for both human-readable and JSON output. -/
structure ResolutionFailure where
  code : String
  message : String
  candidates : Array ResolvedDeclaration := #[]
  totalCandidates : Nat := candidates.size

/-- Maximum number of declaration candidates included in one error. -/
def resolutionCandidateLimit : Nat := 20

/-- Recover the user-facing target components for an environment name. -/
def resolvedDeclaration (env : Environment) (declName : Name) : ResolvedDeclaration :=
  {
    name := declName
    definingModule := moduleOfD env declName
    declaration := privateToUserName declName
  }

/-- All imported declarations, retaining internal names solely for graph traversal. -/
def declarationIndex (env : Environment) : Array ResolvedDeclaration := Id.run do
  let mut declarations := #[]
  for _h : idx in [0:env.header.modules.size] do
    let definingModule := env.header.modules[idx].module
    for info in env.header.moduleData[idx]!.constants do
      declarations := declarations.push {
        name := info.name
        definingModule := definingModule
        declaration := privateToUserName info.name
      }
  return declarations

/-- Sort targets by defining module, user-facing name, then internal identity for determinism. -/
def lessResolvedDeclaration (a b : ResolvedDeclaration) : Bool :=
  match Name.cmp a.definingModule b.definingModule with
  | .lt => true
  | .gt => false
  | .eq =>
    match Name.cmp a.declaration b.declaration with
    | .lt => true
    | .gt => false
    | .eq => Name.cmp a.name b.name == .lt

/-- Sort and cap candidates while recording the total number of matches. -/
def resolutionFailure (code message : String) (candidates : Array ResolvedDeclaration) : ResolutionFailure :=
  let sorted := candidates.qsort lessResolvedDeclaration
  {
    code := code
    message := message
    candidates := sorted.take resolutionCandidateLimit
    totalCandidates := sorted.size
  }

/-- Declarations that are safe to suggest and whose user-facing name has the requested suffix. -/
def suffixCandidates
    (env : Environment) (index : Array ResolvedDeclaration) (suffix : Name)
    (definedIn? : Option Name := none) : Array ResolvedDeclaration :=
  index.filter fun candidate =>
    suffix.isSuffixOf candidate.declaration &&
      shouldDisplay env candidate.name &&
      definedIn?.all (· == candidate.definingModule)

/-- Exact user-facing matches, including private declarations with distinct internal names. -/
def exactUserCandidates
    (index : Array ResolvedDeclaration) (declName : Name)
    (definedIn? : Option Name := none) : Array ResolvedDeclaration :=
  index.filter fun candidate =>
    candidate.declaration == declName && definedIn?.all (· == candidate.definingModule)

/-- Construct an ambiguity error without ever selecting one candidate silently. -/
def ambiguousResolution
    (declName : Name) (mode : String) (found : Array ResolvedDeclaration) : ResolutionFailure :=
  resolutionFailure "ambiguousDeclaration"
    s!"{mode} lookup for `{declName}` matched {found.size} declarations" found

/--
Resolve a declaration target inside an already-loaded query scope.

Unqualified exact lookup retains the historical public-name and scope-module-private behavior.
`definedIn?` identifies a declaration's actual defining module without changing the imported scope.
Suffix resolution is explicit and compares `Name` components rather than rendered substrings.
-/
def resolveDeclaration
    (env : Environment) (scopeModule rawDeclName : Name) (definedIn? : Option Name := none)
    (resolveSuffix : Bool := false) : Except ResolutionFailure ResolvedDeclaration := do
  let declName := privateToUserName rawDeclName
  if resolveSuffix then
    let index := declarationIndex env
    let found := suffixCandidates env index declName definedIn?
    if _h : found.size == 1 then
      return found[0]!
    else if found.size > 1 then
      throw <| ambiguousResolution declName "suffix" found
    else
      let globalMatches := suffixCandidates env index declName
      match definedIn? with
      | some definingModule =>
          if globalMatches.isEmpty then
            throw <| resolutionFailure "declarationNotFound"
              s!"no declaration with suffix `{declName}` was found in the environment of module `{scopeModule}`" #[]
          else
            throw <| resolutionFailure "wrongDefiningModule"
              s!"no declaration with suffix `{declName}` is defined in module `{definingModule}`" globalMatches
      | none =>
          throw <| resolutionFailure "declarationNotFound"
            s!"no declaration with suffix `{declName}` was found in the environment of module `{scopeModule}`" #[]
  else if let some definingModule := definedIn? then
    let index := declarationIndex env
    let found := exactUserCandidates index declName (some definingModule)
    if _h : found.size == 1 then
      return found[0]!
    else if found.size > 1 then
      throw <| ambiguousResolution declName "exact module-qualified" found
    else
      let exactElsewhere := exactUserCandidates index declName
      if !exactElsewhere.isEmpty then
        throw <| resolutionFailure "wrongDefiningModule"
          s!"declaration `{declName}` is not defined in module `{definingModule}`" exactElsewhere
      else
        let suggestions := suffixCandidates env index declName
        throw <| resolutionFailure "declarationNotFound"
          s!"declaration `{declName}` was not found in module `{definingModule}` within the environment of module `{scopeModule}`"
          suggestions
  else
    -- Keep the legacy preference order: global exact name, query-module private name, then the
    -- user-facing name recovered from a supplied internal private encoding.
    if (env.find? rawDeclName).isSome then
      return resolvedDeclaration env rawDeclName
    let privateCandidate := mkPrivateNameCore scopeModule declName
    if (env.find? privateCandidate).isSome then
      return resolvedDeclaration env privateCandidate
    if (env.find? declName).isSome then
      return resolvedDeclaration env declName
    let suggestions := suffixCandidates env (declarationIndex env) declName
    throw <| resolutionFailure "declarationNotFound"
      s!"declaration `{declName}` was not found in the environment of module `{scopeModule}`" suggestions

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

/-- Machine-readable defining-module-qualified declaration target. -/
def resolvedDeclarationJson (target : ResolvedDeclaration) : Json :=
  Json.mkObj [
    ("definingModule", s!"{target.definingModule}"),
    ("declaration", s!"{target.declaration}")
  ]

/-- Format a declaration with its associated module as one compact JSON object. -/
def formatDeclarationJsonLine
    (env : Environment) (scopeModule : Name) (target : ResolvedDeclaration)
    (declName : Name) : String :=
  let definingModule := moduleOfD env declName
  Json.compress <| Json.mkObj [
    ("module", s!"{definingModule}"),
    ("definingModule", s!"{definingModule}"),
    ("declaration", s!"{privateToUserName declName}"),
    ("scopeModule", s!"{scopeModule}"),
    ("target", resolvedDeclarationJson target)
  ]

/-- Render one candidate as an unambiguous defining-module-qualified identity. -/
def formatResolutionCandidate (candidate : ResolvedDeclaration) : String :=
  s!"{candidate.definingModule}::{candidate.declaration}"

/-- Human-readable lookup failure with deterministic, bounded suggestions. -/
def formatResolutionFailure (failure : ResolutionFailure) : String :=
  if failure.candidates.isEmpty then
    s!"error: {failure.message}"
  else
    let candidateLines := failure.candidates.toList.map fun candidate =>
      s!"  {formatResolutionCandidate candidate}"
    let omitted := failure.totalCandidates - failure.candidates.size
    let omittedLine := if omitted == 0 then [] else [s!"  ... and {omitted} more"]
    s!"error: {failure.message}\nCandidates (<defining-module>::<declaration>):\n{String.intercalate "\n" (candidateLines ++ omittedLine)}"

/-- Structured JSONL lookup error for agent callers. -/
def formatResolutionFailureJsonLine (config : QueryConfig) (failure : ResolutionFailure) : String :=
  let definedInJson := match config.definedIn? with
    | some moduleName => Json.str moduleName
    | none => Json.null
  Json.compress <| Json.mkObj [
    ("type", "error"),
    ("scopeModule", config.moduleString),
    ("requestedTarget", Json.mkObj [
      ("declaration", config.declString),
      ("definedIn", definedInJson),
      ("resolution", if config.resolveSuffix then "suffix" else "exact")
    ]),
    ("error", Json.mkObj [
      ("code", failure.code),
      ("message", failure.message)
    ]),
    ("candidateCount", toJson failure.totalCandidates),
    ("truncated", toJson (decide (failure.totalCandidates > failure.candidates.size))),
    ("candidates", Json.arr <| failure.candidates.map resolvedDeclarationJson)
  ]

/-- Load `moduleName`, including private module data, so private declarations can participate. -/
def loadModuleEnvironment (moduleName : Name) : IO Environment := do
  let imports : Array Import := #[{ module := moduleName }]
  importModules imports Options.empty 0 (leakEnv := true) (loadExts := true) (level := .private)

/-- Run a dependency query and print the result. -/
def runQuery (kind : QueryKind) (config : QueryConfig) : IO UInt32 := do
  let moduleName := config.moduleString.toName
  let rawDeclName := config.declString.toName
  let definedIn? := config.definedIn?.map String.toName
  let env ← loadModuleEnvironment moduleName
  let target ← match resolveDeclaration env moduleName rawDeclName definedIn? config.resolveSuffix with
    | .ok target => pure target
    | .error failure =>
        if config.jsonl then
          IO.println (formatResolutionFailureJsonLine config failure)
        else
          IO.eprintln (formatResolutionFailure failure)
        return (1 : UInt32)
  let out :=
    match kind with
    | .dependencies =>
        let reachable := reachableFrom target.name (directDependencies env)
        displayableReachable env target.name config.filter reachable
    | .dependents =>
        let reachable :=
          if config.filter.patterns.isEmpty then
            let reverse := reverseDependencyMap env (relevantModulesForOutput env target.name config.filter)
            reachableFrom target.name (directDependents reverse)
          else
            match relevantModulesForOutput env target.name config.filter with
            | some relevantModules =>
                let outputConstCount := constantCountForFilter env config.filter
                let relevantConstCount := constantCountInModules env (some relevantModules)
                if useReverseScanForFilteredRdeps outputConstCount relevantConstCount then
                  let reverse := reverseDependencyMap env (some relevantModules)
                  reachableFrom target.name (directDependents reverse)
                else
                  dependentReachableViaOutputClosure env target.name config.filter
            | none =>
                dependentReachableViaOutputClosure env target.name config.filter
        displayableReachable env target.name config.filter reachable
  for declName in out do
    if config.jsonl then
      IO.println (formatDeclarationJsonLine env moduleName target declName)
    else
      IO.println (formatDeclaration env declName)
  return (0 : UInt32)

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
