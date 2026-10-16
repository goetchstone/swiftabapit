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

- **An export names its columns** (invariant 11): `CSV.text(items, columns:)`, with one fixed list per view
  in `ExportPolicy` (`devices` today). There is no "every key" mode: abapit's union of keys is
  `CSV.union`, internal, for the parity golden only. `ExportPolicy.isSensitive` is the second defence: it
  drops a listed column whose folded name (NFKC, lowercased, letters and digits only) holds a secret stem.
- **The writer works by Unicode scalar**, as Python's `csv` does: quoting is decided by a `,`, `"`, CR or LF
  scalar, and every `"` scalar is doubled.
- **The formula guard** is abapit's (a tab, a CR or `=+-@` first) plus a listed deviation: the full-width
  forms U+FF1D, U+FF0B, U+FF0D, U+FF20, and a trigger after leading Zs, Cf, tab, CR or LF.
- **Find** trims Python's whitespace (`str.strip()`), the set the serials golden lists.

## Invariants & failure history

- failure-log 2026-10-16, "Swift matched Characters where Python reads code points" (Phase 1b review H1,
  M2): a quote followed by U+0301 broke CSV quoting and let a formula cell through; the export was a
  denylist that let `escrowKey`, `recoveryKey` and a full-width `TOKEN` out.

## Gotchas / stub-lies traps

- **`String` APIs match `Character`s; Python matches code points.** `replacingOccurrences(of:with:)`,
  `contains(_:)`, `first` and `==` on a `String` see `"` + U+0301 as one `Character` that isn't `"`, and a
  CR LF as one `Character` that is neither CR nor LF. Anything ported from Python that tests or edits
  single characters goes through `unicodeScalars`. Compare bytes in tests (`Array($0.utf8)`).
- **`.whitespacesAndNewlines` isn't Python's whitespace**: it misses U+001C to U+001F, which `str.strip()`
  and `str.split()` remove. Use the golden's `python_whitespace` list (Find keeps a copy; `SerialParser`
  another; a test pins each to the golden).
- **A denylist is only a backstop.** Apple adds attributes; a new one must not leave until a view lists
  it. `ExportPolicyTests` checks the Devices list is a subset of `OrgDevice.fields` and that the denylist
  drops none of it (a listed column must not vanish silently).
- **A drawn golden misses the edges.** The 25 drawn `device_stats` fleets never had more than 8 models, a
  non-string value, an offset that crosses a month, or an age of exactly 30 days, so five mutants survived.
  Hand-written cases go after the drawn ones (they draw nothing, so nothing drawn moves).
- **Python's `Counter` merges `True` with `1`** and Swift's names merge `true` with `"True"`: a hand-written
  fleet never mixes those in one field, or the golden would need a deviation.
- **Spreadsheet behaviour is unverified**: whether Excel or Numbers runs `" =1"`, `"\u{200B}=1"` or a
  full-width U+FF1D as a formula wasn't tested; the wider guard costs a `'` on such a cell either way.

## Testing / live-verification status

- Goldens: `csv.json` (79 cases, 37 listed deviations: containers as JSON, and 3 for the wider guard) and
  `reports.json` (`device_stats` 30 cases, no deviation). The generator reads every expected CSV back with
  Python's `csv.reader` and fails if a cell splits, joins or starts (after blanks) with a trigger.
- Mutants for the Phase 1b fixes are listed in that branch's commit message.

## To do common tasks here

- **Export a new view**: add its column list to `ExportPolicy` (documented attributes only, nothing
  secret), call `CSV.text(items, columns: ExportPolicy.<view>)`, and add the subset and denylist checks to
  `ExportPolicyTests`.
- **Change the guard or the writer**: change `corrected_safe` or `corrected_csv` in `gen_fixtures.py` first,
  regenerate, and keep the deviation count in `everyCSVDeviationIsAContainerOrTheWiderGuard` honest.
