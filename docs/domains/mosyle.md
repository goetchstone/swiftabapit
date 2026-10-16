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
  end-of-list statuses; `isAllowed`, the check made again just before sending.
- `Sources/Mosyle/MosyleSession.swift`: the login, an `Authorizer`; `MosyleAPIError` and its words.
- `Sources/Mosyle/MosyleClient.swift`: devices per platform, users, groups, ping; paging, dedupe, the cap, the column
  fallback.
- `Sources/TestSupport/MosyleStub.swift`: the strict stub (Debug only), with its own device-column list.
- Tests: `MosyleModelsTests` (parity); `MosyleTests`: `MosyleClientTests` and `MosyleSessionTests` (the happy paths),
  `MosyleFailureTests` (every failure the client handles), `MosyleLoginTests` (the login's failures, single flight, the
  Logs Stream's login), `MosyleStubTests` (the stub's own strictness), `MosyleReadTests` (the allowlist as values, the
  check before sending, the builders' trap as an exit test, the login's redaction); `RouteTests`
  (`everyMosyleReadIsOnTheAllowlist`, `nothingElseExtendsOrRenamesReadRequest`, the request and exchange makers).

## How it works
- **Login**: `POST /v1/login`, header `accessToken`, body `{email, password}`; the JWT comes back in the response's
  `Authorization` header. Every other request sends both `accessToken` and `Authorization: Bearer <jwt>`. The JWT's
  `exp` sets its life (at most 23 h; none, unreadable, or at or before now: 23 h), renewed 60 s early, or halfway
  through a life shorter than 2 min; PHP's fixed 1981 `Expires` header is ignored. One login at a time per org; a 401
  logs in again once, through `invalidate(rejected:)`, so a late 401 for an older JWT keeps the new one. A 403 is
  `.forbidden` and isn't logged in again (plan §3.5 re-logs on 401; abapit re-logged on 403 too: a recorded
  deviation, Phase 7a review L5). A login answering 429 is `.rateLimited`, a 5xx `.server`, a 2xx without a token
  `.noToken`; only another refusal is `.login(status:)`, the one that names the credentials. A login is never
  retried. The Logs Stream logs in on its own host with its own token (`Service.logs`).
- **Reads are POSTs**, so the method can't tell a read from a write. A read is a `(path, operation)` on
  `MosyleRead.allowed`, and only `MosyleRead` builds one (`precondition`, held by an exit test, plus the source
  scans). The client checks each request again as it will be sent (`MosyleRead.isAllowed`: a POST, no query, the
  body exactly as the builders serialize it, its `path#operation` on the list, the path's own host), so a
  `ReadRequest` made anywhere else in the package can't carry a write (`.notARead`, nothing sent). Anything else
  Mosyle offers is a write, for ChangeCore in Phase 8.
- **The envelope**: the entry's `status` is the operation's (`response[0].status`, or `response.status` where
  `response` is an object); the top-level `"status": "OK"` comes on errors too. A list read accepts no status or
  `OK`, ends on **its own** end-of-list status (`MosyleRead.endOfList`), and fails on any other, **an unknown one
  included** (defect 3: abapit read them as empty lists).
- **A malformed 200 is never an empty list** (Phase 7a review H2): no `response`, a string `response`, an empty
  list, a first entry that isn't an object, a status that isn't a string, a row that isn't an object, or a first page
  with neither a status nor a list is `.malformed`. Past page 1, an entry with neither is the end of the list. The
  ping says "ok" only for `OK`, `DEVICES_NOTFOUND` or a `devices` list.
- **Devices**: one platform at a time (`ios`, `mac`, `tvos`, `visionos`; `os` is required), `specific_columns` =
  the adapter's sources (defect 1: the bypass codes are never asked for, and the adapter drops them if sent),
  deduplicated by abapit's key (the first truthy of serial and UDID, a number as well as a string).
- **The column fallback** (Phase 7a review H3): no source confirms any of the 33 names as a `specific_columns` name
  (abapit sent only `os` and `page`), and one wrong name would fail every device list. On `UNKNOWN_COLUMNS` the
  client asks again without the columns Mosyle's `info` names, the first time; else, or on a second refusal, without
  `specific_columns`, so only the adapter's allowlist keeps the bypass codes out (as it did for abapit); a third
  refusal is the error. Each step is an error-level log line and `MosyleClient.columnFallback`, for a screen to show.
  Failing closed was rejected: it trades a whole lost list for codes the adapter drops anyway.
- **Paging**: from page 1 until the list's own end-of-list status, an empty page, a page that adds nothing new (users
  and groups are deduplicated by id, or by the whole row without one: a tenant that wraps past its end served 60
  users as 6000, review L2), or the cap (200 pages). Rows on the cap's page mark the result `truncated` (a full last
  page at the cap may in fact be the end: the mark means "may be incomplete"), and every list returns it; in the
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

## Gotchas / stub-lies traps
- **`Duration.seconds` traps past about 1.7e20.** A JWT `exp` is clamped as a number before it becomes a `Duration`
  (`exp: 1e300` or `1e999` is the 23 h fallback; so is a past one, which as a zero life logged in for every read).
- **A flat refresh margin is a login per read for a short JWT**: a 45 s JWT was inside the 60 s margin from birth.
  The margin is `min(60 s, lifetime / 2)`.
- **The stub's columns must not come from the client.** Derived from the adapter, `UNKNOWN_COLUMNS` could never fire
  and a misspelt column was green. `MosyleStub.deviceColumns` is written out, with its sources.
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
    status is an error, so a wrong guess fails loudly, not silently.
  - **What a 403 means**: the client doesn't log in again (abapit did). If a live 403 turns out to mean an expired
    login, log in again on 403 as on 401.
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
- **A new read**: add `path#operation` to `MosyleRead.allowed` (a read only: the route scan refuses an operation
  that isn't a read verb or names a change) and to `MosyleReadTests`' exact list, its end-of-list statuses to
  `MosyleRead.endOfList` if it is a list, a builder through `read(_:_:_:)`, a stub handler that fails as Mosyle
  does, a client method that returns its `truncated` flag, and a test per failure.
