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
  assertTrue "scope module parsed" (config.moduleString == "Root")
  assertTrue "declaration parsed" (config.declString == "privateLemma")
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
