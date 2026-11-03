# 2026-11-03 — A contract test that read each key alone, and a secret list written from descriptions it dropped

- **Symptom:** the adversarial review of `profile-schema-masking` (554ded9) found that `ProfileSchemaContractTests`,
  which vendored Apple's 2,321 profile keys to hold `ProfileText`'s masking, held less than it said.
  - M-1: its doc said masking more fails, but two new stems that mask containers (`ondemand`, `ikev`) left it green,
    and five keys were masked in a real profile that the test called shown: AirPlay's `DeviceName` and `DeviceID`
    beside the password in `Passwords`, Platform SSO's `AccountName` and `FullName` in `TokenToUserMapping`, and the
    descriptions in `passwordContentDescription`.
  - M-2: the secret list was written by hand, from descriptions the contract didn't keep. It missed ACME's
    `ClientIdentifier`, which Apple calls an anti-replay code and which was shown, and IKEv2's `PPK` written as a
    string; it didn't name the three data secrets; and moving the SCEP challenge to the over-mask list left every test
    green (mutant T01).
  - M-3: the relay header rule masked a string under four names, so `X-Authorization`, `Ocp-Apim-Subscription-Key`, an
    `Authorization` holding a list, a dictionary or a number, a header dictionary one level deeper and a list of name and
    value pairs each showed their credential.
  - Low: the count check read the stored counts, so a contract cut short with its header kept passed (T05b, L-3); a
    count cross-check that could never fail (L-2); the whole-set SHA-256 couldn't be recomputed from the output (L-6);
    the runbooks said "39" secrets and "every other key is shown except 12" (L-4, L-7).
- **Cause:** each key was tested by its last path component, alone at the top level of an empty profile, so a rule
  that masks a container whole (a list under a secret key) was invisible: the test's claim was about real profiles, its
  input wasn't one. Separately, which keys are secrets was a judgement made once, from YAML the script read and dropped,
  so nothing tied the list to Apple's own words, and the header rule was a denylist of names where the container itself
  says "these are headers".
- **Why not caught:** the test was written beside the code it checks and in the same shape as the code's own unit
  tests (one key, one value), so its mutants were the code's mutants; no mutant added a stem that only bites inside a
  container. The secret list had no source the test could read, so it could only be checked against itself. The class
  is the one failure-log 2026-10-16 named for gates ("the gate looked for what it could not see"), now for a contract
  test: a check is only as strong as the input it builds.
- **Fix:** commits `fix(schema): …` on `profile-schema-masking`.
  - M-1: one profile per payload file, every key in its real nesting from the contract's own types (a dictionary holds
    its subkeys, a list one item of its single subkey, `ANY` by that name), inside `PayloadContent` with its
    `PayloadType`; every string, integer, real, data and untyped value a unique needle, and a container with no subkeys
    a sample. Masked means the needle is gone, and what is masked must be exactly `secrets`, `overMasked` (now naming the
    five) and the data keys. `eachBuiltProfileHoldsEveryKeyAtItsPath` checks the builder without `ProfileText`, and a
    needle count holds the input whole.
  - M-2: the script marks `describedAsSecret` from each description (one regex from Apple's wording, never on a flag:
    45 keys), and every marked key is on `secrets` or on a reasoned `notSecret`; the two secrets no description names
    are listed in the test. `clientidentifier` is a stem and `ppk` a secret ending; the data secrets are named and also
    tested as strings.
  - M-3: under a key that names headers, every value of a dictionary and every item of a list is masked, whatever its
    type; `credentialHeaders` is gone.
  - L-3: counts and the whole SHA-256 recomputed from the payloads; L-6: that SHA-256 over the sorted per-file ones, the
    PyYAML version recorded, regenerated twice byte for byte; L-4, L-7: the runbooks say what the test holds, which
    stems no schema key exercises, and that no drift job watches device-management.
- **Prevention:** every fix has a test shown failing on 554ded9's code, lists or contract, and the mutants (the
  reviewer's survivors that still apply and 31 of the new code and test: 35 killed, one equivalent) are in the PR, each survivor with its reason. The lesson
  for any contract test over a schema: build the input as the real thing nests it, and read the source's own words for
  what a list is, rather than writing the list beside it. Still a denylist: a secret under a key no stem names is shown,
  and the release branch (Release-v27.2) adds an `AdditionalHTTPHeaders` dictionary to the SSO payload that only a
  moved pin will test.
