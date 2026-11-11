# Domain: Apple reads

**One line:** every Apple Business/School read, decoded forward-compatibly over the raw JSON:API attributes
and checked against Apple's DocC contract (plan §3.3, Appendix A).

**Owns invariant(s):** #8 (truncation and forbidden sections said), #10 (forward-compatible decoding).

**Enforcement home:** `ModelContractTests` (each view reads exactly Apple's attributes; enums are Apple's
values; Apple's examples decode), `ReadContractTests` (every read is a documented endpoint, parameter and
`fields` value, for both scopes; the Business-only reads are exactly what School's contract lacks), `AppleClientTests`,
`BusinessReadTests`, `BlueprintTests`, `AuditTests`, `DeviceFilterTests` and `WebhookReadTests` against the strict
`AppleStub`, `WebhookTests` (what a webhook, a delivery and an event show and withhold), `AppleStubTests` (the stub's own
parameter table, and what the contract says only in prose, are the contract's, and it names nothing of the client's), and
`AppModelsTests`
(invariant 8's screen-model tests: org switches, superseded loads, panels, partial and unusable states, the
org editor's save).

## Files
- `Sources/JSONAPI/` — `JSONValue`/`JSONObject` (Python-faithful, ordered, exact text; from SwiftGamGui),
  `Document`/`Resource`/`Linkage`, `ErrorBody`, `OpenEnum`, `ISODate` (abapit's `parse_iso`, golden-held).
- `Sources/AppleModels/` — `OrgDevice`, `AppleCareCoverage`, `ActivationLockStatus`, `MDMService`, and for Phase 2
  `User`, `UserGroup`, `OrganizationalUnit`, `ContentApp`, `ContentPackage`, `Blueprint` (`included`; `related` at `package`),
  `Configuration` and `CustomSettingsValues`, `MDMDevice`, `MDMDeviceDetail`, `AuditEvent` and `AuditEventPayload`
  (`AuditEventType.payload` holds the 50-row table), as `ResourceView`s that keep the resource: the inspector shows
  every attribute, CSV keeps Apple's order, snapshots store what came. `unreadAttributes` (and an audit payload's
  `unreadFields`) feed the acceptance pass. `ProfileText` shows a custom setting's profile with its secrets masked;
  `Configuration` and `CustomSettingsValues` hand out the profile withheld and keep it as it came at `package` access.
  `Webhooks.swift` (Business 2.8): `Webhook`, `WebhookDelivery` (with `WebhookDeliveryRequest` and `…Response`) and
  `WebhookEvent`, whose `payload` string is read as `WebhookPayload` (`WebhookPayloadType`, from Apple's guide); a webhook
  and a delivery hand out their URL as `WebhookURL.shown` (its destination and a tag), a delivery the URLs in its
  `errorMessage` too, and withhold every attribute they don't read (below, "Webhooks"), keeping what Apple sent as
  `asSent`, `package`. `URLTag.swift`: the tag's HMAC-SHA256 (`TagHash`), written out since this module is pure.
  `Sections.swift`: `AppleSection.businessOnly`.
- `Sources/AppleBusiness/` — `ClientAssertion`, `TokenBroker`, `AppleRead` (every read built here; the Business-only
  builders take no scope; `AuditQuery`, the audit read's checked range and filters; `DeviceFilter`, the device list's;
  `WebhookDeliveryQuery`, a webhook's deliveries'), `AppleClient` (pages as an
  `AsyncThrowingStream`, page cap 200 with `truncated` on the last page; member lists as linkage streams; read
  probes; `BlueprintRead`, a blueprint with its `members`, read or refused), `AppleAPIError` (status +
  Apple `code`, never prose; `.notInScope(section)` for a Business-only read asked of a School org), `AcceptancePass`
  (the DEBUG pass, plan §7: Phase 1's eight lines, then 28 for the Business-only reads, the webhooks' three among them,
  then the probes).
- `Packages/AbapitApp/Sources/AppModels/` — the screen models the app's views sit on (`@MainActor`), in their own
  package so the compiler gives them AbapitKit's public API only, as it gives the app:
  `OrgsModel` (orgs, the active client, `onSwitch`, `save(_:key:editing:)`), `DevicesModel` (devices and
  services as separate panels, `LoadState`, `DeviceRow.Assignment`), `DeviceDetailModel` (the inspector); Phase 2b's
  `PeopleModel`, `ContentModel`, `AppleMDMModel`, `ActivityModel` and `DashboardModel` (over `DevicesModel`'s read),
  `Navigation.swift` (`SidebarItem`: each section's reads, when the recorded probes lock it, and which sections a School org
  hides), `ScreenModels` (every screen model over one `OrgsModel`, and each section's Refresh) and `ScreenWords` (what every
  screen says alike).
- `Sources/TestSupport/AppleStub.swift` — the strict stub (plan §6.3): `parameters` (every GET's query parameters and
  allowed values, written out from the contract) and `paged`; `add(_:)`, `relate(_:_:_:to:)`, `setDetails(_:_:)` for the
  Business-only collections; `refuseIncludes(with:)` and `repeatCursors(on:)`. `DemoOrg.make()` loads the demo fleet,
  then `DemoPeople`, `DemoContent`, `DemoAppleMDM` and `DemoAudit` into the stub (`DemoOrg.load(into:)`; DEBUG only,
  invented data).

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
- **A test that needs a window holds it, never races it**: `MemoryStore.holdNextKey()` holds a save inside its
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
- **Apple's device examples said `purchaseSourceUid` where its field list says `purchaseSourceId`** until 2.7 fixed
  them. The view always read the documented name; `ModelContractTests.knownUnread` is empty now, so a gap that comes back
  fails the example test until it is listed with its reason.
- **Assumed, check live (Phase 1 live check):**
  - `GET orgDevices/{id}/relationships/assignedServer` for an unassigned device: the stub answers 404 as the
    full read does (abapit saw that live); the client takes 404 or `{"data": null}` alike.
  - The stub's error `code` strings (`FORBIDDEN_ERROR`, `NOT_FOUND`, `PARAMETER_ERROR.INVALID`): the contract
    documents the shape, not the values. The client classifies on status first, so a different code only
    loses detail.
  - The shape of `links.next`: Apple's example carries only `cursor`, and the stub now does the same (with
    `meta.paging.nextCursor`), so the client re-adds `limit`. The stub refuses any parameter an endpoint
    doesn't document, `cursor` included where it isn't, as Apple's contract says Apple does. Since 2.7 the device list
    pages by cursor and follows no next link; Apple's filtered example's next link carries the filters, its unfiltered
    one the cursor alone.
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
- **A School org's sidebar hides what it can't read** (plan §4): `SidebarItem.shown(for:)` drops a section when every read
  it shows is Business-only (Apple MDM, People, Content, Activity), only for a known School scope of an Apple org; the
  Overview stays (its audit panel says not in scope), and no org or an unknown scope hides nothing, since each screen says
  why it can't read. `showing(_:for:)` puts the Overview on screen for a hidden section. A screen model still maps
  `.notInScope` to `LoadState.notInScope` (`LoadState(after:)`), never to an empty table (`NavigationTests`, `ScaffoldTests`).
- **A section locks only when the recorded probes refused every read it shows** (`SidebarItem.isLocked(for:)`, over
  `reads`; Phase 2b review M1). One probe per section (users for People, apps for Content) locked the whole screen, though
  the models show the groups beside refused users and the blueprints beside refused apps: a partly refused section shows
  its screen, each refused panel saying so in its own `.forbidden`. A read with no probe result on record (an older check,
  or a School org's Business-only reads, which aren't probed) isn't refused, and neither is an `error …` status. The
  Overview locks only when its devices, services and audit log were all refused (`aPartlyDeniedSectionIsUnlocked`,
  `aReadNoProbeRecordedDoesntLock`). Each read of a section is refused alone, and left readable alone, in
  `aSectionOfSeveralReadsLocksOnNoOneOfThem` (verifier round 1, mutant N-lockLastOnly: every partly refused case had its
  last read readable, so a lock on the last read passed). The locked screen's sentence is `SidebarItem.lockedNote`, a
  locked Overview's naming its three reads (it read "can't read overview.", written in the view before the Overview could
  lock).
- **School has no people, content, Apple MDM, audit or webhook endpoints** (plan §2.4): `AppleSection.businessOnly`, and
  for the webhooks, which are no section yet, `AppleAPIError.webhooksNotInScope` in the same words. Their
  builders take no scope and build for the Business host only; `AppleClient` throws `.notInScope(section)` before
  anything is built, so a School org sends nothing, not even a token request (and its broker would refuse the
  Business host anyway: `.wrongHost`). The stub fails a School request for them as unhandled, and
  `theBusinessOnlyReadsAreWhatSchoolLacks` holds the gate to the two contracts. The acceptance pass gives a School org
  each of those lines as `skipped: not in Apple School Manager's API`.
- **The blueprint include fallback** (abapit `client.py` `blueprint`): Apple refuses the whole blueprint read when the
  role can't read one of the included relationships (abapit saw a role that gets 403 on users and user groups get a
  400 here). `blueprint(_:include:)` reads once more without the include on a 400 or a 403, and only when something
  was included; any other status, a 400 with nothing included, and a failure of the second read are thrown. The
  answer's `members` is `.refused(error)`, which holds no members, so no count can be taken from it (Phase 2a review
  L5: an empty `related` beside a separate flag read 0); `.read(related:included:)` holds them. The acceptance pass's
  line is the refusal's status (`error 400`, `forbidden`), never `ok` (invariant 8). An include asks each relationship at
  `limit[<name>]=1000` (Apple's maximum); a relationship that limit cut is `Related.isTruncated`, one Apple didn't
  list is absent from `related`, and the pass says both as `truncated`, the unlisted one's count a dash, never 0.
  `Blueprint.related(_:)` is `package`: after a refusal it reads nil, as for a relationship Apple didn't list, so the app
  counts members only through `members` (verifier round 3 of the fixes: `related(.users)?.linkages.count ?? 0` read a
  refusal as no members). A
  member list the page cap cut is `truncated` on its own line, each of the nine (`everyMemberListCutAtThePageCapIsTruncated`).
  An included relationship whose `data` isn't a
  list of linkages of its own type is `.malformed("the blueprint's <name>")`. The stub's default without
  `limit[<name>]` is 10 (an assumption, small on purpose).
- **Apple MDM posture is `mdmDevices/{id}/details`**, the documented read; abapit called the undocumented
  `mdmDevices/{id}` (plan §2.3, defect 11). The stub has no route for it, so a read of it fails the test. The pass
  doesn't hold the details' `id` to the device's: neither is documented.
- **The device list pages by cursor** (2.7, both scopes), as the audit log does (below): each next page is the first read
  again with Apple's `meta.paging.nextCursor` (or the `cursor` its next link carries), so a filter goes with every page.
  Apple's filtered example's next link carries the filters and the cursor, its unfiltered one the cursor alone: a next
  link that dropped them, followed, would widen the list past the filter with nothing said. A next page with no cursor
  is malformed. The stub's next link carries the cursor alone, stricter than Apple's filtered example, so a client that
  followed it would get the unfiltered list and fail (`aFilteredListKeepsItsFilterOnEveryPage`).
- **Apple filters the device list, the client doesn't** (`DeviceFilter`, Business 2.7 and School 1.8): checked when made,
  as `AuditQuery` is. `filter[serialNumber]` and `filter[orderNumber]` take identifiers of `isPathSafe`'s shape, so a
  comma (a second value) or anything else that would steer the query is refused; `filter[status]`, `[productFamily]` and
  `[purchaseSourceType]` take `DeviceStatus`, `ProductFamily` and `PurchaseSourceType`, the values their descriptions
  list (`ModelContractTests` reads the text), an `.unknown` one refused; each list's values once, in the order given.
  At most 100 serial numbers and 100 order numbers, each counted once (`DeviceFilter.maximumIdentifiers`; one more is
  `.tooMany`, in words): Apple documents no limit, and a long list is a long URL (the contract-2.8 review's L6; check live).
  `filter[addedToOrgDateTime]` and `filter[orderDateTime]` are each a `DateFilter`: exact instants, one lower bound
  (`[GT]` or `[GTE]`) and one upper (`[LT]` or `[LTE]`), so two lower bounds can't be asked. Every date is cut to whole
  seconds, UTC, `Z` (Apple's descriptions show `2025-01-01T00:00:00Z`), 1970 to 9999. Bounds no device could fall between
  (a lower past the upper, or at it while either leaves that instant out) and an exact instant its bounds leave out are
  refused, each in words that name the attribute and never repeat the value (`DeviceFilter.Invalid.message`). The stub
  really filters (each filter narrows the rest, a list's values widen each other, a device without the attribute passes
  none) and refuses with a 400 a value outside a description's list, a date that isn't ISO 8601 and a bound given two
  (`AppleStub.described` and `dateFilters`, held to the contract's text). No screen uses the filter yet: Needs attention
  and history will.
- **The audit log pages by cursor**: each next page is the first read again with `cursor` set to Apple's
  `meta.paging.nextCursor` (or the `cursor` its next link carries), so the required range and every filter go with
  every page. Its next link is never followed: Apple's examples' next links carry only the cursor, and the stub's do
  too, so following one gets the 400 for a missing range. A next page with no cursor is malformed, never the end.
- **A cursor or next link Apple gives twice is malformed** on every list (`a repeated cursor on <template>`), never 200
  identical pages to the cap. The stub's `repeatCursors(on:)` drives it.
- **Apple filters, the client doesn't** (plan §2.1: abapit filtered audit by subject itself). `AuditQuery` checks what
  goes out when it is made: both bounds cut to whole seconds, UTC, `Z`, the start before the end, at most 365 days
  (`longestSpan`, abapit's view cap), 1970 to 9999; `filter[type]` from `AuditEventType` only (an `.unknown` value
  read from an event throws `.unknownType`), each once, joined by commas; `filter[actorId]` and `filter[subjectId]`
  one identifier each, `isPathSafe`'s shape, so a comma (a second value), `&`, `=`, `#`, `%`, a space, a line break or
  anything non-ASCII is refused, and `URL.make` percent-encodes every value anyway. The stub really filters by range,
  type, actor and subject.
- **An audit payload is read where it is, and a miss is said** (Phase 2a review M1): under `eventDataPropertyKey` when
  that holds an object, else under the type's own key, compared by bytes. Apple's object names spell `Icloud` and
  `Applecare` where its attribute keys spell `ICloud` and `AppleCare`, so a key named from the object name misses; read
  as "no payload", the event's serial or subscription went unread, its unknown fields uncounted, and the pass said
  `ok`. `AuditEvent.payloadProblems` holds a named key that is absent, `""` or not a string, and a payload that isn't an
  object (`null` included); the pass's note says each with a count (`payload key named but absent in 1 event`).
- **An audit event's URLs show only where they go** (2.8): `WEBHOOK_CREATED` and `WEBHOOK_UPDATED` carry the webhook's
  `url`, which can hold the receiver's token, and the Activity inspector shows every payload field and common attribute,
  its CSV the common attributes. `AuditEvent.resource` is masked when read (`AuditEvent.withholding`), for every type, an
  unknown one's too; no copy as Apple sent it is kept, since nothing reads a URL from an event. Every attribute but the
  common ones is walked, objects and lists at any depth (`AuditEvent.masked`): a value under a key that is `url` or ends in
  it (any case) is `WebhookURL.shown`'s, a non-string withheld whole; a value under a key holding one of
  `ExportPolicy.sensitiveStems` (mirrored as `AuditEvent.sensitiveStems`, held equal by `ExportPolicyTests`) is
  `AuditEvent.withheld`, whole, but for an attribute that is one of Apple's payload keys (`eventDataAccountPasswordChanged`
  and `eventDataBatchPasswordResetInitiated` hold a stem: their payloads are walked, as an object or as JSON text); any
  other string has every URL in it masked
  (`WebhookURL.maskingURLs`), and a string of JSON text (an object or a list, a payload sent as a string) is read, walked
  the same way and written back as JSON text when the walk changed it. Past `AuditEvent.maskDepth` (32) levels a value is
  withheld whole. Of the common attributes, `subjectName` and `actorName` have every URL in them masked (a webhook's event
  may name it by its URL); the rest are Apple's words and ids, left as they came. Held by
  `aWebhookURLInAnEventShowsOnlyWhereItGoes`, `thePayloadMaskWalksEverythingApplesSent`,
  `anAuditPayloadWithholdsEveryKeyCSVWithholds`, `theAuditCSVShowsNoURLInANameRaw` and, on the app side,
  `ActivityTests.aURLInAnEventShowsOnlyWhereItGoes` (the contract-2.8 review's M2 and L1: the mask read one level of a
  payload and URL-named keys only, and the two names went raw to the screen and the CSV). Not caught: a URL with no
  scheme and no `//`, a URL in a key's name, and JSON text nested past `JSONValue.maximumDepth`, which reads as text. The
  three webhook types are in Access & Security (`AuditView`): a webhook sends the fleet's changes, serials included,
  off-site.
- **Keys inside the objects a view reads are counted too** (Phase 2a review L1): a user's `phoneNumbers` and
  `roleOuList`, a custom setting's `customSettingsValues` and an audit payload's role locations, as `attribute.key`
  (`phoneNumbers.isPrimary`, `accountRoleLocationList.scope`), the attribute this version's name and Apple's key each
  shown as `acceptanceWord` shows it. `ResourceView.unreadNested` (none by default) and `AuditEventPayload.unreadNested`;
  a view that reads a new `ObjectView` adds it there.
- **One list reader** (Phase 2a review L6): every view reads a list with `JSONObject.list(_:_:)`, nil when missing, not a
  list or holding an item that doesn't read, never the items that fit. Phase 1's `strings(_:)` read `[]` and kept what
  fit, so `OrgDevice.imei` and `MDMDeviceDetail.imei` read one shape two ways; it is gone, and Find takes no identifier
  from a list that isn't one (`everyViewReadsAListTheSameWay`). A list Apple sent, not as `null`, that read nil is in
  the view's `misreadLists`, and the acceptance pass says it with a count (`defaultProductFamilies not read as a list in
  1 item`), never `ok` with nothing said (verifier round 3 of the fixes: a families list holding a number read nil, so
  `GLASSES` went unsaid where Phase 1's reader had named it; `everyListThatDidNotReadIsNamed`, `aListThatDidNotReadIsSaid`).
- **A member list is a list of linkages of its type, on every page**: a group's or an org unit's `users`, each
  blueprint relationship's own type, a service's `orgDevices`. Another type, a lookalike (`Users`, `usersX`) or an
  empty id is `.malformed("linkages of type <type>")`, as an assigned server that isn't one is.
- **The configuration list sends a custom setting's `customSettingsValues` as null** (abapit); only
  `configuration(_:)` carries it, and the pass reads a custom setting alone when the org has one.
- **A custom setting's profile is the compiler's to hold** (Phase 2a review M2; invariant 11), as CSV's columns are:
  every public value a configuration gives (`resource`, `attributes`, `customSettings.object`, a description, a mirror
  or a dump, a blueprint's `included`) has `customSettingsValues` withheld: its keys kept, `null` and a string
  `filename` as they came, every other value `CustomSettingsValues.withheld`. The profile as Apple sent it is
  `Configuration.received` and `CustomSettingsValues.configurationProfile`, both `package`: `ProfileText` and Phase 5's
  writer read it in AbapitKit, and in the app or the screen models naming either is a compile error (checked by mutant).
  Phase 3's snapshots don't keep it (operator, 2026-10-31: what can be read again from Apple isn't kept; SQLite on disk
  is outside the Keychain, invariants 3 and 11): a snapshot stores the withheld `resource`, and the detail reads the
  profile live. The detail shows
  `customSettings?.profileText`. So the device inspector's every-attribute pattern is safe for a configuration.
  `aCustomSettingsProfileReachesNoPublicValue` (a canary through the strict stub), `aConfigurationsCSVHoldsNoProfile`,
  `BoundaryTests.theAppSideNeverNamesTheRawProfile`, `BoundaryTests.whatHoldsTheRawProfileStaysPackage`, which holds the
  three declarations at `package` and only that (verifier round 1: widened to `public`, each left every test green
  behind the name scan alone), `BoundaryTests.onlyTheListedLinesReadTheRawProfile`, which lists every line in AbapitKit
  that names either, and `whatAConfigurationStoresIsTheTwoCopies`, which holds the two types' stored layout (verifier
  round 2: a public accessor of another name, in any AbapitKit module, left every test green; a new stored copy would
  name neither). These hold names, modifiers and layout, not raw memory: `theAppSideTouchesNoRawMemory` keeps the app
  side off it, but AbapitKit code that reads a configuration's bytes (`withUnsafePointer` then `load(fromByteOffset:)`)
  names neither property, and only review catches it there, as for `Secret`'s bytes (verifier round 3 of the fixes).
  `CustomSettingsValues`' `==` compares the withheld object and the masked text: Swift's compared the raw profile, so
  the app could test a guessed secret. `Configuration`'s compares its withheld resource and its custom settings, so it
  is `Equatable` for Phase 2b's diffing without the same oracle (verifier round 3: Swift's would compare `received`;
  `aConfigurationComparesByWhatIsShown`). A custom setting of another shape is said, never read as none:
  `Configuration.profileProblems` (`custom settings not an object`, `profile not a string`), with a count on the list's
  and the single read's lines (`aCustomSettingOfAnotherShapeIsSaid`). Not withheld: an
  attribute Apple adds beside `customSettingsValues` at the top level of a configuration is shown raw (invariant 10). If
  Apple moved the profile there, the pass names it as an unknown key, and once the contract documents it
  `aViewReadsApplesAttributes` fails until the view lists it, which is where it gets withheld.
- **What `ProfileText` masks** (Phase 2a review L2): every value under a key whose fold, without its numbers, holds a
  stem (`password`, `secret`, `token`, `psk`, `sharedkey`, an encryption, client, access or licence key, `bypass`,
  `assertion`, an unlock or access code, a WEP key, ACME's `clientidentifier`, …; every stem of
  `ExportPolicy.sensitiveStems`, which `aProfileMasksEveryStemCSVWithholds` holds), or that has `PIN`, `PW` or `PUK` as a
  word or a plural one (`PINs`), or whose fold ends in one or in `PPK` (IKEv2's post-quantum pre-shared key, a secret
  only as the ending, so `PPKIdentifier` shows) past a plural and the trailing words `code`, `number`, `value`
  (`pincode`, `rootpw`, `SIMPINs`), unless it is a flag, a date, or a number that isn't a secret; a number whose fold ends in a stem or one of those
  words, past the same (`Passcode`, `UserPIN`, `UnlockCode`, `PINCode`, `PassCode`, `SharedSecret`, `LicenseKey`,
  `Passwords`), unless a policy word is in the key, whole (`MaxPIN`, `PasscodeMinLength`; `AgentPIN` isn't `age`; a
  string under a policy-worded key is masked all the same); every string holding a private key, whatever its key and
  wherever it sits in the string (after a certificate, as in an identity bundle): a PEM one, a PuTTY key file or a JWK
  with its private member (`d`, or `k`), as text, base64 (padded or not) or a `data:` URL; every data blob. A key's
  words split where letters meet numbers, and a plural `s` stays with its acronym (`PINs`, not `pi`, `ns`: verifier
  round 2), so `DevicePIN2`, `VPNPIN2`, `Passcode1` and `PIN1Code` read as their letters (verifier round 1: a string
  under `DevicePIN2` and a number under each were shown). A policy word wins, so a number under `AgePIN` or `Max2PIN`
  is shown, and so is one under `DeviceMaxPIN`: the policy word needn't come first. A list or a dictionary under a
  secret key is masked whole, a policy word in the key or not (`PasswordHistory`: walked, its items have no key of their
  own; verifier round 3 of the fixes, `aContainerUnderASecretKeyIsMaskedWhole`). A flag is a `CFBoolean` (`objCType` `c`); a number is any other `NSNumber`. A key written twice alike
  (Foundation's reader keeps one, the last) and two keys equal once normalized (merged when Foundation's dictionary
  becomes Swift's) are counted in `.plist`'s `merged`, the first from the XML's own keys, and `note` says it.
  - HTTP headers (review M-3): under a key whose fold holds `header` (the relay payload's `AdditionalHTTPHeaderFields`),
    every value of a dictionary is masked whatever its type (a string, a number, a list, a dictionary one level
    deeper), and every item of a list (name and value pairs), so a credential hides under any header name
    (`X-Authorization`, `Ocp-Apim-Subscription-Key`). A string under such a key is any other string (EAS `HeaderMagic`),
    and no header name is a stem, because the privacy payload's `Authorization` is Allow or Deny for 24 services
    (`everyValueOfHTTPHeadersIsMasked`).
  - Held to Apple's own schemas (`ProfileSchemaContractTests`, over `Contracts/device-management/profiles-27.0.json`:
    127 payload files, 2,321 keys). Each payload is written as a profile carries it, every key in its real nesting
    (a list holds one item, the schema's item name no key) with a unique value of its own type, and what the detail
    shows is searched for each: 1,199 values (every string, untyped, integer, real and data key, and the 4 keys that
    repeat an ancestor, given a sample); a flag or a date carries none. What is masked is exactly the test's 44
    `secrets`, its 17 `overMasked` and the 26 data keys, so masking more fails as masking less does (review M-1: each key
    had been read alone at the top level, so AirPlay's `Passwords` list, masked whole, hid two device names unseen;
    `eachBuiltProfileHoldsEveryKeyAtItsPath` checks the builder). Which keys are secrets follows Apple's descriptions
    (review M-2): the script marks `describedAsSecret` on the 45 keys whose description is a secret's ("the password
    for", "the user's password", a secret, pre-shared, "the token", a challenge, anti-replay, a passphrase, a private
    key; never on a flag), and each is on `secrets` or on the 3-key `notSecret` with the reason, so a described secret
    can't move to `overMasked`; the two secrets no description names (`IKEv2.SharedSecret`, a header's value) are marked
    in the test. The data secrets (an APN password, IPSec's shared secret, IKEv2's `PPK`) are also written as strings.
    The contract's counts and SHA-256 are recomputed from its payloads (review L-3).
  - What no schema key exercises: there, `password`, `secret`, `token`, `passcode`, `credential`, `challenge`,
    `accesskey`, `clientidentifier`, the `PW` word and the `PPK` ending are each the only reason some value is masked.
    Every other stem and word (`PIN`, `PUK`, `psk`, `passphrase`, `privatekey`, `bypass`, an unlock code, …) is held
    only by `ProfileTextTests` (and the CSV's stems by `ExportPolicyTests`); the contract test sees them only if they
    start to mask a key that isn't a flag.
  - Not caught: a secret under a key no stem or word names that isn't a private key in a form above (a homoglyph spelling,
  an unusual name, a number under `AuthCode`, `AuthKey` or `SetupKey`), a secret inside a string's text (a WireGuard
  `PrivateKey =` line, an `Authorization: Basic` header written in text, a URL's `user:password@`, an OpenVPN static key, an SSH2-format
  or unarmoured DER private key: verifier round 3 of the fixes), a key wrapped twice (base64 of base64), a secret inside
  a vendor's dictionary under a name no stem holds (`VendorConfig`, a DNS proxy's `ProviderConfiguration`, an SSO
  extension's `ExtensionData`: no schema says what they hold), and a binary plist's repeated
  keys (its dictionaries can be shared, so its table isn't the tree). Over-masked, the safe way: a policy value under
  a secret word, such as Kerberos' `pwReqText` and `pwChangeURL` or `passwordContentRegex`, a flag written as an
  integer (`askForPassword` = 1, `forcePIN` = 1), `credentialBundleIdACL` and `credentialUseMode`, and a name beside
  a secret in a list masked whole (AirPlay's device names in `Passwords`, Platform SSO's `TokenToUserMapping`, the
  regex's descriptions under `passwordContentDescription`); the key shows, and the note counts it. Masking is a denylist for the detail's display: the raw profile never leaves AbapitKit, so a
  miss shows a secret on the detail's screen, never in the CSV or the pass (each held by a canary test).
- **The stub's parameter table is the contract's, written out** (`AppleStub.parameters`, `paged`), never computed from
  the client or the models (failure-log 2026-10-16, "the mosyle stub agreed with the client"): `AppleStubTests` holds
  it to both contracts and refuses a stub that imports `AppleModels` or names a builder, the client or a model's value
  list. A paged endpoint takes `cursor` (Apple's own next link carries it); a cursor the stub never gave is a 400, as
  is an empty value in a listed set (`include=`, `apps,,users`).
- **Assumed, check live (the device filters, 2.7):**
  - Do the filters combine as AND, and a list's values as OR (the stub's choice)?
  - Does a comma sent percent-encoded (`%2C`, as `URL.make` sends it) separate a filter's values?
  - What does Apple do with a value outside a description's list, a date that isn't ISO 8601, or a bound given two (the
    stub: 400)? The client never sends one.
  - Does an exact date (`filter[addedToOrgDateTime]=…`) match a device whose stamp has a fraction (Apple's examples' do:
    `22:05:14.192Z`), when the client sends whole seconds? The stub compares instants exactly, so it doesn't.
  - Is `[LT]` strictly before and `[LTE]` at or before, as the descriptions say, at Apple's own precision?
  - Is there a cap on how many values a filter takes, or on the query's length? The client takes at most 100 serial numbers
    and 100 order numbers (`DeviceFilter.maximumIdentifiers`), a guess until this is answered.
  - Are `filter[serialNumber]` and `filter[orderNumber]` case-sensitive? The stub matches by bytes, and the client sends
    what was typed.
  - Does a filtered list's next link always carry the filters (the 2.7 example's does)? The client never follows it.
- **Assumed, check live (Phase 2 live check):**
  - Does Apple cap the audit range? The client caps it at 365 days; the stub has no cap.
  - Is the audit range inclusive at both ends (the stub's choice), and is a range that ends before it starts a 400
    (the stub's choice; the client never sends one)?
  - Does `filter[type]` take several types joined by commas (the contract types it `[string]`)?
  - The shape of an actor's and a subject's id: the client refuses anything but letters, digits, `-`, `_` and `.`.
  - Does the audit log's next link carry the range and filters? The client never follows it.
  - Is a refused include a 400 (what abapit saw) or a 403, with which `code`? Both are handled.
  - How many members an included relationship lists without `limit[<name>]` (the stub: 10), whether an empty one
    comes as `data: []` (the pass reads a missing one as `not listed`), and whether `meta.paging` on an included
    relationship has `nextCursor` and `total`.
  - Does a role that can't read users also get 403 on `blueprints/{id}/relationships/users`? The stub refuses it only
    when that path is forbidden itself.
  - Does `mdmDevices/{id}/details` 404 for a device with no details on record (the stub's choice), is its id the
    `mdmDevices` id (the serial?), and is the details' own `id` the same?
  - Does the configuration list send `customSettingsValues` as null (abapit) or leave it out?
  - The models unit's: what the 14 audit payloads Apple documents with no fields carry; whether
    `eventDataPropertyKey` always equals the type's key, and which spelling it uses (the pass says each miss); whether
    a domain event's domain is its `subjectName`;
    `mdmDevices`' `productFamily` values; whether `storageFreeCapacity`/`storageTotalCapacity` are bytes and what
    `platform` holds; and whether a signed profile comes back as base64 DER.
  - Reports' (`docs/domains/history.md`): the format and offset of an audit event's `eventDateTime` (fractional
    seconds, `Z` or `+00:00`; DocC has no audit example); the order Apple sends audit events in (there is no
    `sort`: if oldest first, a list cut at the page cap lacks the newest, so its recent ten aren't the newest and the
    screen must say the list was cut); what `TERMS_ACCEPTED`, `APPLE_SERVICES_SETTINGS_UPDATED` and `COLLECTION_*`
    events record (actor, subject, category), to confirm their places in the audit views; what a never-connected
    service's `lastConnectedDateTime` is (absent and null read as never, any other non-date as unreadable); whether
    `APPLE_CONFIGURATOR` and `APPLE_MDM` services ever set it (if not, they read as never connected for good and may
    need leaving out by `serverType`); and whether an `INACTIVE` service still connects (only `DELETED` is skipped).

## Webhooks (Business 2.8)
Read only here, with no screen (plan §8.0: the writes, and a screen, come later). A webhook's `url` is the operator's own
and can carry the receiver's token; a delivery's `response.body` is the receiver's own words; the `secret` signs every
delivery and is write-only at Apple. Phase 2a review M2's rule applies: a view whose resource holds a secret hands out a
copy with it withheld and keeps what Apple sent at `package` (`asSent`), and prints, debug-prints and mirrors the copy.
- **What a URL shows** (`WebhookURL.destination`): the scheme in lower case, the host (an international one in its `xn--`
  form) and the port, then `/…` when anything else was there: a user or a password (even empty), a path past `/`, a
  query, a fragment. An allowlist of the parts kept, not a parser of where a secret hides (RULE-FEEDBACK 2026-11-03):
  anything that isn't `http` or `https` with a host of ASCII letters, digits, `-` and `.` (or an IPv6 address in
  brackets), at most 253 bytes, is `WebhookURL.withheld` whole (a percent-encoded host, a blank, `;`, no `//`, no scheme).
  Stricter than a package's location (`ContentWords.location`, which keeps the path): a webhook's path is often the
  token itself. Not caught: a token in the host name.
- **The tag** (`WebhookURL.shown`, `tag`; the contract-2.8 review's M4): the destination alone shows two URLs on one host
  alike, so a webhook repointed on a shared receiver couldn't be seen. Every masked URL, a webhook's, a delivery's, an
  audit event's, shows as `https://hooks.example.com/… (tag a1b2c3d4)`: the first 8 hex digits of HMAC-SHA256 of the URL
  as Apple sent it, under a key of 32 random bytes made once per process, held in memory only, never stored or logged. A
  URL withheld whole has one too. **Tags compare only within one run of the app**: the same URL tags alike in a run and
  differently in the next, so a tag in a CSV or a screenshot means nothing beside one from another run, and nothing of the
  URL can be read back from it. The HMAC is written out (`TagHash`, this module being pure) and held to FIPS 180-4's and
  RFC 4231's vectors and to CryptoKit (`theTagsHashIsHMACSHA256`). The acceptance pass prints no URL, so no tag either.
- **A URL in Apple's words** (`WebhookURL.maskingURLs`): a run of text between ASCII blanks holds a URL from a scheme
  whose `:` is followed by `/` or `\` (`https://`, and the `https:/` and `https:\\` a browser reads as one), from an
  `http` or `https` scheme followed by `:` alone, or from a scheme-relative `//` that doesn't follow a scheme's character
  or a `/` (`url=//hooks.example.com/…`), to the run's end; what is glued before it is kept. Errs toward hiding:
  punctuation after a URL goes with it; a time (`10:30`), a label (`Error:`) or `and/or//both` stays. Held by a list of
  cases and by a generated grammar of 4,000 seeded URLs in text (`aGeneratedURLNeverSurvivesTheMask`, RULE-FEEDBACK
  2026-11-03). Not caught: a URL with no scheme and no `//` (`hooks.example.com/token`), a `//` glued to a word, another
  scheme with `:` alone, and what follows a blank inside a URL.
- **A webhook** (`Webhook`): `url` as its destination; every attribute it doesn't read (`fields` is
  `Webhook.Attributes`), `secret` included, withheld as `Webhook.withheld` with its key kept, so the acceptance pass
  counts `secret` as an unknown key and never prints it; an attribute Apple adds may be the secret by another name.
- **A delivery** (`WebhookDelivery`): `request.url` as `WebhookURL.shown` shows it; `response.body` withheld (`hasBody`
  says whether the receiver said anything; Apple keeps a body only for an answer that isn't 2xx); every other key of
  `request` or `response` withheld, `httpStatusCode` kept; a `request` or `response` that isn't an object withheld whole and
  named in `misreadObjects`. Every attribute it doesn't read (`requestHeaders`, a signature by any name) withheld, its key
  kept so the pass counts it, as a webhook's are. `errorMessage` is Apple's words for a receiver that never answered,
  which may quote the URL, token and all: every URL in it is masked (`WebhookURL.maskingURLs`), and one that isn't a
  string is withheld whole; `asSent` keeps it raw. The contract-2.8 review's M1: only `request` and `response` were
  withheld, so an unknown attribute and a token quoted in the message went out in every description, dump and mirror
  (`aDeliveryWithholdsItsURLAndTheReceiversWords`, and the app side's `BoundaryTests.aDeliveryHandsTheAppNoTokenOrHeader`).
- **An event** (`WebhookEvent`): public as it came. Its `payload` names a device by serial and a service by id, the
  organization's own data as an audit event's is; `WebhookPayload` reads it, wrapped in `data` (the guide's examples, the
  POST body) or not (the guide's prose). A field is read only where its type documents it (`WebhookPayloadType.fields`,
  `.relationships`), the rest counted as `unreadKeys` (`payload.`, `attributes.`, `relationships.`), a wrapped payload's
  keys beside `data` among them (`besideData`, as `payload.<key>`: the contract-2.8 review's L3); a payload that isn't a
  string, or a string that isn't an event, is `payloadProblem`, never read as none.
- Held by `WebhookTests` (canaries through each public value, `description`, `dump` and the mirror; the stored layout,
  `whatAWebhookAndADeliveryStoreIsTheTwoCopies`; neither type `Equatable`, whose synthesized `==` would compare `asSent`),
  `applesWebhookExamplesReadTyped`, and `BoundaryTests.whatAppleSentOfAWebhookStaysPackage`: `asSent` is `package` and only
  that, named nowhere on the app side, and read in AbapitKit by its two declarations and two initializers alone (a public
  accessor of another name fails there, as for the raw profile). Raw memory reads inside AbapitKit are review's, as for
  `Secret`'s bytes.
- **The reads** (`AppleClient.webhooks()`, `webhook(_:)`, `webhookDeliveries(_:_:)`; `WebhookReadTests`): the list pages as
  every list does; a webhook's deliveries page by cursor, as the device list and the audit log do, so
  `WebhookDeliveryQuery`'s filters go with every page. That query is checked when made: `filter[createdDateTimeAtOrAfter]`
  and `filter[createdDateTimeAtBefore]` whole seconds, 1970 to 9999, the start before the end after the cut (else
  `.emptyRange`, in words); `filter[deliveryState]` Apple's three states, each once. `include=event` always goes: each
  delivery's `event` is the included `webhookEvents` resource its linkage names, by bytes; an included resource of another
  type is `.malformed("included of type webhookEvents")`, one included twice `.malformed("included webhookEvents twice")`
  (JSON:API includes a resource once; which copy is the event would be a guess: the contract-2.8 review's L2), and the stub
  includes on each page only the events that page names (`eachPageIncludesOnlyTheEventsItNames`). Where a page's next
  link and `meta.paging.nextCursor` name different cursors, every cursor-paged read takes `nextCursor`, the field Apple
  documents as the cursor (`theCursorIsMetaPagingsWhereTheNextLinkDiffers`); an event named and not included leaves
  `event` nil with
  `eventID` set, never another event. An id that can't go in a path is never sent (`.notFound`, as every read's).
- **What each state says** (no screen yet; these are what the client and the pass say): a School org, `.webhooksNotInScope`
  ("Apple School Manager's API has no webhooks to read."), nothing sent, and the pass's three lines
  `skipped: not in Apple School Manager's API`; a role that can't read them, `.forbidden` and `webhooks: forbidden`, the two
  that need a webhook `skipped: no webhook to read (webhooks forbidden)`; none, `webhooks: ok, 0 items` and the two
  `skipped: no webhook to read (webhooks has none)`; a list cut at the page cap, `truncated`; a deliveries walk that fails
  part-way, its status with the count read. The deliveries line reads the first webhook's last day and says, each with a
  count, an event not included, a delivery naming none, a request or response that isn't an object, and a payload that
  isn't a string or an event; it reports unknown keys of a delivery (`request.`, `response.`), its event (`event.`) and the
  payload (`payload.`, `attributes.`, `relationships.`) and unknown `deliveryState`, `eventType` and `payloadType` values.
- **Never printed or logged** (invariant 11; `noURLBodyOrPayloadReachesThePassOrTheLog`): a webhook's URL and name, its
  secret, a delivery's request URL, headers (in `request` or as an attribute of their own), response body, error message
  and every attribute it doesn't read, an event's payload. A description, dump or mirror of a webhook or a delivery shows
  the withheld copy: a URL as its destination and tag, the error message with its URLs masked, the rest withheld. The
  pass prints only words of Apple's vocabulary (a key's name, an enum value) and counts, so `secret` shows as an unknown
  key, never its value;
  `HTTPClient` logs the method, the host, the path's template and the status, and the test reads this process's log back
  (`OSLogStore`), finding the deliveries' line and no canary.
- **No probe for the webhooks yet.** A probe is per `AppleSection`, and `NavigationTests` holds every section to a sidebar
  screen that shows it; the webhooks have none until their writes (plan §8.0). The pass's `webhooks` line says `forbidden`
  for a role that can't read them. The phase that gives them a screen makes them a section with a probe, and drops
  `.webhooksNotInScope`.
- **Check live (webhooks, 2.8):**
  - How long Apple keeps deliveries (the client asks `.all` or the last day; nothing pages back further).
  - Whether a failed delivery still records its event, and whether `include=event` includes it.
  - What Apple does when a URL keeps failing: retries (`redelivery`?), disables the webhook (`enabled` false?), or
    stops recording deliveries.
  - Whether the deliveries' filters combine as AND, a state list as OR, and `createdDateTimeAtBefore` is strictly before
    (the stub's choices); what a value outside the states, or a bound given two dates, gets (the stub: 400).
  - Whether `payload` holds the event wrapped in `data` (the guide's examples) or bare (its prose); both are read.
  - Whether the payload's `id` is the `webhookEvents` id, and what `eventType` a ping's event carries.
  - Whether `errorMessage` quotes the URL, its token and all (every URL in it is masked meanwhile).
  - Whether a delivery carries the request's headers or the signature, in `request` or as an attribute of its own (each
    withheld meanwhile, its key counted).
  - Whether a page of 1,000 deliveries with `include=event` fits the 32 MiB body cap (`HTTPClient.bodyLimit`): each event's
    payload rides with it, and an answer past the cap fails the read.
  - What `subjectName` holds for the `WEBHOOK_*` audit events: the webhook's name, its URL (masked meanwhile), or its id.
  - What `WEBHOOK_UPDATED`'s payload carries: the webhook after the change only, as Apple documents, or the old values
    too (a previous `url` would show as a second tag); and whether any of it comes as JSON text.
  - Whether Apple's roles separate webhook management from the device reads: a role that can read devices may be able
    to create a webhook, and a key that can create one can stream every device change to any URL (plan §3.4.4).
  - Whether Apple ever sends `secret` (documented write-only), and whether `include=event` repeats an event several
    deliveries share (the stub includes each once).
  - The webhook audit payloads' `enabled`: a string in Apple's docs, the webhook's own a boolean.

## Screens (Phase 2b)
Each screen's model is in `Packages/AbapitApp/Sources/AppModels/`, its view in `App/Screens/`, its CSV columns in
`Reports/Export<Name>.swift` (`ExportPolicy.Columns`, never a profile, a package url or an audit payload) and its demo in
`TestSupport/Demo<Name>.swift`.
- **What every screen does the same way.** A list is a panel with its own state and load token, checked after every page
  and every await; an error becomes `LoadState(after:)` (403 "your role can't read this", a School org's Business-only read
  not in scope in words, else failed), a single read's panel too (`Panel(after:)`, the content detail's included); a School
  org sends nothing and shows the sentence, never an empty table; a list cut at the page cap says "showing N of ≥M"; a list
  a failure cut short says "Partial: N" and doesn't export. An org switch clears the screen, its selection included, and
  reads again only if it was showing; `load()` reads once per org, `load(force: true)` (Refresh, ⌘R) cancels and reads
  again, an open detail too. Each model counts its reads in a `package readsFinished` the tests wait on. Each inspector is
  `ColumnWidths.inspector`, each table adopts `selectsFirstRow`, and the snapshot harness fails a `first` run whose screen
  selected nothing. A table shows by default only the columns whose minimums fit within the Devices table's (530 pt):
  - Apple MDM: six of eleven;
  - People's users: five of eight;
  - Activity: five of six.

  The rest are a right-click on the header away (`TableColumnCustomization`, kept per window); the inspector and the
  CSV hold every one. A header of wrapping text takes an ideal width of 0, so its longest line never sets the column's
  width (Activity crashed AppKit that way; PR 12's first snapshot run). A list screen keeps no `.fixedSize()` in its pane: People's
  segmented picker crashed the smallest window the same way, and sits in the toolbar now, as Content's does.
- **What every screen says alike is written once** (`ScreenWords`; Phase 2b review L10): no organization yet
  (`noOrganization`, Apple School Manager named: Apple MDM's copy had dropped it) or one that can't be used (`unusable`), in
  every list and every inspector panel (`everyScreenSaysWhyNothingCanBeReadAlike`); an id `AppleRead.isPathSafe` refuses is
  never sent and says so (`unsendableID`: the client's `.notFound` read "Apple has no such item." of an item Apple had just
  listed, review L1), in Content's detail, a group's or an org unit's members, an Apple MDM device's details and Device
  360's four device panels (verifier round 1: the timeline beside them said its own words, the four "no such item";
  `aSerialThatCantBeSentIsNeverAskedFor`); the Devices read's walk of each service's device list says so in its own
  services note (verifier round 2: a fifth model, "Spaced MDM's devices couldn't be read (Apple has no such item.)",
  `aServiceWhoseIDCantBeSentIsNeverAskedForItsDevices`); a Content detail's guard is held in each of the four lists
  (mutant N2-pathContentAppsOnly: only an app's was); Export's
  rule (`exportBlocked`: still loading, partial, or nothing shown to export, the views only disable on it:
  `everyScreenSaysAnEmptyListHasNothingToExport`, and a search that hides every row on every list of every screen,
  `aSearchThatHidesEveryRowHasNothingToExport`: the views stopped checking `shown.isEmpty`, so Content's and People's
  units' count of the rows read passed every suite, verifier round 1); and one day formatter (`day`, `distantPast` read as
  none).
- **Refresh's routing is `ScreenModels.refresh(_:)`**, which `ContentView` only calls: in the app it had no test, and routing
  People's Refresh to the devices (review mutant X1) left every suite green (`refreshReadsTheSectionsOwnModel`). Refresh on
  a section already read reads it again, in every section (`refreshOnASectionAlreadyReadReadsAgain`; verifier round 1:
  Content's and Apple MDM's routing to an unforced `load()` survived, since only People's force was held).
- **People** (`PeopleModel`): users, user groups and org units side by side, one tab on screen; a group's or an org
  unit's members read when it is chosen (`PeopleModel.Members`, its own token) and matched to the users read by their
  bytes. A member the users read lacks shows by its id, with a note counting them and saying why (still reading, the
  role can't read users, the users list was cut, Apple's list lacks it); a member list cut at the page cap shows Apple's
  `totalMemberCount` beside the count read; a phone or role list of another shape is said (`listNote`), never "None". The
  users list carries every attribute, so there is no single user read. A list refused part-way (a 403 on a later page)
  keeps its rows, is partial and doesn't export (`aListRefusedPartWayIsPartial`, `groupsRefusedPartWayArePartial`; review
  L6, mutant P4).
- **Content** (`ContentModel`, `ContentDetailModel`): apps, packages, blueprints and configurations side by side
  (`ContentList` each); the chosen row is read alone. A blueprint is read with its six relationships at `limit=1000` and
  counted only through `BlueprintRead.members`: "N apps", "Showing N of more than N", "Apple didn't list …" with no count,
  and a refused include one note and no counts. A configuration's profile is only `profileText`, and one that can't be
  shown says why. A package's location is shown with its user, password, query values, path parameters' values and
  fragment masked (`ContentWords.location`) and never exported; App Store and website addresses are text, never opened.
  A scheme is only a leading `[A-Za-z][A-Za-z0-9+.-]*:`, a leading `//` starts an authority, and with no `//` an `@` ahead
  of the path still ends a user and password (review L2: the first `://` anywhere was the scheme's, so one in the query
  copied the query before it raw; `//user:pw@host`, `user:pw@host` and `;jsessionid=` showed raw). Text or an outer scheme
  glued before an address is kept and the address masked from its own scheme, when that scheme's `:` has a slash or a
  backslash after it (`://`, and the `:/` and `:\\` a browser reads as `://`) and no `/`, `?`, `#`, `@`, `;` or blank before
  it (`jar:https://…`, `jar:https:/…`, `url=https:/…`, `Mirror:https://…`, `x:y:https://…`, `token:` and a no-break space);
  after a scheme one slash starts an authority as two do, and backslashes as slashes (`https:/user:pw@host`,
  `https:\\user:pw@host`), and so does a `//` after a digit-led prefix (`1://user:pw@host`, which no address has); verifier
  round 1: each `://` shape showed its user and password in clear (`anOuterSchemeOrALabelBeforeAnAddressIsMasked`), and
  round 3 each slash or backslash shape and the digit-led one (`anInnerSchemeWithOneSlashABackslashOrNoneIsMasked`,
  mutant R3-schemeFirstDigit). The guard holds with no scheme ahead too (round 3: `host/a.pkg?sig=…&next=https://…` was
  split at `https` and its signature copied raw, as was `a;sid=…,https://…`'s parameter;
  `aSchemeSlashesAfterTheQueryPathOrFragmentStartsNoGluedAddress`). An address inside another one's path, a proxy's or an
  archive's (`https://proxy/fetch/https://user:pw@origin/…`, one slash or a backslash too) or one joined by `,` or `;`, is
  masked from its own scheme on, and the path before it kept (verifier round 2: it was copied as the outer path, its user
  and password in clear; `anAddressInsideAnothersPathIsMasked`). A path segment's user and password, before its last `@`,
  are masked whatever comes before them in the segment (`…/fetch/deploy:pw@origin/…`, `…/fetch/https:deploy:pw@origin/…`,
  which a browser reads as `https://deploy:pw@origin/…`, and a line separator, not a blank, gluing one to the segment), and
  a segment's `@` with no `:` before it (`/img@2x/`) is none (verifier round 3: each copied raw). In the Location a blank
  doesn't end an address inside its user and password (its authority, its user part with no `//`, or a path segment with a
  `:`), a path parameter, its query or its fragment, in each address it holds: a client sends such a value whole (a
  browser encodes a space and drops a tab or a newline), so a user and password run past blanks to their last `@` ahead of
  the path, a parameter's value to its next `/`, `;`, `?` or `#`, and a query or a fragment to the Location's last
  run (verifier round 2: `https://deploy:my pw@host` showed `deploy:my` as a host while the note said the password was
  masked; round 3: `?file=My App.pkg&token=…` showed the values after the blank in clear under that note, and a second
  address's password its first part; `aBlankInsideALocationsPasswordIsMasked`,
  `aBlankInsideALocationsQueryFragmentOrParameterIsMasked`). Elsewhere a blank ends an address, so one after an unencoded
  space in a path is masked as its own, and the note shows whenever any run was masked, not only the last
  (`aLocationMaskedOnlyBeforeABlankStillSaysSo`, mutant R3B-maskedLastRunOnly). A `://` after a leading `//`, or after a
  scheme's `?`, `/` or `#`, starts no glued address, and every ASCII blank ends a run in other text, each held by its own
  case (verifier round 2: each of the split's guards and CR, VT and FF survived every suite, each showing a credential;
  `everyBlankEndsAnAddressInOtherText`). Every string of a
  package's other attributes, at any depth (`JSONValue.mappingStrings`), and its Description field go through
  `ContentWords.addresses(in:)`, which masks each run between blanks that is an address (a scheme and more, `//`, a `://`,
  a scheme's `:` before a slash or a backslash, a user before an `@` ahead of a path, or a user and password before a path
  segment's `@`) and leaves a word, a version, a bundle id, a hash or an email address (`it@example.com`, no path) as it
  came; the Description showed in clear what its attribute masked (verifier round 1),
  and so did the title and the Name, Version, Bundle IDs and Hash fields, the list's row and the packages CSV, a file
  that leaves the app (verifier round 2), and a blueprint's member list (round 3): each goes through `addresses(in:)` too
  (`ContentWords.shown`, the row's `exported`; `everyFieldOfAPackageAndItsCSVAreMasked`,
  `aBlueprintsPackageNamesAreMaskedAsThePackagesOwn`, `anInnerSchemesUserAndPasswordAreMaskedInTheDetailAndTheCSV`). A
  blueprint's other members (apps, configurations, devices, users, user groups) are named as Apple sent them, as their own
  screens show them: only a package's text is read for addresses.
  Every string of the package's own `url` attribute is masked as the Location is, whatever its shape: a url that isn't a
  string reads "Not readable" in the Location, with a note, never a dash (`aPackagesDescriptionAndAUrlOfAnotherShapeAreMasked`),
  and a url sent as null is none, a dash and no note (`aNullURLIsNoLocation`, mutant N2-misreadNullIsMisread).
  Each arm of `addresses(in:)` is held through it, not only through `location` (`everyArmOfAnAddressInOtherTextIsMasked`:
  without the skip past a digit, `-`, `+` or `.` before a glued scheme, the split recursed until the stack overflowed; it
  now splits only where the address starts after the text, so it ends whatever the skip does).
  Masking errs toward hiding: a `word:word;word` or `word:word?word` value reads as a scheme and loses its tail, a
  `16:9@60` reads as a user and password, and an email address after a scheme or a label (`mailto:it@example.com`,
  `Contact:it@example.com`) or before a path (`Team@HQ/West`) reads as a user and password, a `user:pw@host`'s shape, and
  loses its name; in the Location, text after a host and a blank up to an `@` (`https://host notes@x/…`) is masked as a
  user, and a query, a fragment or a parameter takes in what follows a blank, a second address after a blank in a query
  included. Not caught, each recorded with why: in other text a blank ends a word, so an address with no scheme, no `//`
  and no user (`host/a.pkg?sig=…`) isn't one, and the second half of one an unencoded space split shows its query, and
  what follows a blank inside an address's password, query, fragment or path parameter shows (`?sig=AAAA BBBB`,
  `deploy:my pw@host`'s `deploy:my`): a description's words can't be told from such a value's halves (the Location, one
  address, joins them); a user with no password in other text with no path (`token@host`, an email address's shape) or in
  a path segment with no scheme before it (`/fetch/token@origin/`, an `img@2x` folder's shape); a parameter's value glued
  to an inner scheme (`;sid=S3https://…`), whose value reads as the scheme's first letters; an unencoded `/`, `?` or `#`
  inside a password, which isn't a valid address (what comes before it shows as the host); an address percent-encoded
  inside a path segment (`/https%3A%2F%2Fuser%3Apw%40origin%2Fa.pkg`), a segment's text until the server it names decodes
  it, which would take a decoder per layer of encoding (`%253A` too); and an address used as a JSON object's key (keys are
  Apple's attribute names, kept by `mappingStrings`).
  `theDemosCustomSettingReachesNothingTheModelExposesUnmasked` follows the demo's canary password through the model.
- **Apple MDM** (`AppleMDMModel`): `mdmDevices`, then each device's `/details` one at a time in list order, at most
  `detailLimit` (50), cancelled on a switch or Refresh; a row past it says "Not read" and reads its own when chosen. A 403
  stops the reads and is said, a 404 is "No details", an id that can't go in a path is never sent, details naming another
  serial are refused. A posture cell without details says why (Reading…, Not read, No details, Role can't read, Failed),
  so an unread FileVault never reads Off; the CSV adds its own `detailsStatus`. A School org gets the model's own words,
  since `AppleAPIError.message` lower-cases `displayName` ("no apple mdm enrolled"). Leaving the screen
  (`AppleMDMView.onDisappear` → `pause()`, invariant 7; review L9) cancels the details read and frees the org's shared rate
  limiter: the details not read yet say "Not read" (never "Reading…"), the note says the read stopped when the screen was
  left, and coming back (an unforced `load()`) asks for those only, which say "Reading…" again while the return reads them,
  with the progress note and Export held, as before the pause (verifier round 2: they said "Not read", the note said the
  read had stopped while it ran, and Export wrote "Not read" for devices being read; `whileTheReturnReadsTheRowsSayReading`);
  Refresh still reads everything. A return to a list that failed part-way asks no details (`comingBackToAFailedListAsksNoDetails`),
  nor does an unforced load during the read with no pause before it (`anUnforcedLoadDuringTheDetailsAsksNothingTwice`).
  Not changed: every window shares one `AppServices` and so one `AppleMDMModel`, so leaving Apple MDM in one window pauses
  the read another window still shows (verifier round 2); a count of the windows showing it would rest on SwiftUI pairing
  each `onAppear` with an `onDisappear`, which no test can hold (App/ has no test target), and a drift would bring review
  L9 back silently. The selection was already shared, so per-window screen models are Phase 3's question. A pause during a list
  read (a Refresh's, an org switch's) drops the part read and leaves the screen idle, and an org switch while the screen is
  away reads nothing until it shows (`leavingStopsTheDetailsAndComingBackAsksOnlyTheUnread`, `aPauseDuringARefreshLeaves…`,
  `aPauseDuringAnOrgSwitchLeaves…`, `aSwitchWhileAwayReadsNothingUntilShown`). A selection's own read stopped by a pause
  says "Not read" and is read on return; a refusal holds across a return (nothing more is asked); and once shown again the
  screen is showing, so an org switch reads the new org (verifier round 1, four surviving mutants:
  `aPauseDuringASelectionsOwnReadReadsItOnReturn`, `comingBackAfterARefusalAsksNothing`, `aSwitchAfterComingBackReadsTheNewOrg`).
  A selection within the limit that a pause left "Not read" is asked first on return, before the details waiting their
  turn; a Refresh after a pause clears it, as a return does, so an org switch then reads the new org and an unforced load
  starts no second sweep; and a pause or a Refresh during the return's read cancels it, its request never sent (verifier
  round 3, five surviving mutants: `aSelectionAPauseLeftIsAskedFirstOnReturn`, `aSwitchAfterARefreshAfterAPauseReadsTheNewOrg`,
  `anUnforcedLoadAfterARefreshAfterAPauseAsksNothingTwice`, `aPauseOrARefreshDuringTheReturnsReadCancelsIt`).
  A selection the list doesn't hold says why,
  as People's does (`selectionNote`: "Reading the devices…", "This device isn't in the list Apple sent."; review L7), in
  place of the inspector's "Select a device".
- **Activity** (`ActivityModel`): one audit read over an `AuditFilter` (the last 1, 7, 30, 90 or 365 days or a range, and
  Apple's type, actor and subject filters), checked through `AuditQuery` when set, so a refused range is said and nothing
  is sent. A refused actor or subject id is told which of `isPathSafe`'s rules it broke: its characters, a leading dot, or
  more than 128 characters (`AuditFilter.idProblem`; review L8). The panes are views over that one read: a type this version
  doesn't know is in Other types and an untyped event only in Audit, both said (`unplacedNote`), never dropped; counts by
  type only over a list read whole. Device 360's timeline (`DeviceDetailModel.timeline`) reads `filter[subjectId]=<serial>`
  over 30 days in its own panel, counted apart (`timelineReadsFinished`); cut at the page cap, it says "Showing N events: the
  list stopped at the page limit" (`aTimelineCutAtThePageCapSaysSo`; review L5, mutant T2).
- **Dashboard** (`DashboardModel`): counts the Devices screen's read (one device read for both) and only a list read
  whole, else each card says why (`fleetWords`, `servicesWords`, `unassignedWords`, `quietWords`); services not connected
  through Reports' `QuietServices`; the newest ten of the last seven days' audit events from its own read and
  `auditState`, so a refusal or a School org is said in that card alone. The recent events are `recentRows`, Activity's
  `ActivityRow`s: type and outcome in words, an actor or a subject Apple named only by id shown by its id (review L3: the
  card showed a dash and the raw type, decided in the view), each with its own id for the card's `ForEach` (verifier round 1,
  mutant N-recentRowsSameID).
- **Services' Last connected is the quiet card's rule** (`DevicesModel.connection(of:now:)` over `QuietServices`; review
  L4): a date this app can't read says so, never "Never", a deleted service isn't flagged, and quiet is more than 30 days
  by the instant, not by whole days, so the column flags exactly what the card lists at its default
  (`theServicesColumnIsTheOverviewsQuietRule`; a stamp ahead of this Mac's clock reads "Today", never "-1 days ago",
  verifier round 2). `DevicesModel.quietServices(after:)` is gone.
- **Long reads a leave doesn't cancel** (review L9; recorded, not changed): only Apple MDM pauses. The Dashboard's seven-day
  audit read walks every page (no `sort`) and runs on after the Overview is left, as do Activity's reads of up to 365 days
  and 200 pages, the Devices read's walk of every service's device list, People's three lists and Content's four (each at
  most the page cap). Device 360's five panels are cancelled by another selection or a closed inspector, not by leaving the
  screen with it open. Each is one bounded read the operator asked for by opening the screen, not a sweep; each still
  shares the org's limiter with what the operator opens next. If that proves slow live, each gets a `pause()` as Apple MDM's.
- **Follow-up for Phase 3, not done here** (review L10, scope decided): the list code is copied, not shared. The token,
  `current(_:)`, `reset`, `partialCount` and the page loop are written separately in `PeopleModel.Listing` and its `read`,
  `ContentList`, `AppleMDMModel`'s list read, `ActivityModel`, `DashboardModel`'s audit read, `DeviceDetailModel`'s timeline
  and `DevicesModel`; `PeopleModel.Members` is a fifth member-list copy. Their words now come from `ScreenWords`; merging the
  loops into one list type waits for Phase 3, which adds the Changes and Reports lists.
- **Known, not fixed**: `AppleAPIError.notInScope(.mdmEnrolled).message` reads "Apple School Manager's API has no apple mdm
  enrolled to read." (AbapitKit lower-cases `AppleSection.displayName`); no screen shows it, as `AppleMDMModel` says its
  own words and the sidebar hides Apple MDM for a School org.
- **A test that holds the main actor holds a read too** (People): `World.buffer` blocks the main actor, so a read started
  from it hasn't sent its request yet; wait until the request is held at the gate, then buffer, or the buffer waits out its
  20 s and the test passes for the wrong reason. A superseded read's return counts in `readsFinished` too, cancelled or
  not, so a test that supersedes a read waits for the state it asserts (the detail loaded), not for a count the superseded
  read can meet first (verifier round 3: `aSupersededDetailWritesNothing` flaked, the detail still loading).
- **The demo's files name one another**: blueprint members are `DemoPeople`'s users and groups (`DEMOUSER…`, `DEMOUG…`) and
  the fleet's serials; audit subjects and actors are `DemoPeople`'s users and org unit, `DemoContent`'s Wi-Fi setting and
  the fleet's serials (two released devices `TEST…`); Apple MDM's devices are the fleet's. `DemoTests` holds it.
- **Check live (Phase 2):** whether the users list carries `phoneNumbers` and `roleOuList` or only `users/{id}` does;
  whether a group's `totalMemberCount` is its linkage count (smart groups too), and whether member lists hold users
  `/v1/users` doesn't return; whether a group's and a role's `ouId`, and an audit role's `locationUniqueIdentifier`, are org
  unit ids; whether a USER audit subject's or actor's id is the `/v1/users` id, and a device event's `subjectId` its serial
  (the timeline filters on it; else it says no event names the device); whether `apps/{id}` and `packages/{id}` carry the
  lists' attributes, a package's url ever carries credentials or a signed query, and a custom app has an `appStoreUrl`;
  whether a blueprint read includes the user and group resources the role can read (for names); whether a
  `CUSTOM_PROFILE` carries `customSettingsValues`; whether a role that can't read details gets 403 on every device's, a
  details record's serial always matches, and what iPhones and iPads send for FileVault and the firewall; whether 50
  details per load suits real fleets and rates; and how long the Dashboard's seven-day audit read takes on a busy org,
  since the endpoint has no `sort` and every page is read to find the newest ten. Manual: whether VoiceOver reads a
  Chart's `accessibilityValue` (each chart's summary).

## Testing / live-verification status
- Offline: green. Live (operator, Phase 1): device count and a 20-serial sample against abapit; Activation
  Lock for 20 serials (rate); a forbidden section reading "your role can't read this".
- Live (operator, Phase 2): the acceptance pass on a Business org, its 25 Business-only lines read whole and each
  "Assumed, check live" item above answered; a blueprint read with a role that can't read users (the fallback); a
  School org's pass sending no Business-only read.
