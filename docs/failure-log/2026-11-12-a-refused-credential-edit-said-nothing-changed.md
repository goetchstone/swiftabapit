# 2026-11-12 — A refused credential edit said nothing had changed, after the Vault had removed the working set

- **Symptom:** the credential review of `mosyle-org-editor` (PR #17, at 2919c02) found two medium defects and several lower
  ones.
  - **M1:** an edit of a Mosyle org whose new credentials were refused (Touch ID cancelled) lost the working ones too. The
    Vault's `replaceSet` keeps a set whole or absent, so it removed all four. The editor said "Nothing was saved; enter them
    again". The screens went on reading with the login kept in memory, and Settings' Test on the org on screen said
    "Connected" with no login, so the empty Keychain stayed hidden until the JWT expired.
  - **M2:** an edit racing a removal of its org left the whole new set (a token, an email, a password: credentials that
    can lock or wipe devices) under an id no org has. No screen could remove it.
  - **The lower ones:**
    - A refused clean-up's leftovers were never said.
    - The first org added, a Mosyle one, became active with no switch.
    - An Add could take an id a stale pair named, and become that Apple org's pair unchosen (defect 17).
    - An edit's draft saved as an Add skipped the Add's credential rule.
    - Cancel stayed on during a save.
    - Settings kept a Test result after the credentials changed.
  - **Untested rules:** 11 surviving mutants (the Keychain half of the id choice, the reservation, "an edit keeps the
    credentials", "an empty Logs Stream token clears one", the password kept as typed).
  - **M37:** a password stored without user presence passed every test.
- **Cause:** the Mosyle save copied the shape of Apple's `save` and not its review history. Apple's edit names what may be
  gone (`keyNotStored`, adding: false), cleans up when its org was removed meanwhile, and switches when an Add becomes
  active. Underneath was the Vault's whole-or-absent rule, right for a set and invisible to the editor's words: the message
  was written for the Add case and reused for the edit.
- **Why not caught:** no test could hold a Mosyle save inside its Keychain write (`MemoryStore` held only key writes). The
  failure tests asserted that a save was refused, not what stayed, and the test org had no Logs Stream token. The
  Keychain's access control has no offline test: `MemoryStore` has none to read.
- **Fix:** branch `mosyle-org-editor`, `fix(mosyle-org): …` after 2919c02.
  - A failed credential write reads back what the Keychain holds (names only, no prompt) and says it, for an Add and for
    an edit. An edit of the org on screen switches, so nothing reads on the old login.
  - Settings' Test always logs in afresh with what is stored.
  - Credentials written for an org removed meanwhile are removed again, and the message says so.
  - An Add that becomes active switches.
  - An Add skips ids a pair names.
  - A draft is saved only onto the org it was opened for.
  - Cancel is off during a save, and a Test result goes when the editor closes.
  - `MemoryStore.holdNextWrite`, debug only, holds a save inside its write.
  - The vault spike now reads a stored Mosyle password's protection back from the Keychain on the team build (this
    device only, with an access control), and fails the spike otherwise.
  - Each fix and each of the review's surviving mutants has a test that fails when it is undone (17, listed in PR #17).
- **Prevention:** a credential save is tested at the window inside its Keychain write, and for what stays after every
  refusal, not only for having refused. Still only the team build can check the ACL (the spike) and whether an update of a
  user-presence item prompts (live check S1).
