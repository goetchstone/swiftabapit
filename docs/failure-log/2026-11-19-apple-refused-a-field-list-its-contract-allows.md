# 2026-11-19 — Apple refused a field list its contract allows

- **Symptom:** the first acceptance pass on a real Apple Business org printed `mdmServers: error 400, 0 items ·
  PARAMETER_ERROR.INVALID fields[mdmServers]`, and so `mdmServers/{id}/relationships/devices: skipped`. The blueprint's `include`
  of all six relationships answered 400 `PARAMETER_ERROR.ILLEGAL` naming `include` (the fallback read it without members,
  and each relationship read alone succeeded); every other read and all 11 probes were ok. The Device Management Services screen and the Dashboard's service cards read from that list,
  so they had nothing.
- **Cause:** `AppleRead.services` sends `fields[mdmServers]` with ten attribute names. Every one is in the contract's
  `allowedValues` for that parameter (2.6 and 2.8), yet Apple's live server answers 400 `PARAMETER_ERROR.INVALID` for the
  list. Which value it refuses is unknown: the pass prints no `detail`, so Apple's words weren't captured. The client had
  no way to read the services without the field list.
- **Why not caught:** the stub follows the contract, and the contract allows every value, so the stub served the read.
  `ReadContractTests` compares each sent value with `allowedValues`, and each matched. Only a live read could show that
  Apple's server disagrees with Apple's contract (the class of failure-log 2026-10-16, "the stub could not fail").
- **Fix:** https://github.com/goetchstone/swiftabapit/pull/21 (branch `services-default-fields`).
  - The services list is read again once without `fields[mdmServers]` when Apple answers 400 `PARAMETER_ERROR.INVALID` for
    that parameter (Apple's default attributes, `limit` kept, only before a page was given), and the refusal is remembered
    for the client's life.
  - It is said, never silent: `Page.note` names the refusal, and `Page.absent` carries the attributes no service came back
    with, as data. The Services screen shows the note; the acceptance pass line shows it with which of the fields asked for
    Apple's `detail` names, never the `detail` itself (it may echo an identifier), and keeps it when the retry fails.
  - Review of the first version: Apple's own example of the list without `fields` has four attributes, no `status` and no
    `lastConnectedDateTime`, so every service read as "Never connected" and quiet, with no reason, and deleted services were
    no longer skipped. Now a service whose `lastConnectedDateTime` Apple didn't send reads "Not sent by Apple", isn't quiet,
    and the Overview's card says quiet services can't be judged; without `status` the card says deleted services are counted.
    A failed read keeps no partial note.
- **Prevention:**
  - `AppleStub.refuseServiceFields()`, off by default (the stub otherwise follows the contract). With it on, the read
    without `fields` answers only the example's four attributes (`Tests/Fixtures/docc/business/get-mdm-servers.response.json`),
    so the stub no longer serves a default read fuller than Apple's example, which is how the false alarm would have passed.
    The blueprint include refusal now answers `PARAMETER_ERROR.ILLEGAL`, as it did live.
  - `ServiceFieldRefusalTests` (the retry, the memory, paging, a refusal on a later page being an error, other errors left
    alone, the pass line, no `detail` in the pass, the failing retry) and `PanelTests` (the false "Never connected", deleted
    services, the partial note).
  - Still only a stub: the live answer to the read without `fields` is unverified until the next live run, and the refused
    field stays unknown until that run's `Apple named:` text is read. The apple-reads runbook records this, the blueprint
    `include` refusal and the dropped connections seen the same day.
