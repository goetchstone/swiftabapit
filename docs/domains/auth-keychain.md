# Domain: auth and keychain

**One line:** Apple API keys live as P-256 `kSecClassKey` items and Mosyle secrets as generic passwords,
in the data-protection Keychain, this device only, behind user presence; one authentication covers a
600 s Vault session; ES256 assertions are signed by the Keychain and live only in memory (plan §3.4,
§3.5; invariant 3).

**Owns invariant(s):** #3 (secrets only in the Keychain; tokens only in memory).

**Enforcement home:** `Secret`'s `package` bytes and the `package` store methods (compiler);
`VaultTests` (OSStatus rule, whole-or-absent sets, session expiry); `credential-guard.sh` (local hook).

## Spike S1 — sandbox + Keychain (Phase 0)

SwiftGamGui proved Personal Team + `keychain-access-groups` **without** the App Sandbox
(its `docs/domains/secrets.md`, 2026-10-08). This app is sandboxed, so S1 repeats it **with**
`com.apple.security.app-sandbox`. The spike is `ABAPIT_SPIKE=keychain` (DEBUG, headless: no window),
in `App/Debug/Spikes.swift`. It touches only one throwaway key item, identified by its application tag
`swiftabapit-spike.p256` (a key item has no service; `kSecAttrService` is a password attribute):

1. add a P-256 `kSecClassKey` item, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `.userPresence`,
   not synchronizable, through `kSecUseDataProtectionKeychain`;
2. sign a test message with it (`SecKeyCreateSignature`, `.ecdsaSignatureMessageX962SHA256`) and verify
   the signature with the public half;
3. sign again in the same `LAContext` (the reuse window: no second prompt expected);
4. delete the item, and confirm a second delete reads `errSecItemNotFound`.

It exits 0 only if every step held, both signatures' verification included.

On an ad-hoc build every data-protection call is expected to fail with `errSecMissingEntitlement`
(-34018); the spike then prints the "sign with your team" guidance and exits non-zero.

**Results:**

- **Ad-hoc, sandboxed (2026-10-16, macOS 27.0.1, Xcode 27.0, CLI Debug build):** `sandboxed=true`,
  `team=none`. The leftover cleanup and `SecItemAdd` of the `kSecClassKey` both returned **-34018**
  (`errSecMissingEntitlement`); no prompt appeared; the spike printed the "sign with your team" guidance and
  exited 2. As SwiftGamGui saw unsandboxed: the sandbox adds no new failure on the ad-hoc path.
