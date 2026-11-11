# 2026-11-11 — A guessed field kept a value of any shape, so an allowlist of keys exported what it never listed

- **Symptom:** the adversarial review of `mosyle-screens` (PR #16, at 2e22cc4) found two medium defects and four low ones.
  - M1: the admin log's and the custom attributes' adapters, allowlists of guessed field names, kept a field's value
    whatever its type. An `action` holding `{"payload": {"wifi_password": …}}` showed a dash on screen and went out whole,
    as JSON, in the CSV. Nothing named it, since its key was on the list.
  - M2: changing the admin log's range (30 days to 7) read again and kept the 30 days' entries on screen under the new
    read's banner. When that read failed, they counted as its partial read ("2 admin-log entries were read before the
    error").
  - The lows:
    - Python's `upper()` and `title()` were Swift's newer tables for four letters with a capital only since Unicode 16,
      and one letter whose Cased property changed; the reconciliation joined two serials abapit keeps apart.
    - A member with an empty UDID was named as a device with none.
    - A report tab's Export called partial devices "OS versions", and said "nothing to export" over a cut list.
    - The stub answered custom attributes under a guessed key, never the sourced one, and took `os` where Mosyle
      wouldn't.
  - It also listed branches no test drove: the reconciliation's cache key, Device 360 over a cut or failed list, the
    dates from both sources keeping and dropping audit events, a range picked before the log was shown, and the UTC day.
- **Cause:**
  - M1: the adapters were written as Phase 7a's user and group allowlists were, by key, for records whose shape no source
    shows. A key on the list was trusted to hold what its name suggests.
  - M2: `start(_:)` set the list's state and left its rows, its total and its unread names.
  - Unicode: `known()` asked when a character was assigned, not whether its case changed since. The author's three
    mutants named the shapes they found (a Garay letter, NFC and NFD, a Hebrew letter) and stopped there.
- **Why not caught:** the canary tests put the canary under a key not on the list, never under one on it. The range test
  waited for the second read to settle before asserting, the shape RULE-FEEDBACK 2026-10-31 names ("a state a fix added
  was checked only after the reads settled"). The Unicode edges were cases, not every character.
- **Fix:** branch `mosyle-screens`, `fix(mosyle): …` after 2e22cc4.
  - A guessed field keeps only a scalar, and a container under one is named as unread.
  - Each list starts again from nothing.
  - The `unicode_case` golden holds `upper()`, `title()` (alone and after a cased character, so the final sigma too),
    cased-ness and `isspace()` from CPython for every code point. The four letters and the one cased letter are read as
    Unicode 15 did; the final sigma is CPython's `handle_capital_sigma`.
  - Members are matched only by a UDID that isn't empty.
  - A report's Export says why in the devices' words.
  - The stub answers under `info` and is strict about `os` and the dates.
  - The reconciliation and Device 360's Mosyle half say how old their reads are (the review's invariant-8 risk).
  - Each fix has a test shown failing when the fix is undone (21 mutants, listed in PR #16), and each untested branch the
    review named has a test.
- **Prevention:**
  - A canary goes under a key the allowlist names too, as a container (`aContainerInAGuessedFieldIsNamedNeverExported`).
  - A rule ported from Python's Unicode is held to every code point, not to cases (`UnicodeCaseTests`).
  - A list that reads again is asserted while its read is held.
  - RULE-FEEDBACK 2026-11-11, "an allowlist of keys trusted the values under them".
  - Still only a stub: what Mosyle sends in these fields is the live check's.
