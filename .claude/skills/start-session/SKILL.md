---
name: start-session
description: Orient before feature or fix work in swiftabapit — check the tree, get a green baseline, read the plan's phase Status and the domain runbook for the area you'll touch, and scope-check the task. Use at the start of any task that will change code; skip for questions and trivial doc edits.
---

# Start-session — ORIENT

Scale it to the task: a question needs none of this; a change in `Packages/AbapitKit` needs all of it.

1. **Where is the tree?** `git log --oneline -8`, `git status`, `git worktree list`. The session-start
   hook's digest has the branch, last commit and dirty count. Another branch in flight? Work in a new
   `git worktree` (`.claude/worktrees/<slug>`), so nobody's checkout changes under them (SwiftGamGui
   RULE-FEEDBACK 2026-10-08).
2. **Is the toolchain sane?**
   - `scripts/test.sh` — a green baseline before you change anything.
   - `xcodebuild` failing to load a plug-in after an OS update means `sudo xcodebuild -runFirstLaunch`
     — the operator runs it (admin password).
3. **Read the plan's Status lines** — `docs/plans/2026-10-16-swift-port.md` §8. Never re-apply an item
   it marks done. Your phase's **Owns** list is the set of files you may touch; a shared file
   (`App/AbapitApp.swift`, `App/AppServices.swift`, `Package.swift`, `CLAUDE.md`, `README.md`) is
   serialized: rebase after the other track merges.
4. **Load the domain, not the whole map** — the [docs/domains](../../../docs/domains/README.md) runbook
   for your area, the SwiftGamGui runbook nearest to it, and the failure-log entries the plan names
   for it. Turn each prior incident into a Swift test before writing code (SwiftGamGui
   RULE-FEEDBACK 2026-10-08, "the port missed lessons already paid for").
5. **Scope check.** Research answers "what could we do"; the task keeps only what the operator asked for
   or what prevents a loss. If the phase is growing past its scope, stop and propose a split.
6. **Plan** the task as a short todo list. A real-tenant read or write needs the operator's per-action
   yes (`live-verify`). Anything needing Touch ID, an Allow dialog or a signing team goes to the
   operator.
