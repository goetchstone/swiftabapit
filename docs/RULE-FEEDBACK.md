# Rule feedback ledger

Low-friction notes on how [CLAUDE.md](../CLAUDE.md)'s invariants performed in practice. **Sessions
append here; they do not edit CLAUDE.md.** The `improve-rules` observer pass reads this pile later,
with distance, and proposes at most one focused constitutional edit as a PR. See
[FRAMEWORK.md](FRAMEWORK.md) §3.

When to add an entry: an invariant almost let something through, was in the wrong enforcement layer,
was worded loosely enough to permit a bad reading, or a failure hit a shape no invariant covers.

**Format**, newest first:

```
## <date> — <one-line title>
- **What happened:** <the incident / near-miss; link commit/PR/failure-log entry>
- **Invariant in force:** <#N and its name, or "none — new shape">
- **Why it didn't hold:** <wrong layer / weak wording / not covered / not a rules problem>
- **Would a rule have caught it?** <no / only if enforced differently / yes but unworded>
- **Enforcement home if changed:** <skill (soft) / hook (hard) / tripwire test (backstop)>
```

The most valuable answer is *"only if enforced differently"*: the invariant exists and lives in the
wrong layer, and moving it (skill → hook → tripwire) needs no text change.

SwiftGamGui's ledger (`../SwiftGamGui/docs/RULE-FEEDBACK.md`) is the history this one starts from;
its entries on parity copying the reference's defects, the reviewer's checkout changing under it,
stacked PRs closing, invisible characters from an editing tool and the wrong GitHub account all apply
here and are already wired into the skills.

## 2026-10-30 — Holding a declaration's modifier didn't hold what reads it
- **What happened:** Phase 2a's verifier round 2 added `public var rawText: String? { configurationProfile }` and
  `public extension Configuration { var sent: Resource { received } }` to AbapitKit: every test in both packages stayed
  green, though round 1's `whatHoldsTheRawProfileStaysPackage` pinned the three declarations' `package` level (the entry
  below). `package` keeps the raw profile from the app, and any AbapitKit module can still hand it out under a new
  public name (failure-log 2026-10-30, "a lenient read pinned by a test, and a secret held by a doc comment").
- **Invariant in force:** #11 (sensitive fields never leave).
- **Why it didn't hold:** the entry below proposed pinning each held declaration's modifier, and that is half the
  boundary: the other half is every public declaration that reads the held value, which the compiler doesn't check.
- **Would a rule have caught it?** only if enforced differently: a value an invariant holds at `package` names its
  readers in a test (`BoundaryTests.onlyTheListedLinesReadTheRawProfile` lists every AbapitKit line that names the raw
  profile) and its stored layout (`whatAConfigurationStoresIsTheTwoCopies`: a new stored copy names neither). And a
  type holding a secret writes its own `==`: Swift's compared the raw profile, an oracle for a guessed secret.
- **Enforcement home if changed:** tripwire test: the one scan the entry below proposes lists, for each held
  declaration, its modifier and every line that reads it (`Secret.bytes` and `Columns.init` too).

## 2026-10-30 — "The compiler holds it" held only while a modifier did, and no test held the modifier
- **What happened:** Phase 2a's verifier round 1 widened `Configuration.received`, `CustomSettingsValues.received` and
  `.configurationProfile` to `public`, one at a time: `scripts/test.sh` stayed green in both packages. Only the app-side
  name scan stood behind the claim, from the M2 fix just before, that the compiler holds the raw profile (failure-log
  2026-10-30, "a lenient read pinned by a test, and a secret held by a doc comment").
- **Invariant in force:** #11 (sensitive fields never leave), and #3's `Secret`'s `package` bytes the same way.
- **Why it didn't hold:** the access level is the enforcement, and nothing tests it: a mutant of one word passes
  everything. `Secret.bytes` and `ExportPolicy.Columns.init` rest on a modifier too, and no test in the packages pins
  either (`noBuildSettingOpensThePackageBoundary` refuses a flag that would open them, not a widened declaration).
