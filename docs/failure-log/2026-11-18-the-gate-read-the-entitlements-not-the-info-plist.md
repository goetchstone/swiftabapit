# 2026-11-18 — The gate read the entitlements, not the Info.plist

- **Symptom** — A Release build whose Info.plist registered a URL scheme, a document type, a Service and AppleScript
  passed `scripts/check_app.sh` (`check_app: ok`) and every source scan. A review built it from a scratch copy with
  `INFOPLIST_FILE` added to the project; a copy of a clean build with `CFBundleURLTypes` added and signed again passed too.
  The app registers none of these today.
- **Cause** — The gate read `NSAppTransportSecurity` and four identity keys from the Info.plist and nothing else. Its
  listener check reads the binary's imports, and an inbound door of this kind is a key in the bundle, not a symbol.
- **Why not caught** — Invariant 4's "no listener" was written as "no listener symbol". No test held the project's
  Info.plist settings, and the gate had no test of its own (its mutants were made by hand, per PR).
- **Fix** — The gate holds the Info.plist's keys exactly (the thirteen the build writes, plus nine toolchain stamps named one by one, each a string) and
  holds `Contents` to exactly the five entries a clean build writes and `Resources` to data only (no nested bundle,
  Info.plist, scripting definition, symlink or `InfoPlist.*`), and `MacOS` to exactly `abapit`. `RouteTests.theInfoPlistIsGeneratedFromThreeKeys` holds the build
  settings. https://github.com/goetchstone/swiftabapit/pull/59
- **Prevention** — `scripts/check_app_selftest.sh`, which CI runs after the gate: twenty-three doors, each refused by
  name (of the first ten, eight are inbound doors and two are guards: the date value and `LSEnvironment`), and it fails
  against the old gate. Also learned: `xcodebuild` registers every app it builds with LaunchServices, `.noindex` or
  not, so a mutant with a door is made from a copy and never built by Xcode.
