# 2026-10-30 — A lenient read pinned by a test, and a secret held by a doc comment

- **Symptom:** Phase 2a's adversarial review (a1ffb4c) found two medium silences the 2b screens would inherit.
  - M1: an audit event whose `eventDataPropertyKey` names an attribute it doesn't have (the contract's object names
    spell `Icloud` and `Applecare` where its attribute keys spell `ICloud` and `AppleCare`), names `""`, or whose
    payload isn't an object, read `payload == nil`: its serial, key id or subscription id vanished from the audit views,
    its unknown fields were never counted, and the acceptance pass, the live check meant to catch this, printed
    `auditEvents: ok, 1 item · the last day`. `AuditEventTests` asserted `missing.payload == nil`.
  - M2: a custom setting's plaintext profile (Wi-Fi and VPN passwords, a certificate's key) sat in
    `Configuration.resource.attributes`, `CustomSettingsValues.object` and `.configurationProfile`, all public, and in
    `BlueprintRead.included`. Only a doc comment ("show it through `profileText`, never raw") kept it off a screen: the
    device inspector's `ForEach(attributes.keys)` pattern, an every-attribute dump or `"\(configuration)"` would have
    shown it.
  - Low: nested objects' unknown keys were never counted (L1); `ProfileText` showed a PSK, an encryption, client,
    access or licence key, an admin `PW`, a numeric passcode or unlock code and a PEM private key under a key that
    isn't a secret word, and dropped one of two keys equal under Unicode normalization unsaid (L2); a member list cut
    at the page cap and the `.notInScope` arm had no test (L3); a lookalike key and a deep binary plist had none (L4);
    a refused include left `related` empty beside a separate flag, so a count read 0 (L5); and drift (L6).
- **Cause:** M1: `payload` read `attributes[eventDataPropertyKey ?? schema.key]` with no fallback, and
  `unreadAttributes` always excused the type's key, so a missed key read as "no payload" and nothing counted it. A
  lenient read with no source, pinned by its own test. M2: `Configuration` kept the resource as it came, and the views'
  "keep the resource" rule (the inspector shows every attribute) met a resource that holds a secret.
- **Why not caught:** M1 is the class failure-log 2026-10-16 ("the mosyle stub agreed with the client") named: a
  lenient reading needs a source, and without one fails closed. Here the test was written to the code's choice, so it
  held the silence in place, and the pass's own tests never sent an event whose key missed. M2 is the class
  RULE-FEEDBACK 2026-10-16 moved to the compiler for CSV (`ExportPolicy.Columns`): a rule held by a comment holds until
  the first caller who didn't read it. Nothing in the app reads a configuration yet, so no test could see the leak.
