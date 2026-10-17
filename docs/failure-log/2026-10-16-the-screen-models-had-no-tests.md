# 2026-10-16 — The screen models had no tests, so an org switch kept the old org on screen

- **Symptom:** Phase 1b's adversarial review (867d7a6) copied `App/Models` into a scratch package with the strict
  stub and found: after switching org, the Devices rows, the CSV and Find were still the old org's and the banner
  said "As of now"; a superseded load said "loaded" over 1,000 of the old org's rows while the new org was loading,
  and wrote its learned rate (20) into the new org's profile (7); Refresh during a load showed "loaded" over 1,000
  of 2,500 rows; a role that can read devices but not MDM servers got no devices at all; editing an org with a new
  key deleted the old key before a duplicate client ID was found; the Add clean-up was `try?`; two Add editors
  could take the same id; the editor wrote back the profile it opened with; an org with no Apple account showed
  idle zeros; and a failed walk left its rows exportable with nothing saying they were partial. Every mutant in
  `App/Models` survived, the generation guard's deletion included.
- **Cause:** nothing reloaded when `generation` changed (only the view's `selection = nil` reacted), and a
  cancelled `AsyncThrowingStream` loop ends without throwing, so the lines after it ran with no generation check
  and recorded the rate for `orgs.active`, not the org the load began for. Services were read first, so their 403
  or one service's failing device list failed the whole screen. The editor's save lived in the view.
- **Why not caught:** invariant 8 names "screen-model tests" as its home, and none existed: the models were in the
  app target, which `swift test` doesn't build, and no app test target exists. A home that isn't there holds
  nothing, and the PR's mutant list had no line for the models.
- **Fix:** branch `fix1b-models` (Phase 1b review H2, M3, M4, M6 and the LOWs). The models moved to a package
  module, `AppModels` (`@MainActor`, public API only; the graph lists, the plan and the Xcode project updated),
  with `AppModelsTests` over the strict `AppleStub` behind a `Gate` that holds pages. `OrgsModel.onSwitch` clears
  and reloads every model at once; each load has a token checked after every await and every page; devices and
  services load side by side, each with its own state, and a device whose service couldn't be read is "Unknown",
  never "unassigned"; `OrgsModel.save` validates before any Keychain write, reserves ids and client IDs, merges
  onto the current profile, clears an old account's locks and rate, and reports a refused clean-up. An unusable org
  says why; a partial list says so and doesn't export. A boundary scan keeps `AppModels` off the package-only
  routes the move made visible to it. The review's four failing race tests are among the new tests; each fix's
  mutant is listed in the unit's report.
- **Prevention:** `AppModelsTests` is invariant 8's home now. A RULE-FEEDBACK entry records that an invariant
  named a home that didn't exist. Still only a stub: a live org switch and a live 403 on MDM servers are Phase 1's
  operator checks.

## Verifier round 1 — the fix's own gaps

- **Symptom:** two verifiers re-attacked `fix1b-models` (d54619f). Every guard in `readServices` could be deleted, and
  so could the switch paths (a reset that kept the old note or assignments, a remove of the active org that didn't
  switch, handlers run before the generation moved), with all 29 tests green. Splitting the panels had made the
  services silent on Devices and Overview: while they were read, rows showed a blank Service, as if unassigned,
  the "not assigned" and Services tiles read 0, and a 403 on services showed "every service has connected". An edit
  didn't reserve its id, so with the org removed during the edit's Keychain write, an Add of the same name took
  the id and the edit merged onto it. The boundary scan erased interpolations with the literals around them, so
  `"\(vault.secret(item))"` passed. An unused JSONAPI edge had been added.
- **Cause:** the first round's tests drove `readDevices` only. The split moved the services' state onto
  `servicesState`, which only the Services screen showed. Only an Add reserved its id. The scan's literal regex
  swallowed `\( … )`.
- **Why not caught:** pre-commit item 14 asks for a test per guard; the list of guards wasn't walked for the second
  task. The saves' windows were `Task.yield()` races, which can't hold an edit inside its Keychain write, and the
  rate-read window couldn't be reached at all.
- **Fix:** `fix(1b-models): verifier round 2`. A test per guard and per switch path; `serviceNote` says the
  services are being read, a pending row reads "Reading…", and `serviceCount`/`unassignedCount`/`quietServices`
  are nil (a dash, with `servicesUnread`) until their lists are read whole; failed services say "Partial: N"; an
  edit reserves its id; the scan tokenizes literals and keeps interpolations as code; the JSONAPI edge is gone. The
  tests hold their windows: `HeldStore` (a save inside its Keychain write), `Stall` (a load inside its rate read).
  The first fix's open item is closed too: a permissions check that was running when its org was edited to another
  account no longer records the old account's locks onto the new one (`record(_:probed:)`).
- **Prevention:** the mutant script for this unit covers every verifier survivor and this round's new code. A count
  shown to the operator is `Int?` unless its list was read whole, so a zero nobody counted can't be written; a
  RULE-FEEDBACK entry (2026-10-17) records the near-miss. Still a stub: a live slow MDM-servers read is Phase 1's
  operator check.
