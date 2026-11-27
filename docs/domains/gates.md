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
- `scripts/check_app_selftest.sh` — the gate's test of its Info.plist and bundle-folder checks: copies of a Release app,
  each with one inbound door, must each be refused by name. CI runs it after the gate. Of its first ten doors, eight are
  inbound doors and two are guards (the date value JSON can't hold, and `LSEnvironment`); the nine added after a review
  are the stamps' type and name, a nested app or extension in `Contents` or `Resources`, a file in a folder the build
  never writes, a scripting definition and `InfoPlist.strings`.
- `scripts/check_graph.py`, `scripts/check_text.py` — the manifest SwiftPM evaluates; invisible characters.

## How it works
- **What a scan reads.** `SourceScan.code` blanks every comment (nested too) and, unless asked to keep them,
  string literals' contents, scalar for scalar with line breaks kept. It follows raw strings, multi-line
  strings, escapes, interpolations (code again), `#/…/#` regex literals and raw identifiers (`` `a // b` ``).
  A line ends at LF or CR, as it does for swiftc.
- **What it can't read, it refuses.** A bare `/…/` regex literal is the one construct the lexer doesn't follow,
  so `TreeTests` refuses any `/` in code that isn't division with a space on each side (`a / b`). Write a regex
  as `#/…/#`. App/ may hold Swift and the inert files a catalog needs; any other file there (an `.m`, a `.c`)
  is refused, since Xcode compiles whatever is put in the synchronized folder. No link may sit at or under a
  root: SwiftPM compiles through a linked folder, and the scans' file walk doesn't descend into one.
- **What counts.** Code and string literals count; comments never do. A string is how a run-time lookup
  names a class (`NSClassFromString("NSURLSession")`), and `nothingLooksCodeUpByName` refuses the lookups.
- **How a needle matches.** Anywhere, inside a longer name too (`URLSession` finds `NSURLSession` and
  `URLSessionConfiguration`), and across whitespace and a raw identifier's backticks. Only a whole `except`
  name is excused (`URLSessionTransport`, in the package only).
- **How a name matches** (`SourceScan.names`, `outsideDebug(…, names:)`): whole, in code only, for a name that
  sits inside common ones: `send` (not `sender`), `Process` (not `ProcessInfo`), `environ` (not `environment`).
- **Debug-only code.** `outsideDebug` reads `#if`/`#elseif`/`#else`/`#endif` from the code alone and counts
  only the true branch of a condition that is exactly `DEBUG`, at any depth. Release code names no `ABAPIT_`
  switch, and no `ProcessInfo`, `CommandLine`, `getenv`, `_NSGetArg…`, `UserDefaults`, `AppStorage`,
  `CFPreferences`, `sysctl`, `KERN_PROC…`, `proc_pid…` or `environ`.
- **Where the transport may be.** Only `AppleClient` builds `URLSessionTransport`, and only `HTTPClient` calls a
  transport's `send` (it takes any `URLRequest`, past the host allowlist and the Executor). The name `send`
  appears in code only in `HTTPCore` and the stubs, so an extension of a conforming type can't call it bare.
- **Who makes a request.** The read and auth makers' needles, and `onlyARequestIsMadeWithAHost`: a call with
  `host:` first is made only on `ReadRequest`, `AuthRequest`, an `init` or `URL.make`, never on another name
  or a bracket (`[ReadRequest].Element(host:…)`, `(ReadRequest)(host:…)`).
  No scan sees every way a request is made, and Apple's two maker files are not counted (`RouteTests.labelled`): what
  holds is `HTTPClient`'s check of each request as it leaves ([http-core.md](http-core.md)).
- **No second door.** Nothing starts a program (`Process`, `posix_spawn`, `execv…`, an AppleScript or a user
  script task): a child inherits the network entitlement and fetches past the transport.
- **No fetch around the transport.** Nothing names `Data(contentsOf:)` and its kin, `AsyncImage`,
  `NSImage(byReferencing:)`, `Stream.getStreamsToHost`, `NSAttributedString(url:` or `NSURLDownload(`, nor takes
  `Data.init`, `NSData.init` or `NSImage.init` unapplied. Nothing makes a `Text` link (`AttributedString(markdown`,
  `LocalizedStringKey(`, a `](http` in a string). Nothing hands a URL to another app through `NSWorkspace`, `openURL`,
  `OpenURLIntent` or `Link` (what else can is in "Not covered" below), in the package or the app. The phase that opens an activity's
  `downloadUrl` in the browser names the one file that may, with an https-only check and its test, as a reviewed change
  to `RouteTests.nothingFetchesOutsideTheTransport`.
- **The Release gate's code checks** run on a stripped copy (`strip -D`, as an archive does) and then on the
  binary as built. Both must be clean. A hit only the second pass finds is in the symbol table alone: the gate
  says so, because an archive would ship that code unseen. It refuses the reads by their selectors and imports:
  `environment`, `arguments`, `standardUserDefaults`, `valueForKey:`, `getenv` and kin, Darwin's `environ`
  getter, `sysctl`, `proc_pid…`, `CommandLine`, the `NSUserDefaults` class, `AppStorage`, `CFPreferences`. It
  refuses a child process's imports (`NSTask`, which is `Process`; `posix_spawn`; `execv…`; the script tasks).
  It refuses TestSupport's names and Vault's `MemoryStore` in `strings -a` and in `nm`.
- **The Release gate's Info.plist check.** The keys are exactly the thirteen the build writes, plus the toolchain's
  stamps, named one by one, each a string (`BuildMachineOSBuild`, `DTCompiler`, `DTPlatformBuild`, `DTPlatformName`,
  `DTPlatformVersion`, `DTSDKBuild`, `DTSDKName`, `DTXcode`, `DTXcodeBuild`): no `DT…` wildcard. A URL scheme, a document
  type, a Service, AppleScript or an activity type is a key, so each is refused by name. `Contents` holds exactly
  `Info.plist`, `PkgInfo`, `MacOS`, `Resources` and `_CodeSignature` (a clean Release build holds just these), so
  `Library`, `XPCServices`, `PlugIns`, `Helpers`, `Extensions`, `SharedSupport` and anything else are refused. `Resources`
  holds no `Info.plist`, `.app`, `.appex`, `.xpc`, `.bundle`, `.framework`, `.sdef` or `InfoPlist.strings`, and
  `TreeTests` refuses an `InfoPlist` string catalog under `App/`.
  `RouteTests.theInfoPlistIsGeneratedFromThreeKeys` holds the build settings: no `INFOPLIST_FILE`, three `INFOPLIST_KEY_`s.
- **No other way to a host.** `RouteTests.nothingReachesAHostAnotherWay` refuses, in the package and the app,
  Foundation's stream pair and `Host`, the resolver (`getaddrinfo`, `gethostby…`), the whole names `socket` and
  `connect` (taken unapplied, `socket(` isn't there to find), an attributed string read from a document or HTML, a web
  view and a sharing service. The Release gate refuses, as imports, exactly these (`_socket`, `_connect`, `_connectx`, `_getaddrinfo`,
  `_gethostbyname`, `_gethostbyname2`, `_gethostbyaddr`, `NSHost`, `CFHost`, `NSStream`, `NSInputStream`,
  `NSOutputStream`, `CFStreamCreatePairWith…`, `AsyncImage`, `NSWorkspace`, `_LSOpen…`, `NSSharingService`,
  `WKWebView`, `_WebKit_SwiftUI`): it reads the binary, so it sees code no scan read. Only `_socket`, `_connect`,
  `_getaddrinfo`, `NSHost` and `NSStream` were proven refused at the binary level (by a probe build). The source scan and the import allowlist hold the rest: `NWConnection`,
  `NSURLConnection`, `CFReadStream`, `dlsym` and other run-time lookups. Both are lists of the routes found so far, not
  every route (failure-log 2026-11-18, "a probe reached a host past every gate").
- **What Xcode compiles.** `TreeTests.theProjectCompilesOnlyTheAppFolder` holds the project to one synchronized
  folder (`App`), one target, four file references and no script, copy or rule phase. A second folder (`Extras/`)
  compiled into the app past every scan. `scripts/check_graph.py` holds the same for SwiftPM (no custom `path`).

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
- **Swift accepts a backtick around any name**, a plain one included: `` Data(`contentsOf`: url) `` compiles
  with a warning (the package doesn't treat warnings as errors). Needles are matched with backticks removed.
- **An extension calls a method bare.** `extension URLSessionTransport { … send(r, limit: 1) }` has neither
  `.send` nor `extension Transport`, so the scan holds the name `send` itself.
- **A directive can follow code on its line** (`let a = 1; #if DEBUG`); its condition runs to the line's end.
- **Swift keeps a string literal of 15 bytes or fewer inside the instructions.** `strings` never shows
  `ABAPIT_DEMO`, `ABAPIT_SCREEN` or `ABAPIT_SNAPSHOT`. So the gate refuses the *read*: ProcessInfo's
  `environment` and `arguments` selectors, `getenv` and its kin, Swift's `CommandLine`. `DebugOnlyTests`
  holds the names in the source, and `"ABAPIT" + "_DEMO"` passes a name scan, so it holds the reads too.
- **Swift reads Darwin's `environ` through the overlay.** The import is `_$s6Darwin7environ…vg`, never
  `_environ`, so an anchored `^_environ$` never fires for Swift code. `sysctl` with `KERN_PROCARGS2` returns the
  process's own arguments and environment, through `_sysctl` alone.
- **`system`, `popen`, `fork`, `vfork` and the variadic `execl…` are unavailable in Swift** (a compile error),
  and `NSTask` is spelled `Process`. The source scan lists what compiles; the gate looks for `NSTask`, the class
  `Process` imports.
- **`FileManager.subpaths` doesn't descend into a symlinked folder**, and SwiftPM compiles through one. Git
  commits a link as a link (mode 120000). Xcode's synchronized App/ folder doesn't follow one.
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
  mutant E. Capture the output, then search it. `GateScriptTests` refuses a pipe into `grep -q`, `-m`, `-l`,
  `-L`, `head` or `read` in any script under `pipefail`, read as bash reads it: a line ending in `|` or `\` goes
  on, `command`, `env` and `LC_ALL=C` run the next word, `/usr/bin/grep` is grep, and getopt_long takes
  `--quie` for `--quiet`. Each of those passed a line-at-a-time read, and two blinded the gate on mutant FN.
- **Vault's `MemoryStore` and `Vault.init(store: MemoryStore, …)` are debug code.** Public in every build, the
  store was picked unnamed: `Vault(store: .init(), now: …)` resolves to the only initializer that takes `now:`.
  Compiled out, that is a Release compile error, and the gate refuses its name. A package test needs a debug
  build (`swift test`, not `swift test -c release`).
- **A needle matches across whitespace, in a string too.** The words `open URL` in a button's title read as `openURL`
  and fail the fetch scan: word the title another way.
- **`xcodebuild` registers every app it builds with LaunchServices** (its `RegisterWithLaunchServices` step). A
  `.noindex` folder keeps Spotlight out, not LaunchServices. A mutant with an inbound door is made from a copy
  (`check_app_selftest.sh`: copy, change, sign, read), never built by Xcode, and never opened.

## Testing / verification status
- Offline: `scripts/test.sh` (all four suites). Gate changes are proven by building mutant Release apps from
  a scratch copy and running the gate on each (list them in the PR).
- Not covered: a name assembled at run time beyond the lookups listed in `RouteTests.lookups`; a free
  function from TestSupport in a stripped (archive) build, which leaves no trace there. The source holds it
  (no Release code imports TestSupport, `PackageGraphTests`), and CI's unstripped Release build would show it.
  A request initializer taken unapplied through a generic type whose last argument isn't the request
  (`Box<ReadRequest, Int>.Inner.init`, then called without labels): `ReadRequest>.` and `].` catch the rest.
  A Foundation, AppKit or SwiftUI call that fetches or opens a URL and is on neither `RouteTests.fetches` nor `linkName`:
  the lists hold the routes found so far (failure-log 2026-11-18). `ShareLink` and `NSSharingService` hand a URL on
  and are not listed. `String(contentsOf:)` and `NSString(contentsOf:)` reached through an unapplied initializer
  given an explicit function type (`let f: (URL, String.Encoding) throws -> String = String.init`) are not caught:
  `String.init` is used legitimately (`.map(String.init)`) and a substring needle can't tell the two apart; the same
  goes for `NSString.init`. A markdown link built with no `](http` in the source (a scheme joined at run time) and
  a `Text` given a `LocalizedStringKey` through another name. `sed …q` and `awk … exit` after a
  pipe, which no script uses.
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
- **A new Info.plist key:** add it to `want` in `scripts/check_app.sh` and its reason to the PR. An inbound door (a URL
  scheme, a document type, a Service) is a design change: stop for the operator.
- **A Release use of `NSWorkspace` or `openURL`** (opening an activity's `downloadUrl` in the browser, by design): a
  reviewed change that excuses the one file by name in `RouteTests` and takes `NSWorkspace` out of the gate's import
  list, with an https-only check and its test in the same PR.
