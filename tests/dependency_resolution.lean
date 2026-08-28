import AFTK.Dependency

open Lean
open AFTK

private def assertTrue (label : String) (condition : Bool) : IO Unit :=
  unless condition do
    throw <| IO.userError s!"assertion failed: {label}"

private def parsedConfig (args : List String) : IO QueryConfig :=
  match parseQueryArgs args with
  | .ok (some config) => pure config
  | .ok none => throw <| IO.userError "unexpected help result"
  | .error error => throw <| IO.userError error

def main : IO Unit := do
  let config ← parsedConfig ["Root", "privateLemma", "--defined-in", "Defining.Submodule",
    "--resolve-suffix", "--jsonl"]
  assertTrue "legacy scope module parsed" (config.scope == .module `Root)
  assertTrue "legacy syntax retained" config.legacySyntax
  assertTrue "declaration parsed" (config.declString? == some "privateLemma")
  assertTrue "defining module parsed" (config.definedIn? == some "Defining.Submodule")
  assertTrue "suffix mode parsed" config.resolveSuffix
  assertTrue "JSONL parsed" config.jsonl

  assertTrue "whole Name component suffix matches"
    ("privateLemma".toName.isSuffixOf "Namespace.privateLemma".toName)
  assertTrue "multi-component Name suffix matches"
    ("Namespace.privateLemma".toName.isSuffixOf "Outer.Namespace.privateLemma".toName)
  assertTrue "arbitrary string suffix does not match"
    (!"Lemma".toName.isSuffixOf "Namespace.privateLemma".toName)

  let candidates := (Array.range 25).map fun index => {
    name := Name.mkNum `internal index
    definingModule := `Defining.Module
    declaration := Name.mkNum `candidate index
  }
  let failure := resolutionFailure "test" "test failure" candidates
  assertTrue "candidate errors are bounded" (failure.candidates.size == resolutionCandidateLimit)
  assertTrue "candidate total is retained" (failure.totalCandidates == 25)

  match parseQueryArgs ["Root", "decl", "--defined-in", "A", "--defined-in=B"] with
  | .error _ => pure ()
  | _ => throw <| IO.userError "duplicate --defined-in was accepted"

  let library ← parsedConfig ["library", "WorkspaceLib", "Target.name"]
  assertTrue "library scope parsed" (library.scope == .library `WorkspaceLib)
  assertTrue "scoped syntax distinguished" (!library.legacySyntax)
  assertTrue "library target parsed" (library.declString? == some "Target.name")

  let rootPackageBatch ← parsedConfig ["package", "--stdin", "--jsonl", "--allow-partial"]
  assertTrue "root package batch parsed" (rootPackageBatch.scope == .package none)
  assertTrue "batch stdin parsed" rootPackageBatch.stdin
  assertTrue "batch has no command-line declaration" rootPackageBatch.declString?.isNone
  assertTrue "partial success parsed" rootPackageBatch.allowPartial

  let namedPackage ← parsedConfig ["package", "workspace", "Target.name"]
  assertTrue "named package scope parsed" (namedPackage.scope == .package (some `workspace))

  match parseQueryArgs ["library", "WorkspaceLib", "--stdin"] with
  | .error _ => pure ()
  | _ => throw <| IO.userError "--stdin without --jsonl was accepted"

  match parseQueryArgs ["Root", "decl", "--allow-partial"] with
  | .error _ => pure ()
  | _ => throw <| IO.userError "--allow-partial outside a batch was accepted"
