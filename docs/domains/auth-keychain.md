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
in `App/Debug/Spikes.swift`. It touches only throwaway items under the service `swiftabapit-spike`:

1. add a P-256 `kSecClassKey` item, `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` + `.userPresence`,
   not synchronizable, through `kSecUseDataProtectionKeychain`;
2. sign a test message with it (`SecKeyCreateSignature`, `.ecdsaSignatureMessageX962SHA256`) and verify
   the signature with the public half;
3. sign again in the same `LAContext` (the reuse window: no second prompt expected);
4. delete the item, and confirm a second delete reads `errSecItemNotFound`.

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
- **The session counts sleep**: `ContinuousClock`, not `SuspendingClock` (GamGUI failure-log
  2026-09-24).
- **Keychain calls block on a prompt**: run them on a GCD thread, never the main thread or the
  cooperative pool.

## Files

- `App/Debug/Spikes.swift` — spike S1 (Phase 0).
- `Packages/AbapitKit/Sources/Vault/` — Phase 1.

## Testing / live-verification status

- S1 team build: pending (operator).
- Assertion reuse (plan §3.4.2) and the token rate: Phase 1 live checks (operator).
