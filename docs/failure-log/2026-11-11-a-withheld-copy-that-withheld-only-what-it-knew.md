# 2026-11-11 — A withheld copy that withheld only the fields it knew, and a masked URL that hid the change it was masked to show

- **Symptom:** the adversarial review of `contract-2.8` (79c32ce, Business 2.8's webhook reads) found:
  - M1: `WebhookDelivery`'s withheld copy, the one its `description`, `dump` and mirror print, withheld `request` and
    `response` only. An attribute Apple adds (`requestHeaders`, a signature) and a token quoted in `errorMessage`
    (`Couldn't reach https://hooks.example.com/T0/<token>`) went out as Apple sent them; `Webhook`, beside it, withheld every
    attribute it didn't read. The runbook said both withheld "the rest".
  - M2: an audit event's `subjectName` and `actorName` went raw to the Activity screen and its CSV, while the payload's
    `url` beside them was masked, and a test pinned a `WEBHOOK_UPDATED` subject holding a URL as raw.
  - M4: the URL mask showed scheme, host and port, so two webhooks on one shared receiver, or one webhook repointed
    from one path to another on it, looked the same: the audit event that records the repoint showed nothing changed.
  - L1: the audit payload mask read one level of a payload, and only keys named for a URL: a URL one level down, under
    another key or inside a payload sent as JSON text, and a value under a key named for a secret, showed raw.
  - M3: the plan's unattended read-only key (§3.4.4) and Phase 4's write probes listed no webhook write, though a key
    that can create a webhook can stream every device change to any URL.
  - Lows: an event included twice was matched to the first copy (L2); keys beside a wrapped payload's `data` went
    uncounted (L3); `.webhooksNotInScope` read as "failed" on a screen (L4); the pass's deliveries line had no test of
    its day or its paging (L5, mutants P1 and P3 survived); a device filter took any number of serials (L6); the stub's
    per-page include and the next link's cursor were untested (mutants S5 and C5 survived).
- **Cause:** two shapes. The delivery's withholding was written as a list of what to hide (`request`, `response`), not
  of what to show, so every key Apple adds was shown: RULE-FEEDBACK 2026-11-03's lesson ("the parts kept are listed")
  applied to the URL and not to the object around it, and the webhook's `withholding` beside it already did it right.
  The audit mask was the same shape one level up: it hid what it knew to be a URL, under a key that said so, where the
  inspector shows everything. And the URL mask was designed only to hide: no one asked what the reader needs to see in
  what is left, so the mask removed the one difference (the path) an access review of a webhook change is for.
- **Why not caught:** the canary tests put each canary where the code was known to read it (`request.headers`,
  `response.body`, a `url` key), so they tested the denylist against itself; no canary sat in an attribute or a key the
  code had never heard of, which is where an API's additions go. No test asked whether two masked values could still be
  told apart. The webhook writes were out of the phase's scope, so no one re-read §3.4.4's write categories when the
  contract grew five new writes.
- **Fix:** commits `fix(2.8): …` on `contract-2.8`.
  - M1: `WebhookDelivery.withholding` withholds every attribute it doesn't read, key kept, and masks every URL in
    `errorMessage` (`WebhookURL.maskingURLs`), a non-string message withheld whole; `asSent` keeps it raw.
  - M2: `subjectName` and `actorName` have every URL masked, for every event, so the row, the inspector and the CSV show
    the destination and tag; the pinned assertion is flipped.
  - M4: every masked URL shows as `https://hooks.example.com/… (tag a1b2c3d4)`: 8 hex digits of HMAC-SHA256 under a key
    made at random once per process, in memory only; tags compare only within one run. The HMAC is written out
    (`TagHash`, AppleModels being pure) and held to FIPS 180-4, RFC 4231 and CryptoKit.
  - L1: the audit mask walks every object and list of every attribute but the common ones, masks a URL in any string
    under any key, withholds a value under a key holding one of `ExportPolicy.sensitiveStems` (mirrored, held equal), reads
    JSON text and walks it, and withholds whole past 32 levels.
  - M3: §3.4.4 and Phase 4's probes name the webhook writes; L2 to L6, C5 and S5 each have their test; the runbook's
    check-live list has the questions the review raised.
- **Prevention:** each fix has a test shown failing on 79c32ce's behaviour by a mutant that restores it, and the
  reviewer's survivors were re-run (results in the branch's PR description). The rule for a view that hands out a copy
  of what Apple sent: list what it shows and withhold the rest, at every level, and put a canary in a key the code has
  never heard of. For a mask: say what the reader must still be able to tell apart, and test that two different
  secrets mask differently. A generated canary test covers the in-text URL mask's grammar
  (`aGeneratedURLNeverSurvivesTheMask`), as RULE-FEEDBACK 2026-11-03 asked of such parsers. Still not caught: a URL with no
  scheme and no `//`, a URL in a key's name, and a token in a host name.