- **Would a rule have caught it?** only if enforced differently: an invariant whose home is "the compiler" names a
  test that pins the modifiers it depends on, as `BoundaryTests.whatHoldsTheRawProfileStaysPackage` now does for the
  raw profile (a widening and a move into a `public extension` both fail it).
- **Enforcement home if changed:** tripwire test: one source scan listing each `package` or `internal` declaration an
  invariant's home names (`Secret.bytes`, `Columns.init`, the raw profile, later `WriteTicket.init`), each held at that
  level and only that.

## 2026-10-30 — A secret held by a doc comment, again: invariant 11 for a model, not only for CSV
- **What happened:** Phase 2a's review found a custom setting's plaintext profile public on `Configuration`'s resource,
  its custom settings' object and a blueprint's `included`; only "show it through `profileText`, never raw" kept it off a
  screen (M2; failure-log 2026-10-30, "a lenient read pinned by a test, and a secret held by a doc comment"). The same
  shape as CSV's every-key export (RULE-FEEDBACK 2026-10-16, below), one layer down.
- **Invariant in force:** #11 (sensitive fields never leave; CSV export is an allowlist).
- **Why it didn't hold:** wrong layer again. The fix for CSV moved the column list to the compiler, but the rule that
  made the leak possible, "a view keeps its resource and the inspector shows every attribute", applied to every view,
  and nothing asked which resources hold a secret.
- **Would a rule have caught it?** only if enforced differently: a view whose resource holds a secret hands out a
  copy with it withheld (as its `resource`, its description and its mirror) and keeps the raw at `package`, so the app
  can't name it. Fixed that way (`Configuration.received`), with a canary test through the stub.
- **Enforcement home if changed:** CLAUDE.md #11's home could name the compiler for models too (`Configuration.received`,
  `CustomSettingsValues.configurationProfile` are `package`) and `aCustomSettingsProfileReachesNoPublicValue`; and the
  `pre-commit` skill's item 10 could ask, for each new model, "does its resource hold a secret? then a canary test".

## 2026-10-30 — A test pinned a lenient read, so the silence had a test holding it in place
- **What happened:** an audit event whose named payload key missed read `payload == nil`, its fields uncounted, and the
  acceptance pass printed `ok`. `AuditEventTests` asserted `missing.payload == nil` (M1; the same failure-log entry).
  failure-log 2026-10-16 ("the mosyle stub agreed with the client") already said a lenient reading needs a source.
- **Invariant in force:** #10 (unknown keys are counted, shown raw) and #8 (never silent).
- **Why it didn't hold:** the lesson lived in a failure-log entry, not in a step anyone runs. A test that asserts what
  the code does for an odd shape, nil or empty, passes whether the odd shape is said or not, and then guards the silence
  against the fix.
- **Would a rule have caught it?** yes, if stated as a check: a test asserting nil, empty or "none" for a shape Apple
  doesn't document also asserts that the shape is said (counted as unknown, noted, or a status that isn't `ok`).
