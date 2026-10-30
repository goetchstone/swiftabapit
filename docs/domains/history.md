# Domain: history

**One line:** Snapshots in SQLite on abapit's schema, per-provider collectors, diffs, reports and the abapit history import (plan L7, phase 3).

**Owns invariant(s):** #6, #8, and #11 for CSV export

**Status:** stub — filled in by phase 3. Until then, read the plan section named above and the nearest
SwiftGamGui runbook. The Reports module (CSV, the export policy, Find, the dashboard's stats) shipped in
phase 1b, and the audit digests and the dashboard's quiet services and recent events in phase 2a; their notes
are below.

## Files

- `Packages/AbapitKit/Sources/Reports/`: `CSV.swift` (the writer, the formula guard, `ExportPolicy`),
  `Find.swift` (⌘L), `DeviceStats.swift` (the Overview's counts, the assignment summary), `AuditDigest.swift`
  (the `AuditView` sets, `AuditDigest`, `newestFirst`, `recent`), `QuietServices.swift` (services not connected
  in N days).
- `Packages/AbapitKit/Tests/ReportsTests/`: parity against `Tests/Fixtures/parity/{csv,reports}.json`,
  `ExportPolicyTests`, `FindTests`, `AuditDigestTests`, `QuietServicesTests`.
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
- **The audit views** (`AuditView`) are fixed sets of Apple's `AuditEventType` strings: abapit's Subscriptions and
  Device Lifecycle sets (held to the golden's `audit_types`, byte for byte and in order) and the new Access &
  Security. `otherTypes` holds the types no view shows, and `everyContractTypeIsPlacedOnce` holds each of the
  contract's 50 types to exactly one place, so a type Apple adds fails a test until it is placed.
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
- **Two quiet-service rules exist until 2b**: the Phase 1b screen model's `DevicesModel.quietServices(after:)` counts
  whole days and keeps `DELETED` services; Reports' `QuietServices` is the exact rule. The 2b dashboard moves the
  Overview onto `QuietServices`, so the two screens can't disagree.
- **Spreadsheet behaviour is unverified**: whether Excel or Numbers runs `" =1"`, `"\u{200B}=1"`, a
  full-width U+FF1D or `"\u{2212}1"` as a formula wasn't tested; the wider guard costs a `'` on such a cell
  either way. A leading combining mark isn't skipped: it shows on its own, and no trimmer drops it.

## Testing / live-verification status

- Goldens: `csv.json` (88 cases, 43 listed deviations: containers as JSON, and 6 for the wider guard; and
  the guard's `blank` and `triggers` sets) and `reports.json` (`device_stats` 33 cases, 1 deviation, the
  Counter fleet; `assignment_summary` 22 cases; `audit_digest` 26 cases, 15 drawn and 11 hand-written
  (`audit_edges`), 8 listed deviations: 5 rows in another order, 3 where abapit raised; and `audit_types`). The
  generator reads every expected CSV back with Python's
  `csv.reader` and fails if a cell splits, joins or starts (after blanks) with a trigger.
- Mutants for the Phase 1b fixes and verifier rounds 1 and 2 are listed in the branch's commit messages.
- Find has no parity golden (abapit's `/find` is in `web/app.py`, not a pure module): `FindTests` holds it,
  with Python 3.12's own outputs written in for the final-sigma cases.

## To do common tasks here

- **Export a new view**: add its `Columns` to `ExportPolicy` (documented attributes only, nothing secret),
  call `CSV.text(items, columns: ExportPolicy.<view>)`, and pin the list and the denylist check in
  `ExportPolicyTests`. Never make `Columns.init` public: the compiler is the allowlist's enforcement.
- **Change the guard or the writer**: change `corrected_safe` or `corrected_csv` in `gen_fixtures.py` first,
  regenerate, and keep the deviation count in `everyCSVDeviationIsAContainerOrTheWiderGuard` honest.
