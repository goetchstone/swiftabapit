# 2026-11-12 — An added org joined a client nobody could see, so two customers' devices could be reconciled together

- **Symptom:** the adversarial review of `client-grouping` (PR #18, at 80b8717) found one high and two medium findings,
  seven lows and nine surviving mutants.
  - **H1:** an added org joined the active client when that client had room. With one Apple org set up, adding a second
    customer's Mosyle org made it that client's Mosyle org: the reconciliation and Device 360 joined one customer's Apple
    devices with another's Mosyle devices. There was still one client, so no client UI showed and nothing could undo it.
  - **M2:** only `migrated = !orgs.isEmpty` stood between an unreadable `orgs.json` and an empty store saved over it at
    launch, untested.
  - **M3:** no test read back a move or a rename from the file (a load that kept `clients` as an unknown key reverted
    both).
  - **The lows:**
    - A no-op move or picking the client on screen cleared every screen.
    - The migration's note outlived the second client.
    - A version-2 file's duplicate or empty client names were kept, and one with no clients split its pairs.
    - Two clients could share an export file name (`/` and `-`).
    - The app could open on another client than the default one.
    - The snapshot list's demo field was never checked.
- **Cause:** H1 was two good rules meeting. "A new org joins the active client when it has room" was a convenience, and
  "with one client there is no client UI" hid the one place that showed it. Neither rule alone mixes clients; together they
  made the operator's hardest rule (no mixing) fail silently. The rest were untested branches of new code.
- **Why not caught:** the tests held the add rule as written (`aNewOrgJoinsTheActiveClientWhenItsPlaceIsFree`), with two
  orgs of one customer, never two customers'. The file round trip was tested for the migration's save only.
- **Fix:** branch `client-grouping`, `fix(clients): …` after 80b8717.
  - A new org is always a client of its own, and the operator moves it into the client it belongs to. Adding a Mosyle org
    beside one Apple org shows the switcher until the move is made.
  - The migrated store is saved only after a successful read.
  - A move or a selection that changes nothing clears nothing.
  - The note goes when one client is left.
  - A version-2 file's names are held unique, and one with no clients is grouped.
  - Uniqueness compares names in their file-name form.
  - The app opens on the default client.
  - The snapshot list's demo field is checked.
  - Each fix, and each of the review's surviving mutants, has a test that fails when it is undone (22, in PR #18).
- **Prevention:** a convenience that acts without the operator's word (placing, pairing, choosing for them) is tested
  with two customers' data, not one customer's, and is checked against what the UI shows at that moment (RULE-FEEDBACK
  2026-11-12, "a convenience met a rule that hid it").
