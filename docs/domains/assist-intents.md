# Domain: assist intents

**One line:** Foundation Models and App Intents only fill drafts; Spotlight indexing is off by default (plan §5).

**Owns invariant(s):** #9

**Status:** begun. Phase 9's read-only step started with the report catalog (below); the answers, the read intents and the
model's pick are built (below); the in-app Ask is a later PR. Read the plan section named above and the nearest SwiftGamGui
runbook too.

## Files

- `Packages/AbapitKit/Sources/Reports/ReportCatalog.swift`: the catalog.
- `Packages/AbapitKit/Sources/Assist/{Choices,WordRule}.swift`: the run-time list and the plain rule.
- `Packages/AbapitKit/Sources/Assist/{Picker,ModelPicker,Refusals}.swift`: the model's pick, checked by code; tests
  `AssistTests/{PickerTests,StubModel}.swift`.
- `Packages/AbapitKit/Tests/AssistTests/Evals/`: code evaluators, the `Evaluations` harness, the model half (flagged).
- `Tests/Fixtures/assist/{dev,heldout}.json`: invented phrasings with the right answer.

## How it works

**The catalog is the one list intents and the model pick from.** `ReportCatalog.entries` holds all six reports (AppleCare
coverage ending, Fleet age, Activation Lock, MDM migration, Device management service health, Out of warranty), each with
its filters, and `ReportCatalog.resolve` is the only code that turns tokens into a report's filters: the Reports screen
(`ReportsModel.build`) calls it and nothing else does. A filter is either a list of exact values (`group`) or a whole number
with inclusive bounds (`days` 1...1825, `years` 1...10). A name the report doesn't have, a name given twice, a non-number
and a number out of bounds are each a problem in words, never clamped and never silently matched to nothing.

Each entry's `holds` line says what the report accepts, built from its filters' group values and bounds only, in code's
words. It holds no list data (no serial, name or id), so a later pick prompt can show it. Operator answers of 2026-11-24
this rests on: Q1, "Six reports + more": the six reports by name and group, the Needs-attention summary and serial lookup;
Q3, "Picks + explanations": the model only picks from this list, and code resolves and words everything else.

## Choices and the word rule

The pick list (the operator, 2026-11-24: Q1 "Six reports + more", Q3 "Picks + explanations": the model maps a sentence onto a
report or rule and its group, code checks every pick, the model gets no tools). This is the list and the plain rule, with the
samples to score both; the model's own pick is a later change.

- **`Choices.build(scope:hasMosyle:thresholds:)`** returns the six reports, one Needs-attention summary and the rules this client
  can answer. No Mosyle rules without a Mosyle org; no Apple MDM rules (the five that read `mdmDevices`) for a School org, whose
  contract has no such list. `Choices.Scope` is Assist's own (Assist may not import `Orgs`); the caller maps its scope onto it.
- **Words come from code only**: a report's label and holds line from `ReportCatalog`, a rule's label from
  `NeedsAttention.Rule.title`; the summary's label ("Needs attention") is the one string of its own, and its holds line is the
  rule titles. The inputs carry no list data: a scan test holds the signature and the imports, and another builds the list after
  a whole demo fleet is made and finds none of its serials or names in any label.
- **Size**: 19 choices at most (a Business client with Mosyle), 16 without Mosyle, 14 for School with Mosyle, 11 for School
  without. `Choices.limit` is 40, the shared lessons' point to narrow in steps; `build` fails past it. A pick of 19 labels with
  holds lines after is small. A later change may still split the reports and the summary from the rules, as two small picks.
