# Domain: mosyle

**One line:** Mosyle Business: the single-flight session, the envelope inside HTTP 200, device and people reads through an allowlisted adapter, lost-device actions (plan §3.5, Appendix C).

**Owns invariant(s):** #2, #3, #11

**Status:** Phase 7a (reads, models, the strict stub). Lost-device actions are Phase 8; the Logs Stream drain is 7b
(`docs/domains/logs-stream.md`).

## Files
- `Sources/MosyleModels/`: `Envelope.swift` (status inside a 200, `rows` as int or string), `Adapters.swift`
  (abapit's field maps as an allowlist), `Python.swift` (the truthiness, `str()` and `int()` the adapters lean on),
  `Logs.swift` (abapit's `normalize_logs`). Pure; held to `Tests/Fixtures/parity/mosyle.json`.
- `Sources/Mosyle/MosyleRead.swift`: every Mosyle read, by `path#operation`, on `MosyleRead.allowed`.
- `Sources/Mosyle/MosyleSession.swift`: the login, an `Authorizer`; `MosyleAPIError` and its words.
- `Sources/Mosyle/MosyleClient.swift`: devices per platform, users, groups, ping; paging and the cap.
- `Sources/TestSupport/MosyleStub.swift`: the strict stub (Debug only).
- Tests: `MosyleModelsTests` (parity), `MosyleTests` (client and session through the stub), `RouteTests`
  (`everyMosyleReadIsOnTheAllowlist`, the request and exchange makers).

## How it works
- **Login**: `POST /v1/login`, header `accessToken`, body `{email, password}`; the JWT comes back in the response's
  `Authorization` header. Every other request sends both `accessToken` and `Authorization: Bearer <jwt>`. The JWT's
  `exp` sets its life (at most 23 h; none or unreadable: 23 h), refreshed 60 s early; PHP's fixed 1981 `Expires`
  header is ignored. One login at a time per org; a 401 logs in again once, through `invalidate(rejected:)`, so a
  late 401 for an older JWT keeps the new one.
- **Reads are POSTs**, so the method can't tell a read from a write. A read is a `(path, operation)` on
  `MosyleRead.allowed`, and only `MosyleRead` builds one (`precondition` plus the source scan). Anything else Mosyle
  offers is a write, for ChangeCore in Phase 8.
- **The envelope**: the entry's `status` is the operation's (`response[0].status`, or `response.status` where
  `response` is an object); the top-level `"status": "OK"` comes on errors too. A status that isn't success or the end
  of a list is an error, and **an unknown one fails closed** (defect 3: abapit read them as empty lists).
- **Devices**: one platform at a time (`ios`, `mac`, `tvos`, `visionos`; `os` is required), `specific_columns` =
  the adapter's sources (defect 1: the bypass codes are never asked for, and the adapter drops them if sent),
  deduplicated by serial, else UDID.
- **Paging**: from page 1 until an empty page, `DEVICES_NOTFOUND`, a page the same as the one before, a devices page
  that adds nothing new, or the cap (200 pages). Rows on the cap's page mark the result `truncated` (a full last page
  at the cap may in fact be the end: the mark means "may be incomplete"), and every list returns it.

## Invariants & failure history
- Defects 1–3 (plan §2.3) are the reasons for the allowlist, the paging rule and the envelope rule.
- Phase 1a's review (failure-log 2026-10-16, "the stub could not fail") applies as written: the stub has a switch
  for each failure the client handles (`failTransport`, `revoke`, `expireLoginsOnce`, `jwtLifetime`, `queue`,
  `failEnvelope`, `ignorePaging`, `ignoreColumns`, `sendRowsAsStrings`), and a test drives each.

## Parity notes (MosyleModels)
- **Users and groups pass an allowlist too** (Phase 7a review L1, invariant 11): `MosyleAdapter.userAttributes` and
  `groupAttributes`, abapit's own names plus the raw fields they are read from. abapit kept every raw field, so a
  password or a token sent on a user reached its page and its CSV. The golden records the cut as a deviation and
  pins both lists. **Check live (Phase 7):** which other user and group fields Mosyle sends that are worth showing;
  each joins its list with its source.
- **`Python.swift` is abapit's Python, exactly** (Phase 7a review L4), each rule held by `py_str`, `py_truthy`,
  `to_iso` and `dedupe_devices` cases: `str()` of a float is `repr()` (`1e+20`, `1000.0`, positional from 1e-4 up
  to 1e16), of a list or dict its `repr()`; `int()` of a string reads any script's decimal digits and strips only
  ASCII whitespace (U+001C refuses); `str.isdigit()`, `in`, set keys and the Logs sort go by code points, never
  Swift's canonical equivalence (verifier round 2: "2024-e" + U+0301 and "2024-" + U+00E9 tied in the sort, where
  Python orders them); dates are computed proleptic Gregorian (Foundation's Gregorian calendar is Julian before
  1582-10-15). Swift's Unicode tables are read as of the golden's `unicode` (`Python.unicodeVersion`, 15.0, held
  to the header by a test): a character assigned since (a Garay digit, 16.0) is unassigned to abapit's Python,
  so `repr()` escapes it and `int()` refuses it here too.
