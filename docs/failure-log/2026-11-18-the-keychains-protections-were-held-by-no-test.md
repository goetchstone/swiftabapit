# 2026-11-18 — The Keychain's protections were held by no test

- **Symptom:** a review changed `KeychainStore.swift` in a scratch copy of f3249c1: `.userPresence` to `[]`,
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` to `kSecAttrAccessibleAfterFirstUnlock` in both places, and all five
  `kSecUseDataProtectionKeychain: true` to `false`. `scripts/test.sh` passed, 912 tests. The repo's file was never
  changed and no Keychain item was touched.
- **Cause:** every `Vault` in `VaultTests` is built on `MemoryStore`. An ad-hoc build gets -34018 from the
  data-protection Keychain, so no offline test can run `KeychainStore`. Its only check is the spike on a team-signed
  build (`ABAPIT_SPIKE=vault`), the operator's. It passed on 2026-11-19 and reads back only the Mosyle password's
  accessibility class and access control, not the Apple key item or the index.
- **Why not caught:** CLAUDE.md names `VaultTests` as invariant 3's home, and `RouteTests` holds only which file names
  the Keychain. The runbook said the offline suite runs `MemoryStore`; nothing said the attributes were unheld.
- **Fix:** branch `fix-protection-pins`. `KeychainShapeTests` holds the text that asks for each protection, by count, and
  carries the weakenings as its own mutants. `KeychainStore.swift` is unchanged.
- **Prevention:** `KeychainShapeTests.theKeychainStoreKeepsItsProtections` and `eachWeakeningIsFound`. It holds the
  text, not the behaviour: a green run says nothing about what the Keychain stores, and it holds against an accidental
  edit and the listed weakenings, not a determined author (the review is the second line). The spike
  (docs/domains/auth-keychain.md) passed on 2026-11-19 for the password alone; reading back the key item and the index
  is open (operator). RULE-FEEDBACK 2026-11-18 asks that invariant 3's
  home line name the new suite.
