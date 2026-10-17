# Domain: mosyle

**One line:** Mosyle Business: the single-flight session, the envelope inside HTTP 200, device and people reads through an allowlisted adapter, lost-device actions (plan §3.5, Appendix C).

**Owns invariant(s):** #2, #3, #11

**Status:** Phase 7a (reads, models, the strict stub). Lost-device actions are Phase 8; the Logs Stream drain is 7b
(`docs/domains/logs-stream.md`).

## Files
- `Sources/MosyleModels/`: `Envelope.swift` (status inside a 200, the malformed shapes, a list page's reading, `rows`
  as int or string), `Adapters.swift`
  (abapit's field maps as an allowlist), `Python.swift` (the truthiness, `str()` and `int()` the adapters lean on),
  `Logs.swift` (abapit's `normalize_logs`). Pure; held to `Tests/Fixtures/parity/mosyle.json`.
- `Sources/Mosyle/MosyleRead.swift`: every Mosyle read, by `path#operation`, on `MosyleRead.allowed`; each list's
  end-of-list statuses; `isAllowed`, the check made again as each request is sent.
- `Sources/Mosyle/MosyleSession.swift`: the login, and `read(_:)`, the only way a request carries it (the session is
  no `Authorizer`; its private `Login` is, made per read); `MosyleAPIError` and its words.
- `Sources/Mosyle/MosyleClient.swift`: devices per platform, users, groups, ping; paging, dedupe, the cap, the column
  fallback.
- `Sources/TestSupport/MosyleStub.swift`: the strict stub (Debug only), with its own device-column list.
- Tests: `MosyleModelsTests` (parity); `MosyleTests`: `MosyleClientTests` and `MosyleSessionTests` (the happy paths),
  `MosyleFailureTests` (every failure the client handles), `MosyleLoginTests` (the login's failures, single flight, the
  Logs Stream's login), `MosyleStubTests` (the stub's own strictness), `MosyleReadTests` (the allowlist as values, the
  check before sending, the builders' trap as an exit test, the login's redaction); `RouteTests`
  (`everyMosyleReadIsOnTheAllowlist`, `nothingElseExtendsOrRenamesReadRequest`, `noRequestIsMadeOutsideTheBuilders`,
  `theRequestScansFindEverySpellingTheyKnow`, `onlyTheSessionCarriesAMosyleLogin`, `theMosyleStubDoesNotAskTheClient`,
  the request and exchange makers; `SwiftCode` reads a file as code for them).

## How it works
- **Login**: `POST /v1/login`, header `accessToken`, body `{email, password}`; the JWT comes back in the response's
  `Authorization` header. Every other request sends both `accessToken` and `Authorization: Bearer <jwt>`. The JWT's
  `exp` sets its life (at most 23 h; none, unreadable, or at or before now: 23 h), renewed 60 s early, or halfway
  through a life shorter than 2 min; PHP's fixed 1981 `Expires` header is ignored. One login at a time per org. A
  read logs in again once, whichever of a 401 or a 403 asks first, as abapit's single `relogged` did (its 7f118fc,
  "reworked against the official Business API docs": "re-login on 401/403"; its Logs Stream path calls a 403 "token
  expired"), dropping only the login the read's last attempt carried, so a late 401 or 403 for an older JWT keeps
  the new one. A second refusal is the error: `.unauthorized` after a 401, `.forbidden` after a 403 (Phase 7a review
  L5: the first fix didn't re-log on 403; round 3 of its verification: HTTPClient's 401 refresh and the 403 retry each
  logged in, up to three times for one read). A login answering 429 is `.rateLimited`, a 5xx `.server`, a 2xx without a
  token `.noToken`; only another refusal (a 3xx included) is `.login(status:)`, the one that names the credentials.
  A login is never retried. The Logs Stream logs in on its own host with its own token (`Service.logs`).
- **Reads are POSTs**, so the method can't tell a read from a write. A read is a `(path, operation)` on
  `MosyleRead.allowed`, and only `MosyleRead` builds one (`precondition`, held by an exit test, plus the source
  scans). The session checks each request as it will be sent (`MosyleSession.read`, through `MosyleRead.isAllowed`:
  a POST, no query, the body exactly as the builders serialize it, its `path#operation` on the list, the path's own
  host), before any login, so a `ReadRequest` made anywhere else in the package can't carry a write (`.notARead`,
  nothing sent). That holds however the request was spelt, because the session is no `Authorizer`: its login reaches
  `HTTPClient` only inside `read(_:)` (round 3 of the verification sent three forged writes, each past every scan,
  through `HTTPClient.read` with the session). Anything else Mosyle offers is a write, for ChangeCore in Phase 8.
- **The envelope**: the entry's `status` is the operation's (`response[0].status`, or `response.status` where
  `response` is an object); the top-level `"status": "OK"` comes on errors too. A list page is one of two answers,
  on every page: a list under the first of its keys that holds one (abapit's `_extract`; an empty list ends the
  walk), or **its own** end-of-list status (`MosyleRead.endOfList`, byte for byte) with no rows beside it. `OK` is
  no status. Any other status fails, **an unknown one, another list's end, a lower-case end and a write's success
  status (`COMMAND_SENT`) included** (defect 3: abapit read them as empty lists).
- **A malformed 200 is never an empty list** (Phase 7a review H2, and its verification): no `response`, a string or
  `null` `response`, an empty list, a first entry that isn't an object, a status that isn't a string, a row that
  isn't an object, a list key holding no list (`null`, a string, PHP's object-keyed array `{"0": …}`), an end status
  beside rows, or an entry with no list and no end status (beside an `OK` too, and past page 1 too: there 50 of 120
  users read as all of them) is `.malformed`. Only a code-shaped top-level `status` is shown, never Mosyle's text,
  and only a string `info`. The ping says "ok" only for a `devices` list or `DEVICES_NOTFOUND`.
