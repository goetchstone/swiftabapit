# Failure log

Institutional memory of what broke and why, so the same shape can't recur silently. Read the recent
entries before working in a domain that has prior ones. Every incident that reaches a user (a broken
test caught late, a live tenant break, a regression, a real review finding) gets an entry via the
`post-failure` skill.

**One file per incident**: `YYYY-MM-DD-<slug>.md`, opening `# YYYY-MM-DD — <title>`. Newest first:
`ls -r docs/failure-log/`. Cite an entry by its date and title.

**Format**, five fields:

- **Symptom** — what was actually observed.
- **Cause** — the line or assumption that did it.
- **Why not caught** — the test, validation or gate gap.
- **Fix** — what shipped (link the commit or PR).
- **Prevention** — the tripwire test, hook, skill or CLAUDE.md rule it fed ("nothing yet" is a valid,
  and telling, answer).

This repo inherits the defining failure class of abapit and SwiftGamGui, **"the mock passed, the live
tenant broke"**. A fix whose only proof is a greener stub is not proven; say so in the Prevention
field.

These entries from SwiftGamGui's `docs/failure-log/` apply here; read each before the phase that touches
its area (plan §1.2):

- 2026-10-10 display name ignored (the display name must match the bundle name)
- 2026-10-10 person-page layout loop (inspector plus split view in a narrow window)
- 2026-10-10 Siri phrases never trained (`AppShortcuts.xcstrings`)
- 2026-10-10 table saved its own widths (persist hidden columns only)
- 2026-10-12 duplicate-create mock lie (a mock failure invented from convention)
- 2026-10-13 calendar subscribe, two mocks (parallel branches bent a shared mock)
- 2026-10-13 offboarding mock lies; Gmail-off hid a person's groups (load each panel as its own `Result`)
- 2026-10-16 timing test read a busy runner (measure time bounds with thread CPU time)

<!-- No entries yet. -->
