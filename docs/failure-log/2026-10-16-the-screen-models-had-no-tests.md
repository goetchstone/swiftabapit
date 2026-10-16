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
