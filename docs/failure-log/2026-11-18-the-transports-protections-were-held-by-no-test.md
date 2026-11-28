# 2026-11-18 — The transport's protections were held by no test

- **Symptom:** a review changed `Transport.swift` in a scratch copy of f3249c1: `delegate: self` to `nil`, the redirect
  handler made to follow everything, both body-cap checks removed, the session made `.default`, cookies accepted and
  sent, the cookie-store, cache and credential-store lines removed, TLS 1.2 made 1.0. `scripts/test.sh` passed, 912
  tests. The repo's file was never changed and no request was sent.
- **Cause:** every test sends through a stub `Transport` (`AppleStub`, `MosyleStub`), so `URLSessionTransport.send`,
  its delegate method and its session configuration run in no test. `HTTPCoreTests.redirectsStayOnTheSameAllowlistedHost`
  tested only a pure helper (`followable(from:to:)`, since removed), and the oversized-body tests pass on the stubs' own `body.count > limit`.
- **Why not caught:** CLAUDE.md names `HTTPCoreTests` as the home of "a redirect elsewhere is refused", and the runbook
  listed the cap among what the stub proves. A test named for the cap passed without running the product's cap.
- **Fix:** branch `fix-protection-pins`. `TransportShapeTests` holds the text of the send (its host check and its one use of the delegate), the delegate method by its
  selector, both caps and each session setting, by count, and carries the weakenings as its own mutants.
  `Transport.swift` is unchanged.
- **Prevention:** `TransportShapeTests.theTransportKeepsItsProtections` and `eachWeakeningIsFound`. It holds the text,
  not the behaviour: no offline test opens a connection, so that URLSession calls the delegate and refuses the redirect
  is proven only live. RULE-FEEDBACK 2026-11-18 asks that invariant 4's home line name the new suite.
