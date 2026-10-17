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
  probes), `AppleAPIError` (status + Apple `code`, never prose).
- `Sources/AppModels/` — the screen models the app's views sit on (`@MainActor`, public API only):
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
- **The boundary scan reads interpolations as code** (`BoundaryTests.code`): `"\(vault.secret(item))"` and a raw
  string's `\#( … )` are uses; literal text, comments and `#/…/#` regex literals are not. It follows raw
  identifiers (`` `a"b` `` is one name, `` .`key` `` is `.key`), a `\` inside `#/…/#` and a lone CR ending a line,
  and refuses what it doesn't follow: a `/` other than spaced division, which a bare `/…/` regex literal needs, in
  the screen models and every module they reach (verifier round 2: `/"""/` hid every line after it). Its routes are
  held to the declarations: every `package` declaration in a module AppModels reaches (from Package.swift) is a
  route or sits in a route type, so a new `package` API is a reviewed addition to `BoundaryTests.routes`.
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
- **A probe says what failed**: `forbidden`, `ok`, or `error <status>`; never `ok` for a failure (invariant 8).
- School has no people, content or audit endpoints: `AppleSection.businessOnly`, and the stub fails a School
  request for them as unhandled.

## Testing / live-verification status
- Offline: green. Live (operator, Phase 1): device count and a 20-serial sample against abapit; Activation
  Lock for 20 serials (rate); a forbidden section reading "your role can't read this".
