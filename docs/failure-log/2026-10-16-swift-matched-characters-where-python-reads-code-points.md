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
  for the golden. The denylist folds a key (compatibility forms, case, letters and digits: NFKC at first,
  NFKD since verifier round 1) and has more stems. Find trims Python's whitespace. `gen_fixtures.py` adds
  hand-written CSV and `device_stats` cases and reads every expected CSV back with `csv.reader`.
- **Prevention:** the generator's round trip fails on a split cell or a formula cell; the golden holds the
  reviewer's payloads; `ExportPolicyTests` holds the allowlist; 42 mutants, listed in the commit. The
  `history` runbook's gotchas say: port single-character logic through `unicodeScalars`, and use the
  golden's Python whitespace, not `.whitespacesAndNewlines`. Still unverified: how Excel and Numbers treat a
  leading blank or a full-width sign (no spreadsheet run).
- **Verifier round 1** (two independent verifiers, 68cddbf): the fix held, and 10 more mutants survived, all
  low. Find still compared by `Character` (`String`'s `==` and `contains`), the same class as H1. The
  generator joined a list inside a list where Swift wrote JSON, and no golden had one. Nothing tested the
  denylist with `includeNotByDefault: true`, the fold's order, a `passwd` key, the whole Devices list, a row
  of several empty fields, JSON keys past the BMP, a whitespace-only or NFD name in `device_stats`, or
  Python's `Counter` merging `True` with `1`. Fixed: Find matches UTF-8 bytes; `Columns` can only be made in
  Reports; the fold is NFKD, lowercase, letters and numbers; the guard skips every invisible lead and
  catches look-alike triggers, with both sets in the golden; the `Counter` quirk is a listed deviation.
  Grepping the module for the class then found two more nobody had flagged: `AssignmentSummary` kept
  serials in a `Set<String>` (NFC and NFD spellings were one device), and the denylist found a stem with
  `String.contains` (a prepended U+0D4E hid `token`). The lesson for the next port: a review fixes the
  instance, so grep the module for the class (`==`, `contains`, `first`, `Set<String>` and `String` keys on
  ported data) before calling it done.
- **Verifier round 2** (two independent verifiers, 00938e8): the fix held; every finding was low. The same
  class again, one level down: a blank Prepend scalar (U+0600) and the trigger after it are one `Character`,
  so a guard finding its lead by `Character` would miss `"\u{600}=1"`, and no golden cell had one. Swift's
  `lowercased()` has no Final_Sigma rule, so Find differed from Python's `lower()` on a word-final capital
  sigma, held only by prose. Golden gaps let four more mutants through: JSON keys written raw, `-0.0` kept as
  a name, unassigned serials sorted as `String`s, one service's serials deduped as `String`s. The allowlist
  was never tested on a long list, `notByDefault` matched only its exact spelling while the denylist folded,
  and nothing checked Find ignores non-identifier attributes. Fixed: Prepend and escaped-key cells in
  `csv.json`; `-0.0` and NFC/NFD service cases in `reports.json`; `Find.lower` with CPython's sigma rule;
  `notByDefault` read folded; tests for each. The lesson: grapheme rules have more joiners than combining
  marks (Prepend, ZWJ, regional indicators), so a port that skips or tests "the first thing" says scalar.
- **Verifier round 3** (two independent verifiers, b3e35d5): the fix held; every finding was low. Most were
  missing tests. Find kept every test green when it kept only the first exact hit (no fleet had two devices
  sharing an order number), stripped the identifiers, or dropped its empty-query guard. The formula guard did
  the same when capped at five scalars (no cell had more than three blanks). Eight sigma-rule mutants
  survived: looking for the sigma by `Character` (the H1 class again: U+03A3 + U+0301 is one `Character`),
  the first scalar instead of the nearest, `isAlphabetic` or upper-or-lower for Cased on either side, and a
  skip that stopped at a scalar both cased and case-ignorable. Two were real differences. Apple's data calls
  40 private-use scalars case-ignorable, which Unicode and Python don't, so `A\u{F870}\u{3A3}` lowered to a
  final sigma. And the fold kept modifier letters such as U+02BC, which looks like the `'` it drops. The
  docs had also said Find agreed with Python on every code point but 55 new letters, which holds for the
  case mapping only: the sigma rule's two properties also differ on the 194 code points Unicode 15 doesn't
  assign, on U+0295 and U+1171E, and on Apple's 40. Fixed: `Find.isCaseIgnorable` leaves private use out, and the fold drops the modifier letters
  NFKD leaves. Each fix and each gap has a test, with Python 3.12's outputs. The lesson: a rule that reads a
  property needs a test scalar with that property and without its neighbours (cased but case-ignorable,
  alphabetic but uncased, titlecase), and a differential over every code point before the docs say "agrees".
