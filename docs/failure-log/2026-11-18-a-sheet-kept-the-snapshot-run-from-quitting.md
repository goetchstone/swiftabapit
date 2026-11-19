# 2026-11-18 — A sheet kept the snapshot run from quitting, and PR #19 sat red for six days

- **Symptom:** PR #19 (`add-to-client`, head 6fc512b): CI's "Screenshots" step failed on 2026-11-12 at 18:21 UTC. Its two
  new runs, `add-mosyle-asks` and `clients-add-apple`, each wrote their picture, printed "snapshot: the app didn't quit
  within 10 s of its picture" and exited 1. The other 26 runs passed, and so did the package tests, the Release build and
  both `check_app.sh` gates. The session had ended about ten minutes earlier with CI still running. Nobody looked until the
  audit of 2026-11-18.
- **Cause:** these are the first runs to open a sheet (`ABAPIT_SHEET`). `Snapshots.snapshot` drew the sheet and then called
  `NSApp.terminate(nil)` with the sheet still attached, and the quit did not finish. SwiftGamGui met the same hang on
  2026-10-12 and 13 and leaves a sheet run with `exit(EXIT_SUCCESS)`, "even with the sheet ended first" (its
  `App/Spikes.swift` @ bfdb494, lines 141-151). This harness was adapted from lines 73-115 of that file: the line that
  draws an attached sheet came along, and the exit for a sheet run did not.
- **Why not caught:** no run opened a sheet before PR #19, so the sheet path had never run here. The app is never
  launched on the operator's screen, so CI was the first place the two runs ran, and the session ended before CI did.
- **Fix:** PR #19, `fix(snapshots): a run that drew a sheet exits once its picture and checks are done`. A run that asked
  for a sheet and has none attached now fails in words.
- **Prevention:** the two runs themselves: they fail at 6fc512b. The new "ABAPIT_SHEET asked for a sheet and none was
  attached" check keeps a sheet run from passing with a picture of the window. A sheet run no longer shows that the app
  can quit; the other 26 runs still do.
