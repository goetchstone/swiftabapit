# 2026-10-31 — A whole-section lock outlived the per-list models, so the tested behaviour never reached the screen

- **Symptom:** Phase 2b's adversarial review (9dca2ae) recorded a permissions check that refused users and apps and
  allowed every other People and Content read. `SidebarItem.people.isLocked` and `.content.isLocked` were both true, and
  `ContentView` replaced each whole screen with "The last permissions check found this API account's role can't read
  people/content", while `PeopleModel` and `ContentModel`, and their tests (`aRoleThatCantReadUsersStillSeesGroupsAndUnits`,
  `aForbiddenListSaysSoAndTheOthersLoad`), showed the groups, org units, blueprints and configurations beside the refused
  list (M1). Ten lows came with it:
  - L1: a Content detail, or a group's or an org unit's members, for an id that can't go in a path said "Apple has no such
    item." of an item Apple had just listed.
  - L2: a package's location masking missed an address nested in an object or a list of objects, a `://` only in the
    query (everything before it, query values included, copied raw), `//user:pw@host`, `user:pw@host` and `;jsessionid=`.
  - L3: the Dashboard's recent events showed a dash for an actor Apple named only by id, and the type raw, decided in a
    view.
  - L4: two quiet-service rules, so the Services screen showed an unreadable date as "Never" and flagged a deleted service.
  - L5, L6: mutants T2 (a timeline cut at the page cap said nothing) and P4 (a People list refused part-way exported as
    whole) survived every test.
  - L7: the Apple MDM inspector said "Select a device" beside a selected one, during a Refresh or after the device left
    the list.
  - L8: the audit filter told a 129-character id and `.hidden` to fix characters that were all allowed.
  - L9: the 50-device details read ran on after the screen was left, holding the org's shared rate limiter.
  - L10: copies with drifted words (six "No organization yet" sentences, Apple MDM's without Apple School Manager; only
    People's export said an empty list had nothing to export; three day formatters), a public test-only property, and
    Refresh's routing in a view: mutant X1, People's Refresh sent to the devices, left every suite green.
- **Cause:** M1: Phase 1's lock was one probe per section (`SidebarItem.probed`), written when a section was one list.
  Phase 2b split People and Content into per-list panels, each with its own `.forbidden`, and left the gate whole-section,
  above them: the per-list behaviour the models were built and tested for sat under a lock that never let it reach the
  screen. The lows: decisions made in views, which have no test target (the recent events' words, the Services column, the
  inspector's placeholder, the Refresh switch); a credential mask keyed on a substring (`://` anywhere) instead of an
  address's shape; a guard (`isPathSafe`) checked in one model of three; and list code copied six times, whose words and
  tests drifted apart (DevicesModel had a refused-part-way test, People's copy didn't).
- **Why not caught:** each half was tested alone. `NavigationTests.eachSectionLocksOnItsProbe` pinned the lock's table as a
  constant (`.people: "users"`), so a test held the old shape in place; the model tests held the per-list states; and
  nothing asked what the screen shows for a set of probe results, because that composition was `ContentView`'s, which no
  test builds. Pre-commit item 14 (a test per cap, per guard) was walked for the guards each unit's author named, not for
  the timeline's cap or the `.forbidden` arm of People's `partialCount`; a twin's test (DevicesModel's) made the copy look
  covered.
- **Fix:** branch `phase-2b-screens`, commit 8f45fa6 ("fix(2b): lock a section only when every read it shows is refused, …"). M1: `isLocked(for:)` locks a section only when
  every read in its `reads` probed "forbidden"; a read with no probe on record isn't refused (an older check, a School
  org's unprobed Business-only reads), nor is an error; the Overview and Activity follow the same rule, and a School org's
  scope rule is unchanged. L1: Content's detail and People's members check `AppleRead.isPathSafe` and say
  `ScreenWords.unsendableID`, Apple MDM's sentence too; nothing is sent. L2: `ContentWords.location` parses a scheme only
  from a leading `[A-Za-z][A-Za-z0-9+.-]*:`, an authority after `//`, a user before an `@` ahead of the path without one,
  and masks path parameters; `addresses(in:)` masks the address runs of every string at any depth
  (`JSONValue.mappingStrings`, new in JSONAPI because AppModels can't name its types) and leaves a plain string as it
  came. L3: `DashboardModel.recentRows` (Activity's `ActivityRow`). L4: `DevicesModel.connection(of:now:)` over
  `QuietServices`, `quietServices(after:)` deleted. L5, L6: the two tests. L7: `AppleMDMModel.selectionNote`. L8:
  `AuditFilter.idProblem`, one sentence per rule. L9 (operator: invariant 7, a sweep is cancellable): `AppleMDMModel.pause()`
  from `onDisappear`, resumed by an unforced load. L10: `ScreenWords` (the sentences, the export rule, the day),
  `Panel(after:)` over `LoadState(after:)`, `ScreenModels` (the models and Refresh's routing, which `World` and
  `AppServices` both build), `timelineQuery` at `package`; merging the copied list code waits for Phase 3 (apple-reads
  runbook).
- **Prevention:** each fix has a test that fails on the unfixed code or on its mutant (the fix's report lists 46 mutants and
  what killed each, the review's T2, P4 and X1 among them: 45 killed, and one equivalent, `pause()`'s token bump, since it
  cancels every task and `current(_:)` checks `Task.isCancelled` too). The lock is tested over the reads it gates, partly and wholly
  refused and with probes missing (`aPartlyDeniedSectionIsUnlocked`, `aReadNoProbeRecordedDoesntLock`), not as a table. The
  Refresh switch and every view's words that branch now live in AppModels, so `swift test` reaches them; App/ still has no
  test target, so a branch left in a view is still untested (CI's snapshots render the states, they don't assert them).
  RULE-FEEDBACK 2026-10-31, "a whole-section gate outlived the per-list models below it". Still only a stub: whether a
  role refused users is refused user groups too, and what Apple's probes return for each list, is the Phase 2 live check.
