# 2026-11-28 — The transport trusted its caller for the allowlist, and followed a redirect for any method

- **Symptom:** a review found that `URLSessionTransport().send` for `https://host.invalid/v1/x` tried to resolve the name,
  and that the redirect delegate followed a same-host redirect for a POST, and for a GET to `/v2/x` and `/v1/../v2/x`.
  Nothing reached it: only `HTTPClient` calls `send`, and no write exists yet.
- **Cause:** the allowlist check sat in `HTTPClient.exchange` only, with `send`'s callers held by name scans; `followable`
  compared the two hosts and nothing else (commit c23c964, Phase 1a).
- **Why not caught:** `HTTPCoreTests` tested the static `followable` for hosts only. No test called the transport or its
  delegate, and the `/v1/` rule was tested for next links only.
- **Fix:** this PR. `send` refuses a host off the allowlist before connecting; a redirect is followed only for a GET, to the
  same allowlisted host, where a next link may go (`HTTPClient.staysInTheAPI`, one rule for both). Narrowing redirects is a
  proposal the operator decides; the alternative is to refuse every redirect, as the Python app's httpx did.
- **Prevention:** `theTransportRefusesAHostOffTheAllowlist` and `onlyAGETFollowsARedirectAndOnlyInsideTheAPI`; the second
  calls the delegate itself, with a task that is never resumed. Not proven over a socket or live: whether Apple or Mosyle
  ever redirect is unknown. Phase 4's write send must keep "a write never follows a redirect".
