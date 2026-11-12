# 2026-11-12 — A stale customer answer became a different customer, and a separated client kept the other org's name

- **Symptom:** the adversarial review of `add-to-client` (PR 19, at 6d289ea) found two medium findings, five lows and
  four surviving mutants.
  - **M1:** an add sheet sent its answer only while the question still offered it. Two sheets can be open at once (the
    Settings window and the main window's Settings). When the client a sheet's answer named was filled by the other sheet,
    the question disappeared, Add stayed enabled, the answer was sent as none, and the org became a client of its own: the
    opposite of "the same customer", with nothing said. During the Keychain write the same race was refused instead, so
    the outcome hung on timing.
  - **M2:** Separate, or removing a client's org, left the client that stayed named after the org that left. After
    separating an Apple org from its Mosyle org, the Mosyle org's exports and switcher entry carried the Apple org's name,
    which the operator had just said was another customer.
  - **The lows:** the Apple editor's Cancel stayed enabled while a save that can now be refused after the key is stored
    ran; the Apple Add's two answer checks and both "no bump" cases had no test (mutants A3, A4, A8, A9); answers are keyed
    by client ids, which a removed client's name can give again; two doc sentences overstated (the Keychain, "at once").
- **Cause:** M1 put a decision in the view: "an answer the question no longer offers is no answer" was a filter in two
  sheets, untested, where the model would have refused it. M2: client names were set once, when a client was made, and
  nothing renamed a client when the org it was named after left.
- **Why not caught:** the race tests held the model (`aClientFilledMeanwhile…`), not what the sheet sent; the views have no
  tests. The removal test pinned the old name as expected.
- **Fix:** branch `add-to-client`, `fix(clients): …` after 6d289ea.
  - The sheets send the answer as chosen. `clientQuestion(adding:answer:)` keeps the question open for an answer whose
    client was filled or removed, with a note and the answers left, and Add waits; the model refuses a stale answer.
  - A client an org leaves, by a move or a removal, takes the staying org's name when it was named after the leaving one
    (a name the operator gave is kept), before the leaving org's new client is made.
  - The Apple editor can't be cancelled or dismissed while it saves; neither can the Mosyle editor be dismissed.
  - Tests for each, and for the four surviving mutants; the docs say what the code does.
  - Not fixed: client ids can be given again after a removal (contrived, said in the PR).
- **Prevention:** what the operator chose is sent as chosen, and only the model decides it no longer holds, where a test can
  see it; a view never turns one answer into another.
