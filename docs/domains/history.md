# Domain: history

**One line:** Snapshots in SQLite on abapit's schema, per-provider collectors, diffs, reports and the abapit history import (plan L7, phase 3).

**Owns invariant(s):** #6, #8, and #11 for CSV export

**Status:** stub — filled in by phase 3. Until then, read the plan section named above and the nearest
SwiftGamGui runbook. The Reports module (CSV, the export policy, Find, the dashboard's stats) shipped in
phase 1b, and the audit digests and the dashboard's quiet services and recent events in phase 2a; their notes
are below. The Phase 3 fleet reports (Activation Lock, migration, service health, out of warranty, the catalog) are built (PR #29);
the parity goldens for the store, diff and coverage are merged (PR #28), and the Swift snapshot store, collectors and diff are still to do.

## Files

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
  `days_left` is `timedelta.days` (floor); soonest first, equal days in input order. Added, not in abapit: `notRead`, the
  serials whose coverage sweep failed. A device with no active record that is in it is `notRead`, never `uncovered`
  (an unread device is not an unprotected one); with none given the report is abapit's.
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
- **Who wasn't read** (`notRead`, no default: a caller must say, so a missing entry can't pass for a read one): both
  reports take the serials whose AppleCare sweep failed. A device with no active record that is among them is `notRead`
  in `CoverageReport`, and `covered` nil in `FleetAgeReport` (counted in `notReadCandidates`, never in
  `uncoveredCandidates`; the refresh-candidates CSV writes `not read` in `activeCoverage`, where no coverage data leaves it
  empty and a read device says `True` or `False`). A later PR (the collector and the Reports screen, after
  PR #29 merges) aligns both with #29's `DeviceRead`/`ListRead`, which treat a missing entry as not read; this PR imports
  none of it.
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

- **Export a new view**: add its `Columns` to `ExportPolicy` (documented attributes only, nothing secret),
  call `CSV.text(items, columns: ExportPolicy.<view>)`, and pin the list and the denylist check in
  `ExportPolicyTests`. Never make `Columns.init` public: the compiler is the allowlist's enforcement.
- **Change the guard or the writer**: change `corrected_safe` or `corrected_csv` in `gen_fixtures.py` first,
  regenerate, and keep the deviation count in `everyCSVDeviationIsAContainerOrTheWiderGuard` honest.
