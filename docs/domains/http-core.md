# Domain: HTTP core

**One line:** outbound HTTPS to five allowlisted hosts through one transport, with an adaptive per-credential
rate limiter, bounded retries and progressive paging (plan §3.3).

**Owns invariant(s):** #2 (reads by type), #4 (no listener, host allowlist), #7 (bounded), #8 (never silent).

**Enforcement home:** `APIHost` (the allowlist, an enum), `ReadRequest`/`AuthRequest` `package` inits,
`RouteTests` (only `Transport.swift` names `URLSession`; only the read builders make a read; only the token
broker makes a credential exchange), `HTTPCoreTests`, `scripts/check_app.sh` (no listener symbol). How the scans
and the gate read code, and how they failed: [gates.md](gates.md).

## Files
- `Sources/Wire/APIHost.swift` — the five hosts; `APIHost(of:)` accepts only `https`, no user, password or port.
- `Sources/Wire/Requests.swift` — `ReadRequest` (method, path, path template for logs, ordered query, Mosyle
  body), `AuthRequest` (a credential exchange), `URL.make` (names and values percent-encoded except
  unreserved: `fields%5BorgDevices%5D`, as abapit's httpx sent it).
- `Sources/HTTPCore/Transport.swift` — `Transport` and `URLSessionTransport`: ephemeral, no cookies, cache or
  credential storage, TLS ≥ 1.2, bodies capped at 32 MiB while they stream in, redirects followed only to the
  same allowlisted host.
- `Sources/HTTPCore/HTTPClient.swift` — reads (retry transport failures ×4 with backoff; 429 → `Retry-After`
  seconds or HTTP date, else 2^n s, capped 60 s, and the limiter halves; 401 → `invalidate()` and one retry;
  any other status returned as is), credential exchanges (never retried), next-page links (same host, `/v1/`
  only). Logs method, host, path template, status and latency; never a header, body or identifier.
- `Sources/HTTPCore/RateLimiter.swift` — token buckets per lane: reads 20/min burst 10 to start, floor 2/min,
  ceiling 600/min; writes 10/hour burst 3. Halves on 429; +10% per 20 successes.

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
  cap would cover a tenth of a large fleet. Check live.
- A rate read from `orgs.json` that isn't finite is the default: a NaN rate never waits.
- An ID typed into Find goes into a path: `AppleRead.isPathSafe` refuses anything but `[A-Za-z0-9._-]`, not
  starting with `.`, at most 128 characters, before a request exists.

## Testing / live-verification status
- Offline: `HTTPCoreTests`, `AppleClientTests`, `AppleClientFailureTests` (transport failures, a revoked
  account, a body over the cap, short and expiring tokens: all through the strict stub). Live (Phase 1, operator): the real read rate and
  whether 429 carries `Retry-After`.
