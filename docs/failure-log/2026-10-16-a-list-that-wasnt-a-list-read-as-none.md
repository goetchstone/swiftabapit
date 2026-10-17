# 2026-10-16 — A list page that wasn't a list read as an empty one

- **Symptom:** the round-1 verifiers of the Phase 1b acceptance-pass fix answered `GET /v1/orgDevices` with a 200
  of `{}`, `{"data":null}`, one object, items with no `id` or an `errors` body. The pass printed
  `orgDevices: ok, 0 items` and five `skipped: no device to sample (orgDevices has none)`, and a probe answered
  `{}` read `ok`. A pass cancelled mid-walk read `ok, 0 items` too. Of the first verifier's 35 new mutants, 26
  survived, and the second verifier's found the same gaps: each one-arm "failure as ok" (transport, token,
  malformed, not JSON, 422, cancelled, 401), the code filter's call sites and character classes, a services list
  cut unsaid, the per-service count and position, the School host, and every part of the copied text but the
  status. An identifier-shaped `source.parameter` reached a note.
- **Cause:** `AppleClient.walk` yielded `Document.resources`, which turns anything that isn't an array into `[]`.
  Phase 1a's `.malformed` fix covered single reads only. `check` called a body that returned normally `ok`, and a
  cancelled `for try await` over an `AsyncThrowingStream` returns normally. The code filter checked a character
  set, not a shape, so a serial passed.
- **Why not caught:** the stub couldn't send a malformed 200, a body with a chosen `code`, or a failure on a later
  page, so no test could reach those branches (failure-log 2026-10-16, "the stub could not fail", again). The
  fixer's tests asserted the line struct's status and count, not the text the operator copies. Its mutants were
  written next to those tests, so they shared the tests' blind spots.
- **Fix:** branch `fix1b-acceptance`, commit "fix(1b-acceptance): verifier round 1". `AppleClient.list` makes a list
  page that isn't a list `.malformed`, probes included. The pass checks for cancellation around each check and sends
  nothing once cancelled. The probes run as checks. The services' device lists say what they cover when that list
  stopped short. A code reaches a note only as words of letters joined by `_` or `.`, and a parameter only as a
  parameter name. New stub switches: `queue(_:for:headers:body:)`, whose path may go on into the query, and
  `failNextToken(_:error:)`.
- **Prevention:** `AcceptanceFailureTests` drives each failure through a stub switch and holds every arm of
  `acceptanceFailure` in a table. `aGreenPassReadsLineByLine` holds the whole text. The round's mutant script
  re-ran both verifiers' survivors and this round's own mutants: 74, all killed. Still only a stub: what
  Apple sends for a malformed list is unknown, and the live acceptance pass is the proof.
- **Recurrence (verifier round 2, same branch):** both verifiers held the round-1 fix but found the pass still read
  `ok` for reads it hadn't proved: a page of another type (`users` for `mdmServers`, a next link that walked off to
  the services), another device for a single read, and the coverage walk passing over an id that can't go in a path
  (the four other per-device lines said Apple's `error 404` with nothing sent). A newline in an unknown attribute name
  or enum value forged an `ok` line in the copied text. A check cancelled inside its loop kept sending over the stub
  and said it stopped at the last item. Eighteen distinct mutants survived, among them six of the unknown-value
  fields, the later-page `list()` check, `cut = 1` for `cut += 1`, three token codes and the walk's own cancellation
  check. Cause: the tests drove one example per branch, so a branch that needs a second example (a second cut, a later
  page, a non-last device) or another field went unasserted. Fix: commit "fix(1b-acceptance): verifier round 3":
  `typed(_:asked:)`, `sendable`, `acceptanceWord`, a cancellation check per item, a skip reason that says `truncated`,
  codes in one case, and parameters from the contracts' list. Prevention: each survivor has a test that fails on it
  (this round's mutant script: 62 mutants, the survivors and this round's own, all killed); the per-item tests use two
  or more items and the last one differs, and a cancellation test logs in the transport, since a walk's task can
  outlive the pass.
- **Recurrence (verifier round 3, same branch):** the round-2 word filter held for attribute names but not for enum
  values. `shown(value:)` found the field again by the first `=` `Character` of `field=value`; a value led by a
  combining mark (U+0301) joined that `=` into one `Character`, so Apple's whole value was taken for the field and
  copied raw: a service's, a coverage's or the lock's value forged two lines and named a serial and an email, and a
  device's was dropped from the report (`isUnknown` split the same way and fell to `default: false`). This is the
  Phase 1b review's H1 (a combining mark after a CSV quote) in new code. `typed(_:asked:)` compared ids with `String
  ==`, so an id with U+212A KELVIN SIGN read as the `K` serial asked for. Fifteen mutants survived, among them
  lookalike and mixed-type pages, an empty page cut at the cap one level in, an id guard weakened to "no space", and
  the byte tables. Cause: Apple's text was handled as `Character`s at one more seam, and the filter's tests ran it
  alone, never through the string it was spliced into. Fix: commit "fix(1b-acceptance): verifier round 4":
  `Found.unknown(_:_:)` takes the field and Apple's value apart and is the only way a value reaches the text, and
  `typed` compares bytes. Prevention: a test sends a value led by a combining mark on each of the ten fields; each
  survivor has a test that fails on it (this round's mutant script: 32 mutants, all killed). Rule: never split,
  search or compare Apple's text as `Character`s; bytes, or keep the parts apart.
