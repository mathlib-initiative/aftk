import AFTK.Server

open AFTK.Server

def assertTrue (label : String) (condition : Bool) : IO Unit :=
  unless condition do
    throw <| IO.userError s!"assertion failed: {label}"

def process (pid uid start : Nat) (executable : String) (argv : List String) : ProcessInfo :=
  { pid, effectiveUid := uid, startTimeTicks := start, executable, argv }

def statLine (startTime : Nat) : String :=
  let fields := ["S"] ++ List.replicate 18 "1" ++ [toString startTime, "0", "0"]
  s!"123 (command name with ) characters) {String.intercalate " " fields}"

unsafe def main : IO Unit := do
  let special := [
    "/tmp/tool chain/bin/aftk", "daemon", "--project-root", "/tmp/My Project/$work",
    "--token", "quote:'\" glob:* tab:\t"]
  assertTrue "NUL-delimited argv preserves spaces and special characters"
    (parseNulDelimitedArgv (String.toUTF8 (String.intercalate "\x00" special ++ "\x00")) ==
      some special)
  assertTrue "NUL-delimited argv preserves an empty argument"
    (parseNulDelimitedArgv (String.toUTF8 "lean\x00\x00--worker\x00") ==
      some ["lean", "", "--worker"])
  assertTrue "effective UID parser selects the effective rather than real UID"
    (parseProcEffectiveUid? "Name:\ttest\nUid:\t1000\t2000\t3000\t4000\n" == some 2000)
  assertTrue "proc stat parser tolerates spaces and closing parentheses in comm"
    (parseProcStartTime? (statLine 424242) == some 424242)

  let worker := process 10 1000 1 "/tmp/tool chain/bin/lean"
    ["/tmp/tool chain/bin/lean", "--worker"]
  let otherUidWorker := { worker with pid := 11, effectiveUid := 2000 }
  let extraArgWorker := { worker with pid := 12, argv := ["lean", "--worker", "lookalike"] }
  let substringLookalike := process 13 1000 1 "/usr/bin/python3"
    ["python3", "-c", "lean --worker; aftk daemon --project-root"]
  let daemon := process 20 1000 7 "/tmp/aftk build/bin/aftk"
    ["/tmp/aftk build/bin/aftk", "daemon", "--project-root", "/tmp/My Project",
      "--token", "token with symbols $*'"]
  let otherUidDaemon := { daemon with pid := 21, effectiveUid := 2000 }
  let looseDaemon : ProcessInfo := { daemon with
    pid := 22
    argv := ["aftk", "daemon", "--project-root", "/tmp/My Project", "--token", "t", "extra"] }
  let snapshot := #[worker, otherUidWorker, extraArgWorker, substringLookalike,
    daemon, otherUidDaemon, looseDaemon]
  let noSignal : Nat → String → IO Unit := fun _ _ =>
    throw <| IO.userError "unexpected signal"
  let inventory : ProcessInventory := {
    currentUid := pure 1000
    list := pure snapshot
    lookup := fun pid => pure (snapshot.find? (·.pid == pid))
    signal := noSignal
  }
  assertTrue "worker discovery filters ownership, executable identity, and exact argv"
    ((← leanWorkerPidsUsing inventory) == #[10])
  let (workerCount, workerMemory) ← leanWorkersMemoryUsing inventory fun pid =>
    if pid == 10 then
      pure <| some { rssKb := 10, pssKb := 8, privateKb := 6, swapKb := 4 }
    else
      pure <| some { rssKb := 1000, pssKb := 1000, privateKb := 1000, swapKb := 1000 }
  assertTrue "global worker count excludes other effective UIDs" (workerCount == 1)
  assertTrue "global worker memory excludes other effective UIDs"
    (workerMemory.rssKb == 10 && workerMemory.pssKb == 8 &&
      workerMemory.privateKb == 6 && workerMemory.swapKb == 4)
  assertTrue "daemon discovery filters ownership, executable identity, and exact argv"
    ((← aftkDaemonProcessesUsing inventory).map (·.pid) == #[20])
  assertTrue "daemon root and token round-trip from exact argv"
    (aftkDaemonProcess? daemon == some ("/tmp/My Project", "token with symbols $*'"))

  let signals ← IO.mkRef (#[] : Array (Nat × String))
  let changed := { daemon with startTimeTicks := daemon.startTimeTicks + 1 }
  let staleInventory : ProcessInventory := {
    currentUid := pure 1000
    list := pure #[daemon]
    lookup := fun _ => pure (some changed)
    signal := fun pid sig => signals.modify (·.push (pid, sig))
  }
  assertTrue "PID reuse prevents signaling" (!(← signalIfUnchanged staleInventory daemon "TERM"))
  assertTrue "stale identity did not invoke signal" ((← signals.get).isEmpty)

  let wrongOwnerInventory : ProcessInventory := {
    currentUid := pure 1000
    list := pure #[otherUidDaemon]
    lookup := fun _ => pure (some otherUidDaemon)
    signal := fun pid sig => signals.modify (·.push (pid, sig))
  }
  assertTrue "different effective UID prevents signaling"
    (!(← signalIfUnchanged wrongOwnerInventory otherUidDaemon "TERM"))
  assertTrue "ownership mismatch did not invoke signal" ((← signals.get).isEmpty)

  let matchingInventory : ProcessInventory := {
    currentUid := pure 1000
    list := pure #[daemon]
    lookup := fun _ => pure (some daemon)
    signal := fun pid sig => signals.modify (·.push (pid, sig))
  }
  assertTrue "unchanged identity is signaled" (← signalIfUnchanged matchingInventory daemon "TERM")
  assertTrue "matching signal target" ((← signals.get) == #[(20, "TERM")])

  -- Exercise the production procfs reader against this test process.
  let selfPid := (← IO.Process.getPID).toNat
  let some self ← systemProcessInventory.lookup selfPid
    | throw <| IO.userError "production procfs inventory could not read the current process"
  assertTrue "production snapshot uses current effective UID"
    (self.effectiveUid == (← currentEffectiveUid))
  assertTrue "production snapshot has exact argv" (!self.argv.isEmpty)
  IO.println "all process inventory tests passed"
