# 2026-11-28 — A next link was decoded and re-encoded when `limit` was added

- **Symptom:** a review sent `https://api-business.apple.com/v1/mdmServers?cursor=abc%2Bdef%2Fghi%3D%3D` through
  `HTTPClient.read(next:)` with a kept limit of 1000. It went out as `...?cursor=abc+def/ghi%3D%3D&limit=1000`. No live read
  broke: Apple's documented cursors hold no `+` or `/`. The stub's own next link did the same to a filter value: a request
  for `filter[orderNumber]=A%2BB` got a next link with `A+B`, which a server reads as `A B`.
- **Cause:** `HTTPClient.swift` added `limit` through `URLComponents.queryItems`, which decodes every item and encodes it
  again on assignment (commit d8e072a, Phase 1a's review fix); `AppleStub.page` rebuilt the other parameters the same way.
- **Why not caught:** `AppleStub`'s cursors are integers and Apple's DocC examples are base64 of digits and colons, so no
  test had a cursor or a filter value whose bytes change when re-encoded.
- **Fix:** this PR. `limit` is percent-encoded and appended through `percentEncodedQueryItems`; the rest of the link is
  untouched. The stub keeps the request's other parameters byte for byte, as Apple's next link keeps them
  (`Tests/Fixtures/docc/business/get-org-devices.response.2.json`, `links.next`). `HTTPCoreTests.aNextLinkKeepsItsBytesWhenLimitIsAdded`
  and `AppleStubTests.aNextLinkKeepsTheRequestsEncodedFilters` each fail when their line is reverted.
- **Prevention:** those two tests, the first with a recording transport and not the stub. The stub's cursor format was left
  alone, because Apple's real cursor alphabet is not recorded (invariant 5). Not proven live. Open: a next link with
  literal `[` and `]` is re-encoded by `URL(string:)` in `AppleClient.walk` before it reaches HTTPCore; record a real next
  link in `live-verify` before changing that.
