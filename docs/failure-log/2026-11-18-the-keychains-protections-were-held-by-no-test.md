# 2026-11-18 — The Keychain's protections were held by no test

- **Symptom:** a review changed `KeychainStore.swift` in a scratch copy of f3249c1: `.userPresence` to `[]`,
  `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` to `kSecAttrAccessibleAfterFirstUnlock` in both places, and all five
  `kSecUseDataProtectionKeychain: true` to `false`. `scripts/test.sh` passed, 912 tests. The repo's file was never
  changed and no Keychain item was touched.
- **Cause:** every `Vault` in `VaultTests` is built on `MemoryStore`. An ad-hoc build gets -34018 from the
  data-protection Keychain, so no offline test can run `KeychainStore`. Its only check is the spike on a team-signed
  build (`ABAPIT_SPIKE=vault`), which is the operator's and still pending.
- **Why not caught:** CLAUDE.md names `VaultTests` as invariant 3's home, and `RouteTests` holds only which file names
  the Keychain. The runbook said the offline suite runs `MemoryStore`; nothing said the attributes were unheld.
- **Fix:** branch `fix-protection-pins`. `KeychainShapeTests` holds the text that asks for each protection, by count, and
  carries the weakenings as its own mutants. `KeychainStore.swift` is unchanged.
- **Prevention:** `KeychainShapeTests.theKeychainStoreKeepsItsProtections` and `eachWeakeningIsFound`. It holds the
  text, not the behaviour: a green run says nothing about what the Keychain stores. The team-build spike reads the
  attributes back (docs/domains/auth-keychain.md) and is still pending. RULE-FEEDBACK 2026-11-18 asks that invariant 3's
  home line name the new suite.
