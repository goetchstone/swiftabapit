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
- **Personal Team, sandboxed:** **pending — needs the operator.** One build inside Xcode (so it
  provisions the access group) and one Touch ID. Steps:
  1. Create `Config/Local.xcconfig` with `DEVELOPMENT_TEAM = <your team>`,
     `CODE_SIGN_IDENTITY = Apple Development`, `CODE_SIGN_ENTITLEMENTS = Config/abapit-Team.entitlements`.
  2. Open `SwiftAbapit.xcodeproj`, build the `abapit` scheme (Debug) once in Xcode.
  3. In Terminal: `ABAPIT_SPIKE=keychain <DerivedData>/Build/Products/Debug/abapit.app/Contents/MacOS/abapit`
     and answer Touch ID. Paste the printed lines (no secrets are printed) into this section.
  4. Then `ABAPIT_SPIKE=vault …/abapit` (Phase 1a): the app's own `KeychainStore` and `Vault` end to end on a
     throwaway org (`swiftabapit-spike`, service `swiftabapit-spike`) — a key stored, two signatures verified
     (the second inside the session, so no second prompt), a password stored, the inventory listed, everything
     removed. It is the only check of `KeychainStore`'s DER-to-raw conversion before a live token mint: the
     offline suite runs `MemoryStore`, and an ad-hoc build gets -34018 (seen 2026-10-16).

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
- **Every use checks the session**, not only reads: `sign`, `store`, `storeKey` and `refresh` end an
  expired one first (Phase 1a review: an hour-old session still covered a write).
- **A set's clean-up tries every kind** and throws the first refusal, so what is left after a refused
  clean-up is at most the refused items, never old and new mixed.
- **A key and a secret each have one door**: `store` refuses `.appleKey` and `storeKey` refuses the rest
  (`VaultError.wrongKind`). `KeychainStore.write` would trap on a key; `MemoryStore` hid that.
- **`storeKey` is still delete-then-add** (a `kSecClassKey` item can't be updated in place). A failed add
  unindexes the key, so the inventory never lists a key that isn't stored; the old key is gone either way.
- **A removed org's id stays taken while its items are stored**: `OrgStore.uniqueID(for:avoiding:)` takes
  the vault inventory, or a new org of the same name would inherit the old one's secrets.
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
- `Sources/Orgs/` — `orgs.json`: profiles without secrets, tolerant of fields a newer version wrote.
- `Sources/AppleBusiness/ClientAssertion.swift`, `TokenBroker.swift` — the ES256 assertion (`exp` an hour,
  not abapit's 179 days: a listed deviation) and the single-flight, memory-only token.

## Testing / live-verification status

- S1 team build: pending (operator).
- Assertion reuse (plan §3.4.2) and the token rate: Phase 1 live checks (operator).
