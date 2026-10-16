---
name: pre-commit
description: The checklist before a `git commit` in swiftabapit — catches the failure classes abapit and SwiftGamGui kept hitting (the stub lying, a write slipping the chokepoint, a secret reaching a log or CSV, parity drifting from abapit, invisible characters). The local pre-commit hook injects the items relevant to your changed files.
---

# Pre-commit checklist

Act on the items your diff touches.

## Always
1. **Green**: `scripts/test.sh`, and the app builds
   (`xcodebuild -project SwiftAbapit.xcodeproj -scheme abapit -derivedDataPath build/DerivedData.noindex build`).
   Swift 6 strict-concurrency warnings are errors in spirit: fix them, don't silence them.
2. **Read before you wrote.** Verify claims against the code, the SDK's `.swiftinterface` and
   `Contracts/apple/*.json` — not memory.
3. **Hygiene**: `python3 -I scripts/check_text.py` (no invisible or bidirectional characters: an editing
   tool once decoded `\u200b` into the character itself) and `.claude/hooks/private-terms-check.sh`.
4. **Docs follow code in the same commit**: the area's runbook; a failure-log entry for a regression
   (the hook blocks a `fix:` commit without one); the plan's phase Status for a closed item.

## If your diff touches an API client, a model or a stub
5. **The contract first (#10)**: every endpoint, parameter and enum value you use is in
   `Contracts/apple/*.json` (Apple) or `Contracts/mosyle/operations.json` (Mosyle, with its source).
   Unknown keys are ignored; unknown enum values survive as `.unknown(raw)`.
6. **The stub lies (#5)**: `AppleStub`/`MosyleStub` must fail the way the API fails — status, error
   body (`ErrorResponse`, Mosyle's envelope-in-200), headers. A failure mode comes from the contract or
   a recording, never from convention (SwiftGamGui failure-log 2026-10-12).
7. **Parity (#6)**: a ported behaviour is held to `Tests/Fixtures/parity/`; never regenerate a golden to
   make Swift pass. Compare bytes (`Array($0.utf8)`), never `String ==` (canonical equivalence hides
   the difference). A deliberate deviation is recorded in the golden's `abapit` field and listed.
8. **Regenerated a fixture?** Regenerate it again after an unrelated edit to the generator and check
   nothing moved (SwiftGamGui RULE-FEEDBACK 2026-10-08, seeded data that still moved).

## If your diff touches secrets, writes, models, Siri or anything streamed
9. **One write path (#1)**: a write runs only from a held preview through the `Executor`; nothing but
   the `Executor` names `WriteTicket`; the held bytes are what's sent. One test per invariant the
   executor enforces (SwiftGamGui RULE-FEEDBACK 2026-10-09).
10. **Secrets (#3, #11)**: Keychain only; no secret, token, assertion, password or `activation_bypass*`
    value in a log line, an audit record, a CSV, a fixture, a screenshot or an error message.
    `os.Logger` interpolations are `.private` unless provably not sensitive.
11. **Drafts only (#9)**: a model or intent fills a draft the operator previews; the never-list can't be
    drafted.
12. **Bounded (#7)** and **never silent (#8)**: caps hold, and the UI says when they bite.

## If your diff touches a screen (`App/`)
- **Accessible as built**: every control has a label and a unique identifier; a status is said in
  words, not only colour; system text styles; keyboard reachable (⌘R refreshes); a tooltip never holds
  the only explanation. Say in the PR what was checked.
- **Screenshots as we go**: CI renders each screen (`scripts/screenshots.sh`); a PR that changes one
  refreshes its image in `docs/screenshots` from that run's artifact.
- **Fits the smallest window**: a new column, panel or inspector gets bounds in `ColumnWidths` and a
  `narrow-*` run. On macOS 27 an inspector that can't fit crashes on a Mac and only clips on CI
  (SwiftGamGui failure-log 2026-10-10).
- **Never launch the app on the operator's screen** to look at it: CI's snapshot run, or a headless spike.

## Before the PR
13. **One adversarial review agent** reads the diff (the `abapit-write-reviewer` agent for the write
    path, Vault, signing or hosts; `/code-review high` plus `/security-review` otherwise for anything
    parsing API or operator input). Fix each real finding with a test. A finding an invariant should
    have stopped → one RULE-FEEDBACK entry.
14. **Mutants**: for ported behaviour, mutate the code by hand and record the mutants the tests killed
    in the PR description.
15. **Publish as goetchstone**: `GH_TOKEN="$(gh auth token --user goetchstone)"`, after
    `gh api user --jq .login` says `goetchstone`. Don't stack on a branch `--delete-branch` will remove.
