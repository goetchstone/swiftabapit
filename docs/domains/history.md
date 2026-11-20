# Domain: history

**One line:** Snapshots in SQLite on abapit's schema, per-provider collectors, diffs, reports and the abapit history import (plan L7, phase 3).

**Owns invariant(s):** #6, #8, and #11 for CSV export

**Status:** Phase 3 in progress (split into PRs, 2026-11-20): the snapshot store is built (`SnapshotStore`, below; PR #30);
the Needs-attention store and `settings.json` are built (PR #33; below); the fleet reports (Activation Lock, migration,
service health, out of warranty, the catalog) are built (PR #29); the parity goldens for the store, diff and coverage are
merged (PR #28); the diff, coverage and fleet-age ports are built (PR #31), and read devices as the fleet reports do
(PR #32). The Apple collector is built on branch
`phase-3-apple-collector` (below, "The Apple collector"), without its per-device sweeps. The sweeps, the Mosyle collector,
the abapit import, the Changes screen and scheduled snapshots are still to do. The Reports module (CSV, the export policy,
Find, the dashboard's stats) shipped in phase 1b, and the audit digests and the dashboard's quiet services and recent
events in phase 2a; their notes are below.

## Files

- `Packages/AbapitKit/Sources/History/`: `SQLite.swift` (a thin wrapper over the system `SQLite3`: values bound and
  read by their bytes, a transaction that rolls back on any error), `Schema.swift` (abapit's `SCHEMA` word for word, this
  app's additions, `StoredJSON`, `taken_at`'s text) `SnapshotStore.swift` (the actor) and `AttentionStore.swift` (the Needs-attention methods on it).
- `Packages/AbapitKit/Sources/Orgs/LocalSettings.swift` (`settings.json`) and its `OrgsTests/LocalSettingsTests`.
- `Packages/AbapitKit/Tests/HistoryTests/`: `SnapshotStoreTests`, `SchemaTests`, `AttentionStoreTests`, and `Scratch` (a temporary folder by
  its real path, synthetic orgs and devices, a second connection that looks at the file from outside the store).
- `Packages/AbapitApp/Sources/AppModels/`: `SnapshotPolicy.swift` (what a snapshot keeps of each resource: the allowlist,
  error codes) and `SnapshotCollector.swift` (the Apple collector; `ScreenModels.snapshots`); `OrgsModel.history` (the
  store, or why it didn't open) and its `takenIDs`. Tests: `Packages/AbapitApp/Tests/AppModelsTests/CollectorTests.swift`.
- `Packages/AbapitKit/Sources/Reports/`: `CSV.swift` (the writer, the formula guard, `ExportPolicy`),
  `Find.swift` (⌘L), `DeviceStats.swift` (the Overview's counts, the assignment summary), `AuditDigest.swift`
  (the `AuditView` sets, `AuditDigest`, `newestFirst`, `recent`), `QuietServices.swift` (services not connected
  in N days; `lastConnected` public, so the Services screen reads a service's last connection the same way),
  `SnapshotDiff.swift` (`diff_snapshots`, `item_label`), `Coverage.swift` (`coverage_report`), `FleetAge.swift`
  (`fleet_age_report`), `ExportHistory.swift` (the refresh-candidates and expiring-coverage CSVs), and the Phase 3 fleet
  reports (below: `ActivationLockReport`, `MigrationReport`, `ServiceHealth`, `WarrantyReport`, `ReportCatalog`, `ExportFleet`).
- `Packages/AbapitKit/Tests/ReportsTests/`: parity against `Tests/Fixtures/parity/{csv,reports}.json`,
  `ExportPolicyTests`, `FindTests`, `AuditDigestTests`, `QuietServicesTests`, and one suite per fleet report;
  `SnapshotDiffTests` (`diff.json` and `history.json`'s diff reads), `CoverageFleetAgeTests` (`reports.json`),
  `ExportHistoryTests`.
- `scripts/gen_fixtures.py`: `gen_csv` (`csv_edges`, `corrected_safe`, the `csv.reader` round trip) and
  `gen_reports` (`stats_edges`, `audit_edges`, `corrected_audit_digest`, and `audit_types`, abapit's two sets).

## How it works

### The snapshot store

- **One file on abapit's schema** (plan L7): `history.sqlite` in the folder the app injects (`Application
  Support/abapit`, beside `orgs.json`), or `.memory` for the demo and the tests. For a new, empty file, abapit's `SCHEMA`
  runs first, unchanged (`SchemaTests` pins its SHA-256 to abapit's text at the pin); then version 1's additions:
  `org_id`, `notes` and `counts` on `snapshots`, an index on `(org_id, id)`, and `activation_lock_view` (serial,
  `is_locked`, `lock_type`) over the items recorded as `SnapshotStore.activationLockResource` (`activation_lock`). The
  plan's `schema_version` is `PRAGMA user_version` (2: version 2 adds the `attention` table, below), set in the same transaction, which reads the version and checks
  the file is empty again under the write lock. Foreign keys are on for every connection the store opens, so a
  snapshot's items go with it.
- **Only a file this app made** (coordinating session's proposal, 2026-11-20, for the operator): a file at version 0 that
  already holds tables (abapit's history copied in, another program's database) is refused (`.notThisAppsFile`: "import
  abapit's history instead") before any write lock is taken on it, and again under the write lock (another connection
  can fill an empty file between the two: `aFileFilledAfterTheFirstLookIsRefusedUnderTheLock`). An existing file with a
  second name on disk (a hard
  link) is refused before SQLite opens it (`.hardLinked`). Either is left as it was, bytes and mode: a file's mode is
  narrowed only once it is accepted. The import (a later PR) reads abapit's file read-only and copies its rows, as the
  plan says; nothing here changes abapit's file.
- **A file from a newer version is read, never written**: a `user_version` above `Schema.version` opens with `PRAGMA
  query_only`, `access` is `.readOnly(version:)`, and `record`, `prune` and `removeAll` throw `.readOnly`, whose message
  says a newer abapit wrote it.
- **The owner's alone, from the first instant**: missing folders are made `0700` by `mkdirat`, and the store's own
  folder is narrowed to `0700` if it was wider. `history.sqlite` is made by `openat(O_CREAT | O_EXCL | O_NOFOLLOW, 0600)`
  before SQLite opens it (without `SQLITE_OPEN_CREATE`), so it is `0600` the moment it exists, never made and then
  narrowed; an accepted existing wider file is narrowed. SQLite gives its journal the database's mode (abapit's default
  rollback journal; the store never turns WAL on).
- **Links**, exactly:
  - The store reaches its folder from `/` one name at a time, each opened `O_DIRECTORY | O_NOFOLLOW` relative to the
    descriptor of the folder above (`openat`), made there (`mkdirat`) where missing, and makes or opens the database
    relative to the folder's descriptor (`openat`, `O_NOFOLLOW`). A link anywhere on the way is refused (`.link`), and a
    link put in place of a folder the walk has already opened leads nowhere: what the store makes goes into the folder
    it holds, so the link's target receives nothing (`aLinkSwappedInDuringTheWalkReceivesNothing`).
  - SQLite can't be handed a descriptor, so it opens the database by its path, with `SQLITE_OPEN_NOFOLLOW`: a link
    anywhere in that path when SQLite opens it is refused (`aLinkSwappedInAfterTheChecksIsRefused`). It makes its journal
    by path later, opened without following a link in its last name (a link planted there fails the write and its target
    isn't made, `aLinkedJournalIsNeverWrittenThrough`).
  - What the walk guarantees (made `0600`, one name, its folder `0700`) holds for the file behind the store's
    descriptor. SQLite opens a path, not that descriptor: something running as the same user that renames a real folder
    on the path (no link) between the walk and SQLite's open can make SQLite open another file there, which the walk
    never looked at (the delta review's probe, 2026-11-20). After the open, a folder above swapped for a link could
    receive a journal SQLite makes by path; SQLite refuses to write once the database's path no longer reaches the file
    it opened (`SQLITE_READONLY_DBMOVED`), which narrows that window to the instant between its check and the journal's
    creation. Both need code running as the operator, which can read the file anyway.
- **The API** (an actor; each call throws `SnapshotStore.Failure`, whose `message` is in the operator's words):
  - `record(org:takenAt:resources:errors:notes:)`: one transaction, so a failure part way leaves no row. Items by
    abapit's `INSERT OR REPLACE INTO items VALUES (?, ?, ?, ?)`: two items of a resource with one id keep the last.
    Attributes are stored as abapit stores them (`StoredJSON`: `json.dumps(sort_keys=True)`, ASCII escapes), so they
    load in abapit's order (keys sorted). `errors` and `notes` are JSON objects of words, keys sorted (abapit kept the
    collectors' order; a Swift dictionary has none). `counts` holds, for every resource in `resources`, the items
    recorded (distinct ids), zero included; a resource that failed goes in `errors` and one not tried is in neither.
    `taken_at` is abapit's `strftime` text (UTC, whole seconds); the caller passes the time, so an import can keep the
    original one. `org_scope` is the Apple scope, or the provider's name (`mosyle`) for another org; `org_client_id` is
    empty for a Mosyle org; `abapit_version` is `swiftabapit <version>`, so a row this app wrote is never taken for
    abapit's. Text is bound by its bytes: a NUL inside a name or an id is kept.
  - `snapshots(org:limit:)` newest first by id, at most 100 by default, with abapit's `device_count` and `counts`;
    `load(_:org:)` every item, each resource's items by id.
  - `latest(_:org:)` (coordinating session's proposal, 2026-11-20, for the operator): the newest snapshot that tried to
    read the resource (it is in that snapshot's `counts` or `errors`) answers. If it read it, `.read` with what it found,
    possibly nothing ("none at T2", where abapit's `latest_resource` showed an older copy as current); if it failed,
    `.failed` with its error and the last good copy: the newest snapshot that read the resource without an error, an
    empty read included ("failed at T2; showing T1"; T1 read a device, T2 none, T3 failed: "failed at T3; showing T2's
    none", plan §2.3 defect 13). A read that recorded part and then failed (in `counts` and `errors` both) is never a good
    copy. A snapshot that didn't try is passed over; nil when none tried. Each answer carries its snapshot's `takenAt`, so
    its age always shows (invariant 8).
  - `prune(org:keep:)` keeps the org's newest `keep` **by id** (an import records old snapshots after new ones, so
    `taken_at` would keep the wrong ones), and the items go too; a negative `keep` removes nothing. `removeAll(org:)`
    for an org the operator removed with its history.
  - `orgIDs()`: every org id with any snapshot or Needs-attention finding (PR #33).
- **One org at a time**: every query filters by `org_id`, the org's `OrgProfile.id` (never the client ID: a Mosyle org
  has none). Another org's snapshot is refused as one that isn't there (`.noSnapshot`); an org with no id is refused
  (`.noOrg`).
- **An org's history is never inherited** (coordinating session's proposal, 2026-11-20, for the operator): org ids are
  slugs of names, so a removed org's id can come round again. A new org's id (`OrgStore.uniqueID(for:avoiding:)`) avoids
  `SnapshotStore.orgIDs()` (snapshots and, since PR #33, findings) as it avoids the ids with Keychain items: `OrgsModel.takenIDs`, wired in the collector PR with
  the `AppModels → History` edge, for an Apple and a Mosyle Add alike (`aNewOrgNeverTakesAnIDWithHistory`). A history
  that didn't open can't say which ids it holds, so it is opened again at each Add (and each snapshot), and an Add is
  refused only while it still can't be, saying why and what to do: fix what the message names or move `history.sqlite`
  aside, then add again (`aHistoryThatDidntOpenRefusesAnAdd`, `aHistoryThatFailedToOpenIsOpenedAgainAtTheNextAdd`; the
  executor's choice, refined by the coordinating session's review: one failure must not block Adds for the session).
  Removing an org keeps its history; the offer
  to delete it (`removeAll(org:)`) is a question in Settings' removal, so it comes with the Changes screen, the first UI
  over the history.
- **What it never holds**: a secret, or a custom setting's profile (operator, 2026-10-31; Gotchas below). The collectors
  decide what is recorded. As a backstop (coordinating session's decision, 2026-11-20, for the operator), `record` leaves
  out every attribute, at any depth, whose name `ExportPolicy.isSensitive` reads as a secret's, keeps the rest of the
  item, and adds to that resource's note the number left out ("2 attributes left out: their names look like a
  secret's"), never their names: an object keyed by data (a device's name, say) would echo the data. A member left out
  isn't looked into. The trade-off: an attribute Apple adds whose name only looks like a secret's is left out and
  counted, never stored, until a collector or this rule changes. Audit events aren't snapshotted: their
  `eventDataAccountPasswordChanged` and `eventDataBatchPasswordResetInitiated` keys would be left out.
- **A row changed outside the app says so** (`.corrupt`, never an empty value or U+FFFD): attributes, errors, notes or
  counts that don't read as theirs (abapit's `json.loads` raised too); text in any column that isn't UTF-8, naming the
  column; and a JSON escape of half a character (a lone surrogate, `\uD800` to `\uDFFF` without its other half),
  naming the column. `JSONValue.parse` reads that escape as U+FFFD, which would change an id or merge two keys, so the
  store looks for one before it parses (`SnapshotStore.hasLoneSurrogate`); `JSONValue.parse` itself is unchanged for
  its other callers. This app never writes one: `StoredJSON` writes a pair.
- **Numbers keep their text** (the one deviation in `StoredJSON`): abapit's `json.dumps` writes what Python read, so
  `-0` became `0`, `1.50` `1.5`, `1e2` `100.0`, `3.0e-5` `3e-05` and `1e400` `Infinity`; this store keeps `-0`,
  `1.50`, `1e2`, `3.0e-5` and `1e400`. So a diff must compare numbers by value (1 is 1.0, as the operator reads them),
  never by `JSONValue.==`, which compares their text. Apple's and Mosyle's numbers are integers.

### The Apple collector (Phase 3)

- **What a snapshot keeps is the operator's** (2026-11-20, answering "Minimal (Recommended)"): "Devices, services, apps,
  packages, configurations, AppleCare and Activation Lock as abapit kept them, minus: package download URLs, services'
  last-connected IPs, MDM-detail IMEI/MEID/MAC addresses, and error text (codes only). People: only the Managed Apple
  Account, status, external flag and dates; no names, emails, phones, job titles or departments. Profiles' Wi-Fi/VPN
  passwords are never kept (already decided)." And (2026-10-31) a configuration is `Configuration.resource`, its profile
  withheld, not even hashed.
- **Two more answers of the operator's** (2026-11-20, asked once the collector was built):
  - Asked "Apple's main device list carries the same identifiers (IMEI, MEID, Wi-Fi/Bluetooth/Ethernet MAC). Leave them out
    of snapshots there too?", the operator answered "Leave them out (Recommended)": `devices` keeps no IMEI, MEID or MAC
    address, and `theAllowlistIsTheOperatorsMinimal` holds every list to no `imei`, `meid`, `eid` or `…MacAddress` by
    name, so one Apple adds can't join a list unseen. `eid` (the eSIM's identifier) wasn't named in the question; it is left
    out as a hardware identifier of the same kind: the coordinator's reading of the operator's device-list answer (the side
    that stores less), which the operator can overrule.
  - Asked whether to keep blueprints (abapit kept them: name, description, status, dates; not their members), the operator
    answered "Keep them (Recommended)": `blueprints` is the list as abapit read it (no `include`), with
    `appLicenseDeficient`, which Apple's blueprint resource carries and abapit stored; never a member, a single blueprint
    or a relationship's list (`aBlueprintIsKeptWithoutItsMembers`).
- **An allowlist per resource** (`SnapshotPolicy`), written out and compared by bytes, never a denylist: abapit stored
  every attribute Apple sent, so an attribute Apple adds later is left out here until a review adds it to the list, and
  the snapshot's note counts how many such attributes were left out ("left out 2 attributes Apple sent that this version
  doesn't keep until reviewed"), never their names. `known` is each view's `fields` (held to the contract by
  `ModelContractTests`): a documented attribute the policy doesn't keep (a user's email) is left out without a note.
  `CollectorTests.theAllowlistIsTheOperatorsMinimal` writes every list out a second time, holds each to `known`, and holds
  none to look like a secret's (the store's backstop would drop it from every row unsaid).

  | Resource (the store's name) | Read | Kept |
  |---|---|---|
  | `devices` | `orgDevices` | all 24 documented attributes but `imei`, `meid`, `eid`, `wifiMacAddress`, `bluetoothMacAddress` and `ethernetMacAddress` (18) |
  | `mdm_servers` | `mdmServers` | all but `lastConnectedIp` |
  | `assignments` | each service's device list | abapit's shape: one item per serial, `serverId`, `serverName` |
  | `users` | `users` | `status`, `managedAppleAccount`, `isExternalUser`, `startDateTime`, `createdDateTime`, `updatedDateTime` |
  | `user_groups` | `userGroups` | `status`, `type`, `totalMemberCount`, the two dates: not `name`, which can name people, nor `ouId` |
  | `apps` | `apps` | all 7 |
  | `packages` | `packages` | all but `url`; every string with any address masked (`ContentWords.addresses`), noted |
  | `blueprints` | the list | all 6 (`name`, `description`, `status`, `appLicenseDeficient`, the two dates); never members |
  | `configurations` | the list | all 6 of `Configuration.resource`: the list sends a profile as null, and the single read is never made |
  | `mdm_enrolled` | `mdmDevices` | `serialNumber`, `productFamily`, `enrolledUserId`: not `deviceName`, which commonly holds its user's name |
  | `applecare` (sweep) | per device | all 9, and the serial it was read for (abapit's shape) |
  | `activation_lock` (sweep) | per device | `isLocked`, `lockType` |
  | `mdm_details` (sweep) | per Apple-managed device | the posture: no IMEI, MEID, MAC address or `deviceName` |

  Not kept: org units, blueprints' members, audit events and webhooks. Who decided: the operator decided what to keep (the
  "Minimal" answer, the device list's identifiers, blueprints); the lists are the executor's translation of those words,
  reviewed; the coordinating session, the scope (no org units, blueprint members, audit events or webhooks) and `eid` left
  out with the other identifiers (the coordinator's reading of the operator's device-list answer); the executor, for
  review, `user_groups`' and `mdm_enrolled`'s lists (no names) and masking a package's other strings.
- **Errors are codes** (`SnapshotPolicy.code`): the HTTP status and Apple's `code` when it is two or more words of capital
  ASCII letters joined by `_` or `.` ("HTTP 403 FORBIDDEN_ERROR", "HTTP 400 PARAMETER_ERROR.INVALID"), or this app's word
  ("transport", "keychain", "malformed"); never Apple's `detail`, a parameter, a URL or a `code` of another shape.
- **Per resource, never all or nothing** (abapit's `_collect`): a resource that fails is its code in `errors`, the rest
  are read; one that failed after some pages keeps them, in `counts` and `errors` both, so `latest` never takes it for a
  good copy, and one that failed before any is in `errors` only (`aListThatFailedPartWayKeepsWhatItRead`). **A list the
  page cap cut is a part read too** (the review, 2026-11-20): its items with the error `page cap`
  (`SnapshotPolicy.pageCap`), so `latest` never takes it for a good copy and a Needs-attention rule, whose caller judges
  only whole reads, doesn't judge it; so are `assignments` built from a cut services list or a service's cut device list.
  A failure of the key, the token or the account (401, the token endpoint, the Keychain) stops the asking: every later
  read would fail the same way, and a refused Touch ID would be asked again for each, so each resource after it is "not
  asked after HTTP 401", and the services' device lists after it aren't asked either ("1 of 3 services' device lists
  couldn't be read; 2 weren't asked after the sign-in failed"). `assignments` is "not read: mdm_servers failed" when the
  services weren't read, a failed read (never "none assigned") when every service's list failed, and keeps what the other
  services' lists gave when one fails (its code, and "1 of 2 services' device lists couldn't be read"); a service whose id
  can't be sent is never asked for and makes the assignments a part read ("unsendable id").
- **`notes`** say what was read in part: a list the page cap stopped ("stopped at the page limit: 1000 of 1001 read", or
  "…, more not read" without Apple's total), the services read with Apple's default fields and the kept attributes no
  service came back with (`Page.absent`), attributes left out unknown, addresses masked in a package, and for
  `assignments` the services not covered. Every resource a run read is in `counts` (the store's), zero included.
- **One org, captured.** A run captures the active org's profile, its client and `OrgsModel.generation` at the start,
  reads only through that client (the screens', so the org's rate limiter and page cap) and records under that profile,
  never `orgs.active`: a rename mid-run records the name it started with (`theSnapshotIsTheCapturedOrgs`). An org or
  client switch (`onSwitch`) or `cancel()` stops it; it checks its token, its task and the generation after every page
  and await. **A run stopped before its write writes nothing; a switch during the write lets it finish under the org it
  started for, and its outcome is not shown under the new org** (`anOrgSwitchMidRunWritesNothing`,
  `aClientSwitchMidRunWritesNothing`, `aSwitchDuringTheWriteFinishesUnderTheOrgItStartedFor`, which switches through the
  collector's `package` hook `beforeWrite`, after the last check). A switch clears `lastOutcome` and `refusal`, and
  `finish` shows an outcome only while the orgs are on the generation its run started for. One run at a time: a call
  while one runs is refused, and the refusal stays in `refusal` (`run()`'s result can't be discarded); after a switch it
  says the previous organization's snapshot is still stopping (`aRefusalAfterASwitchSaysThePreviousRunIsStopping`).
- **School**: a rule marked `businessOnly` isn't tried for an Apple School Manager org, which then has `devices`,
  `mdm_servers` and `assignments` only, and sends nothing else.
- **The sweeps** (AppleCare, Activation Lock and the Apple MDM details: one read per device) have their rules here and
  their slot in the collector; they run in the next PR, with plan §3.6's bounded fan-out and retry pass. Until then a
  snapshot has none of them in `counts` or `errors`, so `latest` passes over it for them.
- **The store** is opened at launch in `AppServices` (`history.sqlite` in `Application Support/abapit`, beside
  `orgs.json`; in memory for the demo) through an opener handed to `OrgsModel`, which opens it again when it is needed
  while the last try failed (`openHistory`); the collector takes it from there. No screen starts a
  snapshot yet: the Changes screen and "Snapshot now" come later.

### Needs attention: the store and the local settings (PR #33)

- **What is stored** (plan §8.0, "Stored: only what can't be read again"): `AttentionStore.swift` adds methods to
  `SnapshotStore`, not a second store, because the table is in the same file (`attention`, `PRAGMA user_version` 2) and so
  has the same walk from `/`, modes, refusals and read-only access for a newer file. A row is
  `(org_id, rule, subject, first_seen, last_seen, dismissed_at, snoozed_until)`, primary key `(org_id, rule, subject)`.
  `last_seen` is the one column beyond the plan's list (**a proposal, for the operator to confirm**): without it a finding
  that is gone can't be forgotten after 30 days.
  `subject` is an identifier (a serial number, a service or activity id), never a name. **It never holds** a name, a
  message, a secret or any attribute of the device; what a finding says is computed from the latest snapshot every time.
  The sensitive-key leave-out (`withoutSecrets`) has nothing to act on here, because no attribute is stored.
- **Migration 1 to 2** runs `Schema.toVersion2` (one `CREATE TABLE`, then `user_version = 2`) in one `BEGIN IMMEDIATE`
  transaction, the version read again under the lock. It never names `snapshots`, `items` or a view;
  `aVersionOneFileMigratesAndKeepsEverySnapshotByteIdentical` compares every row before and after. The file safety is
  the snapshot store's, unchanged (`theMigrationKeepsTheFileSafety`: a wider mode is narrowed, a link refused, the file
  left at version 1). A version-1 file must have this app's `snapshots` shape (`org_id` and `counts` columns), else `.notThisAppsFile`, the file
  untouched (a foreign file can carry `user_version` 1). The version is read again under the lock (hook steps
  `foundVersion1`, `migrating`; `twoStoresOpeningAVersionOneFileMigrateItOnce`). A new file is made version 2 in one script. `removeAll(org:)` also deletes the org's findings.
- **Semantics** (the coordinating session's proposals, for the operator to confirm):
  - `seen(org:rule:subjects:at:)` takes every subject one run of a rule found (none is valid). A new subject gets
    `first_seen`; `first_seen` is never written for a row that exists (the conflict clause names only `last_seen`, which
    only moves forward). An empty rule or subject is refused.
  - `dismiss` and `snooze` need a row `seen` made (`.noFinding` otherwise, so no row is invented); the latest choice wins
    (a dismissal clears a snooze and the reverse). A dismissal holds while the finding is there. A snooze hides it until its
    date (`Finding.isHidden(at:)`), then it shows again with its original `first_seen`.
  - **Forgetting** (the 30 days is a **proposal, for the operator to confirm**): each `seen` deletes **that rule's** rows
    of the org not seen for more than 30 days (exactly 30 is kept), a dismissal included. Another rule's rows are never
    aged by the call, so a rule that isn't run keeps its findings and dismissals. This reads "a dismissal holds until the
    finding clears" as "cleared for 30 days", so one failed read doesn't un-dismiss; a finding that returns after that is new,
    with a new `first_seen`. A snooze on a finding gone 30 days goes with it.
  - **The caller's contract**: call `seen` only for a run that judged the rule over a complete read, `[]` included. For a
    rule skipped as not read, or a partial read (cut at a page cap, a resource that failed), don't call it at all, not even
    with `[]`, which would age every finding of the rule. `at` is the current time.
  - **Identifiers only**: `rule` (up to 64 characters) and `subject` (up to 128) can't be empty or hold whitespace, a control
    or format character, a quote, a slash or a backslash (`.notAnIdentifier`), so a name with a space ("Jane Example's
    MacBook Pro") can't be stored. A one-word name would pass: the collectors pass serials and ids, and this is the backstop.
    Subjects are compared by bytes: precomposed and decomposed "e with acute" are two rows.
  - `orgIDs()` lists orgs with snapshots or findings, so an org that has only findings is still a name in use.
  - There is no undo for a dismissal yet; a later screen PR adds it if the operator wants it.
  - Org isolation is the snapshots': every query filters on `org_id`; another org's finding is `.noFinding`.
- **`settings.json`** (`Orgs/LocalSettings.swift`; the file beside `orgs.json`, in the app's container; never
  `UserDefaults` or `@AppStorage`, which `scripts/check_app.sh` fails). It holds the Needs-attention thresholds, in days:
  check-in 30, AppleCare expiring 90, migration deadline 14, quiet service 30 (**proposals, for the operator to confirm**).
  `load` reads a value outside 1...3650, or not a whole number, as its default; `save` throws for one (`thresholdOutOfRange`),
  writing nothing. Written atomically (a `0600` temporary file made
  `O_EXCL | O_NOFOLLOW`, synced, renamed), read with `O_NOFOLLOW`; unknown keys, at the top and among the thresholds, are
  kept. **A file it could not read is never written over**: `load` doesn't throw, it returns the defaults with `blocked` set
  (not JSON, an `attention` value that isn't an object, not a file, a link, unreadable, or a newer version, whose values
  are read), and `save` throws that. `save` also reads the file again first and refuses on the same grounds, whatever the
  in-memory value says (a reset to defaults, or a value loaded before the file changed). A missing
  file isn't blocked. A crash between the write and the rename leaves the old file whole and a stale `.settings.json.<uuid>`
  beside it. No slots for the schedule, retention or login item yet: they come with those features.

### Reports

- **An export names its columns** (invariant 11): `CSV.text(items, columns:)` takes an
  `ExportPolicy.Columns`, which only the Reports module can make, so a screen exports one of the fixed lists in
  `ExportPolicy` (`devices` today) and an every-key list doesn't compile outside Reports. abapit's union of
  keys is `CSV.union`, internal, for the parity golden only. `ExportPolicy.isSensitive` is the second defence,
  with or without `includeNotByDefault`: it drops a listed column whose folded name (NFKD, then lowercased,
  then letters and numbers by general category, less the modifier letters NFKD leaves) holds a secret stem.
  `notByDefault` is read folded the same way and matched whole, so `last_connected_ip` stays out unasked as
  `lastConnectedIp` does, and `lastConnectedIpCount` isn't held back.
- **The writer works by Unicode scalar**, as Python's `csv` does: quoting is decided by a `,`, `"`, CR or LF
  scalar, and every `"` scalar is doubled.
- **The formula guard** is abapit's (a tab, a CR or `=+-@` first) plus a listed deviation: a cell whose first
  visible scalar is a trigger or reads as one. Visible means not in `check_text.py`'s invisible set (Cc, Cf,
  Zs, Zl, Zp, default-ignorable, U+2800), which holds Python's, .NET's and Java's whitespace. Reads as one:
  U+2212, or a compatibility form starting with `=+-@` or U+2212 (full-width, small, super- and subscript
  forms). `csv.json` lists both sets and `theGuardsSetsAreTheGoldens` holds Swift to them scalar by scalar.
- **Find** trims Python's whitespace (`str.strip()`), the set the serials golden lists, lowercases as
  Python's `lower()` does (`Find.lower`: Swift's `lowercased()` plus Unicode's Final_Sigma rule), and matches
  by code point (UTF-8 bytes), as Python's `==` and `in` do. It matches the device's id and abapit's eight
  identifier fields (`OrgDevice.identifiers`), never a model, family, status or other attribute. Only the
  query is stripped, never an identifier, and every exact hit counts, so an order number shared by several
  devices filters the table.
- **`device_stats`** counts a breakdown by the name shown: Python's `Counter` keys by value (a listed
  deviation, one fleet in `reports.json`). **`AssignmentSummary`** keeps serials as sets of UTF-8 bytes, as
  Python's sets compare code points; the denylist finds a stem in the folded key's bytes.
- **The audit views** (`AuditView`) are fixed sets of `AuditEventType` cases (`eventTypes`; `types` are their
  strings), so the compiler holds each to a type Apple documents and the 50 strings are written once, in AppleModels
  (Phase 2a review L6): abapit's Subscriptions and Device Lifecycle sets (held to the golden's `audit_types`, byte for
  byte and in order) and the new Access & Security. `otherTypes` holds the types no view shows, and
  `everyContractTypeIsPlacedOnce` holds each of the contract's 50 types to exactly one place, so a type Apple adds
  fails a test until it is placed.
- **`AuditDigest`** is abapit's `audit_digest` over Apple's `auditEvents` resources: the set's events newest first
  by instant (a listed deviation: abapit sorted the strings), equal instants in input order, undated events last;
  a count per type over the sorted rows; types matched by bytes. `recent` is the newest `recentLimit` (10) by
  instant, where abapit's dashboard showed the API's first ten. It takes `Resource`s: the client's `AuditEvent`
  pages hand theirs over as `.resource`, and a typed overload waits for a caller it would save code for.
- **`QuietServices`** lists the services more than `days` days of 86,400 s past their last connection (exactly
  `days` isn't), and those that never connected or sent a stamp that isn't a date (said apart: `never`, `unreadable`),
  most stale first; a `DELETED` service is skipped.

### Diff, coverage and fleet age (phase 3)

- **`SnapshotDiff.diff(old:new:)`** is abapit's `diff_snapshots` over two in-memory `Snapshot`s (`{resource: {id:
  attributes}}`, kept as `JSONObject`s, so an NFC and an NFD id stay two). Resources, ids and fields are ordered by
  code point (`Python.precedes`) and are distinct by bytes; a field missing from one side reads as null. Numbers
  compare by value without `Double` where both are integers: `2**53 + 1` differs from `2**53`, `10**16` equals `1e16`
  (an integer against a float compares the float's exact integer value). The store that fills a `Snapshot` from SQLite
  is the History module's. `SnapshotDiff.label` is `item_label` (no golden: abapit's web layer calls it; held by tests).
- **Two listed deviations** (the operator's decisions of 2026-11-20, in the golden's `abapit` field; `DIFF_DEVIATIONS`
  is 6 cases): a boolean is not a number, so `true` against `1` is a change (asked "should swiftabapit report true <-> 1
  as a change", answer "Report it (Recommended)"); an item is changed only when a field really changed, so `null`
  against a missing field is no change and yields no item (answer "Only real changes (Recommended)"). `1` against `1.0`
  is still no change. Two `NaN`s are equal (abapit's `json.loads` shares one `NaN` object and a
  container's `==` takes identity first, so abapit sees no change either; only a `NaN` that is itself a field, in an item
  with another change, abapit would list, since `nan != nan`; the port treats it as no change: **a listed deviation**,
  unreachable from Apple's or Mosyle's JSON, with no golden case). The generator's
  `strict_equal` has the same blind spot: a golden case for `NaN` is a follow-up for the generator.
- **`CoverageReport`** is `coverage_report`: an `ACTIVE` record (exactly) covers its serial; an end between now and
  now + days, both ends included, to the microsecond (`Instant` works in whole microseconds, as a `Date`'s `Double` can't);
  `days_left` is `timedelta.days` (floor); soonest first; equal days keep the order of the records as the device list reaches them (the device list's order, then keys matching no listed device by bytes, then the record's own order within a device; abapit's was the flat list's order, and the two agree on the goldens: **a recorded deviation**). Added, not in abapit: `notRead`, the
  devices whose coverage wasn't read (see "Read as the fleet reports do" below); never `uncovered` (an unread device is not
  an unprotected one); with every device read it is abapit's.
- **`FleetAgeReport`** is `fleet_age_report`: age is `timedelta.days / 365.25` (days floored) from `orderDateTime`, else
  `addedToOrgDateTime` (a value that is empty or doesn't read as a date falls through, but `ordered` shows the order
  text when it is truthy, even unreadable); `ageYears` is `Python.round1`, and candidates (age at least `years`)
  sort by that rounded age, descending, ties in input order. Deviation, the generator's correction (`FLEET_AGE_DEVIATIONS`,
  2 fleets; not one of the operator's two diff decisions): a device ordered more than 365 days ahead is "< 1 yr", never a
  candidate; abapit's
  `bucket_labels[min(int(age), 4)]` read `int(-1.2) = -1` as "4+ yrs". The clamp is on the bucket only: an age is never
  clamped, so a device ahead by days is not a candidate even at `years` 0. The generator's correction is right only for
  `int(age) = -1` (a device 366 to 730 days ahead): a case 731 or more days ahead (`int(age) = -2`, abapit's index -2, "3-4
  yrs") would be corrected from the wrong bucket. A follow-up for the generator; the port clamps every negative to "< 1 yr".
- **Read as the fleet reports do** (follow-up to the reviews of #29 and #31). Both reports take the device list's
  `ListRead` (default `.whole`) and the coverage sweep's reads as a map by device id (`DeviceRead<[Resource]>`: the device's
  own records, or `.notRead(why)`); a device with no entry is not read ("the sweep didn't reach this device"), the rule
  `WarrantyReport` uses. A device not read is in `CoverageReport.notRead`, and has `covered` nil in `FleetAgeReport`
  (counted in `notReadCandidates`, never in `uncoveredCandidates`); it is never covered and never uncovered. `words` says the list's
  read state first, and a list that wasn't read says only that (no zero counts). Both CSVs lead with a `listRead` column
  ("read in full", "read in part: how"), written over any record attribute of that name. Records are a device's by the key
  they sit under; keys that match no listed device still count toward `expiring`, and equal `days_left` keep the device
  list's order, then the other keys by bytes. With every device read and the list whole both reports equal the goldens
  (32 coverage and 35 fleet-age cases, the same two fleet-age deviations). **Recorded deviations from abapit**: the tie order above, and a leading `listRead` column on both history CSVs (abapit's two CSVs had none). Ids are matched by bytes: an NFC id with coverage under the NFD spelling is not that device's read. `FleetAgeReport`'s map is optional: nil is no
  coverage data; an empty map is data in which nobody was read. A list that wasn't read, or was read in part, and left no rows exports one row, `listRead` saying why and every other cell empty (every fleet CSV and both history CSVs; never a bare header).
- **Bounds**: `days` is held to 0...1825 and `years` to 0...10 in the initializers, with no overflow (abapit's routes
  allowed 1...1825 and 1...10; the goldens call `days` 0 and `years` 0, so the lower bound is 0).
- **An unreadable end** (`CoverageReport.unreadableEnd`): an active record whose `endDateTime` is there and not null but
  isn't a date (a number, an empty string, text) is counted apart, as `QuietServices` counts `unreadable`. abapit quietly
  took it as never expiring: a recorded deviation with no golden case (Apple types the field as a date-time;
  none is needed). A missing or null end is still never expiring.
- **`ExportHistory`** writes abapit's two CSVs through `CSV.text`, so the allowlist columns (`ExportPolicy.
  refreshCandidates`, `coverageExpiring`), the denylist and the formula guard apply as for every export. A coverage
  record's other attributes never leave (abapit chose these seven keys too).

## Invariants & failure history

- failure-log 2026-10-16, "Swift matched Characters where Python reads code points" (Phase 1b review H1,
  M2): a quote followed by U+0301 broke CSV quoting and let a formula cell through; the export was a
  denylist that let `escrowKey`, `recoveryKey` and a full-width `TOKEN` out.

## Gotchas / stub-lies traps

- **`standardizedFileURL` drops `/private`**: Foundation turns `/private/var/…` into `/var/…`, and `/var` is a link,
  so every test folder was refused. The store takes the folder's path as given (refusing `.` and `..`), and the tests
  use the temporary folder's `realpath` (`Scratch.folder()`).
- **`SQLITE_OPEN_NOFOLLOW` refuses a link anywhere in the path** (`SQLITE_CANTOPEN_SYMLINK`, 1550), not only the last
  component: `/tmp/…` and `/var/…` fail. The app's container path holds none.
- **abapit's items alone can't tell "read and found none" from "didn't read"**: abapit's `latest_resource` showed an
  older copy as current after a read that came back empty. `counts` records every resource read, zero included, and
  `latest` answers from the newest attempt.
- **The store's own descriptor and SQLite's locks**: the store holds the database's descriptor until it has accepted
  the file (to narrow its mode after) and closes it outside any transaction. POSIX drops a process's `fcntl` locks on a
  file when any descriptor to it closes; the delta review's two-store probe (2026-11-20) found SQLite's locks on this Mac
  unaffected by such a close, and closing outside a transaction keeps it harmless either way.
- **Resource names and the keys of `errors` and `notes` are Swift dictionary keys**, which merge canonically equivalent
  strings. They are the app's ASCII constants; an item's id is never a key (items are an array, ordered by bytes).
- **The editing tool decodes JSON's `\uXXXX`**: a test literal written with `\u0301` and `\ud83d\ude00` landed in
  the file as the characters themselves, and only the test's own failure said so (`check_text.py` passes a visible
  combining mark). Write such escapes from a script, and look for non-ASCII in what you wrote
  (`grep -nP '[^\x00-\x7F]'`).
- **A snapshot keeps no custom-setting profile** (operator, 2026-10-31: what can be read again from Apple isn't kept).
  `Configuration.resource` withholds it; the profile as Apple sent it (`Configuration.received`, `package`) holds Wi-Fi
  and VPN passwords and a certificate's key, and a snapshot is SQLite on disk, outside the Keychain (invariants 3, 11).
  A collector stores the withheld resource, and no hash of the profile (a short password's hash is guessed offline).
  A collector that read `received` would fail `BoundaryTests.onlyTheListedLinesReadTheRawProfile`. A diff sees a
  profile change only through the configuration's other attributes (`updatedDateTime`). Phase 2a verifier round 2: the
  docs had named the snapshots as a use of the raw profile.

- **`String` APIs match `Character`s; Python matches code points.** `replacingOccurrences(of:with:)`,
  `contains(_:)`, `first` and `==` on a `String` see `"` + U+0301 as one `Character` that isn't `"`, and a
  CR LF as one `Character` that is neither CR nor LF. Anything ported from Python that tests or edits
  single characters goes through `unicodeScalars`. Compare bytes in tests (`Array($0.utf8)`). The same
  holds for `Set<String>` and `[String: _]` keys (canonical equivalence), which Python's sets and dicts
  don't have: key them by `Array($0.utf8)`. A dictionary the caller builds (`deviceIDs`, keyed by service ID)
  still merges equivalent keys; service IDs are Apple's ASCII.
- **A Prepend scalar joins what follows it.** U+0600, U+06DD, U+070F, U+0890, U+08E2, U+110BD and U+110CD
  are format characters (blank to the guard) and Grapheme_Cluster_Break=Prepend, so `"\u{600}=1"` starts
  with one `Character` holding U+0600 and `=`. A guard that skipped blank `Character`s would miss the trigger;
  `CSV.safe` skips blank scalars. The golden holds such a cell (verifier round 2).
- **Swift's `lowercased()` isn't Python's `lower()`** on a capital sigma that ends a word: Python gives the
  final U+03C2, Swift U+03C3, so `\u{3A3}` found an order number `A\u{3A3}` that abapit wouldn't. For every
  other code point the two agree (per-scalar full case mapping), apart from letters newer than Python's
  Unicode version. `Find.lower` applies CPython's `handle_capital_sigma` rule, which reads Cased and
  Case_Ignorable. Swift's copies of those are newer than Python 3.12's Unicode 15: they differ on the 194
  code points Unicode 15 doesn't assign, on U+0295 (no longer cased) and on U+1171E (no longer
  case-ignorable). And Apple's data calls 40 private-use scalars from U+F870 to U+F8B8 case-ignorable, which
  Unicode never does, so `Find.isCaseIgnorable` leaves private use out. A sigma followed by a combining
  mark is one `Character` with it: look for U+03A3 by scalar.
- **A golden needs two of a kind to pin an order or a merge.** One non-ASCII unassigned serial, one spelling
  per service, no JSON key needing an escape, no `-0.0`: each let a mutant through (verifier round 2). The
  hand-written `assignment_summary` and `csv` cases now hold NFC and NFD serials in one service and in one
  unassigned list with an ASCII serial between them, and dict keys with a quote, a backslash and controls.
  `FindTests` had the same gap: no fleet had two devices sharing an identifier, so keeping only the first
  exact hit survived (verifier round 3).
- **`.whitespacesAndNewlines` isn't Python's whitespace**: it misses U+001C to U+001F, which `str.strip()`
  and `str.split()` remove. Use the golden's `python_whitespace` list (Find keeps a copy; `SerialParser`
  another; a test pins each to the golden).
- **A denylist is only a backstop.** Apple adds attributes; a new one must not leave until a view lists
  it. `ExportPolicyTests` checks the Devices list is the table's columns, then `OrgDevice.fields` in order
  (a subset check let a dropped or reordered column through), and that the denylist drops none of it (a
  listed column must not vanish silently).
- **Fold order matters.** Lowercase before NFKD missed a modifier-letter or mathematical-bold `TOKEN` (no
  lowercase until it decomposes to `T`); NFKC composed `k` + U+0301 into U+1E31, and `isAlphabetic` kept
  U+0345, so `tok\u{301}en` and `tok\u{345}en` missed `token`. The modifier letters NFKD leaves are mostly
  apostrophes, primes, length marks and the tatweel, so the fold drops them as it drops `'`: `to\u{2BC}ken`
  reads `token`. Homoglyphs (U+0441, a Cyrillic es, for the `c` of `secret`) still pass: the platform has no
  confusables table, and only a constant column list reaches the denylist.
- **A drawn golden misses the edges.** The 25 drawn `device_stats` fleets never had more than 8 models, a
  non-string value, an offset that crosses a month, or an age of exactly 30 days, so five mutants survived.
  Hand-written cases go after the drawn ones (they draw nothing, so nothing drawn moves).
- **Python's `Counter` keys by value**: `True`, `1` and `1.0` are one row, `"5"` and `5` two rows both shown
  as `5`. Swift counts names, the corrected expectation; the generator builds it by running abapit on the
  fleet with each value as `str` shows it (`shown`), and records abapit's output only where the rows read
  differently (`named`), so the other fleets keep abapit's bytes.
- **`Tally`'s `==` compares `String`s**, so a test comparing breakdowns compares bytes and counts instead.
- **A number name is its JSON text**: `1.50` stays `1.50` where Python shows `1.5`. Unreachable from the
  golden (the generator writes canonical JSON) and from Apple (the three fields are strings in the contract).
- **An audit list is ordered by instant, never by its string**, and ties compare `ISODate.date`: `ISODate`'s `==`
  compares the offset too, so two spellings of one instant would not tie.
- **One quiet-service rule, on both screens**: the Overview's card counts with Reports' `QuietServices`, and since the
  Phase 2b review (L4) the Services screen's Last connected column does too (`DevicesModel.connection(of:now:)` over
  `QuietServices.lastConnected` and the same rows), so the two screens share one rule: more than 30 days by the instant
  (not whole days), a date this app can't read said as one (never "Never"), a `DELETED` service never flagged.
  `DevicesModel.quietServices(after:)`, the whole-days rule, is gone. `PanelTests.theServicesColumnIsTheOverviewsQuietRule`
  holds the column to the card's rows.
- **Spreadsheet behaviour is unverified**: whether Excel or Numbers runs `" =1"`, `"\u{200B}=1"`, a
  full-width U+FF1D or `"\u{2212}1"` as a formula wasn't tested; the wider guard costs a `'` on such a cell
  either way. A leading combining mark isn't skipped: it shows on its own, and no trimmer drops it.

## Fleet reports (Phase 3, PR #29)

Pure, deterministic reports in `Reports/`: no UI, no store, no Apple reads of their own. They take what a screen or a
sweep already read, and each says how much of it it was given. No abapit counterpart, so no golden: the tests hold them.
Files: `ReportRead.swift` (`ListRead`, `DeviceRead`, `sent`), `ActivationLockReport`, `MigrationReport`, `ServiceHealth`,
`WarrantyReport`, `ReportCatalog`, `ExportFleet` (the CSV columns and rows); tests beside the others in `ReportsTests`.

- **The input says what was read** (invariant 8). `ListRead` is `.whole`, `.partly("showing 500 of at least 800")` or
  `.notRead("why")`, and the report's first line repeats it; a list that wasn't read prints that line only, no zero counts.
  The per-device reports (Activation Lock, warranty) take the devices plus a map of reads by device id: `.read(value)`,
  `.notRead(why)`, or no entry, which a cut sweep leaves and which counts as not read. A device not read is never an answer.
- **A value Apple sent is never "not sent"**: one in another shape is shown as its JSON text (`sent`, `unreadableDate`,
  the Services screen's `jsonText`), a date this app can't read as Apple sent it.
- **Activation Lock**: groups `lock:USER` ("blocks redeploy and release"), `lock:MDM`, `lock:NONE`, `lock:other` (a type this
  version doesn't know: shown raw in rows and CSV), `unlocked`, `unclear` (read, no readable `isLocked`), `not-read`. The CSV's
  `blocksRelease` is `yes` or `no` only where it can be judged, `unknown` for `unclear` and for a lock type this version can't
  place, `not read` for a device not read. A `USER` type on a device that isn't locked doesn't block.
- **MDM migration**: groups `status:REQUESTED|STARTED|SUCCESS|FAILED`, `status:other` (raw in rows), `no-status`, `no-data`.
  **The day rule**: 24-hour periods counted from now to the deadline instant (UTC instants). Days left round down (10 periods
  ahead is 10, a second short is 9, the instant itself 0); days overdue round up (anything past is at least 1; exactly one
  period past is 1, a second more is 2). **Past due** (`past-due`) means past the deadline with a known status other than
  `SUCCESS`; past the deadline with an unknown or missing status is counted apart (`past-due-status-unknown`) and not called
  past due; an unreadable deadline is counted, shown as sent and never past due. The CSV writes an overdue deadline in its
  own `overdue` column ("overdue N days"), never as bare days, and `pastDue` says `status unknown` or `deadline not readable`
  where it can't say yes or no.
- **Service health**: `quiet` (never connected, a last-connected value this app can't read, or silent more than `days`) is exactly `QuietServices`' rows for the same services, `now` and `days` (one rule for the
  Overview's card and this report; the status is a column beside it), `healthy` is ACTIVE and not quiet, then `inactive`,
  `deleted` (never healthy, never quiet), `other-status` (raw), `cannot-judge`. Services read with default fields: `notSent`
  lists the attributes Apple sent for no service (without `status` the words say deleted services can't be told apart and are counted); a service whose `lastConnectedDateTime` wasn't sent is `cannot-judge`, never
  quiet or "never connected", and the CSV says "not sent by Apple". Days ago are whole days, truncated as the Services screen
  does (0 is "today"); a stamp after now says "in the future". The device count is the relationship's (`exactly` or
  `atLeast`), else Apple's `deviceCount`, else "not read".
- **Out of warranty** keeps four things apart: `no-active-coverage` (records, all known statuses, none ACTIVE), `no-record`
  (the read was empty: may mean no AppleCare, not expired; apple-reads, "Answered live 2026-11-20"), `status-unknown` (a record
  with no status or one this version doesn't know, none ACTIVE: raw, never estimated, never counted as out of warranty) and
  `estimated-past-limit`, an estimate: order date plus one calendar year in UTC (29 February becomes 28), made only for the
  first two. `WarrantyReport.assumption` says it wherever an estimate shows: Apple's one-year limited warranty from the order
  date; the real term varies by country and product and starts at purchase or delivery, not the order date. `not-read` gets no
  estimate. The words count devices with no readable order date. There is no single out-of-warranty number.
- **`ReportCatalog`** is the list a later Siri step maps spoken requests onto (plan §5): four reports with id, title, filter
  tokens, inputs and CSV columns (`quiet-services` isn't one: `service-health`'s `quiet` group answers it). `resolve` takes
  only known values: case and spaces around a value or its colon normalize to the canonical token (`lock:user` and
  `status: SUCCESS` work), anything else (`lock:bogus`) is a problem, so a token never silently matches nothing.
- **A quoted cell** means Apple sent a value in a shape this app didn't expect; it is shown as sent (its JSON text, with any value under a secret-looking key, at any depth, replaced by the audit payloads' withheld marker, never shown: a
  string keeps its quotes). This holds on every row kind: an `orderDateTime` that isn't a date is quoted on active,
  status-unknown, not-read, no-record and no-active-coverage rows alike, and an ACTIVE record whose `endDateTime` isn't a
  date is never exported blank: `activeCoverageEnds` reads `end date not readable: "<as sent>"`, after the latest readable
  end if there is one. A missing or null value is blank.
- **CSV**: `ExportPolicy.{activationLockReport,migrationReport,serviceHealth,warrantyReport}`. Every export leads with a
  `listRead` column ("read in full", "read in part: how", "not read: why"); a list that wasn't read exports no judgment cells
  (they say "not read"). Every value Apple sent is written as sent (a string as it is where text is expected; any other value
  as its JSON text, so a flag sent as the string `"true"` shows its quotes), yes and no only where a value can be judged
  (`isMdmMigrationCapable` is blank when not sent); a lock type sent on any row is written, and `isLocked` beside it. A past
  deadline of a migration that isn't past due says "deadline passed N days ago", never "overdue". Each cell is computed; no source
  attribute is copied beyond the named identifying ones, so a bypass code or nested secret can't leave (a canary test per report);
  the service export never carries `lastConnectedIp`.
- **Who decided what.** The operator asked for out-of-warranty and voice reports (2026-11-20) and "just add and follow the
  plan, do it where it makes the most logical sense". The design is the coordinating session's proposal. The coordinating
  session decided, after review: "unknown" and "not read" cells instead of "no"; a separate group for an unknown coverage
  status; no count lines for an unread input; catalog values normalized and unknown ones refused; one quiet rule and no
  `quiet-services` entry; reads passed by device id; past due counting only known non-SUCCESS statuses (so `SUCCESS` is never
  past due), with the day rule above; the `listRead` column. The executor's choices, for review: the UTC calendar-year estimate,
  `lock:other` and `status:other` as the catalog's names for unknown values, `ListRead`/`DeviceRead` living in Reports, a total
  migration order (readable deadline by instant, then none, then serial).
- **Not decided here**: whether Apple lists the standard limited warranty as a coverage (a live check); the estimate stays an
  estimate until then.

## Testing / live-verification status

- The collector: `CollectorTests` (each resource as the policy keeps it; a configuration from the list, never the
  detail; a blueprint without its members; canaries for the profile's password, a package's url and description, a
  service's IP, a user's names, email, phone, job title and department, a device's and a group's names, a device's IMEI,
  MEID, EID and MAC addresses and a blueprint's members, in no byte of the folder's files; an attribute off the
  allowlist left out and counted; a package's nested strings masked; a 403 leaving the rest; error codes, never Apple's
  text; the services' default fields; the page cap, a part read, `latest` included; a list failed part-way; assignments in
  part, when every list failed, with an unsendable service id, over a cut services list, and stopped by a sign-in failure;
  a credential failure stopping the asking; an org switch, a client switch, a cancel and a rename mid-run; a switch during
  the write; a refused second run and its words after a switch; School; no org or no history; the history opened again at
  an Add; a new org's id avoiding the history's; the allowlist written out).
- The store: `SnapshotStoreTests` (what reads back; the last duplicate; `latest` answering from the newest attempt, none
  and failed included; the bounded list; one org at a time; an org with no id; prune by id with its items, counting the
  org's own only; removing an org's history; `orgIDs`; a NUL kept; a secret-looking attribute left out and counted,
  canary and all; the last good copy, empty included, never a part read that failed; an escape of half a character; a fault
  part way through a record; the folder, file and journal modes; the mode the moment the file exists; a wider folder and
  file narrowed; a linked folder, a link above it, a linked file, a link swapped in during the walk and after it, a
  linked journal; a path that isn't the store's; a newer file read-only; a row changed outside the app; text that isn't
  UTF-8) and `SchemaTests` (abapit's `SCHEMA` by SHA-256; the tables, columns, foreign key, index and views a new file
  has, and abapit's statements as SQLite keeps them; a current file isn't migrated again; abapit's file, copied or hard
  linked, refused and unchanged; a file filled after the first look refused under the lock; an empty file made this
  app's; the three views; `StoredJSON` against Python 3.12's `json.dumps(sort_keys=True)`, and the number deviation;
  `taken_at`).
- The store's parity golden, `Tests/Fixtures/parity/history.json`, merged in #28; its `schema` has the SHA-256 the pin
  holds. Its test is wired in the import PR: its reads use abapit's client-id API, and its `latest` cases encode defect
  13 (abapit's `latest_resource` passing over an empty read), so they need a listed deviation there.
- **For the import PR**: imported rows must fill `counts` (abapit's rows have none; without it `latest` passes over
  every imported snapshot).
- Goldens: `csv.json` (88 cases, 43 listed deviations: containers as JSON, and 6 for the wider guard; and
  the guard's `blank` and `triggers` sets) and `reports.json` (`device_stats` 33 cases, 1 deviation, the
  Counter fleet; `assignment_summary` 22 cases; `audit_digest` 26 cases, 15 drawn and 11 hand-written
  (`audit_edges`), 8 listed deviations: 5 rows in another order, 3 where abapit raised; and `audit_types`). The
  generator reads every expected CSV back with Python's
  `csv.reader` and fails if a cell splits, joins or starts (after blanks) with a trigger.
- Mutants for the Phase 1b fixes and verifier rounds 1 and 2 are listed in the branch's commit messages.
- Phase 3 goldens (read in Swift by `SnapshotDiffTests` (diff.json: 72 cases, 6 deviations; history.json's 7 diff reads)
  and `CoverageFleetAgeTests` (reports.json: coverage 32 cases, no deviation; fleet age 35 cases, 2 deviations); the
  rest of history.json waits for the store): `diff.json` (40 drawn + 32 hand-written
  `diff_edges`; 6 deviations, both the operator's decisions of 2026-11-20: a boolean is not a number, asked "should
  swiftabapit report true <-> 1 as a change", answer "Report it (Recommended)" (4 cases); an item is changed only
  when a field really changed, answer "Only real changes (Recommended)" (None against a missing field, 2 cases);
  abapit's output sits in `abapit`; two number cases abapit pins, 2**53 + 1 against 2**53 (changed) and 10**16
  against 1e16 (not), fail a port that compares by Double), `reports.json`'s `coverage_report` (20 + 12
  hand-written, no deviation) and `fleet_age_report` (20 + 15; 2 deviations: an order more than 365 days ahead is
  "< 1 yr", abapit's "4+ yrs" is in `abapit`), and `history.json`: abapit's `SCHEMA`, a fake database's seed rows and
  abapit's own `list_snapshots`, `latest_resource`, `snapshot_resource`, `diff_snapshots`, `latest_applecare` (37
  reads) and, in order, `prune` (8 steps). The generator holds every case of those functions, the drawn ones and
  history.json's diff reads too, to the corrected function and stops on a difference it doesn't list.
- Find has no parity golden (abapit's `/find` is in `web/app.py`, not a pure module): `FindTests` holds it,
  with Python 3.12's own outputs written in for the final-sigma cases.

## To do common tasks here

- **Change the schema**: add `Schema.toVersion2` (never edit abapit's text: `abapitsSchemaIsCopiedByteForByte`), bump
  `Schema.version`, and run it in `SnapshotStore.prepare` for a file at version 1, in the same transaction that reads the
  version again. A file above it stays read-only; a file at 0 that isn't empty is still refused.
- **Export a new view**: add its `Columns` to `ExportPolicy` (documented attributes only, nothing secret),
  call `CSV.text(items, columns: ExportPolicy.<view>)`, and pin the list and the denylist check in
  `ExportPolicyTests`. Never make `Columns.init` public: the compiler is the allowlist's enforcement.
- **Change the guard or the writer**: change `corrected_safe` or `corrected_csv` in `gen_fixtures.py` first,
  regenerate, and keep the deviation count in `everyCSVDeviationIsAContainerOrTheWiderGuard` honest.