- **Devices pass the allowlist exactly**: the golden's expectation is abapit's own output for the raw cut to the
  requested columns (`device_columns`, pinned: abapit's maps' sources plus `os` and `device_type`). So a raw key
  spelled like one of abapit's names (`serialNumber` sent without `serial_number`), which abapit passed through,
  is cut, and the golden records it.
- **A number passed through keeps Mosyle's text** (`battery: 1e3` stays `1e3`); abapit's pages and CSV printed its
  `str()` (`1000.0`). Only the fields abapit `str()`'d (ids, the family's words, a log's stamp) use the Python rule.
- **The device dedupe key** is `MosyleAdapter.deviceKey`: by value for a number (`123` = `123.0` = `1.23e2`, `true`
  = `1`; `"123"` differs), by code points for a string; a list or an object is no key (abapit raised `TypeError`).
  `MosyleClient.devices()` still keys on string serials only, and is to switch to it, with a client test through
  the stub (one page holding `123`, `123.0` and `"123"`).
- **Compliance stamps** are ASCII, hour 1 to 12, a real proleptic Gregorian date; anything else stays raw, as abapit
  showed it. A log entry that isn't an object is skipped (abapit raised `AttributeError` and lost the page; the
  golden's `abapit_without_junk` is abapit's reading with the junk out, which the test holds the expectation to).

## Gotchas / stub-lies traps
- **`Duration.seconds` traps past about 1.7e20.** A JWT `exp` is clamped as a number before it becomes a `Duration`
  (`exp: 1e300` or `1e999` is the 23 h fallback; a past one is zero).
- **`Authorization: Bearer ` with nothing after it is no token**, not the token "Bearer".
- **Mosyle sends 50 rows a page whatever `page_size` asks** (abapit recorded `"page_size": 50`; it asked for 500 and
  stopped at the first short page, losing every row past 50). The client never stops on a short page.
- **A no-op `sleep` with the real clock makes `RateLimiter.acquire` spin** until real time refills the bucket (the
  first Mosyle tests took 12 s). Tests give the limiter a clock its sleep advances.
- **Assumed, check live (Phase 7 live check):**
  - The stub's 401 body (`{"error": …}`) and the login's success body (`{"status": "OK"}`): the client reads the
    status code and the header only, so another shape loses only detail.
  - `405 INVALID_METHOD` for a non-POST: plan §3.5 names the status; the body is the stub's choice.
  - Whether `rows` is the overall total or the page's count: the client doesn't rely on it.
  - Whether a users or groups list past its end is empty or carries a status: both stop the walk.
  - Device groups answer with an object (`response.devicegroups`), as plan §3.5 says; users and user groups with
    the usual one-entry list.
- A tenant that ignores `page` would return the first page forever: the walk stops at the first repeat.

## Testing / live-verification status
- Offline: green (`MosyleTests`, `MosyleModelsTests`, the route scans); the mutants are in the Phase 7a PR.
- Live (operator, Phase 7): a login, the device count per platform against Mosyle's console, a 401 from an
  IP-restricted token reading as such, and the assumptions above.

## To do common tasks here
- **A new read**: add `path#operation` to `MosyleRead.allowed` (a read only: the route scan refuses an operation
  that names a change), a builder through `read(_:_:_:)`, a stub handler that fails as Mosyle does, a client
  method that returns its `truncated` flag, and a test per failure.
