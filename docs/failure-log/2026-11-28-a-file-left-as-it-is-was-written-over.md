# 2026-11-28 — A file "left as it is" was written over by the next Add

- **Symptom:** a review found that over a cut-off `orgs.json` the first Add threw nothing, replaced the file with an empty store
  plus the new org, and stored the new org's credentials; over a file a newer version wrote, the Add returned a profile, the
  credentials stayed in the Keychain, the file was unchanged, and after a relaunch the organization was gone with its items
  stored under an id nothing shows. Dismissing the migration notes was a second route to the overwrite.
- **Cause:** only the launch save was guarded (the 2026-11-12 review of the clients change: an unreadable file and an empty
  store saved over it). The private `save()` wrote whenever asked, and the Add, edit and removal paths write the Keychain
  before a save whose failure is only a banner.
- **Why not caught:** the earlier test, `aFileTheAppCantReadIsNeverWrittenOverAtLaunch`, held the launch only; no test tried a
  later change over a file that wasn't read, or over a newer version's file.
- **Fix:** https://github.com/goetchstone/swiftabapit/pull/65. `OrgsModel.cannotPersist` is asked first by `move`, `renameClient`, `saveMosyle`, `save` and `remove`, before any
  Keychain write or history deletion, and says why in words; `save()` writes nothing after a failed load. Left alone on purpose: a
  save that fails as `unwritable` (a full disk) still returns success with the banner and is retried by the next save.
- **Prevention:** `StoreGuardTests`, one test per guard, each killed by a mutant that removes it; `settings.json` over a file that
  can't be read is held by two tests there too.
