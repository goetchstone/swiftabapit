# Domain: contracts

**One line:** Apple publishes no OpenAPI spec, so `scripts/apple_contracts.py` turns Apple's DocC JSON
into `Contracts/apple/*.json`, and every model, stub and client is checked against it (plan §3.10;
invariant 10).

**Owns invariant(s):** #10 (forward-compatible decoding), and the "stub lies" rule's source of truth.

**Enforcement home:** `ContractManifestTests` (Phase 0: counts, shapes, examples parse); per-model contract
tests (Phases 1–2); the weekly `Contracts drift` workflow (an issue with the diff), for Apple's DocC only.

## Files

- `scripts/apple_contracts.py` — the crawler. Standard library only; fetches only `developer.apple.com`
  over HTTPS; every page is data (JSON-parsed, capped at 4 MiB, at most 1,500 pages per root).
- `Contracts/apple/business-2.8.json`, `school-1.8.json` — endpoints (method, path, parameters with
  `allowedValues`/`maximum`, body, status codes, which examples exist), objects (properties) and enums
  (possible values). Sorted, no timestamps: a re-run that finds nothing new changes nothing.
- `Tests/Fixtures/docc/<scope>/<slug>.{request,response}.json` — every JSON example Apple wrote.
- `Contracts/mosyle/operations.json` — hand-written in Phase 7 from the plan's Appendix C, a source per row.
- `scripts/device_management_schemas.py` and `Contracts/device-management/profiles-27.0.json`: every MDM profile
  payload in apple/device-management at the pinned `09f249a0` (Release-v27.0). That is 127 payload files (121 payload
  types: `com.apple.MCX` is split over six files, `com.apple.extensiblesso` over two) and 2,321 keys, each with its
  path, type, value type and presence, and each payload's supported OS. `describedAsSecret` marks the 45 keys whose
  description is a secret's (the script's `SECRET`; never a flag); the descriptions themselves aren't stored.
  - How it's fetched: HTTPS from `api.github.com` (the tree, once) and `raw.githubusercontent.com` (each file at
    the commit), with no redirect followed.
  - How it's checked: each file's bytes against the tree's git blob hash, then `yaml.safe_load`. Each file's SHA-256,
    a SHA-256 over their sorted SHA-256s (one per line, so it is recomputable from the output alone), the PyYAML version
    and Apple's MIT licence are in the output. Files are in path order and keys in the YAML's own, so two runs at the
    same pin write the same bytes (checked 2026-11-03).
  - PyYAML runs only in a dev venv. The output is committed, so CI never runs the script.
  - Read since 2026-11-03 by `ProfileSchemaContractTests`, which holds `ProfileText`'s masking to it: every payload
    written with each key in its real nesting, the values masked exactly its `secrets`, `overMasked` and data keys, each
    `describedAsSecret` key on `secrets` or `notSecret`, and the counts and SHA-256 recomputed from the payloads. The
    detail is in [apple-reads.md](apple-reads.md) ("What `ProfileText` masks"). Phase 5 adds the custom-setting
    validation the plan names.
  - No drift job watches it: `contracts-drift.yml` crawls Apple's DocC, not this repository. The pin is the operator's
    decision; the release branch is at Release-v27.2 (2026-10-27, one profile schema changed: the SSO payload gains
    `AlwaysUseLoginUI` and an `AdditionalHTTPHeaders` dictionary, whose values the header rule masks).
- `.github/workflows/contracts-drift.yml` — weekly, opens one issue at a time.

## How it works

The crawler starts at `/documentation/applebusinessapi` and `/documentation/appleschoolmanagerapi`,
follows every `references` URL under the same root, and classifies each page by its
`primaryContentSections`: a `restEndpoint` is an endpoint, `properties` an object, `possibleValues` an
enum. Example code listings sit under Request/Response tabs; a JSON listing (or a curl `-d '…'` body) is
written as a fixture.

## First run (2026-10-16)

Business 2.6: 57 endpoints, 272 objects, 27 enums. School 1.7: 11 endpoints, 51 objects, 7 enums. 53
Business and 11 School example files. The counts match the plan's research (§8 Phase 0). The crawl takes
about two minutes.

## Business 2.8 and School 1.8 (2026-11-11, drift issue #11)

