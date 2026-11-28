# Domain: HTTP core

**One line:** outbound HTTPS to five allowlisted hosts through one transport, with an adaptive per-credential
rate limiter, bounded retries and progressive paging (plan §3.3).

**Owns invariant(s):** #2 (reads by type), #4 (no listener, host allowlist), #7 (bounded), #8 (never silent).

**Enforcement home:** `APIHost` (the allowlist, an enum), `ReadRequest`/`AuthRequest` `package` inits,
`RouteTests` (only `Transport.swift` names `URLSession`; only the read builders make a read; only the token
broker makes a credential exchange), `HTTPClient`'s check of each request as it leaves (`isReadShaped`, `logins`; `HTTPCoreTests`), `scripts/check_app.sh` (no listener symbol). How the scans
and the gate read code, and how they failed: [gates.md](gates.md).

## Files
- `Sources/Wire/APIHost.swift` — the five hosts; `APIHost(of:)` accepts only `https`, no user, password or port.
- `Sources/Wire/Requests.swift` — `ReadRequest` (method, path, path template for logs, ordered query, Mosyle
  body), `AuthRequest` (a credential exchange), `URL.make` (names and values percent-encoded except
  unreserved: `fields%5BorgDevices%5D`, as abapit's httpx sent it).
- `Sources/HTTPCore/Transport.swift` — `Transport` and `URLSessionTransport`: ephemeral, no cookies, cache or
  credential storage, TLS ≥ 1.2, bodies capped at 32 MiB while they stream in, a host off the allowlist
  refused before connecting, and no redirect followed.
- `Sources/HTTPCore/HTTPClient.swift` — reads (retry transport failures ×4 with backoff; 429 → `Retry-After`
  seconds or HTTP date, else 2^n s, capped 60 s, and the limiter halves, a `Retry-After` holding its read lane that long
  for every read waiting on it; 401 → `invalidate()` and one retry;
  any other status returned as is), credential exchanges (never retried), next-page links (same host, `/v1/`
  only). Logs method, host, path template, status and latency; never a header, body or identifier.
- `Sources/HTTPCore/RateLimiter.swift` — token buckets per lane: reads 20/min burst 10 to start, floor 2/min,
  ceiling 600/min; writes 10/hour burst 3. Halves once per throttle event; +10% per 20 successes. `throttled(_:retryAfter:)`
  (Phase 3, the sweeps): with the server's `Retry-After` (Apple's or Mosyle's), the bucket goes negative so that no token is
  given before it has passed, or before one token's time at the halved rate, whichever is later (`heldUntil`). **The minute is
  per 429, not per throttle event**: each `Retry-After` is capped at `longestHold` (a minute, whoever asks), counted from that
  429's answer, and a 429 inside a hold may extend it. So reads already in flight can carry a hold past a minute: at worst the
  slowest in-flight answer's time plus 60 s. Chained 429s (a refused read's retries refused again inside the hold, up to
  `HTTPClient.attempts`, five) can reach about five minutes. A sweep has four reads in flight; without the hold only the refused read waited, and the
  other three went on at the halved rate inside the server's window (`aRetryAfterHoldsTheLaneForEveryRead`,
  `the429sRetryAfterReachesTheLimiter`). The refused read's own wait refills the bucket by the same amount, so it doesn't wait
  twice. **One throttle event, one halving** (review of PR #37, M1): a 429 before `heldUntil` is the same event (the reads in
  flight were sent before the first answer). It extends the hold to its own `Retry-After` if that ends later, never shortens
  it, and doesn't halve again: four refused at once took 600 a minute to 37.5, and the sweep saved that. A credential
  exchange's 429 (no `Retry-After` read) inside a hold leaves it as it is (L1); outside one it halves, as before
  (`fourReadsRefusedAtOnceHalveTheRateOnce`, `aLater429ExtendsTheHoldAndNeverShortensIt`, `aTokenExchange429KeepsTheHold`,
  `aHoldIsAtMostAMinute`, `everyRetryAfterHoldIsBounded`). `1e400` and `inf` read as infinity, not a delay this reads (as
  `garbage` isn't): no hold past a token's time. A hold is the read lane's alone (`theWriteLaneIsNotHeld`), and a read waiting
  it out leaves at once when cancelled (`aCancelledWaiterLeavesAtOnce`).

## Gotchas
- **Foundation's `Host` and the ObjC runtime's `Method` shadow plain names**: the types are `APIHost` and
  `HTTPMethod`.
- **Swift 6.4 crashes compiling the async form of `urlSession(_:task:willPerformHTTPRedirection:newRequest:)`**
  in a class with `NonisolatedNonsendingByDefault` (SILGen, `emitNativeToForeignThunk`). The completion-handler
  form compiles. Recheck on the next toolchain.
- **`Duration.seconds(Double)` traps past about 1.7e20 seconds.** A server's `Retry-After` is clamped as a
  number before it becomes a `Duration` (Phase 1a review H1: a 22-digit value crashed the app). Any wait or
  lifetime taken from a response goes through the same clamp.
- **A late 401 must not drop a newer token.** `Authorizer.invalidate(rejected:)` gets the headers the refused
  request carried; the broker drops its token only if they match. One expiry, one mint, however many reads
  were in flight.
- **A next link is checked after decoding**: a segment that decodes to `.` or `..` or holds a `/` is refused
  (`.%2e` got past a list of spellings). Foundation re-encodes a bad escape (`%zz` becomes `%25zz`), so that
  case is a literal, not a bypass.
- **Apple's next link carries only `cursor`.** The client re-adds the first page's `limit`, or the 200-page
  cap would cover a tenth of a large fleet. Check live. `limit` is appended to the link's percent-encoded query and the rest goes
  out byte for byte (`queryItems` re-encoded it: `%2B` went out as `+`, failure-log 2026-11-28); the encoded setter traps on a value
  that isn't percent-encoded, so `limit` is encoded first. Check live: the cursor's alphabet, and whether a next link has literal
  `[` and `]` (`URL(string:)` re-encodes such a link before HTTPCore sees it). The stub's own next link keeps the request's other
  parameters byte for byte too (`aNextLinkKeepsTheRequestsEncodedFilters`).
- **No redirect is followed.** The operator, 2026-11-28: refuse every redirect, as the Python app did (httpx's default). The
  delegate hands back nil, so the 3xx answer reaches the caller, who says "answered HTTP 307 (a redirect), which this app doesn't
  follow". A 307 or 308 would replay a body to a path nothing previewed: a credential exchange, a Mosyle read, later a held write.
  Whether Apple or Mosyle ever redirect: check live. `HTTPClient.staysInTheAPI` is the next-link rule only; it refuses a
  dot segment in any spelling and a `;` in a segment (`/v1/..;/v2`).
- A rate read from `orgs.json` that isn't finite is the default: a NaN rate never waits.
- An ID typed into Find goes into a path: `AppleRead.isPathSafe` refuses anything but `[A-Za-z0-9._-]`, not
  starting with `.`, at most 128 characters, before a request exists.
- **A request is checked as it leaves, not only where it is built.** `HTTPClient.read` refuses anything that isn't
  read-shaped (an Apple GET with no body; a Mosyle POST with a body and no query; nothing to the token host), and
  `authenticate` anything but the three logins, with no header beyond Mosyle's `accessToken`, and that only to a Mosyle host (`HTTPFailure.notARead`). A
  `method: .delete` built in `AppleRead.swift` passed every source scan (failure-log 2026-11-18). Phase 4's write door is
  a method of its own; it does not loosen these two.

## Testing / live-verification status
- Offline: `HTTPCoreTests`, `AppleClientTests`, `AppleClientFailureTests` (transport failures, a revoked
  account, a body over the cap, short and expiring tokens: all through the strict stub). Live (Phase 1, operator): the real read rate and
  whether 429 carries `Retry-After`.
- `URLSessionTransport` itself runs in no test: every suite sends through a stub `Transport`, and the oversized-body
  tests run the stubs' own cap, which imitates the transport's. Its redirect delegate, its body cap and its session
  settings are held as text by `SourceScanTests`' `TransportShapeTests` (failure-log 2026-11-18, "the transport's
  protections were held by no test"); `HTTPCoreTests.noRedirectIsFollowed` calls the delegate method on a task never resumed, not its wiring (`delegate: self`). Live (Phase 1, operator):
  that a redirect off the host is refused on the wire.
