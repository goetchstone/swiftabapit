# 2026-10-16 — The Mosyle stub agreed with the client, and a malformed 200 read as an empty list

- **Symptom:** Phase 7a's adversarial review (faca7c0) sent four HTTP 200 bodies (`{"status":"ERROR",…}`, a string
  `response`, `{}`, a numeric entry status) and each read as zero devices with no error, and the ping as "ok": defect 3
  again, the same class as Phase 1a's "malformed 200 read as unassigned". A mutant that asked Mosyle for a column it
  lacks survived, because `MosyleStub.deviceColumns` was `MosyleAdapter.deviceColumns` plus the bypass codes. 50 users
  and then any status on page 2 threw all 50 away (only `DEVICES_NOTFOUND` ended a list). A JWT whose `exp` read as
  past logged in once per read, and a 45 s JWT once per ping; a login 429 told the operator to re-enter the
  password. 27 of 30 mutants survived: the 403, 405 and 429 mappings, `notJSON`, `noToken`, single flight, the whole
  Logs Stream service, cancellation, the stub's own `accessToken` and expiry checks, and seven allowlist evasions
  (`insert_users`, `variables#save`, an operation-less `/v1/lostmode#`, `|| true` in the `precondition`, a
  `reduce(into:)` after the literal, a `Self(host:)` builder in an extension, an operation in the Logs Stream body).
- **Cause:** the envelope treated "no status" as success whatever the shape; the stub's column list was derived from
  the code under test, so it could only agree with it; end-of-list was one global status; `lifetime(of:)` returned
  zero for a past `exp` and the margin was a flat 60 s; the stub had no switch for most of the failures the client
  maps, so no test reached them; the allowlist was checked as source text (a write-word list and a literal count),
  never as a value or at send time.
- **Why not caught:** Phase 1a's lesson ("a switch for every failure the client handles") was applied to the switches
  the author thought of, and the stub's strictness about columns was strictness about the client's own list. Nobody
  mutated the stub itself, or asked what a 200 that isn't Mosyle's shape does. The fix's verification then found the
  same class one step on: the fix chose lenient shapes with no source (an `OK` beside no list, or a list key holding
  `null`, read as an empty list; any page past 1 without a list as the end, so 50 of 120 users read as all) and its
  own tests pinned them; and its scans matched `ReadRequest(` as text, which `ReadRequest (` with a space defeats.
- **Fix:** branch `fix7a-client`. `MosyleEnvelope.malformed` and `read(_:endOfList:)` (a malformed 200 is
  `.malformed`; a ping needs `DEVICES_NOTFOUND` or a `devices` list); `MosyleRead.endOfList` per list;
  `MosyleStub.deviceColumns` written out with its sources, plus `lackColumns` and a bounded, logged column fallback in
  the client; `margin(for:)` = min(60 s, life/2), a past `exp` is the fallback, login 429/5xx mapped; `.forbidden`
  for a 403 (not re-logged at first; in round 2, once, as abapit did); `MosyleRead.isAllowed` checked before every
  send; an exit test for the builders' trap; exact-value and extension scans; dedupe by id for users and groups; cumulative
  truncation in the device stream; redacting descriptions for `AuthRequest` and `HTTPResponse`. New stub switches:
  `queue` with a body, host and page (the login too), `endLists`, `lackColumns`, `wrapPages`,
  `holdRequests`/`release`, `Account.logsToken`. 64 hand mutants, each killed (listed in the fix's report).
  Round 2, after the fix's verification: a list page is a list under its key or its own end status with no rows
  beside it, on every page, and anything else is `.malformed`; the ping asks as the list does and shares its column
  fallback, which never sends an empty `specific_columns`; a 403 logs in again once, as abapit did (its 7f118fc, from
  Mosyle's docs); the dedupe key compares numbers as Python does; the device stream sends no empty page;
  whitespace-tolerant, whole-file builder scans; a scan that the stub never names the adapter or the client. Hand
  mutants listed in the round's report, all killed but one equivalent.
- **Prevention:** `MosyleStubTests` mutate-proof the stub's own checks; `everyRequestedColumnIsOneMosyleHas` fails when
  the client asks for a column the stub's list lacks, which holds only while that list is written out, so
  `theMosyleStubDoesNotAskTheClient` refuses a stub that names the adapter or the client; `MosyleReadTests` hold the
  allowlist as a value; `noRequestIsMadeElsewhereHoweverItIsSpelt` reads each file whole, whitespace-tolerant. The
  lesson for the review brief: **a stub's "known values" must not be computed from the client**, a
  malformed-but-successful answer is a failure mode to drive like a 500, and **a lenient reading needs a source**:
  without one, an odd shape fails closed and goes on the live-check list. Still only a stub: none of the 33 column
  names nor the guessed end-of-list statuses is confirmed; they are named Phase 7 live checks (plan §8, Phase 7).