- **Devices**: one platform at a time (`ios`, `mac`, `tvos`, `visionos`; `os` is required), `specific_columns` =
  the adapter's sources (defect 1: the bypass codes aren't asked for unless the column fallback below has had to
  ask for every column, and the adapter drops them whenever they are sent), deduplicated by abapit's key (the first
  truthy of serial and UDID, a number as well as a string, compared as Python's set compares: `1000`, `1e3` and
  `1000.0` are one key, `true` is `1`, a zero is no key; past `Int`'s range an integer and an equal float stay two,
  a recorded deviation). The stream sends no empty page.
- **The column fallback** (Phase 7a review H3): no source confirms any of the 33 names as a `specific_columns` name
  (abapit sent only `os` and `page`), and one wrong name would fail every device list. On `UNKNOWN_COLUMNS` the
  client asks again without the columns Mosyle's `info` names, the first time; else, or on a second refusal, without
  `specific_columns`, so only the adapter's allowlist keeps the bypass codes out (as it did for abapit); a third
  refusal is the error. An empty `specific_columns` is never sent: Mosyle naming every column is every column. Two
  walks refused at once settle on one fallback (the second asks again with the first's). The ping asks as the list
  does and shares its fallback. Each step is an error-level log line naming the columns (a test reads it back from
  the process's own log) and `MosyleClient.columnFallback`, for a screen to show. Failing closed was rejected: it
  trades a whole lost list for codes the adapter drops anyway.
- **Paging**: from page 1 until the list's own end-of-list status, an empty page, a page that adds nothing new (users
  and groups are deduplicated by id, or by the whole row without one: a tenant that wraps past its end served 60
  users as 6000, review L2), or the cap (200 pages). New rows on the cap's page mark the result `truncated` (a full
  last page at the cap may in fact be the end: the mark means "may be incomplete"; a cap page that adds nothing new
  is the end, unmarked), and every list returns it; in the
  device stream every page after a cut says so, so the last page does (review L3). Each page's log line gives the
  rows it held and Mosyle's `rows`, for the live check of what `rows` means.