- **Personal Team, sandboxed (2026-11-19, the operator's build on macOS 27, Xcode 27, a Personal Team):** the build
  signed and provisioned the app with the App Sandbox on. `ABAPIT_SPIKE=keychain` passed: `sandboxed=true`, the team
  shown as "a Personal Team" (never its ID), the key added (status 0), two signatures verified, the second without a
  prompt (about 2 ms), the delete 0 and a second delete -25300 (`errSecItemNotFound`). `ABAPIT_SPIKE=vault` passed: two
  signatures verified (the second inside the session, so no prompt), the Mosyle token held this-device-only with an
  access control, the inventory listing the two items, and empty after the remove. This is the only check so far of
  `KeychainStore`'s DER-to-raw conversion against the real Keychain. The steps, for anyone repeating it:
  1. Create `Config/Local.xcconfig` with `DEVELOPMENT_TEAM = <your team>`,
     `CODE_SIGN_IDENTITY = Apple Development`, `CODE_SIGN_ENTITLEMENTS = Config/abapit-Team.entitlements`.
  2. Open `SwiftAbapit.xcodeproj`, build the `abapit` scheme (Debug) once in Xcode.
  3. In Terminal: `ABAPIT_SPIKE=keychain <DerivedData>/Build/Products/Debug/abapit.app/Contents/MacOS/abapit`
     and answer Touch ID. The printed lines hold no secrets.
  4. Then `ABAPIT_SPIKE=vault …/abapit` (Phase 1a): the app's own `KeychainStore` and `Vault` end to end on a
     throwaway org (`swiftabapit-spike`, service `swiftabapit-spike`) — a key stored, two signatures verified
     (the second inside the session, so no second prompt), a password stored, the inventory listed, everything
     removed.
  A Personal Team build expires after 7 days: rebuild weekly.

## Gotchas (inherited from SwiftGamGui, each a test when Phase 1 builds the Vault)

- **Only `errSecItemNotFound` (-25300) means absent.** Every other status throws. A refused delete
  once read as success with the secret still stored (GamGUI failure-log 2026-10-01).
- **Ad-hoc signing can't use the data-protection Keychain**: -34018 on every call, no prompt. A team
  signature alone isn't enough either: claiming a keychain access group makes Xcode provision the app.
- **A locked Mac refuses every read and write** of `WhenUnlocked` items with
  `errSecInteractionNotAllowed` (-25308). Say "Unlock your Mac", not the status.
- `errSecAuthFailed` (-25293) is a failed or abandoned authentication; `errSecUserCanceled` (-128) a
  cancelled prompt. Neither is absence.
- **Listing items can prompt.** Keep a name-only index (no user presence) and list from it.
- **Writes update in place** and add only when missing; never delete-then-add. Write-backs are
  compare-and-swap, so a removed org stays removed.
- **A set is whole or absent**: a failure part-way through importing a Mosyle org's four secrets
  removes what was written.
- **A file that wasn't read is never saved over, and a change that can't be saved isn't made**: after a failed load, or over a
  file a newer version wrote, an Add, an edit, a move, a rename and a removal are refused before any Keychain write
  (`OrgsModel.cannotPersist`); a selection, a probe result and the migration notes write nothing. The file is `orgs.json` in the
  app's Application Support folder, `abapit/`: move or repair it, then reopen the app. `settings.json` has its own guard
  (`LocalSettings.blocked`). A save that fails for another reason (a full disk) still shows the banner and is retried by the next save.
- **Every use checks the session**, not only reads: `sign`, `store`, `storeKey` and `refresh` end an
  expired one first (Phase 1a review: an hour-old session still covered a write). Every use that may have
  authenticated the session's context also starts its clock when it returns, a write, a write-back and a use that
  failed after its prompt was answered included, never when it begins (failure-log 2026-11-28, "A write authenticated
  a session nobody timed"). A cancelled prompt (-128), a failed authentication (-25293), a locked Mac (-25308), no Keychain (-25291), a missing
  entitlement (-34018), a read or a signature that found no item (`KeychainStore` maps -25300 to nil and never throws it:
  the absent Logs Stream token is the common case) and a key import (it passes no context) start none. A write-back whose
  secret was not the expected one, and a write that adds a new item, may not have used the context, but the Vault can't
  tell, so they start the clock: that can end a session early, never late.
- **A set's clean-up tries every kind** and throws the first refusal, so what is left after a refused
  clean-up is at most the refused items, never old and new mixed.
- **A key and a secret each have one door**: `store` refuses `.appleKey` and `storeKey` refuses the rest
  (`VaultError.wrongKind`). `KeychainStore.write` would trap on a key; `MemoryStore` hid that.
- **`storeKey` is still delete-then-add** (a `kSecClassKey` item can't be updated in place). A failed add
  unindexes the key, so the inventory never lists a key that isn't stored; the old key is gone either way.
- **A removed org's id stays taken while its items are stored**: `OrgStore.uniqueID(for:avoiding:)` takes
  the vault inventory, or a new org of the same name would inherit the old one's secrets.
- **Items under an id no organization has are listed and removable in Settings** (`OrgsModel.orphanedCredentials`,
  `removeOrphanedCredentials`): never an organization's own id, never one a save in flight is writing, never
  while `orgs.json` wasn't read or a newer version wrote it (the store is then not the whole truth), and never
  removed without the operator's click. Cited: failure-log 2026-11-28, "Leftover credentials the app named".
- **The PEM text can't be wiped.** `KeyImport` zeroes its read buffer, but the `String` copies it parses
  live until Swift frees them. Accepted: the key leaves memory for the Keychain at once.
- **The session counts sleep**: `ContinuousClock`, not `SuspendingClock` (GamGUI failure-log
  2026-09-24).
- **Keychain calls block on a prompt**: run them on a GCD thread, never the main thread or the
  cooperative pool.

## Files

- `App/Debug/Spikes.swift` — spike S1 (Phase 0).
- `Sources/Vault/Secret.swift` — `Secret` (never prints); `VaultItem` (org slug + kind; the slug can't steer
  an account name).
- `Sources/Vault/SecretStore.swift` — the protocol; `MemoryStore` with `failNext` and real OSStatus codes,
  debug builds only with its `Vault` initializer (a Release app keeps keys in the Keychain; gates runbook).
- `Sources/Vault/KeychainStore.swift` — generic passwords (Mosyle) and `kSecClassKey` items (Apple keys,
  tagged `swiftabapit/<org>/apple-key`, signed with in place, never read out); a name-only index of what each
  org stores; one shared `LAContext` under a lock. Queries that carry the context are built inside the lock
  (Swift 6 region isolation refuses a dictionary from outside it).
- `Sources/Vault/Vault.swift` — the actor: 600 s session on an injected `ContinuousClock`, Keychain calls on a
  GCD thread, whole-or-absent sets, removal most-dangerous-first, compare-and-swap write-back.
- `Sources/Vault/KeyImport.swift` — read the picked file once by descriptor (regular, `O_NOFOLLOW`, ≤ 16 KiB);
  abapit's normalization, P-256 only (golden-held); `ImportedKey` shows a public-key fingerprint, never the
  key; `Base64URL`.
- `Sources/Orgs/` — `orgs.json`: profiles without secrets, tolerant of fields a newer version wrote. `LocalSettings.swift`: `settings.json` beside it (the Needs-attention
  thresholds; written the same way, never over a file it couldn't read; docs/domains/history.md).
- `Sources/AppleBusiness/ClientAssertion.swift`, `TokenBroker.swift` — the ES256 assertion (`exp` an hour,
  not abapit's 179 days: a listed deviation) and the single-flight, memory-only token.

## Testing / live-verification status

- S1 team build, the keychain spike and the vault spike: passed 2026-11-19 (operator; results above).
- Assertion reuse (plan §3.4.2) and the token rate: Phase 1 live checks (operator).
- The protections `KeychainStore` asks for (the data-protection Keychain, this device only, user presence) are held
  as text by `SourceScanTests`' `KeychainShapeTests` (failure-log 2026-11-18, "the Keychain's protections were held by
  no test"): no offline test can run `KeychainStore`. The pins hold against an accidental edit and the weakenings they
  list, not against a determined author; the review is the second line. What the Keychain stored was read back by the
  `ABAPIT_SPIKE=vault` spike on a team-signed build, which passed 2026-11-19, and only for the Mosyle password's
  accessibility class and access control: not the Apple key item, and not the name-only index (open, operator).
- Does `SecItemUpdate` on a user-presence item prompt and authenticate the shared context? Operator's check (Touch ID); not
  measured. See `docs/domains/mosyle.md`, the editor on the team-signed build (S1).
- Does a cancelled `SecKeyCreateSignature` report its error in the OSStatus domain (-128) or as an `LAError` code? If it
  is an `LAError`, the signature's failure starts the clock (early only, never late). Operator's check (Touch ID); not measured.
- Does the Settings section for leftover credentials list what the real Keychain holds under an id no organization has,
  and does its delete remove the item and its index entry? Operator's check (Touch ID, a team-signed build); not run. The
  tests use `MemoryStore` only.
