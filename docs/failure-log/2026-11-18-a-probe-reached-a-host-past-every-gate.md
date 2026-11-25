# 2026-11-18 — A probe reached a host past every gate

- **Symptom:** a review put three probe files in a scratch copy of f3249c1 and called them from `App/AbapitApp.swift`: a
  stream pair, a `Host(name:)` lookup and a BSD socket taken unapplied in `Sources/AppleBusiness`; an `AsyncImage`, an
  `NSImage(byReferencing:)` and an `NSWorkspace.shared.open` in `App/Screens`; and `URLSession.shared.upload` in a second
  synchronized folder, `Extras/`. `scripts/test.sh` passed (912 tests), the Release build succeeded, and
  `scripts/check_app.sh` printed ok on it. The binary imported `_socket`, `_connect`, `_getaddrinfo`, `NSHost`,
  `NSStream`, `AsyncImage` and `NSWorkspace`. No such code is in the app, and nothing was sent.
- **Cause:** invariant 4's five hosts are held by `HTTPCore` for requests that go through it, and by name lists for
  everything else. `RouteTests.networking` and `fetches` named `URLSession`, the Network framework and Foundation's
  fetches. The Release gate looked for listener imports only. No test read the project's source folders, so the three
  scanned roots were "everything the app compiles" by assumption.
- **Why not caught:** each list was written from the routes a review had found (Phase 1a, Phase 1b). The gate's mutants
  were listeners, child processes and debug switches, never an outbound route.
- **Fix:** branch `fix-network-gates`. `RouteTests.hostRoutes` and `hostNames` with `nothingReachesAHostAnotherWay`;
  `TreeTests.theProjectCompilesOnlyTheAppFolder`; `scripts/check_app.sh` refuses the same routes as imports.
- **Prevention:** `ScannerTests.theHostRoutesFind` (a line per probe) and `theHostNamesAreWhole`. The gate change is
  proven by the probe build: the gate refuses it by name, and passes a clean Release build (both in the PR). The lists
  hold the routes found so far, not every one: a route through an allowed framework that no list names still passes,
  and the runbook says so. Proven offline only; no request left the machine.
