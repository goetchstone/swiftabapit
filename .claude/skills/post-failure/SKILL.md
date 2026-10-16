---
name: post-failure
description: Run after any regression, broken test, real review finding, or bug caused by a change — especially "the stub passed but the live tenant broke". Document, reproduce, fix, and leave a tripwire so the same shape can't recur silently.
---

# Post-failure learning

1. **Root cause**: what broke (the exact symptom), what caused it (which line, which assumption), why it
   wasn't caught (a permissive stub, a missing test, a golden that copied abapit's defect), what would
   have prevented it. For a live break, take the status, the Apple error `code` or the Mosyle status
   from the audit record — never by re-running the write.
2. **Reproduce before fixing**: a failing Swift test, or for a live-only break a stub case that fails
   the way the real API failed (check `Contracts/apple/*.json`, `Contracts/mosyle/operations.json`, the
   recordings). It becomes the regression test.
3. **Fix**, then `scripts/test.sh`.
4. **Leave a tripwire** in the right home (docs/FRAMEWORK.md §2): a coding pattern → `pre-commit`; a
   permissive stub → tighten `AppleStub`/`MosyleStub`; a cross-cutting invariant gap → one
   `docs/RULE-FEEDBACK.md` entry (do not edit CLAUDE.md now); a domain assumption → its runbook.
5. **Log it**: a new `docs/failure-log/YYYY-MM-DD-<slug>.md` with the five fields (Symptom, Cause, Why
   not caught, Fix, Prevention). This is what clears the hook's `fix:` block, so write it before
   committing the fix.
