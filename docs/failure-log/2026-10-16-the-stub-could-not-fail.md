# 2026-10-16 — The stub could not fail, so the failure paths were never run

- **Symptom:** Phase 1a's adversarial review (PR #3, snapshot c23c964) crashed the app with one header: a
  429 carrying `Retry-After: 1000000000000000000000` trapped in `Duration.seconds` ("Overflow in
  multiplication") before the 60 s cap applied. Of the reviewer's 14 hand mutants, 13 survived: no host
  guard on the token broker, no early refresh, an unbounded 401 retry, no transport retries, a
  `try?` clean-up in `replaceSet`, any error read as "unassigned", the body cap off, `expires_in` unclamped,
  the stub's own `exp`/`iat` checks deleted, a probe failure read as `ok`, an expired session still signing,
  and two source-scan evasions (`.init(host:)`, a `Data(contentsOf:)` fetch). Probes also found a late 401
  minting a third token, a removed org's id handed to a new org with the old secrets, a duplicate id
  accepted, `orgs.json` losing entries and keys on a load and save, a NaN rate that never waits, a
  malformed 200 read as "unassigned", and the stub refusing its own page-2 `cursor` on three endpoints.
- **Cause:** the strict `AppleStub` was strict about what a request may say and had no way to make
  anything go wrong: no dropped connection, no revoked account, no short token, no oversized body. Every
  test took the happy path through the client because the stub offered no other. The `Duration` trap was
  the one H1 line: clamp after converting, not before.
- **Why not caught:** "stubs fail like the APIs" (invariant 5) was read as "refuse what Apple refuses",
  not also "fail the ways Apple and the network fail". The tests named in the PR covered success and
  refusal; nothing exercised a retry, a refresh or a cap. A test that can't reach a branch can't hold it.
- **Fix:** PR #3, before merge. The stub gained `failTransport(_:)`, `revokeAccount()`, `tokenLifetime(_:)`,
  a body cap, cursor-only next links and `reportTotals()`. `AppleClientFailureTests`, `AppleStubTokenTests`
  and new Vault, org-store and HTTP-core cases each kill one of the reviewer's mutants. Re-run against 26
  mutants (the reviewer's plus the new fixes'), all killed (listed in the PR). Code fixes: the `Retry-After`
  clamp, `invalidate(rejected:)`, dot segments checked after decoding, `limit` kept on next links,
  `.malformed` for a 2xx without the resource, `uniqueID(for:avoiding:)`, `duplicateID`, preserved
  unaddressable entries and unknown keys, trimmed case-insensitive client IDs, finite rates, `wrongKind`,
  every Vault use checking the session, the clean-up trying every kind, `unsafeFlags` and package-name
  build settings refused by `check_graph.py` and `SourceScanTests`.
- **Prevention:** invariant 5's runbook (`docs/domains/stubs.md` when it exists; until then
  `docs/domains/apple-reads.md` and `http-core.md`) now says a stub has a switch for every failure the
  client handles, and a branch with no switch is an untested branch. The `pre-commit` skill's review
  item already asks the reviewer to mutate; this entry adds "list the client's failure branches and
  check each has a stub switch" to the review brief. Still only a stub: the live Phase 1 checks (a real
  429, a real `links.next`) are the proof, and they need the operator.
