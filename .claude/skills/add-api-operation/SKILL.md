---
name: add-api-operation
description: Add an Apple Business/School or Mosyle API operation to swiftabapit — a read through the client, or a write as a planner that builds held request bytes through ChangeCore. Use when asked to add an endpoint, expose an API operation, or extend what the app reads or changes.
---

# Add an API operation

1. **Contract first** — never guess. Apple: find the endpoint in `Contracts/apple/business-*.json` /
   `school-*.json` (method, path, parameters with `allowedValues`/`maximum`, body schema, every status
   code, the example request and response). Mosyle: a row in `Contracts/mosyle/operations.json` with its
   source (OD, PM, LV); a Postman-only shape is untrusted until recorded live.
2. **Models**: Codable, forward-compatible: unknown keys ignored, every enum an `OpenEnum`. A contract
   test decodes the DocC example and checks the enum's known cases equal Apple's `allowedValues`.
3. **Strict stub**: the `AppleStub`/`MosyleStub` handler accepts exactly the contract's shape and fails
   as the API does (each documented status, Apple's `ErrorResponse`, Mosyle's status inside HTTP 200).
4. **A read** gets an `AppleRead`/`MosyleRead` built only by the read builders, paging with a cap that
   shows in the UI (#7, #8). A Mosyle `(path, operation)` joins the read allowlist only if it changes
   nothing — and the Logs Stream is never an automatic read (#2).
5. **A write** is a planner in `Planners/` (or a `*WriteBuilders.swift`) returning a plan with changes,
   no-ops, unknowns, blast radius, preconditions and `WireOperation`s with a `kind` and its
   `minimumRisk`. It runs only through ChangeCore (#1). A destructive kind joins the never-list for
   drafts (#9).
6. **Parity**: if abapit has the behaviour, hold the Swift to its golden in `Tests/Fixtures/parity/`;
   if abapit is wrong, record the corrected expectation with abapit's output beside it.
7. `scripts/test.sh` green; the README live-verification table gets a **not yet** row for a new write
   until `live-verify` proves it.
