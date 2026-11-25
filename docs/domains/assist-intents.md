# Domain: assist intents

**One line:** Foundation Models and App Intents only fill drafts; Spotlight indexing is off by default (plan §5).

**Owns invariant(s):** #9

**Status:** begun. Phase 9's read-only step started with the report catalog (below); the intents, the model's pick and
the answers are later PRs. Until then, read the plan section named above and the nearest SwiftGamGui runbook.

## Files

- `Packages/AbapitKit/Sources/Reports/ReportCatalog.swift`: the catalog.
- `Packages/AbapitKit/Sources/Assist/{Choices,WordRule}.swift`: the run-time list and the plain rule.
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
- **The model half** runs only with `ABAPIT_MODEL_EVALS=1`, and never when `CI` or `GITHUB_ACTIONS` is set. It is a placeholder
  until the model picker exists: skipped with that reason, and failing if the flag is set, so it can't pass by doing nothing.
  CI never calls the model.

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