- **`WordRule`** picks the choice sharing the most whole words with the sentence (lowercase, a plural's s dropped, plain stop
  words and one-letter words dropped), then the group whose words (not already in the label) the sentence shares; ties go to the
  earlier choice, the list being reports first. A short list of change words makes it a change request; no shared word refuses.
  The change words are the verbs of the dev samples only (the coordinating session's decision, 2026-11-25), so the held-out
  requests to change something use verbs the rule has not seen. It is the plain alternative the model must beat. Proposal for
  the operator, not a decision: the in-app Ask uses `WordRule` until the model beats it on the held-out samples.
- **Samples**: 212 dev and 106 held out (a third of each category), in `Tests/Fixtures/assist/`. About 30 per report and for the
  summary, 6 per Needs-attention rule, and 18 write-shaped and 18 off-topic. Invented; no tenant terms. A sample lists every
  accepted answer (a report and a rule can both fit, but a fixed-window rule only when the request names no window or the
  rule's own), and the accepted groups of its first. Note `lock:NONE` is "locked, with a
  lock type of NONE", not "no lock": a request for no lock expects `unlocked`. The held-out file is read by the shape test and
  by the flagged model run only: no fast test scores, prints or quotes it, no Swift file holds one of its sentences, and nobody
  tunes against it.
- **Evaluators** (`Judge`): report (any accepted answer), group (an accepted group; a rule answered where a report fits too is credited only the group it stands for, by a small table)
  and refusal (a change request told as one, an off-topic sentence refused), each over only the samples it applies to.
  `PickEvaluation` runs them through Apple's `Evaluations`, which works under plain `swift test` here; the model's picker will
  take the same evaluation.
- **WordRule on dev (fast run)**: report 108 of 188, group 30 of 81, refusal 24 of 24. Printed as `EVAL wordrule dev` and pinned
  in `WordRuleEvaluations`; a change to the rule, the list or the dev file moves it, and the pin says so.
- **The model half** runs only with `ABAPIT_MODEL_EVALS=1`, and never when `CI` or `GITHUB_ACTIONS` is set: the model picker on
  the dev samples, `WordRule` printed beside it, and each pick's largest call counted with `tokenCount`. CI never calls the model.

## The model's pick

`Picker.pick(_:for:using:)` maps a sentence onto one of the client's `Choices` and its group, and returns a pick: it runs
nothing (the operator, 2026-11-24, Q3 "Picks + explanations": code checks every pick, the model gets no tools; D7 and D10:
on-device only, never Private Cloud Compute).

- **Refused before any call, in words** (`Refusals.before`): no client; an empty sentence or one over 300 characters (never
  cut); Mosyle named for a client without a Mosyle org; the model unavailable (each `UnavailableReason`); an unsupported language.
- **Three picks** (`ModelPicker`), each one fresh session, greedy, a 100-token response cap, a `DynamicGenerationSchema` `anyOf`
  built at run time, the pick field first and then the request's own words that point to it: (1) see or list something, or
  change something; a change request is answered by code, "This version only reads; nothing was drafted." (2) one of the
  client's choices (at most 19, one list: the shared lessons narrow in steps past about 40) or "None of these", the reports'
  holds lines after the list; (3) for a report with groups whose sentence names one, a group's plain label or "all".
- **The prompt** holds the sentence and the catalog's words only: no example sentence, no list data. A test takes each call
  apart and finds nothing else.
- **Code checks every answer**: a pick off the list, a missing pick, empty words, the words field's description echoed back, or
  words the request doesn't hold is asked about once, the fault named; a second fault is "not understood". A thrown error (each
  `LanguageModelError` case, a parsing error, assets not ready, a concurrent request) is "not understood" at once, worded by
  kind, never the error's own text. Code checks the final id and group against the list again (`Picker.check`).
- **Numbers** come from code's parse of the sentence: plain digits before day(s), week(s) or wk(s) (seven days each), year(s)
  or yr(s), "90-day" too, passed to `ReportCatalog.resolve` as written so its bounds refuse what's too big. A number written with `.`, `,`, `-` or a
  minus sign or a dash ("1.5 years", "-30 days", "30-60 days", "30—60 days", "1,000 days"), glued to letters that aren't a unit
  ("90d"), in months, hours or minutes, or a unit word with no digits ("two weeks", "a year") is a problem; so is, for a choice
  that takes a number, a bare number ("within 60", "30 d", "before 2021", one end of "30 to 60 days"); so is a unit the report doesn't take, two different values,
  and, for a rule with a window (AppleCare ending, check-in, quiet service, migration deadline), a number other than its window.
  **Any problem refuses the pick** (`Refusal.numbers`, the problems as its words; the coordinating session's decision,
  2026-11-25), so no caller runs a pick past a refused number into the default window. A choice that takes no number (the
  summary, a rule with no window, a report with no number filter) refuses a sentence that gives one, never drops it ("firewall
  off for over 30 days"; the coordinating session, 2026-11-27), and ignores a bare number ("Activation Lock on macOS 15").
- **The group** (the coordinating session's decisions, 2026-11-25 and 2026-11-27): a sentence that shares no word naming one
  group is every group, decided by code with no call. A word names a group when it is in any of the report's group labels, isn't
  a word of the report's own label, and isn't general (status, coverage, data, type, each read through `WordRule.words`, which
  makes "status" "statu"): "show MDM migration status", "service health status" and "devices out of AppleCare coverage" ask
  for every group; "past due" opens the pick. The pick lists "all" first, then plain labels ("user lock", "requested", "no
  coverage record", ...; `ModelPicker.groupLabels`, one per group, a test holds it), and code maps the answer back to the
  catalog's token (round 3, 2026-11-27: a word in two labels counts, as "all" leads the list).
- **Size**: each pick's largest call (a 300-character sentence, a fault line, the full list) counted with `tokenCount` on the
  operator's Mac: 379, 1,018 and 457 tokens with the cap, under 1,500 of an 8,192 context. The fast run holds an estimate
  (characters / 3 plus the cap) to the same budget.
- **Dev score** (flagged runs on the operator's Mac, 2026-11-25; `WordRule` beside it 108 of 188, 30 of 81, 24 of 24):
  - first run: report 134 of 188, group 35 of 81, refusal 22 of 24; mean 1.45 s a sentence, at most 2.59 s. The group pick
    leaned to the first group listed when the sentence named none (`lock:USER`, `status:REQUESTED`, `healthy`; 13 times).
  - after the number refusals and the group decision: report 122, group 41, refusal 22; mean 1.34 s, at most 2.68 s. 16 dev
    sentences are now refused for their numbers ("this year", "a month", "in two weeks", a window other than the rule's), which
    is most of the report drop; the group pre-check also sends a few named groups to every group where the sentence's word
    isn't the label's ("request" against "requested").
  - after the second round (ranges, abbreviations, a choice that takes no number refusing one, the stricter group gate, "all"
    first; 2026-11-27): report 122, group 38, refusal 22; mean 1.33 s, at most 2.83 s; 17 sentences refused for numbers. Group
    fell 3 as the gate now sends "past the deadline" and other shared words to every group.
  - after round 3 (the stoplist read as the sentence is, a bare number refused where a number is taken, a word in two group
    labels counting): report 122, group 39, refusal 22; mean 1.30 s, at most 2.61 s; 17 refused for numbers.
  - In all runs, 3 or 4 guardrail stops and 7 of the model's own refusals in 212 sentences (each "not understood"). Held out is a
    later step's single run.
- Gotcha: the stub (`StubModel`) throws a required field left out as `GeneratedContent.ParsingError` (what SwiftGamGui saw) and
  fails a test that scripts a value guided generation can't write; `.unchecked` replies test code's own defence. Whether the SDK
  throws a dropped field or returns content without it (code's `.noPick` fault, asked about once) isn't settled: both paths are
  tested, and the next flagged run should count which one occurs.

## Invariants & failure history

## Gotchas / stub-lies traps

## Testing / live-verification status

## To do common tasks here

## Waiting for a live read

`Packages/AbapitApp/Sources/AppModels/LiveWait.swift`, tests `AppModelsTests/LiveWaitTests.swift`.
The operator decided on 2026-11-24 ("Yes, bounded (Recommended)") that an intent may start the screen's own live read, never a
sweep, and wait up to a time limit, and that a read under 15 minutes old is reused with its age said.

- `LiveWait.lists(_:bound:fresh:)` over Apple's device list, Apple's services with each service's device list, and the Mosyle
  org's devices. A wanted list that is idle, stopped on an error (a 403 included), older than `fresh` (15 minutes), or stamped
  after now (the clock was set back) is read again: the Devices model's own `load(force: true)`, or the Mosyle model's device list
  alone (`reloadDevices`: its other lists, the selection and a group's members stay). Each model is read at most once per request:
  a read that fails is said, not tried again. A read under way is never restarted, even when a list the Devices model already
  ended would need reading on its own: the request waits on that read, so two requests, or a request and a screen, share one.
- The wait watches the models' observable states (`Observations`), raced against the injected clock's `bound` (25 seconds, until
  the operator's live check of Siri's and Shortcuts' own time limit). A cancel or the bound ends the wait, never the read: it
  lands on the screens.
- Each list ends `.whole(at:)`, `.partly(why, at:)` (the page cap, "showing N of ≥M", or a failure after rows), `.notRead(why)`
  (on Apple's lists a 403 is "your role can't read …"; Mosyle's model words every error, a refusal included, as a failure, since
  its refusal may be the token's address limit; a failure; can't be read here; no Mosyle org, when Mosyle is asked nothing) or
  `.stillReading(after:)`. Each end is kept the moment the wait sees its list end, so a Refresh after it never changes what is
  said; a list is still reading only when the bound passed. The words are the screens' own (`ReportsModel.liveDevices`/`liveServices`, the Needs-attention
  screen's for Mosyle); the services' part read is counted ("the device lists of 2 of 5 services weren't read whole"), never
  named. A request ends `.cancelled`, or
  `.switched` when the org generation changed: then nothing of either client is answered.
- Tests: the strict stubs with the test target's `Gate` (an Apple page held) and `MosyleStub.holdRequests` (a Mosyle page held),
  the bound on a manual timer, and the Apple clients' retry wait on the same timer for a 429 whose `Retry-After` outlasts the
  bound. Every test checks that only the lists' own paths were asked: never a device's own path.
- Gotcha: `.whole` says every page was read, nothing about fields. Mosyle may have refused columns (the column fallback,
  `MosyleModel.columns`) and Apple may have left attributes out (`DevicesModel.servicesAbsent`, a field list it refused). An
  answer that counts or shows such a field checks it was sent before it says anything of it.
- Gotcha: a `.notRead` or `.partly` reason that comes from an error is the screen's words, which may quote Apple's `detail` or
  Mosyle's own text verbatim. Never speak or show it as it is in an intent's answer: say the list wasn't read, and leave the
  quoted words to the app's screen.
- Gotcha: a model's read can end one list before the other (the Devices model ends its services after the devices, or the
  reverse). A request that wants only the ended list doesn't wait for the other, and the next request shares that read until it
  ends.

## Answers

`Packages/AbapitApp/Sources/AppModels/Answers.swift` (held by `ScreenModels.answers`), tests `AppModelsTests/AnswersTests.swift`.
One function per question, each returning code's words, for every later intent and the in-app Ask (the operator, 2026-11-24: Q1
"Six reports + more", Q4 "Yes, bounded", Q5 "Counts aloud, 10 rows", Q6 "Active client, named").

- `answer(report:tokens:)`: a token that doesn't resolve reads nothing. A snapshot report (coverage, out of warranty, Activation
  Lock, and fleet age when a snapshot read AppleCare) awaits the Reports screen's history read (`ReportsModel.loadHistory`, `load`
  without its live read); a live one (migration, service health, fleet age without AppleCare) waits on `LiveWait`; then
  `ReportsModel.build`, the screen's one function. An answer's history read replaced by the screen's own waits for that one,
  bounded, and the screen's live read is never lost to an answer's (`liveWanted`: whichever read of the history wins asks for it).
  `attention()`: `LiveWait` over all three lists, the Needs-attention screen's history read (`loadHistory`), the lists checked
  as the wait saw them, then the screen's own `evaluate`, so findings are recorded as the screen records them, only for a rule
  judged whole, and never over a list said not counted. It says the oldest snapshot its rules used, with its age.
  `lookUp(serial:)`: Find over the awaited device list (serial, IMEI, MEID, EID, order number, MAC), said as an exact match or
  as part of an identifier; the identifier is never said back.
- Each returns `Answer { lead, spoken, rows, capNote, estimateNote }`. `spoken`: a snapshot report's "judges nothing" as the
  screen says it; else the data's date and age, how much was read, the report's own count lines after its read line, values
  this version doesn't know counted, never said (Apple's raw value stays on the screen and in the rows), "N estimated from the order date" for out of warranty (the assumption in `estimateNote`).
  Rows: serial, model, state, at most 10, the cap said; service health shows none, as services are known by name.
- **An error is a fixed phrase per kind** (`Answers.Phrase`), never the reason's text, which can quote Apple's `detail`, Mosyle's
  own words, a snapshot's code or note, or the history's message: your role can't read; read in part (with counts, never why in
  the API's words); failed ("abapit says why"); not in scope; can't be read for this organization; no Mosyle org; still being
  read after the bound; the active organization changed; cancelled. A snapshot report whose history failed, or whose newest
  snapshot read none of the sweep, says a fixed phrase in place of the screen's words.
- **Never more than was read**: a list still being read, refused or failed counts nothing. After the wait each list's end is
  asked again (`LiveWait.end(of:seen:)`), and a list still being read at the bound must still be under way: a list changed
  since (a Refresh, or a read that ended after the bound) answers nothing, so no count or finding is over another read. A
  field the API didn't send is said (the services' default fields, Mosyle's refused columns, a device's model or status).
- **Clients**: with two or more, the client's name leads `lead` and `spoken`; with one, nothing says "client" (the Mosyle org's
  Needs-attention words drop it). A Mosyle org active says the Reports and Needs-attention screens' words; serial lookup says it
  reads Apple's list (the executor's words). A School org answers as its screens do.
- Gotcha: a snapshot report never waits on Apple, so it has no still-being-read words; a switch during its history read answers
  nothing.

## Intents

`App/Intents/{ReportIntents,AttentionIntent,LookUpIntent,Snippets,Shortcuts}.swift`, `App/AppShortcuts.xcstrings`. The intents
reach `Answers` alone, through `AppServices.registerIntents` (`AppDependencyManager`, as SwiftGamGui's `SiriIntents.register`):
never the screen models whole, through which the snapshot collector, the history transfer, Dismiss and Snooze and a switch of client
write (a fix from the review of PR 52). `Answers` keeps the models it reads private. The operator's answers they rest on: Q1 "Six
reports + more", Q2 "Out for now" (no Spotlight, no `IndexedEntity`), Q4 "Yes, bounded", Q5 "Counts aloud, 10 rows", Q6 "Active
client, named" (2026-11-24), and "Don't record (Recommended)" (2026-11-25, below).

- **Nine read-only intents**: `RunReportIntent(report:group:number:)` for Shortcuts (a `ReportChoice`, the catalog's six titles;
  the number goes to the report's own number filter, `Answers.tokens`), `NeedsAttentionIntent`, `LookUpSerialIntent(serial:)`,
  and one intent per report with no parameter (`OutOfWarrantyIntent`, `CoverageEndingIntent`, `FleetAgeIntent`,
  `ActivationLockIntent`, `MigrationIntent`, `ServiceHealthIntent`) for Siri. Each `perform` calls `Answers` and nothing else.
- **Each declares `.background`** (`supportedModes`) **and `authenticationPolicy = .requiresLocalDeviceAuthentication`**. Neither
  is verified on a Mac. A cold launch still runs `AbapitApp`, whose `WindowGroup` may open a window, and the app quits when its last
  window closes (`applicationShouldTerminateAfterLastWindowClosed`). Whether a window opens, what the authentication policy does,
  and whether the Keychain key's Touch ID prompt shows from Siri are the operator's live checks.
- **What is said is `Answers`' words**: the dialog and the returned value (what Shortcuts passes on) are `Answer.spoken`; the
  snippet (`AnswerSnippet`) shows the lead, the rows (serial, model, state; at most 10), which devices they are (`rowsNote`), the
  cap and any estimate. With no group asked, the rows are the devices the question is about: out of warranty's without active
  coverage, Activation Lock's locked ones, migration's past the deadline without success; coverage lists those ending and fleet age
  its refresh candidates (a fix from the review of PR 52: ten ACTIVE rows had hidden the one out of warranty). The counts are spoken
  whole.
- **Needs attention from an intent records nothing** (the operator, 2026-11-25: "Don't record (Recommended)"): it is judged and
  said, with no `seen`, no first-seen date and no ageing, by `NeedsAttentionModel.judge()`, which reads what is kept (a dismissed or
  snoozed finding isn't counted open) and leaves the screen's evaluation alone. Only the screen records. What the rules read is
  checked again after the judgement; changed, nothing is answered.
- **Phrases**: one per report, "What needs attention in abapit", "Look up a serial number in abapit" and "Run the <report>
  report in abapit"; each names the app (`\(.applicationName)`) and is in the catalog, which the build ships as
  `en.lproj/AppShortcuts.strings` (SwiftGamGui failure-log 2026-10-10). Change a phrase in both places.
- **Checks**: `scripts/check_app.sh` reads every `extract.actionsdata` in the bundle (exactly these nine intents, each background
  only with the local authentication policy set in code and never opening the app; every phrase names the app and is in the built
  catalog; no app entity, query or indexed type; no Spotlight index imported). SourceScanTests' `IntentTests` hold the source:
  `App/Intents`, `Assist` and `Answers.swift` never name the write path (`noIntentReachesAWrite`); the intents import only
  AppIntents, SwiftUI, AppModels and Foundation, never name a screen model, and depend on `Answers` alone; the one dialog is
  `answer.spoken`; the report choices are the catalog's titles. `scripts/intents_test.sh` (CI only) registers the Release build and
  reads the nine definitions and their parameters from outside the app with `AppIntentsTesting`. Running an intent there (the
  no-key answer) ended "transport cancelled" on the runner, so it isn't run; the authentication policy is a likely cause,
  unconfirmed.
- Gotcha: a serial dictated to Siri goes through Siri's speech recognition, which may not run on the Mac (D7 keeps models on
  device; Siri's dictation is Apple's, outside this app). Typed into Shortcuts, it stays on the Mac.
- Gotcha: an App Shortcut can't preset a parameter (`AppShortcut(intent: RunReportIntent(report: .outOfWarranty), …)` builds,
  but the metadata keeps only the intent's name, so Siri would ask which report). Hence one intent per report.
- Screenshot: `snippet-out-of-warranty` (`ABAPIT_SNIPPET`, debug builds) draws the dialog's words and the snippet over the demo
  org; Siri's own frame isn't drawn.
