# 2026-11-28 — A write authenticated a session nobody timed

- **Symptom:** in a scratch copy with `MemoryStore`, `Vault.store`, then 601 s on the injected clock, then `secret`: no
  session ended (`sessionsEnded` 0, expected 1). A failed read, 601 s, then a read ended none either. A review found it.
- **Cause:** `Vault.used()` ran only after a successful read or signature. `store`, `storeKey` and `refresh` never
  started the clock, although `KeychainStore.update` and `replace` hand the Keychain the shared context; a use that
  failed after its prompt was answered did not start it either. The session a credential replace began stayed untimed
  until the next read or signature, which then ran without a prompt.
- **Why not caught:** every session test began with a read or a signature, and Phase 1a's review fixed only the reverse
  case (a use ends an expired session). `MemoryStore` has no authenticated context to outlive anything.
- **Fix:** this PR. A read, a signature, a write and a write-back start the clock when they return, whatever they
  did, except after a status that authenticated nothing (-128, -25293, -25308, -25300): a clock started by a cancelled
  prompt would let a later unanswered prompt be cut off 600 s after it. A key import passes no context and starts none.
  A write that adds a new item starts it though it never used the context (the Vault can't tell); that can end a
  session early, never late. The clock starts when a use returns, not at its start: a second use arriving 600 s after a prompt nobody has answered would
  end the session under that prompt and throw away the authentication the operator gives next.
- **Prevention:** `aWriteStartsTheSessionClock`, `aUseThatFailsAfterItsPromptStartsTheSessionClock`,
  `aUseThatAuthenticatedNothingStartsNoClock`, `aKeyImportStartsNoClock`, `aWriteBackStartsTheSessionClock`,
  `aUseStillWaitingIsNotEndedByTheNextUse` and `aCancelledPromptDoesNotCutOffALaterUnansweredOne`. The real Keychain's
  behaviour on `SecItemUpdate` is not measured: whether it prompts and authenticates the shared context is the
  operator's check (Touch ID), listed in the runbook.
