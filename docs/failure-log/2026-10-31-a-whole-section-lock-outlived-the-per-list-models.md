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
  address's shape; a guard (`isPathSafe`) checked in one model of five (Device 360's was found only in verifier round 1,
  the Devices read's walk of each service's device list only in round 2); and list code copied six times, whose words and
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
  - Verifier round 1 (`fix(2b): verifier round 1`): both verifiers held the fix; every finding was low, and 14 mutants of
    the fix survived as real test gaps (one more, the order of the audit filter's two id sentences, isn't a defect: either
    sentence is true when both ids are refused). The lock's partly refused cases all had their last read readable, so a
    lock on the last read alone passed: each read of each section is now refused alone and left readable alone. M1's rule
    let the Overview lock, and the view's sentence read "can't read overview.": `SidebarItem.lockedNote`. Four of
    `pause()`'s and `resume`'s branches had no test (a selection's own read stopped by a pause stayed "Reading…" under its
    mutant, a refusal was asked again on return, a past-limit selection wasn't re-read, an org switch after a return read
    nothing): each has one. The views had stopped checking `shown.isEmpty`, and only Devices' search was held, so
    Content's and People's units' Export counting the rows read passed; Refresh's force was held for People only; the
    Dashboard's recent rows' ids were never checked: each has a test. `addresses(in:)`'s arms were held only through
    `location`, and without the skip past a digit or `-` before a glued scheme the split recursed until the stack
    overflowed: each arm is held through `addresses(in:)`, and the split now needs the address to start after the text, so
    it ends whatever the skip does. Leaks the review's shapes didn't name: an outer scheme or a label glued before an
    address (`jar:https://deploy:pw@…`, `Mirror:https://…`, `token:` and a no-break space) was read as its scheme and the
    address copied as a path; one slash after a scheme (`https:/user:pw@host`) was no authority; a url that isn't a string
    had its strings read only as other text, and the Location read a dash; and the Description field showed in clear what
    its attribute masked. Each is masked, with a test; an email address in other text now shows as it came, since the
    Description is masked too. Device 360 said "Apple has no such item." in four panels for a serial that can't go in a
    path, review L1's class in a fourth model: it says `ScreenWords.unsendableID` and sends nothing. Not changed, and why,
    in the apple-reads runbook: an address split by an unencoded space inside other text, a user with no password and no
    path (`token@host`, an email's shape), a JSON key, and masking that errs toward hiding (`Requires:macOS;iOS`).
  - Verifier round 2 (`fix(2b): verifier round 2`): one medium, the rest low. The medium came from round 1's L9 fix:
    `pause()` marked the unread details "Not read", and coming back started their read without marking them back, so
    while the return read them every row said "Not read", the note said the read had stopped when the screen was left,
    and Export was on and wrote "Not read" for devices being read; every pause test waited for the reads to settle before
    asserting, so the window between the return and the read's end had no test. The return now marks them to be read
    ("Reading…", the progress note, Export held), held while the return's read is at the gate. Masking leaks no shape
    list had named: an address inside another's path (a proxy's, an archive's, one joined by `,` or `;`) was copied as the
    outer path, and a blank inside a Location's password cut the address, its first half shown as a host while the note
    said the password was masked; each is masked. The package's title, Name, Version, Bundle IDs and Hash fields, its row
    and its CSV, a file that leaves the app, showed raw what its attributes masked: round 1 masked the Description for
    that reason and stopped there; each now goes through `addresses(in:)`. The Devices read sent nothing for a service
    id that can't go in a path and called the service "no such item", review L1's class in a fifth model: it says the id
    can't be sent. 14 mutants of round 1's code survived every suite (four guards of the glued split, CR, VT and FF as
    blanks, a leading `@`, a null url, the path guard held for apps only, a return to a failed list, an unforced load
    with no pause, the idle selection note, a stamp ahead of the clock): each has a test that kills it, as do the
    mutants of this round's own fixes (the repairer's report lists each). Not changed, and
    why, in the apple-reads runbook: one Apple MDM model shared by every window (a pause in one pauses another), an
    address percent-encoded in a path segment, a password a blank splits in other text, and over-masks of an email after
    a scheme or a label or before a path.
  - Verifier round 3 (`fix(2b): verifier round 3, …`): every finding low. Nine mutants of rounds 1 and 2 survived every
    suite, each a test gap with the code right: the scheme's bytes ending at its own `:` (an Azure SAS's
    `st=…T00:00:00Z` and a `#t=1:` fragment, scheme-less, copied raw under the mutant), the scheme-less user arm's last
    `@` (`deploy:p@ss@host`), the join's last `@`, the masked flag ORed over every run (a Location masked only before a
    blank lost its note), and four of Apple MDM's: the selection asked first on return (only a past-limit one was
    held), a Refresh clearing the pause (an org switch after it read nothing, and an unforced load ran a second sweep
    beside the Refresh's), and the return's read among the tasks a pause or a Refresh cancels (its held request went out
    after the screen was left). Each has a test that fails under it, run through the verifiers' own runners before and
    after. `ContentTests.aSupersededDetailWritesNothing`, older than this diff, flaked: the superseded read's
    `CancellationError` return counts in `readsFinished`, so the wait for one read could end on it with the second still
    loading; it now waits for the first read at the gate, then for the detail itself.
- **Prevention:** each fix has a test that fails on the unfixed code or on its mutant (the fix's report lists 46 mutants and
  what killed each, the review's T2, P4 and X1 among them: 45 killed, and one equivalent, `pause()`'s token bump, since it
  cancels every task and `current(_:)` checks `Task.isCancelled` too). The lock is tested over the reads it gates, partly and wholly
  refused and with probes missing (`aPartlyDeniedSectionIsUnlocked`, `aReadNoProbeRecordedDoesntLock`), not as a table. The
  Refresh switch and every view's words that branch now live in AppModels, so `swift test` reaches them; App/ still has no
  test target, so a branch left in a view is still untested (CI's snapshots render the states, they don't assert them).
  RULE-FEEDBACK 2026-10-31, "a whole-section gate outlived the per-list models below it". Verifier round 1's 14 gaps are
  RULE-FEEDBACK 2026-10-16's lesson again (the author mutates within the shape they already check: the fixer's 46 mutants
  held each fix's named shape, not its other ends) and 2026-10-31's "a fix that made a read stricter made a new silence"
  (a fix that deletes a view's check makes the model the only guard, and every screen's model then needs the test): no
  new rule; the repairer's report lists each mutant and the test that kills it. Round 2's medium: RULE-FEEDBACK
  2026-10-31, "a state a fix added was checked only after the reads settled" (a fix that adds a state is followed through
  every way out of it, and asserted while a read is held at the gate, not only after `settled`). Its masking leaks repeat
  RULE-FEEDBACK 2026-10-16 (the author mutates within the shape they already check) at the next layer: the fixer named
  the review's shapes, round 1 the outer ones, round 2 the inner and the blank; no new rule for those. Still
  only a stub: whether a role refused users is refused user groups too, and what Apple's probes return for each list, is
  the Phase 2 live check.
