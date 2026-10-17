# Domain: Apple reads

**One line:** every Apple Business/School read, decoded forward-compatibly over the raw JSON:API attributes
and checked against Apple's DocC contract (plan §3.3, Appendix A).

**Owns invariant(s):** #8 (truncation and forbidden sections said), #10 (forward-compatible decoding).

**Enforcement home:** `ModelContractTests` (each view reads exactly Apple's attributes; enums are Apple's
values; Apple's examples decode), `ReadContractTests` (every read is a documented endpoint, parameter and
`fields` value, for both scopes), `AppleClientTests` against the strict `AppleStub`, and `AppModelsTests`
(invariant 8's screen-model tests: org switches, superseded loads, panels, partial and unusable states, the
org editor's save).

## Files
- `Sources/JSONAPI/` — `JSONValue`/`JSONObject` (Python-faithful, ordered, exact text; from SwiftGamGui),
  `Document`/`Resource`/`Linkage`, `ErrorBody`, `OpenEnum`, `ISODate` (abapit's `parse_iso`, golden-held).
- `Sources/AppleModels/` — `OrgDevice`, `AppleCareCoverage`, `ActivationLockStatus`, `MDMService` as
  `ResourceView`s that keep the resource: the inspector shows every attribute, CSV keeps Apple's order,
  snapshots store what came. `unreadAttributes` feeds the acceptance pass.
- `Sources/AppleBusiness/` — `ClientAssertion`, `TokenBroker`, `AppleRead` (every read built here),
  `AppleClient` (pages as an `AsyncThrowingStream`, page cap 200 with `truncated` on the last page; read
  probes), `AppleAPIError` (status + Apple `code`, never prose), `AcceptancePass` (the DEBUG pass, plan §7).
- `Packages/AbapitApp/Sources/AppModels/` — the screen models the app's views sit on (`@MainActor`), in their own
  package so the compiler gives them AbapitKit's public API only, as it gives the app:
  `OrgsModel` (orgs, the active client, `onSwitch`, `save(_:key:editing:)`), `DevicesModel` (devices and
  services as separate panels, `LoadState`, `DeviceRow.Assignment`), `DeviceDetailModel` (the inspector).
- `Sources/TestSupport/AppleStub.swift` — the strict stub (plan §6.3).

## Gotchas / stub-lies traps
- **A cancelled `for try await` over an `AsyncThrowingStream` ends without throwing**, and can still be handed a
  page already in its buffer. A load checks its token after every page and every await, or a superseded load
  says "loaded" and records its rate on the next org (Phase 1b review H2; failure-log 2026-10-16, "the screen
  models had no tests"). An org switch clears every model through `OrgsModel.onSwitch`, not through a view.
- **What an await learned is saved for what it was read for**: a load records its rate for the org it captured,
  and only while its token holds; a permissions check passes the profile it probed (`record(_:probed:)`), and its
  results are dropped if the org was edited to another account meanwhile.
- **A device is "unassigned" only when every service's device list was read whole.** A 403 on `mdmServers`, one
  service's failing list or a list cut at the page cap makes the rest "Unknown", with a note; the devices still
  load (Phase 1b review M3).
- **Side-by-side panels say each other's state.** Devices can be loaded while the services are still read,
  refused or failed: a row not read yet shows "Reading…" (never blank, which reads as unassigned), `serviceNote`
  says the services are being read, and the Overview's "not assigned" and Services tiles and its health box show a
  dash or the reason (`unassignedCount`, `serviceCount`, `quietServices`, `servicesUnread`) unless the services and
  every service's device list were read whole. A services walk that fails part-way says "Partial: N" (verifier
  round 1: the split itself had made all of that silent). The device tiles, "not assigned" included, show a dash
  until the device list itself is read whole (`devicesReadWhole`: not loading, failed, refused or capped).
- **An edit writes only what its sheet changed** from the profile it opened (`OrgDraft.base`), so two sheets on one
  org keep each other's changes; the account's four fields go together, and always with a picked key, which
  belongs to the IDs it was picked with (verifier round 2).
- **A test that needs a window holds it, never races it**: `HeldStore.holdNextKey()` holds a save inside its
  Keychain write, `Stall` holds a client's limiter so a load waits in its rate read, `World.buffer` holds the main
  actor while a page or an error is answered. `Task.yield()` ordering isn't a window. Storing a key doesn't prompt
  (the prompt is on use), so a save's Keychain window is milliseconds live: an edit reserves its own id for it.
- **The screen models' boundary is the compiler's.** In AbapitKit they could see every `package` declaration, and
  a source scan held them off: verifier round 4 read `ImportedKey.key` through implicit `self` past it. In
  `Packages/AbapitApp` that read, `Secret.bytes` and `Vault.sign` are compile errors (checked by mutant at the
  merge); `scripts/check_graph.py` holds the package to AbapitKit's products and refuses `unsafeFlags`, and
  `BoundaryTests` keeps only what access control can't stop: reflection, raw memory, `@testable`. A test that
  needs a hook in AbapitKit gets a public, debug-only one (`MemoryStore.holdNextKey()`), not a wrapper store.
- **`fields[orgDevices]` can't name the MDM-migration attributes** (`isMdmMigrationCapable`,
  `mdmMigrationStatus`, `mdmMigrationDeadlineDateTime`), and the device table filters on them, so the device
  list asks for every attribute. The services list uses sparse fields.
- **Apple's own example says `purchaseSourceUid`; its field list says `purchaseSourceId`** (2.6). The view
  reads the documented name; the other survives raw, and the contract test pins it as the one gap.
- **Assumed, check live (Phase 1 live check):**
  - `GET orgDevices/{id}/relationships/assignedServer` for an unassigned device: the stub answers 404 as the
    full read does (abapit saw that live); the client takes 404 or `{"data": null}` alike.
  - The stub's error `code` strings (`FORBIDDEN_ERROR`, `NOT_FOUND`, `PARAMETER_ERROR.INVALID`): the contract
    documents the shape, not the values. The client classifies on status first, so a different code only
    loses detail.
  - The shape of `links.next`: Apple's example carries only `cursor`, and the stub now does the same (with
    `meta.paging.nextCursor`), so the client re-adds `limit`. The stub refuses any parameter an endpoint
    doesn't document, `cursor` included where it isn't, as Apple's contract says Apple does.
  - `meta.paging.total`: absent in Apple's example; the stub sends it only when a test asks.
