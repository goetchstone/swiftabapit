# Domain: history

**One line:** Snapshots in SQLite on abapit's schema, per-provider collectors, diffs, reports and the abapit history import (plan L7, phase 3).

**Owns invariant(s):** #6, #8, and #11 for CSV export

**Status:** stub — filled in by phase 3. Until then, read the plan section named above and the nearest
SwiftGamGui runbook. The Reports module (CSV, the export policy, Find, the dashboard's stats) shipped in
phase 1b; its notes are below.

## Files

- `Packages/AbapitKit/Sources/Reports/`: `CSV.swift` (the writer, the formula guard, `ExportPolicy`),
  `Find.swift` (⌘L), `DeviceStats.swift` (the Overview's counts, the assignment summary).
- `Packages/AbapitKit/Tests/ReportsTests/`: parity against `Tests/Fixtures/parity/{csv,reports}.json`,
  `ExportPolicyTests`, `FindTests`.
- `scripts/gen_fixtures.py`: `gen_csv` (`csv_edges`, `corrected_safe`, the `csv.reader` round trip) and
  `gen_reports` (`stats_edges`).

## How it works

- **An export names its columns** (invariant 11): `CSV.text(items, columns:)` takes an
  `ExportPolicy.Columns`, which only the Reports module can make, so a screen exports one of the fixed lists in
  `ExportPolicy` (`devices` today) and an every-key list doesn't compile outside Reports. abapit's union of
  keys is `CSV.union`, internal, for the parity golden only. `ExportPolicy.isSensitive` is the second defence,
  with or without `includeNotByDefault`: it drops a listed column whose folded name (NFKD, then lowercased,
  then letters and numbers by general category) holds a secret stem.
- **The writer works by Unicode scalar**, as Python's `csv` does: quoting is decided by a `,`, `"`, CR or LF
  scalar, and every `"` scalar is doubled.
- **The formula guard** is abapit's (a tab, a CR or `=+-@` first) plus a listed deviation: a cell whose first
  visible scalar is a trigger or reads as one. Visible means not in `check_text.py`'s invisible set (Cc, Cf,
  Zs, Zl, Zp, default-ignorable, U+2800), which holds Python's, .NET's and Java's whitespace. Reads as one:
  U+2212, or a compatibility form starting with `=+-@` or U+2212 (full-width, small, super- and subscript
  forms). `csv.json` lists both sets and `theGuardsSetsAreTheGoldens` holds Swift to them scalar by scalar.
- **Find** trims Python's whitespace (`str.strip()`), the set the serials golden lists, and matches by code
  point (UTF-8 bytes), as Python's `==` and `in` do.
- **`device_stats`** counts a breakdown by the name shown: Python's `Counter` keys by value (a listed
  deviation, one fleet in `reports.json`). **`AssignmentSummary`** keeps serials as sets of UTF-8 bytes, as
  Python's sets compare code points; the denylist finds a stem in the folded key's bytes.

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
- **`.whitespacesAndNewlines` isn't Python's whitespace**: it misses U+001C to U+001F, which `str.strip()`
  and `str.split()` remove. Use the golden's `python_whitespace` list (Find keeps a copy; `SerialParser`
  another; a test pins each to the golden).
- **A denylist is only a backstop.** Apple adds attributes; a new one must not leave until a view lists
  it. `ExportPolicyTests` checks the Devices list is the table's columns, then `OrgDevice.fields` in order
  (a subset check let a dropped or reordered column through), and that the denylist drops none of it (a
  listed column must not vanish silently).
- **Fold order matters.** Lowercase before NFKD missed a modifier-letter or mathematical-bold `TOKEN` (no
  lowercase until it decomposes to `T`); NFKC composed `k` + U+0301 into U+1E31, and `isAlphabetic` kept
  U+0345, so `tok\u{301}en` and `tok\u{345}en` missed `token`. Homoglyphs (U+0441, a Cyrillic es, for the
  `c` of `secret`) still pass: the platform has no confusables table, and only a constant column list
  reaches the denylist.
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
- **Spreadsheet behaviour is unverified**: whether Excel or Numbers runs `" =1"`, `"\u{200B}=1"`, a
  full-width U+FF1D or `"\u{2212}1"` as a formula wasn't tested; the wider guard costs a `'` on such a cell
  either way. A leading combining mark isn't skipped: it shows on its own, and no trimmer drops it.

## Testing / live-verification status

- Goldens: `csv.json` (86 cases, 41 listed deviations: containers as JSON, and 5 for the wider guard; and
  the guard's `blank` and `triggers` sets) and `reports.json` (`device_stats` 32 cases, 1 deviation, the
  Counter fleet). The generator reads every expected CSV back with Python's `csv.reader` and fails if a cell
  splits, joins or starts (after blanks) with a trigger.
- Mutants for the Phase 1b fixes and verifier round 1 are listed in the branch's commit messages.

## To do common tasks here

- **Export a new view**: add its `Columns` to `ExportPolicy` (documented attributes only, nothing secret),
  call `CSV.text(items, columns: ExportPolicy.<view>)`, and pin the list and the denylist check in
  `ExportPolicyTests`. Never make `Columns.init` public: the compiler is the allowlist's enforcement.
- **Change the guard or the writer**: change `corrected_safe` or `corrected_csv` in `gen_fixtures.py` first,
  regenerate, and keep the deviation count in `everyCSVDeviationIsAContainerOrTheWiderGuard` honest.
