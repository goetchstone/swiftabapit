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
- **A device is "unassigned" only when every service's device list was read whole.** A 403 on `mdmServers`, one
  service's failing list or a list cut at the page cap makes the rest "Unknown", with a note; the devices still
  load (Phase 1b review M3).
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
