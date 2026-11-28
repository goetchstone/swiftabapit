# 2026-11-28 — Leftover credentials the app named and could not show

- **Symptom:** the app tells the operator that credentials can stay in the Keychain "under an id no new organization will
  reuse" after a save or a removal the Keychain refused, and a lost or replaced `orgs.json` leaves them the same way. Nothing in
  Settings listed them or removed them: Remove is offered only for an organization in the file. A review found it.
- **Cause:** `Vault.inventory()` was used only to avoid ids when adding an organization, and to name what stayed in a message.
  No code listed ids no organization has, and no path deleted by id alone.
- **Why not caught:** every test of a refused clean-up stopped at the message that says something stayed.
- **Fix:** this PR. Settings shows a section, only when there is something to list, with a "Delete from Keychain…" button and a
  confirmation (the operator, 2026-11-28: yes to the section, with this wording). `OrgsModel.orphanedCredentials` lists nothing,
  and `removeOrphanedCredentials` refuses, while `orgs.json` wasn't read or a newer version wrote it: the store is then empty
  or not the whole truth, and every stored id would look left over. They also leave out an organization's own id and an id a
  save in flight is writing.
- **Prevention:** `OrphanedCredentialsTests` (eight tests, each guard killed by a mutant). Not tried on the real Keychain: the
  operator's check (Touch ID) is listed in the runbook.
