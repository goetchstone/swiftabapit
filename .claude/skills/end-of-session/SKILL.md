---
name: end-of-session
description: The wrap-up routine at the end of a swiftabapit session — capture what was learned where the next session will find it. Deliberately does NOT edit CLAUDE.md.
---

# End-of-session — capture

1. **Incident this session?** → a failure-log entry via `post-failure`.
2. **An invariant strained?** → one `docs/RULE-FEEDBACK.md` entry. Don't edit CLAUDE.md;
   `improve-rules` decides later.
3. **A domain behaved differently than its runbook says?** → update the runbook.
4. **Plan progress** → the phase's **Status** line in `docs/plans/2026-10-16-swift-port.md`, and the
   README live-verification table for any write proven live, in the same change.
5. **Deferred work** → a task chip or the plan's open items; "later" in chat is not tracking. Anything
   waiting on the operator (Touch ID, a signing team, a live check, a decision) is written in the PR
   and the Status line, with the exact steps.
6. **Leftovers**: remove command-line builds outside `build/DerivedData.noindex`, stale worktrees and
   throwaway `swiftabapit-spike*` Keychain items the session created.

Commit documentation as its own atomic commit.
