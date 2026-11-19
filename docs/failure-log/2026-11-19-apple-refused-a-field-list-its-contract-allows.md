# 2026-11-19 — Apple refused a field list its contract allows

- **Symptom:** the first acceptance pass on a real Apple Business org printed `mdmServers: error 400, 0 items ·
  PARAMETER_ERROR.INVALID fields[mdmServers]`, and so `mdmServers/{id}/relationships/devices: skipped`. Every other read
  and all 11 probes were ok. The Device Management Services screen and the Dashboard's service cards read from that list,
  so they had nothing.
- **Cause:** `AppleRead.services` sends `fields[mdmServers]` with ten attribute names. Every one is in the contract's
  `allowedValues` for that parameter (2.6 and 2.8), yet Apple's live server answers 400 `PARAMETER_ERROR.INVALID` for the
  list. Which value it refuses is unknown: the pass prints no `detail`, so Apple's words weren't captured. The client had
  no way to read the services without the field list.
- **Why not caught:** the stub follows the contract, and the contract allows every value, so the stub served the read.
  `ReadContractTests` compares each sent value with `allowedValues`, and each matched. Only a live read could show that
  Apple's server disagrees with Apple's contract (the class of failure-log 2026-10-16, "the stub could not fail").
- **Fix:** the services list is read again once without `fields[mdmServers]` when Apple answers 400 `PARAMETER_ERROR.INVALID`
  for that parameter (Apple's default attributes, `limit` kept), and the refusal is remembered for the client's life. It is
  said, never silent: `Page.note` names the refusal and the requested attributes no service came back with, the Services
  screen shows it, and the acceptance pass line shows it with Apple's `detail` (control characters removed, at most 200
  characters) so the next live run names the refused field. Any other error stays an error.
- **Prevention:** `AppleStub.refuseServiceFields()`, off by default (the stub otherwise follows the contract), and
  `ServiceFieldRefusalTests`: the refused read then one without `fields`, the note, the memory, paging, a refusal for any
  other parameter or code left as an error, and the pass line. Still only a stub: the live answer to the new request (a
  read without `fields`) is unverified until the next live run, and the refused field stays unknown until that run's
  `Apple said:` text is read. The apple-reads runbook records this and the blueprint `include` refusal and the dropped
  connections seen the same day.
