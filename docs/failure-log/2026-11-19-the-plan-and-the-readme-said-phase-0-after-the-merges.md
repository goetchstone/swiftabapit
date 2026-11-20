# 2026-11-19 — The plan's Status lines and the README said "on branch", "next" and "Phase 0" after the merges

- **Symptom:** the plan's Status lines and the README were behind `main`. Line 3 of the plan said "Phase 0 under way";
  Phase 1 said 1a was "on branch" and 1b "next"; Phase 2b was "on branch"; build-order step 2 and Phase 7 said "built on"
  a branch; step 1 said nothing had read a real tenant. The README said "Phase 0 — scaffold. Nothing talks to Apple or
  Mosyle yet" and linked a repository that has since gone private. By then, PRs #3 to #21 had merged the work between 2026-10-16
  and 2026-11-19. SECURITY.md said "tests guard them" of invariants whose write path, audit records and model rules are
  not built, and the README described the write path and the model rules in the present tense.
- **Cause:** each Status text was written while its branch was open, and the README's sentence in Phase 0; nothing sent
  anyone back to them after the merge. The live checks of 2026-11-19 moved the facts again.
- **Why not caught:** `end-of-session` item 4 asks for the Status line, not for what it says once the PR merges, and no
  check reads the plan or the README against what `main` holds. `CLAUDE.md` tells every session to read these lines first,
  so a session read Phase 1b as "next".
- **Fix:** https://github.com/goetchstone/swiftabapit/pull/23 (branch `docs-truth`) rewrote the Status lines, the README's status and SECURITY.md's wording to say what is built, what is
  planned and what was verified live, and records the 2026-11-19 spike results in `docs/domains/auth-keychain.md`.
- **Prevention:** nothing mechanical yet; no check compares a Status line with the merged pull requests. The split
  phases' Status lines now lead with the merged state, so the session-start digest's first 110 characters show it.
