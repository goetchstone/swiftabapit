# Domain: history

**One line:** Snapshots in SQLite on abapit's schema, per-provider collectors, diffs, reports and the abapit history import (plan L7, phase 3).

**Owns invariant(s):** #6, #8, and #11 for CSV export

**Status:** Phase 3 in progress (split into PRs, 2026-11-20): the snapshot store is built (`SnapshotStore`, below); the
collectors, the abapit import, the diff, the reports and scheduled snapshots follow. The Reports module (CSV, the export
policy, Find, the dashboard's stats) shipped in phase 1b, and the audit digests and the dashboard's quiet services and
recent events in phase 2a; their notes are below.

## Files

- `Packages/AbapitKit/Sources/History/`: `SQLite.swift` (a thin wrapper over the system `SQLite3`: values bound and
  read by their bytes, a transaction that rolls back on any error), `Schema.swift` (abapit's `SCHEMA` word for word, this
  app's additions, `StoredJSON`, `taken_at`'s text) and `SnapshotStore.swift` (the actor).
- `Packages/AbapitKit/Tests/HistoryTests/`: `SnapshotStoreTests`, `SchemaTests`, and `Scratch` (a temporary folder by
  its real path, synthetic orgs and devices, a second connection that looks at the file from outside the store).
- `Packages/AbapitKit/Sources/Reports/`: `CSV.swift` (the writer, the formula guard, `ExportPolicy`),
  `Find.swift` (⌘L), `DeviceStats.swift` (the Overview's counts, the assignment summary), `AuditDigest.swift`
  (the `AuditView` sets, `AuditDigest`, `newestFirst`, `recent`), `QuietServices.swift` (services not connected
  in N days; `lastConnected` public, so the Services screen reads a service's last connection the same way).
- `Packages/AbapitKit/Tests/ReportsTests/`: parity against `Tests/Fixtures/parity/{csv,reports}.json`,
  `ExportPolicyTests`, `FindTests`, `AuditDigestTests`, `QuietServicesTests`.
- `scripts/gen_fixtures.py`: `gen_csv` (`csv_edges`, `corrected_safe`, the `csv.reader` round trip) and
  `gen_reports` (`stats_edges`, `audit_edges`, `corrected_audit_digest`, and `audit_types`, abapit's two sets).

## How it works

### The snapshot store

- **One file on abapit's schema** (plan L7): `history.sqlite` in the folder the app injects (`Application
  Support/abapit`, beside `orgs.json`), or `.memory` for the demo and the tests. For a new, empty file, abapit's `SCHEMA`
  runs first, unchanged (`SchemaTests` pins its SHA-256 to abapit's text at the pin); then version 1's additions:
  `org_id`, `notes` and `counts` on `snapshots`, an index on `(org_id, id)`, and `activation_lock_view` (serial,
  `is_locked`, `lock_type`) over the items recorded as `SnapshotStore.activationLockResource` (`activation_lock`). The
  plan's `schema_version` is `PRAGMA user_version` (1), set in the same transaction, which reads the version and checks
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
  - `orgIDs()`: every org id with any snapshot.
- **One org at a time**: every query filters by `org_id`, the org's `OrgProfile.id` (never the client ID: a Mosyle org
  has none). Another org's snapshot is refused as one that isn't there (`.noSnapshot`); an org with no id is refused
  (`.noOrg`).
- **An org's history is never inherited** (coordinating session's proposal, 2026-11-20, for the operator): org ids are
  slugs of names, so a removed org's id can come round again. `OrgStore.uniqueID(for:avoiding:)` must also avoid
  `SnapshotStore.orgIDs()`, as it already avoids ids with Keychain items, and removing an org offers to delete its
  history (`removeAll(org:)`). Both are wired in the collector PR, which adds the `AppModels → History` edge.
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

## Testing / live-verification status

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
- Phase 3 goldens (generated, nothing reads them in Swift yet): `diff.json` (40 drawn + 32 hand-written
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
