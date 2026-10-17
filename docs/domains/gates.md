# Domain: the gates (source scans and the Release gate)

**One line:** the checks that hold the invariants the compiler can't: source scans over the app and the
package (`SourceScanTests`), and `scripts/check_app.sh` over the built Release app (plan §3.9).

**Owns invariant(s):** the structural halves of #1–#4 (one door per route, reads by type, the Keychain only in
the Vault, no listener) and plan §3.9's "no debug code in Release". Each invariant's own runbook names its
home; this one says how the homes themselves work and fail.

**Enforcement home:** `ScannerTests` (the scanner finds every spelling each needle list must find, and its
lexer reads literals as Swift does), `TreeTests` (the scans read the whole tree), `DebugOnlyTests`,
`GateScriptTests` (no pipe into `grep -q`), and the mutants recorded in each gate change's PR.

## Files
- `Packages/AbapitKit/Sources/TestSupport/Fixtures.swift` — `SourceScan`: `code(_:strings:)` (the lexer),
  `mentions`/`files(in:matching:except:)` (needles), `outsideDebug` (`#if DEBUG` regions), `unreadable` (what
  the lexer can't follow), `imports(of:)`.
- `Packages/AbapitKit/Tests/SourceScanTests/` — `RouteTests` (the needle lists and where each may appear),
  `PackageGraphTests` (edges, imports, `TestSupport` only in debug code), `DebugOnlyTests` (every `ABAPIT_`
  switch, every environment, argument or defaults read, and Vault's `MemoryStore` in debug code), `TreeTests`
  (every file lexes, and only Swift is compiled), `GateScriptTests` (the scripts' pipes), `ScannerTests` (the
  scanner's own tests).
- `scripts/check_app.sh` — the Release gate; CI runs it on the Release build and again after an incremental
  `DEPLOYMENT_POSTPROCESSING=YES` build (an archive's strip), which costs seconds.
- `scripts/check_graph.py`, `scripts/check_text.py` — the manifest SwiftPM evaluates; invisible characters.

## How it works
- **What a scan reads.** `SourceScan.code` blanks every comment (nested too) and, unless asked to keep them,
  string literals' contents, scalar for scalar with line breaks kept. It follows raw strings, multi-line
  strings, escapes, interpolations (code again), `#/…/#` regex literals and raw identifiers (`` `a // b` ``).
  A line ends at LF or CR, as it does for swiftc.
- **What it can't read, it refuses.** A bare `/…/` regex literal is the one construct the lexer doesn't follow,
  so `TreeTests` refuses any `/` in code that isn't division with a space on each side (`a / b`). Write a regex
  as `#/…/#`. App/ may hold Swift and the inert files a catalog needs; any other file there (an `.m`, a `.c`)
  is refused, since Xcode compiles whatever is put in the synchronized folder.
- **What counts.** Code and string literals count; comments never do. A string is how a run-time lookup
  names a class (`NSClassFromString("NSURLSession")`), and `nothingLooksCodeUpByName` refuses the lookups.
- **How a needle matches.** Anywhere, inside a longer name too (`URLSession` finds `NSURLSession` and
  `URLSessionConfiguration`), and across whitespace. Only a whole `except` name is excused
  (`URLSessionTransport`, in the package only).
- **Debug-only code.** `outsideDebug` reads `#if`/`#elseif`/`#else`/`#endif` from the code alone and counts
  only the true branch of a condition that is exactly `DEBUG`, at any depth. Release code names no `ABAPIT_`
  switch, and no `ProcessInfo`, `CommandLine`, `getenv`, `UserDefaults`, `AppStorage` or `CFPreferences`.
- **Where the transport may be.** Only `AppleClient` builds `URLSessionTransport`, and only `HTTPClient` calls a
  transport's `send` (it takes any `URLRequest`, past the host allowlist and the Executor).
- **The Release gate's code checks** run on a stripped copy (`strip -D`, as an archive does) and then on the
  binary as built. Both must be clean. A hit only the second pass finds is in the symbol table alone: the gate
  says so, because an archive would ship that code unseen. It refuses the reads by their selectors and imports:
  `environment`, `arguments`, `standardUserDefaults`, `valueForKey:`, `getenv` and kin, `CommandLine`, the
  `NSUserDefaults` class, `AppStorage`, `CFPreferences`. It refuses TestSupport's names and Vault's
  `MemoryStore` in `strings -a` and in `nm`.

## Invariants & failure history
- failure-log 2026-10-16, "the gate checked names, not values" (Phase 0): exact entitlements, one Mach-O,
  the tokenizing import scan.
- failure-log 2026-10-16, "the gate looked for what it could not see" (Phase 1b review H3, M1 and LOW, and a
  pipe that hid every `nm` hit): this runbook's gotchas.

## Gotchas / traps
- **`\b` in a Swift `Regex` is a Unicode word boundary** (UAX #29). `.` doesn't break a word, so
  `\bURLSession\b` misses `URLSession.shared`, `Foundation.URLSession` and `URLSession.self`. The scans
  compare scalars and use ASCII boundaries.
- **Swift accepts whitespace in a call:** `ReadRequest (host:`, `ReadRequest .init(host:`, and `.init(` with
  `host:` on the next line. Needles have no spaces and are matched with whitespace removed.
- **A directive can follow code on its line** (`let a = 1; #if DEBUG`); its condition runs to the line's end.
- **Swift keeps a string literal of 15 bytes or fewer inside the instructions.** `strings` never shows
  `ABAPIT_DEMO`, `ABAPIT_SCREEN` or `ABAPIT_SNAPSHOT`. So the gate refuses the *read*: ProcessInfo's
  `environment` and `arguments` selectors, `getenv` and its kin, Swift's `CommandLine`. `DebugOnlyTests`
  holds the names in the source, and `"ABAPIT" + "_DEMO"` passes a name scan, so it holds the reads too.
- **`UserDefaults` reads launch arguments.** `-demoMode YES` sets the default `demoMode`, so
  `UserDefaults.standard.bool(forKey:)` and `@AppStorage` are debug switches too. Key-value coding
  (`value(forKey: "environment")`) reaches ProcessInfo's environment without its selector.
- **A lone CR ends a `//` comment for swiftc.** A lexer that ends it only at LF reads the code after it as a
  comment. `check_text.py` allows CR, so the lexer, its spot lines and the directive scan all end lines at CR.
- **Swift 6 lexes bare `/…/` regex literals.** `/\/*/` is a regex to swiftc and a block comment to a naive
  lexer, which then hid everything up to the next `*/`. The old line scan caught code the first lexer hid: a
  lexer that fails open is weaker than no lexer, so the scans refuse what it can't read.
- **A stripped binary has no symbol table.** `nm` finds nothing in an archive build. A linked stub still shows
  in `strings` as `_TtC11TestSupport9AppleStub` and as its `#filePath` (`…/Sources/TestSupport/…`).
- **`strings -a` reads every section, not the whole file.** The symbol table isn't in a section, so a free
  function linked from TestSupport shows only in `nm` (mutant FN). `strings -` reads every byte, but in every
  unstripped build it finds `TestSupport` and `AppleStub` in the debug map's object paths (the module is
  linked, compiled empty), so the gate uses `strings -a` and `nm` with the same needles.
- **Never `tool | grep -q` under `pipefail`.** `grep` exits at the first match and the writer dies of SIGPIPE
  once its output outgrows the pipe (64 KiB). The pipeline then fails, and `if` reads that as "no match".
  `nm` prints over 1 MB here: the old check never saw `MemoryStore` in any Release build, or the stub in
  mutant E. Capture the output, then search it. `GateScriptTests` refuses a pipe into `grep -q`, `-m`, `-l`
  or `head` in any script under `pipefail`.
- **Vault's `MemoryStore` and `Vault.init(store: MemoryStore, …)` are debug code.** Public in every build, the
  store was picked unnamed: `Vault(store: .init(), now: …)` resolves to the only initializer that takes `now:`.
  Compiled out, that is a Release compile error, and the gate refuses its name. A package test needs a debug
  build (`swift test`, not `swift test -c release`).

## Testing / verification status
- Offline: `scripts/test.sh` (all four suites). Gate changes are proven by building mutant Release apps from
  a scratch copy and running the gate on each (list them in the PR).
- Not covered: a name assembled at run time beyond the lookups listed in `RouteTests.lookups`; a free
  function from TestSupport in a stripped (archive) build, which leaves no trace there. The source holds it
  (no Release code imports TestSupport, `PackageGraphTests`), and CI's unstripped Release build would show it.
- On a new Xcode, re-run the environment-read mutants (an `ABAPIT_DEMO` read, a `getenv`, a `CommandLine`
  read, a `UserDefaults` read, `@AppStorage`). The check reads ObjC selector names and C imports, which a
  Foundation rewrite could move.

## To do common tasks here
- **A new guarded API:** add the needle to its `RouteTests` list and its spellings to `ScannerTests`. Then
  check the scan fails with one use added in the package and one in `App/`.
- **A new debug switch:** name it `ABAPIT_…` and read it under `#if DEBUG`. Both gates hold it with no edit.
- **A Release use of `ProcessInfo` or `UserDefaults`** (a preference, the OS version): a reviewed change to
  `DebugOnlyTests.processReads` and to the gate's selector list, with the mutant that shows what it lets in.
- **A second transport user** (Mosyle's client, Phase 7): a reviewed change to
  `RouteTests.onlyTheClientBuildsTheTransportAndOnlyHTTPClientSends`.
- **A gate change:** build each mutant it should refuse, from a scratch copy, and run the gate on each.
