# 2026-11-18 — A fetch no needle named

- **Symptom** — A scratch mutant put `AsyncImage(url:)`, `NSImage(byReferencing:)`, `Stream.getStreamsToHost`,
  `NSWorkspace.shared.open`, the `openURL` action and a SwiftUI `Link` on an API-supplied string in a screen. All 71
  source-scan tests passed. No screen does any of this today.
- **Cause** — `RouteTests.fetches` listed Foundation's and URLSession's fetches only. The sandbox's `network.client`
  entitlement allows any host, so invariant 4's five hosts rest on the scans for anything that isn't the transport.
- **Why not caught** — Each needle list was written from the routes a review had found. Nobody listed what SwiftUI and
  AppKit fetch or open by themselves, and `docs/domains/gates.md` named only `NSWorkspace` as not covered.
- **Fix** — `fetches` gains `AsyncImage`, `byReferencing:`, `getStreamsToHost`, `NSWorkspace`, `openURL` and `OpenURL`; a
  whole-name scan refuses SwiftUI's `Link`; the failure names the file.
- **Prevention** — `ScannerTests.theFetchNeedlesFind` (a sample per needle), `theLinkNameIsWhole`, and
  `RouteTests.nothingFetchesOutsideTheTransport`. The list holds the routes found so far, not every one: the runbook says so.
