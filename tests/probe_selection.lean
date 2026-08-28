import AFTK.Server

open Lean
open Lean.Lsp
open AFTK.Server

def assertTrue (label : String) (condition : Bool) : IO Unit :=
  unless condition do
    throw <| IO.userError s!"assertion failed: {label}"

def assertRange (label : String) (result : Except String Range)
    (startLine startCharacter endLine endCharacter : Nat) : IO Range := do
  let .ok range := result
    | throw <| IO.userError s!"assertion failed: {label}: range resolution returned an error"
  assertTrue label <|
    range.start.line == startLine && range.start.character == startCharacter &&
      range.end.line == endLine && range.end.character == endCharacter
  return range

def assertError (label needle : String) (result : Except String α) : IO Unit := do
  match result with
  | .ok _ => throw <| IO.userError s!"assertion failed: {label}: expected an error"
  | .error error => assertTrue label (containsSubstring error needle)

def assertSelection (label : String) (result : Except String ProbeSelection)
    (expected : ProbeSelection) : IO Unit := do
  match result with
  | .ok actual => assertTrue label (actual == expected)
  | .error _ => throw <| IO.userError s!"assertion failed: {label}: selection returned an error"

unsafe def main : IO Unit := do
  let ascii := "first\n\nlast".toFileMap
  let first ← assertRange "first line preserves its terminator"
    (resolveProbeSelection ascii (.line 1)) 0 0 0 5
  assertTrue "whole-line replacement leaves the terminator byte in place"
    ((Lean.Server.replaceLspRange ascii first "new").source == "new\n\nlast")
  let _ ← assertRange "empty line" (resolveProbeSelection ascii (.line 2)) 1 0 1 0
  let _ ← assertRange "final line without a terminator"
    (resolveProbeSelection ascii (.line 3)) 2 0 2 4

  let trailing := "first\n".toFileMap
  let _ ← assertRange "final empty line after a terminator"
    (resolveProbeSelection trailing (.line 2)) 1 0 1 0

  let block ← assertRange "inclusive multi-line range"
    (resolveProbeSelection ascii (.lines 1 2)) 0 0 1 0
  assertTrue "multi-line replacement includes internal separators and preserves the final one"
    ((Lean.Server.replaceLspRange ascii block "new").source == "new\nlast")

  let unicode := "-- symbols: 𝟙𝓝𝕜\n-- 𝟙 replace-me".toFileMap
  let _ ← assertRange "whole line uses UTF-16 columns for non-BMP characters"
    (resolveProbeSelection unicode (.line 1)) 0 0 0 18
  let _ ← assertRange "to-eol accepts a boundary after an astral character"
    (resolveProbeSelection unicode (.toEol 2 7)) 1 6 1 16

  let crlf := "first\r\nsecond\r\n" |>.crlfToLf.toFileMap
  let _ ← assertRange "CRLF-normalized logical line"
    (resolveProbeSelection crlf (.line 2)) 1 0 1 6

  assertError "line zero" "must be >= 1" (resolveProbeSelection ascii (.line 0))
  assertError "line past EOF" "past end of file" (resolveProbeSelection ascii (.line 4))
  assertError "reversed interval" "reversed" (resolveProbeSelection ascii (.lines 3 2))
  assertError "half of a UTF-16 surrogate pair" "UTF-16 boundary"
    (resolveProbeSelection unicode (.toEol 2 5))
  assertError "column past line content" "UTF-16 boundary"
    (resolveProbeSelection unicode (.toEol 2 99))

  let selections := #[
    ProbeSelection.range 1 2 3 4, .at 2 3, .line 4, .lines 4 7, .toEol 8 9]
  for selection in selections do
    assertSelection "probe selection JSON round trip"
      (probeSelectionFromJson selection.toJson) selection
  assertSelection "legacy concrete range protocol remains readable"
    (probeSelectionFromParams (Json.mkObj [
      ("startLine", 1), ("startColumn", 2), ("endLine", 3), ("endColumn", 4)]))
    (.range 1 2 3 4)

  IO.println "all probe selection tests passed"
