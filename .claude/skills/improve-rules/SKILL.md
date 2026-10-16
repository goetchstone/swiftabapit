---
name: improve-rules
description: The observer pass over accumulated evidence that proposes ONE focused edit to CLAUDE.md as a PR. Run when the session-start nudge trips, or on demand when the invariants feel stale. Never edits CLAUDE.md on main.
---

# Improve the rules

Same discipline as SwiftGamGui's and GamGUI's skill of the same name: **run with distance** (not while
an incident is warm) and **propose, don't decide** (one focused edit, as a PR).

Evidence since the last run (`.claude/.rules-last-run`): `fix:`/`revert:` commits (read each diff and
ask which invariant was in force and why it didn't hold); `docs/RULE-FEEDBACK.md` entries;
`docs/failure-log/`; tripwire and hook firings; review findings named in PR bodies.

Sort each into one: **new failure mode** (propose a new numbered invariant, citing the incident) ·
**known mode, wrong layer** (move enforcement: skill → hook → tripwire; no text change) · **known mode,
weak wording** (sharpen it) · **not a rules problem** (record, change nothing — a frequent, successful
verdict).

The bar: cite the incident; name the enforcement home; prefer strengthening an existing invariant;
never renumber or reuse a number (retire into a runbook with the number's meaning intact); one change
per PR; demonstrate it (the check that would have caught the incident fails without it). Mark the
RULE-FEEDBACK entries it settles **Resolved** with the PR link. Then stamp
`date -u +%Y-%m-%d > .claude/.rules-last-run`.
