# Domain: HTTP core

**One line:** outbound HTTPS to five allowlisted hosts through one transport, with an adaptive per-credential
rate limiter, bounded retries and progressive paging (plan §3.3).

**Owns invariant(s):** #2 (reads by type), #4 (no listener, host allowlist), #7 (bounded), #8 (never silent).

**Enforcement home:** `APIHost` (the allowlist, an enum), `ReadRequest`/`AuthRequest` `package` inits,
`RouteTests` (only `Transport.swift` names `URLSession`; only the read builders make a read; only the token
broker makes a credential exchange), `HTTPCoreTests`, `scripts/check_app.sh` (no listener symbol).

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
- An ID typed into Find goes into a path: `AppleRead.isPathSafe` refuses anything but `[A-Za-z0-9._-]`, not
  starting with `.`, at most 128 characters, before a request exists.

## Testing / live-verification status
- Offline: `HTTPCoreTests`, `AppleClientTests` (strict stub). Live (Phase 1, operator): the real read rate and
  whether 429 carries `Retry-After`.
