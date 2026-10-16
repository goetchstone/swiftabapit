# 2026-10-16 — The gate looked for what it could not see

- **Symptom:** Phase 1b's adversarial review (867d7a6) got past three checks.
  - `URLSession.shared.upload(…)` added to AppleBusiness and to a screen left `RouteTests` green.
  - An `ABAPIT_DEMO` read outside `#if DEBUG` (mutant A), and `ABAPIT_SCREEN`/`ABAPIT_SELECT` reads (mutant B),
    passed `scripts/check_app.sh`.
  - The strict stub linked into a stripped Release build (mutant E3) passed the gate too, and so did
    `import TestSupport // demo` outside `#if DEBUG`.
  - Fixing them showed the gate's `nm | grep -q` check had never run. It named `MemoryStore`, which every
    Release build carries (101 symbols), and printed `ok` each time. It passed the stub linked into an
    unstripped build (mutant E) the same way.
- **Cause:** each check looked for a form the code doesn't take.
  - `Regex("\\bURLSession\\b")` uses Unicode word boundaries, and `.` doesn't break a word there.
  - Swift keeps a string literal of 15 bytes or fewer inside the instructions, so `strings` never shows a
    switch name. The regex also left out SCREEN, SELECT and WINDOW.
  - An archive strips the symbol table that `nm` reads.
  - The import check compared whole lines.
  - Under `pipefail`, `grep -q` exits at its first match. `nm` (over 1 MB of output) then dies of SIGPIPE, and
    `if` reads the failed pipeline as "no match". The script's own comment warned about this pipe, and its
    last two checks used it anyway.
- **Why not caught:** nothing tested the checks with the inputs they must refuse. The scanner had no
  self-test of the spellings it must find. The gate was never shown failing on a binary that should fail, so
  a check that couldn't fail looked the same as one that passed. This is the stub failure-log entry's
  shape again ("the stub could not fail"): a check that can't fail can't hold.
- **Fix:** the gates fix of the Phase 1b review (`fix(1b-gates)`).
  - `SourceScan` reads Swift as the lexer does: comments, raw and multi-line strings, interpolations and regex
    literals. Code and strings count; comments don't. Needles match inside names and across whitespace.
    Only the whole `URLSessionTransport` is excused, in the package only.
  - `ScannerTests` holds every needle list to its spellings. `DebugOnlyTests` holds every `ABAPIT_` in debug
    code, and every use of `MemoryStore`.
  - `PackageGraphTests` reads `TestSupport` as code inside `#if DEBUG` regions. `RouteTests` adds
    `AuthRequest.init`, `SecKeychain` and run-time lookups.
  - `check_app.sh` refuses any environment or argument read (the selectors, `getenv` and kin, `CommandLine`).
    It refuses TestSupport's class names and paths. It checks a stripped copy and then the binary, with every
    output captured before it is searched. CI also gates an archive-style stripped build.
- **Prevention:** the mutants are now tests or recorded gate runs, all killed: the reviewer's A, B, E3 and
  both H3 mutants, the comment-import, a `getenv` read, a `CommandLine` read, and 16 mutants of the scanner
  itself. `docs/domains/gates.md` lists the traps. RULE-FEEDBACK: a check needs a test that it fails.