- **Enforcement home if changed:** skill (`pre-commit` item 12, "never silent": "a test of an odd shape's nil asserts
  its note too"), and the review brief.

## 2026-10-17 — A fix for invariant 8 made other data silent
- **What happened:** the first fix for Phase 1b's M3 loaded devices and services side by side, each with its own
  state, but only the Services screen showed the services' state. While they were read, or after a 403, Devices
  showed a blank Service column (read as unassigned) and Overview showed a Services tile of 0, an unassigned tile of
  0 and "every service has connected". Every guard in the services read could also be deleted with the tests green
  (failure-log 2026-10-16, "the screen models had no tests", verifier round 1).
- **Invariant in force:** #8, "stale or truncated data is never silent", home "screen-model tests".
- **Why it didn't hold:** the home now existed, but its tests followed the half of the code the review had named.
  A count or verdict built from a list nobody read whole looks the same as one built from a whole list.
- **Would a rule have caught it?** Only if enforced differently: pre-commit item 14's "a test per guard" was in
  force but not walked for the new half. A model-level rule would: a count shown to the operator is optional
  (`Int?`, a dash) unless the list it counts was read whole, so the type, not a reviewer, refuses the zero.
- **Enforcement home if changed:** skill (item 14: walk every guard of each new task, not only the named one).

## 2026-10-16 — Invariant 8 named a home that didn't exist
- **What happened:** Phase 1b's review found the screen models (`App/Models`) untested: an org switch kept the
  old org's rows, CSV and Find; a superseded load said "loaded" and saved its rate on the next org; one failing
  services read emptied the device list. Every mutant there survived (failure-log 2026-10-16, "the screen models
  had no tests").
- **Invariant in force:** #8, "stale or truncated data is never silent", home "screen-model tests".
- **Why it didn't hold:** the models lived in the app target, which `swift test` doesn't build, and no app test
  target existed, so the named home was empty and nothing said so.
- **Would a rule have caught it?** Only if enforced differently: a home an invariant names should be a test target
  that exists. The models are now `AppModels`, in their own package (`Packages/AbapitApp`, AbapitKit's public API only),
  with `AppModelsTests`.
- **Enforcement home if changed:** tripwire test (a check that every enforcement home CLAUDE.md names exists).

## 2026-10-16 — Invariant 11 names an enforcement home that doesn't exist
- **What happened:** Phase 1b's review found CSV export was a denylist (M2), and its verifier found the fix
  held only by convention: any caller could pass `Array(item.attributes.keys)` as the column list. Invariant
  11 names `RedactionTests` and `SourceScanTests` as its home; no `RedactionTests` exists, and no scan looks
  at CSV export. Fixed in `fix1b-reports`: `CSV.text` takes an `ExportPolicy.Columns` only Reports can make.
- **Invariant in force:** #11 (sensitive fields never leave; CSV export is an allowlist).
- **Why it didn't hold:** wrong layer: the wording was right, and the home named a test nobody wrote.
- **Would a rule have caught it?** only if enforced differently: by the compiler, as #1 is.
- **Enforcement home if changed:** CLAUDE.md #11's home becomes "the compiler (`ExportPolicy.Columns` has an
  internal init) and `ExportPolicyTests`", plus the Mosyle adapter's test when Phase 7 writes it.

## 2026-10-16 — A check that was never seen to fail
- **What happened:** Phase 1b's review got past the URLSession scan, the Release gate's debug-switch check
  and the `#if DEBUG` import check. Fixing them showed the gate's `nm` check had never run: a pipe under
  `pipefail` turned every match into "no match" (failure-log 2026-10-16, "the gate looked for what it could
  not see").
- **Invariant in force:** #4 (no listener; its scans) and plan §3.9 (no debug code in Release).
- **Why it didn't hold:** not covered as a check. Each check was written to find a shape, and none was run
  against something it must refuse. The stub entry below is the same lesson for stubs.
- **Would a rule have caught it?** yes, if stated as a check: every scan and gate has a test, or a recorded
  mutant run, that it fails. A scan gets a self-test of the spellings it must find. A binary gate is run on
  mutant builds made from a scratch copy.
- **Enforcement home if changed:** tripwire tests (`ScannerTests` for the scanner; `DebugOnlyTests`) and the
  `pre-commit` skill's item 13, which could add "show each new check failing once".

## 2026-10-16 — "Stubs fail like the APIs" was read as "refuse like the APIs"
- **What happened:** Phase 1a's strict stub refused every request Apple would refuse, and could not
  produce a dropped connection, a revoked account, a short-lived token or an oversized body. 13 of the
  reviewer's 14 mutants survived, and one header crashed the app (failure-log 2026-10-16, "the stub could
  not fail").
- **Invariant in force:** #5 (stubs fail like the APIs) and #7 (bounded).
- **Why it didn't hold:** wrong reading: the invariant's text covers it, but "strict" pulled the work toward
  validating requests. Bounds (#7) were written and never exercised, so they held only by inspection.
- **Would a rule have caught it?** yes, if stated as a check: every failure branch in a client has a stub
  switch that drives it, and a test that uses the switch.
- **Enforcement home if changed:** skill (`pre-commit`: "for each retry, refresh, cap and fallback in the
  diff, name the test that drives it") and the review brief. CLAUDE.md invariant 5 gains "and has a switch
  for each failure the client handles".

## 2026-10-16 — A check's own author picked its mutants, and the review broke eight checks
- **What happened:** Phase 0's checks each passed their author's mutants and fell to the reviewer's (failure-log
  2026-10-16, "the gate checked names, not values"): a sandbox entitlement of another type, a second
  executable, a computed manifest edge, a key attribute from the wrong class, a second example on a page.
- **Invariant in force:** #4 (no listener, sandbox on, exact entitlements) and #1 in spirit (Assist must not
  reach a write).
- **Why it didn't hold:** wrong layer for the mutants: "mutate the code by hand" is in CLAUDE.md, but the
  author mutates within the shape they already check.
- **Would a rule have caught it?** only if enforced differently: the adversarial review earned its cost here
  exactly as SwiftGamGui's PR #1 review did (nine defects in credential code). Keep it mandatory for every
  check, gate and hook, not only for feature code; ask it to attack the check's assumptions.
- **Enforcement home if changed:** skill (`pre-commit` item 13: the review attacks the checks too).
- **Not fixable alone:** a PR can edit its own gate and so its own `ci-ok`. With one maintainer, a CODEOWNERS
  review rule would block every merge. Left to the operator; meanwhile the reviewer is told to read any
  change to `.github/`, `scripts/check_*`, `Config/*.entitlements` and the graph lists first.

## 2026-10-16 — The editing tool decoded escapes into invisible characters, again, on day one
- **What happened:** writing `scripts/gen_fixtures.py`, the file-editing tool turned `\u00a0`, `\u2003`,
  `\u200b`, `\u3000`, `\u2028` and `\ufeff` in string literals into the characters themselves; writing the
  `pre-commit` skill, it did the same to the `\u200b` in the sentence warning about exactly this.
  `scripts/check_text.py` refused both before the first Phase 0 commit; they were re-escaped by a script
  and the goldens regenerated byte-identical. Same shape as SwiftGamGui RULE-FEEDBACK 2026-10-08.
  Writing this entry, the tool did it a third time, and `check_text.py` caught that too.
- **Invariant in force:** none numbered; the hygiene tripwire (`check_text.py`, local pre-commit, CI).
- **Why it didn't hold:** it did: the tripwire is the right home and caught it. Recorded because the
  recurrence rate is now two repos out of two.
- **Would a rule have caught it?** yes, and did (tripwire).
- **Enforcement home if changed:** none. A habit worth a line in `pre-commit`: write such characters
  through a script (`\N{...}` or `chr()`), never by hand in an edit.

## 2026-10-16 — The plan's module graph had Planners build a type its edges couldn't reach
- **What happened:** plan §3.2 has `Planners → {AppleModels, MosyleModels, JSONAPI}` build
  `WireOperation`, which §3.1 puts in `HTTPCore` (URLSession; not pure). Following both would either
  break the "pure modules import only Foundation" rule or make the dependency-edge test fail on day
  one. Phase 0 added a pure `Wire` module (`WireOperation`, `ReadRequest`, `Host`) that `Planners`,
  `HTTPCore` and `ChangeCore` share; `WriteTicket` and `send(_:ticket:)` stay in `HTTPCore`.
- **Invariant in force:** #1 (one write path) and #4 (the package graph).
- **Why it didn't hold:** not a rules problem: a plan inconsistency found by writing the graph test
  first.
- **Would a rule have caught it?** yes, and it did: the graph test is written before any module.
- **Enforcement home if changed:** none needed; `PackageGraphTests` holds the corrected graph.
