# 2026-10-16 — Swift matched Characters where Python reads code points

- **Symptom:** Phase 1b's adversarial review (867d7a6) gave `CSV.text` the value `Mosyle"` + U+0301 +
  `,=HYPERLINK(...)`. The quote wasn't doubled, so the quoted field closed after `Mosyle`, and Python's
  `csv.reader` read the rest as new cells, one of them an exact, unguarded `=2+5` (H1). A field
  holding CR LF could go unquoted under a one-line mutant that no test caught. The export was a denylist:
  `escrowKey`, `recoveryKey`, `fileVaultRecoveryKey`, `privateKey`, `apiKey`, a full-width `TOKEN` and a
  token split by U+200B all left the app (M2), and the `fields` allowlist nobody passed was never tested.
  Find's trim survived a spaces-only mutant. Five `device_stats` mutants survived (`<` at 30 days, a boolean
  or zero value, a UTC month, the top-9 cap).
- **Cause:** `replacingOccurrences(of: "\"", with: "\"\"")` compares whole `Character`s, and `"` + U+0301
  is one `Character` that isn't `"`. Python's `csv` works on code points. The guard looked at the first
  scalar (right), but the broken quoting moved the payload to a cell of its own. The export took "every key
  Apple sent, minus a few substrings", so any secret not on that short list was exported.
- **Why not caught:** the CSV golden's drawn cells were ASCII-heavy with no combining mark after a quote and
  no CR LF, and nothing read the written CSV back. The `device_stats` golden was drawn: at most 8 models, no
  non-string value, every timestamp in UTC, no exact boundary. Invariant 11 said "allowlist" and the code had
  an optional one with no caller and no test.
- **Fix:** branch `fix1b-reports`. The writer quotes and doubles by scalar; the guard also catches the
  full-width triggers and a trigger after leading Zs, Cf, tab, CR or LF (a listed deviation). `CSV.text`
  takes a column list (`ExportPolicy.devices` for the Devices view); abapit's every-key union is internal,
  for the golden. The denylist folds a key (NFKC, case, letters and digits) and has more stems. Find trims
  Python's whitespace. `gen_fixtures.py` adds hand-written CSV and `device_stats` cases and reads every
  expected CSV back with `csv.reader`.
- **Prevention:** the generator's round trip fails on a split cell or a formula cell; the golden holds the
  reviewer's payloads; `ExportPolicyTests` holds the allowlist; 42 mutants, listed in the commit. The
  `history` runbook's gotchas say: port single-character logic through `unicodeScalars`, and use the
  golden's Python whitespace, not `.whitespacesAndNewlines`. Still unverified: how Excel and Numbers treat a
  leading blank or a full-width sign (no spreadsheet run).
