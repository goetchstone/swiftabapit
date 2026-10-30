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
- **Prevention:** each fix has a test that fails on the unfixed code or its mutant (listed in the fix's report). Still
  only a stub: what Apple sends in `eventDataPropertyKey` and in the fourteen field-less payloads is a Phase 2 live check.
