# Domain: assist intents

**One line:** Foundation Models and App Intents only fill drafts; Spotlight indexing is off by default (plan §5).

**Owns invariant(s):** #9

**Status:** begun. Phase 9's read-only step started with the report catalog (below); the intents, the model's pick and
the answers are later PRs. Until then, read the plan section named above and the nearest SwiftGamGui runbook.

## Files

- `Packages/AbapitKit/Sources/Reports/ReportCatalog.swift`: the catalog.

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
