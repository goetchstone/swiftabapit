# 2026-11-18 — The stub took several audit types where Apple documents one, and three tests pinned it

- **Symptom:** found by the 2026-11-18 audit, not by a break.
  - `AuditQuery` took any number of types, and `AppleRead.auditEvents` joined them with commas into `filter[type]`.
  - `AppleStub` split the value on commas and answered the union of the types' events with a 200.
  - `AuditTests` expected `filter[type]=ROLE_UPDATED,ROLE_CREATED` on the wire, the union of two types' events from the
    stub, and a 200 for two types on a raw request.
  - Apple's contract says of `filter[type]`: "Type of event. Note that only one type in query is supported." The
    sentence has been in `Contracts/apple/` since Phase 0 (8889c8b).
  - No screen sent two types (the Activity filter holds one), so nothing was wrong on screen.
- **Cause:** e1f09eb (Phase 2a, 2026-10-30) read the parameter's type, `[string]`, and not its description. The same
  commit did read the descriptions of `filter[actorId]` and `filter[subjectId]` ("only one actor id in query is
  supported"), and the client held each to one id; the stub did not refuse a second, which this PR also fixes. The runbook
  listed several types as a question to check live when the contract had already answered it.
- **Why not caught:** the contract tests compare each sent value with `allowedValues` after splitting it on commas, so a
  list of allowed types passed. No test read a parameter's description for a limit. The stub was written from the same
  reading as the client, so the two agreed (invariant 5; failure-log 2026-10-16, "the Mosyle stub agreed with the client").
- **Fix:** https://github.com/goetchstone/swiftabapit/pull/20 (branch `audit-one-type`).
  - `AuditQuery` throws `.tooManyTypes` for two different types; the same type given twice is one.
  - `ActivityModel` has words for the refusal; no screen can trigger it today, because the Activity picker selects one
    type.
  - The stub refuses a `filter[type]`, `filter[actorId]` or `filter[subjectId]` that holds a comma with a 400 naming the
    parameter.
  - The three tests that pinned several types expect the refusal, and the contract test sends each type in a read of its
    own.
- **Prevention:**
  - `everyAuditTypeIsSentAloneAsAppleDocuments` reads the contract's sentence: it fails if Apple lifts the limit, or if a
    read holds two types.
  - `pre-commit` item 6 says to read each parameter's description for a limit, not only its type.
  - Still only a stub: Apple documents the limit, not its answer to a second type. The stub's 400 is an assumption
    (apple-reads runbook, "Assumed, check live"). The client never sends two, so the live check is for the record.
