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
