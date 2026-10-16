# Domain: Apple reads

**One line:** every Apple Business/School read, decoded forward-compatibly over the raw JSON:API attributes
and checked against Apple's DocC contract (plan §3.3, Appendix A).

**Owns invariant(s):** #8 (truncation and forbidden sections said), #10 (forward-compatible decoding).

**Enforcement home:** `ModelContractTests` (each view reads exactly Apple's attributes; enums are Apple's
values; Apple's examples decode), `ReadContractTests` (every read is a documented endpoint, parameter and
`fields` value, for both scopes), `AppleClientTests` against the strict `AppleStub`.

## Files
- `Sources/JSONAPI/` — `JSONValue`/`JSONObject` (Python-faithful, ordered, exact text; from SwiftGamGui),
  `Document`/`Resource`/`Linkage`, `ErrorBody`, `OpenEnum`, `ISODate` (abapit's `parse_iso`, golden-held).
- `Sources/AppleModels/` — `OrgDevice`, `AppleCareCoverage`, `ActivationLockStatus`, `MDMService` as
  `ResourceView`s that keep the resource: the inspector shows every attribute, CSV keeps Apple's order,
  snapshots store what came. `unreadAttributes` feeds the acceptance pass.
- `Sources/AppleBusiness/` — `ClientAssertion`, `TokenBroker`, `AppleRead` (every read built here),
  `AppleClient` (pages as an `AsyncThrowingStream`, page cap 200 with `truncated` on the last page; read
  probes), `AppleAPIError` (status + Apple `code`, never prose), `AcceptancePass` (the DEBUG pass, plan §7).
- `Sources/TestSupport/AppleStub.swift` — the strict stub (plan §6.3).

## Gotchas / stub-lies traps
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
- **The acceptance pass says `ok` only for a read that ran and fully succeeded** (Phase 1b review M5: a
  forbidden device list left five per-device lines `ok … 0`). Otherwise `forbidden`, `truncated` (the page cap
  cut a list; the count is what was read), `skipped: <why>` (a read it needs failed or found nothing, so it
  isn't sent) or `error <status>`. Every per-device read covers the whole sample, capped at
  `acceptanceSampleLimit` (20) whatever the caller asks. Its notes carry counts and Apple's `code` only, never
  `detail` (it may echo an identifier) or `AppleAPIError.message` (which quotes it). `AcceptancePassTests`.
- **A Keychain refusal while signing is `AppleAPIError.vault(guidance)`** (Touch ID cancelled, a locked Mac,
  no key stored): nothing is sent, and the next read signs again. `MemoryStore.failNext(.sign, with:)` drives it.
- School has no people, content or audit endpoints: `AppleSection.businessOnly`, and the stub fails a School
  request for them as unhandled.

## Testing / live-verification status
- Offline: green. Live (operator, Phase 1): device count and a 20-serial sample against abapit; Activation
  Lock for 20 serials (rate); a forbidden section reading "your role can't read this".