- **Only a 404 or `"data": null` is unassigned.** A 403, a 500 or a malformed 200 (`{}`, `[]`, a linkage of
  another type) throws `.malformed` or its error: Phase 4's Guard re-validates assignments with this read.
- **A list page is a list.** A 2xx list page (a probe's too, and every later page) whose `data` isn't an array of
  resources (`{}`, `null`, one object, an item without `type` or `id`, an `errors` body with no `data` sent with
  200) is `.malformed("a page of <template>")`, never an empty page: read as one, the device list said "none" and
  the acceptance pass printed `ok, 0 items` (Phase 1b verifier round 1; the same shape as Phase 1a's malformed
  "unassigned"). The stub sends such a body with `queue(200, for:, body:)`. Not checked by the client: the items'
  `type`, a next link that leads to another collection on the same host, a single read's `type` and `id`, and
  `data` sent together with `errors` (`Document` keeps no `errors`). The acceptance pass checks the items' `type`
  and the single device's `id` for what it reads, so it catches a next link only into a collection of another type:
  one into another collection of the same type (one service's device list into another's, one device's coverage
  into another's, the device list into a service's `orgDevices` linkages) is followed and reads `ok` with that
  list's items counted too (verifier round 3). The lock's `id` isn't checked: only Apple's example makes it the
  serial.
- **A probe says what failed**: `forbidden`, `ok`, or `error <status>` (Settings' `probeReads` says a bare `error`
  when no HTTP status came back: offline, too large, the token or the Keychain); never `ok` for a failure
  (invariant 8).
- **The acceptance pass says `ok` only for a read that ran and fully succeeded** (Phase 1b review M5: a
  forbidden device list left five per-device lines `ok … 0`). Otherwise `forbidden`, `truncated` (the page cap
  cut a list, or the list it walks stopped short: the services' device lists say `covers only the N services
  mdmServers read`; the count is what was read), `skipped: <why>` (a read it needs failed or found nothing, or
  the pass was cancelled, so it isn't sent) or `error <status>`. The probes run as checks, so a probe's failure
  reads like a read's (`error transport -1005`, not a bare `error`). Every per-device read covers the whole
  sample, capped at `acceptanceSampleLimit` (20) whatever the caller asks. Its notes carry counts, where a loop
  stopped, Apple's `code` only when it is words of letters joined by `_` or `.`, `source.parameter` only when
  `Contracts/apple` documents it (`acceptanceParameters`, held to both contracts), the token endpoint's code,
  this app's words for a malformed answer and the Vault's guidance: never `detail` (it may echo an identifier),
  `AppleAPIError.message` (which quotes it), or anything shaped like an identifier (a digit, a `-`, a single
  word) or a name (mixed case, or lower-case joined by `.`). `AcceptancePassTests`, `AcceptanceFailureTests`.
- **What the pass reads is checked as it reads it** (Phase 1b verifier round 2): every item it walks or reads is the
  contract's type (`orgDevices`, `mdmServers`, the services' `orgDevices` linkages, `appleCareCoverage`,
  `activationLockStatus`) and a single device is the one asked for, byte for byte, else `error malformed · items of
  type …`; an id that can't go in a path is never sent and reads `error malformed · an id that can go in a path`, not
  Apple's 404; the unknown attribute names and enum values it reports are ASCII words (a letter, then letters, digits
  or `_`, at most 64 bytes), anything else `(not shown)`, so a newline can't forge a line; and a list cut at the cap
  before any item came gives what depends on it `skipped: … (<list> truncated)`, not "has none". Apple's text is
  tested as bytes and never split or compared as `Character`s: a combining mark joins the character before it, so a
  value led by U+0301 hid the `=` its field was found by and went into the text raw (verifier round 3).
- **A cancelled `for try await` over an `AsyncThrowingStream` ends without throwing.** The pass checks for
  cancellation after each check, so a walk cut short reads `error cancelled` and every later line `skipped: the
  pass was cancelled` (verifier round 1: it read `ok, 0 items`, and the per-device reads said the org had no
  device). Inside a check it checks before each device or service and after each list it walks, so the read in
  flight is the last one sent and the line names the item it stopped at: the stub, like any transport that ignores
  cancellation, answers a cancelled read, and a check cancelled at its first device sent all twenty (verifier
  round 2). `AppleClient.walk` checks before each page.
- **The stub's switches for these** (invariant 5): `queue(_:for:headers:body:)` sends a given body (a malformed
  200, bytes that aren't JSON, an `ErrorResponse` whose `code` or `parameter` is prose or a serial), and a `path`
  that goes on into the query (`/v1/orgDevices?cursor=`) fails a later page and not the first;
  `failNextToken(_:error:)` sets the OAuth `error`. Cancellation mid-walk is a test transport around the stub
  (`Interceptor`), since it is the caller's, not Apple's.
- **A Keychain refusal while signing is `AppleAPIError.vault(guidance)`** (Touch ID cancelled, a locked Mac,
  no key stored): nothing is sent, and the next read signs again. `MemoryStore.failNext(.sign, with:)` drives it.
- School has no people, content or audit endpoints: `AppleSection.businessOnly`, and the stub fails a School
  request for them as unhandled.

## Testing / live-verification status
- Offline: green. Live (operator, Phase 1): device count and a 20-serial sample against abapit; Activation
  Lock for 20 serials (rate); a forbidden section reading "your role can't read this".
