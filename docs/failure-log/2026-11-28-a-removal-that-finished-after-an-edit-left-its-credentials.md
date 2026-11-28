# 2026-11-28 — A removal that finished after an edit left the edit's credentials behind

- **Symptom:** a re-read of the credential review of PR #17 found that its reviewer had listed a race it could not
  check (a removal landing between a Keychain write's index entry and its item). Nothing carried that list into the PR,
  the runbook or a live check. A probe of the nearest order a test can drive failed on `main`: a removal of an
  org, held inside its last Keychain delete while an edit of the same org saved, finished after the save. The save
  reported success, the org was removed, and what the save had stored stayed under an id no org has: a Mosyle org's
  token, email and password, or an Apple org's new key.
- **Cause:** a save checks once, after its Keychain write, whether its org is still there (`save`; `saveMosyle` since
  PR #17's fix for M2). That holds when the removal is done by then. `remove` never looked again: `Vault.remove(org:)`
  deletes each kind once, and a save that wrote a kind after that kind's delete kept it. On the real Keychain `forget`
  then drops the org's index entry, so the inventory would not list what stayed and a new org could take the id (read
  from `KeychainStore`, not run: an ad-hoc build can't reach the Keychain).
- **Why not caught:** the regression test for M2 holds the save and lets the removal finish: one order. No test could
  hold a removal inside its Keychain work (`MemoryStore` held writes and key writes only). The reviewer's "could not
  check" list had no home: the PR body and the failure-log entry carried the findings, not what was left open.
- **Fix:** branch `fix-removal-after-save`, `fix(orgs): …`.
  - `OrgsModel` counts the Keychain writes each save finishes for an org (`credentialWrites`), stored or refused.
  - `remove` repeats `Vault.remove(org:)` until no save finished one while it ran, with no await between its last look
    and dropping the profile. A save still inside its write is covered by the check it already had.
  - `MemoryStore.holdNextDelete(of:)`, debug only, holds a removal inside its deletes.
  - `RemovalRaceTests` holds the order that was missing, for a Mosyle org and for an Apple org. Each of the three parts
    of the fix, undone, fails one of them (the mutants are in the PR).
- **Prevention:** a fix for a race is tested with each side finishing last. The Keychain's own window (an item added
  after its index entry was dropped) still has no offline test, because `MemoryStore` has no index: the stub is greener,
  the real Keychain is not proven. What covers it is by construction: every save and removal through `OrgsModel` now
  ends with a removal by item after the last write, and that removal never reads the index
  (`docs/domains/auth-keychain.md`, Gotchas). RULE-FEEDBACK 2026-11-28 holds the lesson about a review's open list.