## Invariants & failure history
- Defects 1–3 (plan §2.3) are the reasons for the allowlist, the paging rule and the envelope rule.
- Phase 1a's review (failure-log 2026-10-16, "the stub could not fail") applies as written: the stub has a switch
  for each failure the client handles, and a test drives each: `failTransport`, `revoke`, `expireLoginsOnce`,
  `jwtLifetime`, `queue` (any status and body, for a path, a host and a page, the login included: 403, 405, 429,
  5xx, a 200 that isn't JSON or isn't Mosyle's shape, a login without a token), `failEnvelope`, `endLists`,
  `lackColumns`, `ignorePaging`, `wrapPages`, `ignoreColumns`, `holdRequests`/`release` (a page still out when the
  stream stops), and the Logs Stream's login (`Account.logsToken`). `sendRowsAsStrings` went: the client never
  relies on `rows`, and the parity test holds its parse.
- Phase 7a's review (27 of 30 mutants survived): the malformed 200s (H2), the stub's columns being the adapter's
  (H3), the one list end (M1), the login storms (M2), the unreached branches (M3) and the allowlist scan's gaps (M4).
  `MosyleStubTests` now hold the stub's own checks (deleting its `accessToken` or expiry check survived before).
- Its verification (round 1, 33 survivors over two lenses): an `OK` beside a list key holding no list, and any page
  past 1 without a list, still read as an empty success; `ReadRequest (host:` with a space, a line break or the
  metatype passed every builder scan, and `HTTPClient` sends such a request unchecked; a write built through
  `MosyleRead.read` in another file passed the scan of one file; the stub's column list had nothing keeping it its
  own; the fallback's underscore names, second refusal, concurrent re-ask and log level were untested; the 403
  deviation from abapit; Python's number equality in the dedupe key. Each now has a test that kills its mutant.
- Round 3 (two lenses): a backticked `` `ReadRequest`( ``, `ReadRequest/**/(`, `Array<ReadRequest>.Element(`,
  `.init(/**/host:`, a backticked `AuthRequest`, `` MosyleRead.`read`( `` and a spaced third builder inside
  MosyleRead.swift each passed every builder scan, and `HTTPClient.read(_:authorizer:)` sent the forged writes with the
  session's login; a 401 then a 403 logged in twice more, and which login a 403 dropped was untested; the log test
  passed on other tests' lines; big-integer serials, a lower-case `ok`, the stub's column trim and empty `os`, a 599
  login and the lenient end-of-list beside an empty list were unpinned. The session became the checked door, the
  scans read code (`SwiftCode`), and each has a test that kills its mutant.

## Gotchas / stub-lies traps
- **`Duration.seconds` traps past about 1.7e20.** A JWT `exp` is clamped as a number before it becomes a `Duration`
  (`exp: 1e300` or `1e999` is the 23 h fallback; so is a past one, which as a zero life logged in for every read).
- **A flat refresh margin is a login per read for a short JWT**: a 45 s JWT was inside the 60 s margin from birth.
  The margin is `min(60 s, lifetime / 2)`.
- **The stub's columns must not come from the client.** Derived from the adapter, `UNKNOWN_COLUMNS` could never fire
  and a misspelt column was green. `MosyleStub.deviceColumns` is written out, with its sources.
- **Swift's call syntax defeats a scan of the text**: `ReadRequest (host:` with a space, `ReadRequest` and `.init(`
  on separate lines, `ReadRequest.self` then `t.init (`, a backticked `` `ReadRequest` ``, a comment between the
  tokens and `Array<ReadRequest>.Element(` all compile. The scans read each file as code (`SwiftCode.read`: comments
  out, backticks out, strings and interpolations followed), count each maker's `host:` argument lists exactly, and
  allow `ReadRequest` elsewhere only as a parameter or result type. They still can't see every spelling, which is
  why the session checks each request as it is sent.
- **Swift's `\b` is Unicode's**: `reader.read` and `Wire.ReadRequest` are one word each, so `\bread` and
  `\bReadRequest` match neither. The scans use `wordBoundaryKind(.simple)`.
- **A bare regex literal can hide code from a scan**: a `"` or `/*` inside one reads as a string or a comment to
  anything that doesn't know it is a regex. `SwiftCode` takes one as written only when it holds no quote, backtick,
  bracket or hash (MosyleModels' compliance pattern), and the scans refuse a file with any other.
- **The fallback's log test reads `OSLogStore`** (this process's own entries): it takes a few seconds, and a
  `.debug` line isn't kept at all, which is the point (the live check reads the error-level line). Other tests write
  their fallback lines at the same moment, so the test refuses two columns no other test refuses and matches each
  line whole; the every-column line names the columns refused, when Mosyle named any.
- **The Write tool decodes `\uXXXX` in a file's text** (it turned a JSON escape in a test into the letter itself:
  the "escape" case passed vacuously until the body's byte count gave it away). Write escapes through a script.
- **`Authorization: Bearer ` with nothing after it is no token**, not the token "Bearer".
- **Mosyle sends 50 rows a page whatever `page_size` asks** (abapit recorded `"page_size": 50`; it asked for 500 and
  stopped at the first short page, losing every row past 50). The client never stops on a short page.
- **A no-op `sleep` with the real clock makes `RateLimiter.acquire` spin** until real time refills the bucket (the
  first Mosyle tests took 12 s). Tests give the limiter a clock its sleep advances.
- **Assumed, check live (Phase 7 live check):**
  - **Every device column name in `specific_columns`** (the adapter's 33: abapit's `_FIELD_MAP` and `_DATE_MAP`
    sources, `os`, `device_type`). abapit read them from responses and never sent `specific_columns`; in particular
    whether both `CurrentConsoleManagedUser` and `currentconsolemanageduser` are accepted, and `os` and `device_type`
    as columns. Also whether `UNKNOWN_COLUMNS`'s `info` names the columns (the stub's does; the fallback works either
    way). `MosyleStub.deviceColumns` is the stub's guess at Mosyle's list, with `activation_bypass_mdm` (plan defect
    1) and `latitude`/`longitude` (plan §2.2).
  - **Each list's end-of-list status**, past the last row: `DEVICES_NOTFOUND` (abapit's recorded envelope) and
    `USERGROUP_NOTFOUND` (plan §3.5) have sources; `USERS_NOTFOUND`, `USER_NOTFOUND`, `USERGROUPS_NOTFOUND`,
    `DEVICEGROUPS_NOTFOUND` and `DEVICEGROUP_NOTFOUND` are guesses. An empty list also ends a walk; any other
    status is an error. A guess Mosyle doesn't send fails loudly; but a guess Mosyle sends for an error (say
    `USER_NOTFOUND` for a missing user, on a list) would read as the end, silently, so the guesses are as few as
    the shapes need, and the live check settles each.
  - **That nothing else ends a list**: an entry with no list and no end status, beside an `OK` or past page 1, is an
    error, as is a list key holding `null` or PHP's object-keyed array. No source shows Mosyle sends any of these; if
    a live list ends that way, its read fails loudly (live check 4) rather than dropping rows.
  - **What a 403 means**: a read logs in again once, as abapit did, and a second refusal is the error. If a live
    403 is always a permission, the extra login per refused read is the cost.
  - A login's 429 and 5xx: mapped from the status alone, as the client reads no login body.
  - The stub's 401 body (`{"error": …}`) and the login's success body (`{"status": "OK"}`): the client reads the
    status code and the header only, so another shape loses only detail.
  - `405 INVALID_METHOD` for a non-POST: plan §3.5 names the status; the body is the stub's choice.
  - Whether `rows` is the overall total or the page's count: the client doesn't rely on it; the page log line shows it.
  - Device groups answer with an object (`response.devicegroups`), as plan §3.5 says; users and user groups with
    the usual one-entry list.
  - The stub refuses a Logs Stream JWT on the business host and the reverse (its choice: two services, two logins).
- A tenant that ignores `page` would return the first page forever, and one that wraps past its end would serve its
  pages again: either way the walk stops at the first page that adds nothing new.

## Testing / live-verification status
- Offline: green (`MosyleTests`, `MosyleModelsTests`, the route scans); the mutants are in the Phase 7a PR.
- Live (operator, Phase 7): a login, the device count per platform against Mosyle's console, a 401 from an
  IP-restricted token reading as such, **the device list with every requested column and no `UNKNOWN_COLUMNS`
  fallback in the log**, and the assumptions above.

## To do common tasks here
- **The Logs Stream's drain (Phase 7b)** sends through a `.logs` `MosyleSession`'s `read(_:)`, which checks each
  request as it is sent (a computed `operation` in its body is caught there). The stub's Logs host already checks
  the Logs token and JWT, then leaves the read itself unhandled.
- **A new read**: add `path#operation` to `MosyleRead.allowed` (a read only: the route scan refuses an operation
  that isn't a read verb or names a change) and to `MosyleReadTests`' exact list, its end-of-list statuses to
  `MosyleRead.endOfList` if it is a list, a builder through `read(_:_:_:)`, a stub handler that fails as Mosyle
  does, a client method that returns its `truncated` flag, and a test per failure.