- **Fix:** branch `phase-2a-apple-reads`, commits `fix(2a): …` after a1ffb4c.
  - M1: the type's own key is read when the named one misses, and `AuditEvent.payloadProblems` says what was wrong (a
    named key absent, empty or not a string; a payload that isn't an object); the pass adds each to its note with a
    count. Tests for both spellings of the four iCloud and AppleCare types, `""`, a non-string key, five non-object
    shapes, a lookalike named key, and a pass through the strict stub.
  - M2: `Configuration.resource` and `CustomSettingsValues.object` are copies with `customSettingsValues` withheld
    (keys kept, `null` and a string `filename` as they came, every other value a marker); the profile as Apple sent it
    is `received` and `configurationProfile`, `package`; a blueprint's `included` goes through the same withholding;
    both types print, debug-print and mirror only the withheld copy, since a struct's default description shows
    `package` stored properties. A canary password through the strict stub reaches none of the view's resource,
    attributes, object, description or dump, the list, a blueprint's included configuration, or the pass's text;
    abapit's every-key CSV of the resource holds none; `profileText` still shows the profile masked. In
    `Packages/AbapitApp`, naming `configurationProfile` or `received` is a compile error (both checked by mutant), and
    `BoundaryTests` keeps the names out of App/ and the screen models.
  - L1: `ResourceView.unreadNested` and `AuditEventPayload.unreadNested` name the keys inside the objects a view reads,
    and the pass counts them as `attribute.key` (users' phone numbers and roles, list and single read; a custom
    setting's values; both audit role lists), each part filtered as a word.
  - L2: new stems (`psk`, `sharedkey`, encryption, client, access and licence keys) and `PW` as a word; a number is
    masked when its key's last word ends in a secret word and no policy word is in it; a string holding a PEM private
    key, as text or base64, is masked whatever its key; keys merged by normalization are counted and said
    (`ProfileText.note`). L4: a KELVIN SIGN lookalike key, and a binary chain of a hundred dictionaries.
  - L3: a pass at the page cap of one with every member list two pages long, each of the nine lines `truncated`; the
    `.notInScope` arm in the failure table. L5: `BlueprintRead.members` is `.read(related:included:)` or
    `.refused(error)`, so a count needs the read case; the pass's note gives an unlisted relationship a dash, not 0.
  - L6: one list reader (`strings(_:)` retired for `list(_:_:)`, so `OrgDevice`'s lists and a service's default
    families read nil, not the items that fit); `AuditView` built from `AuditEventType` cases, its strings unchanged;
    `ConfigurationType.isWritable` dropped until Phase 5; "fifteen" field-less payloads corrected to fourteen. The two
    quiet-service rules stay until 2b, as recorded.
  - Verifier round 1 (`fix(2a): verifier round 1`): nine mutants of the fix survived. The pass's payload-problem count
    was never held (every test had one event per problem), so `in 1 event` written in passed: a second miss of one kind
    now reads `in 2 events`. Five of `ProfileText`'s new arms had no test (a policy word matched as a prefix, so
    `AgentPIN` read as `age`; `passphrase` and `passwd` dropped from the number words; base64 never padded; the PEM scan
    stopping at a certificate before the key): each has one. The `package` level of the raw profile's three holders was
    held by no test, only by the app-side name scan: `BoundaryTests.whatHoldsTheRawProfileStaysPackage` holds it, a
    widening and a move into a `public extension` both killed. And a number under `Passcode1`, `DevicePIN2`,
    `PasscodeValue` or `PINValue` was shown, and a string under `DevicePIN2` or `VPNPIN2` too (the verifier took the
    string to be masked; it wasn't: the digit joined `pin` into one word, `pin2`): a key's words now split where
    letters meet numbers, the number rule skips the numbers, the fold's `pin` ending skips trailing ones, and `value`
    after a secret word is a secret, as `code` and `number` are.
  - Verifier round 2 (`fix(2a): verifier round 2`): both verifiers held the fix; every finding was low, and two
    mutants survived. A public accessor of another name in any AbapitKit module (`public var rawText: String? {
    configurationProfile }`, `public extension Configuration { var sent: Resource { received } }`) republished the raw
    profile with every test green, since the round-1 test held only the three declarations' modifiers:
    `BoundaryTests.onlyTheListedLinesReadTheRawProfile` now lists every line in AbapitKit's sources that names `received`
    or `configurationProfile`, and `whatAConfigurationStoresIsTheTwoCopies` holds the two types' stored layout, so a new
    stored copy (`let original = resource`), which names neither, fails too. `CustomSettingsValues`' synthesized `==`
    compared the raw profile, an equality oracle for a guessed secret: it compares the withheld object and the masked
    text. No test put a secret string under a policy-worded key (`RequiredPassword`), so the number rule's exception
    could spread to strings: it has one. A custom setting whose values aren't an object, or whose profile isn't a
    string, read `configurations/{id}: ok, 1 item`, and the new shape test pinned the nil (this entry's own RULE-FEEDBACK
    lesson, again): `Configuration.profileProblems`, said with a count on the list and the single read. `ProfileText`:
    a key written twice alike is counted from the XML's own keys (Foundation's reader keeps one); `PINs` and `PWs` read
    as one word, not `pi`, `ns`; a fold ending in a PIN, a PW or a PUK past a plural and trailing words (`pincode`,
    `rootpw`, `SIMPINs`) is a secret; a number is masked when the fold ends in any stem or secret word (`SharedSecret`,
    `PassCode`, `PINs`), not only the last word's number words; the stems hold `ExportPolicy.sensitiveStems` (`bypass`,
    `assertion`, `unlockpin`, held by a test), unlock and access codes and a WEP key, found in the fold without its
    numbers; and a PuTTY key file, a JWK's private member and a private key in a `data:` URL are masked. The docs gave the
    raw profile to Phase 3's snapshots; that is an open operator decision now (SQLite is outside the Keychain).
  - Verifier round 3 (`fix(2a): verifier round 3`): both verifiers held; every finding was low. Review L6's one list
    reader made a families list holding a number read nil, which the pass iterated as none, so `mdmServers: ok, 1 item`
    said nothing where Phase 1's reader had named `GLASSES` (this entry's lesson a third time, from a fix): every view
    names such lists in `misreadLists`, and the pass says each with a count. `Configuration` wasn't `Equatable`, but
    adding it would have had Swift compare `received`, the oracle round 2 closed on `CustomSettingsValues`: it has its
    own `==` over what is shown. `Blueprint.related(_:)` was public and read nil after a refused include, so `?? 0`
    still gave the zero L5 removed: it is `package`, and the app counts through `members`. Two masking arms had no test
    (a container under a policy-worded secret key; a policy word after the key's first word): each has one. A raw-memory
    reader inside AbapitKit (`withUnsafePointer`, `load(fromByteOffset:)`) passes the line scan, which holds names; the
    runbook now says review holds that, as for `Secret`'s bytes.
- **Prevention:** each fix has a test that fails on the unfixed code or on its mutant; the fix's report lists every
  mutant and what killed it (84: 81 by a test, 2 by the compiler, and `presharedkey`, an equivalent stem, removed), and
  verifier round 1's report the 15 it added (14 by a test, one equivalent). Three lessons, in RULE-FEEDBACK
  2026-10-30: a test that asserts nil or empty for an odd shape must also assert the odd shape is said (counted or
  noted), or it pins the silence; a view whose resource holds a secret hands out a withheld copy and keeps the raw at
  `package`, so the compiler, not a comment, holds invariant 11 there; and (verifier round 1) a boundary the compiler
  holds lasts only while its modifier does, so a test holds the modifier; and (verifier round 2) the modifier holds
  only the declaration, not what reads it, so a test lists the readers and the stored layout too; and (verifier round 3)
  a fix that makes a read stricter makes a new nil, and the nil-is-said lesson applies to it before it merges. The
  round's count mutant is the history
  runbook's "a golden needs two of a kind" again: a count one test sees only as 1 isn't held. Still only a stub: what
  Apple sends in `eventDataPropertyKey`, in the fourteen field-less payloads and in a custom setting's values is a Phase
  2 live check; and `ProfileText`'s masking is still a denylist, so a secret under a key no stem or word names, that
  isn't a private key in a form it knows, is shown, while a policy value under a secret word is masked (Kerberos'
  `pwReqText` and `pwChangeURL`). A binary plist's repeated keys aren't counted.
