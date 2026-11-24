# 2026-11-18 — A write could leave through the read door

- **Symptom** — An audit mutant added a `DELETE /v1/mdmServers/{id}` builder to `AppleRead.swift` and a POST to
  `/v1/orgDeviceActivities` through `TokenBroker`'s credential exchange. Both went out with the bearer token.
  `scripts/test.sh` and `scripts/check_graph.py` were green. No write was in the app, so nothing was sent to a tenant.
- **Cause** — `HTTPClient.read(_:authorizer:)` sent a request's method and body as given, and `HTTPClient.authenticate(_:)`
  posted to any allowlisted host and path with the caller's headers. Only Mosyle's session checked a request as it left
  (Phase 7a review M4).
- **Why not caught** — `RouteTests.labelled` counts request builders in Mosyle's files and not in `AppleRead.swift` or
  `TokenBroker.swift`, and `ReadContractTests` matched a builder to Apple's contract by the builder's own method. Phase 7a's
  verifier had named the credential door (attack S9); it was handed off and not picked up.
- **Fix** — `HTTPClient` refuses, as each request leaves, anything that isn't a read (an Apple GET with no body, a Mosyle POST
  with a body and no query) or one of the three logins with no header beyond Mosyle's access token (`HTTPFailure.notARead`).
  the PR that adds this file
- **Prevention** — `HTTPCoreTests` (`aRequestThatIsNotAReadIsNeverSent`, `aNextLinkIsFollowedOnlyOnAnAppleAPIHost`,
  `aCredentialExchangeGoesOnlyToALogin`, and their controls), `ReadContractTests.everyAppleReadIsAGetWithNoBody`, and `RouteTests.appleReadBuildersNameNoMethodOrBody` (AppleRead.swift
  names no method and no body). Eleven
  mutants of the check, each killed by a named test, and the audit's two mutants, both refused, are in the PR. Proven on the
  stub only: no live request is involved.