Business 2.8: 65 endpoints, 312 objects, 28 enums. School 1.8: 11 endpoints, 51 objects, 7 enums. 72 Business and 18
School example files (61 and 17 before). The crawl took two and a half minutes. What moved:

- **The device list's filters** (Business 2.7 and School 1.8, 2026-10-29): `GET orgDevices` documents `cursor` and 15
  filters: `filter[serialNumber]`, `[status]`, `[productFamily]`, `[purchaseSourceType]`, `[orderNumber]`, and
  `filter[addedToOrgDateTime]` and `filter[orderDateTime]`, each also as `[GT]`, `[GTE]`, `[LT]` and `[LTE]`. None has
  `allowedValues`: the three enum filters list their values in their descriptions ("Possible values: …"), which
  `ModelContractTests` reads, and `ProductFamily` gained `iPod` from that list. `ProductFamily` is also
  `MDMDevice.productFamily`'s type, whose values Apple documents nowhere, so `iPod` reaches it too, unchecked there;
  `ServiceProductFamily` (`MdmServerProductFamily`, a documented enum) lists `IPOD`, which backs it. A second
  device-list example (`get-org-devices.response.2.json`) is a filtered page whose next link carries the filters and
  the cursor.
- **Webhooks** (Business 2.8, 2026-11-04): eight endpoints, three reads (`GET webhooks`, `webhooks/{id}`,
  `webhooks/{id}/deliveries`) and five writes; `WebhookEventType` (4 values); the objects `Webhook`, `WebhookDelivery`
  and `WebhookEvent`. Apple's deliveries example names its event and includes none.
- **Audit values**: `AuditEventType` +3 (`WEBHOOK_CREATED`, `_UPDATED`, `_DELETED`), `AuditEventCategory` +2
  (`ACCESS_MANAGEMENT`, `WEBHOOK_ACTIVITY`), `AuditEventSubjectType` +4 (`ROLE`, `IDP`, `INVITATION`, `WEBHOOK`), and the
  webhook payload objects; `WEBHOOK_DELETED`'s payload has no object, the fifteenth with no fields.
- **Examples fixed or lost**: the device examples now say `purchaseSourceId`, as the field list always did (the one
  known gap is gone); the org unit's member list page was renamed (`get-all-user-ids-for-an-organizational-unit`) and
  lost its example. Every page's `introducedAt` moved to the version.

## Gotchas / stub-lies traps

- Apple's own enum lists are incomplete (`AuditEventCategory`, `AuditEventSubjectType`, plan §3.3): an
  enum's contract test allows the documented gaps, listed in the test, never silently.
- **A value set can live in prose.** The device filters' values are only in their descriptions, so the enums are held to
  the text ("Possible values: A, B, and C"); a rewording breaks that test before it lets a value through unseen.
- **Apple's guides aren't crawled.** The webhook payloads' shape and types come from "Understanding webhook events"
  (`/documentation/apple-school-and-business-manager-api/…`, another doc root), read through the crawler's `fetch` on
  2026-11-11 and copied into `WebhookTests` as Apple's five examples. The drift job doesn't watch it: re-read it when
  `WebhookEventType` moves.
- Apple's Create-a-Configuration example sends `com.apple.airplay.security` with `PLATFORM_IOS`, which the
  device-management schema marks tvOS-only (plan §2.1): examples are inputs, not truths.
- Some list endpoints have no example (`GET /v1/auditEvents`, `/v1/blueprints`, `/v1/configurations`,
  `/v1/mdmDevices`): their decode tests use recorded, scrubbed responses (Phase 2).

## To do common tasks here

- Regenerate the profile schemas, which changes nothing at the same pin:
  `<a venv with PyYAML>/bin/python -I -B scripts/device_management_schemas.py --out Contracts/device-management`.
  To move the pin (the operator's decision), set `COMMIT`, `RELEASE` and `VERSION`, regenerate, then update
  `ProfileSchemaContractTests` (the pin and counts in `theContractIsThePinnedRelease`, the needle count, and a list
  entry for each newly marked or newly masked key, with Apple's description read), the plan's Appendix E row and this
  file.
- Regenerate: `python3 -I -B scripts/apple_contracts.py --out Contracts/apple --examples Tests/Fixtures/docc`,
  then `scripts/test.sh`. A version bump renames the file; update `ContractManifestTests`' arguments and
  the plan.
