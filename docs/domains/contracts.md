# Domain: contracts

**One line:** Apple publishes no OpenAPI spec, so `scripts/apple_contracts.py` turns Apple's DocC JSON
into `Contracts/apple/*.json`, and every model, stub and client is checked against it (plan §3.10;
invariant 10).

**Owns invariant(s):** #10 (forward-compatible decoding), and the "stub lies" rule's source of truth.

**Enforcement home:** `ContractManifestTests` (Phase 0: counts, shapes, examples parse); per-model contract
tests (Phases 1–2); the weekly `Contracts drift` workflow (an issue with the diff).

## Files

- `scripts/apple_contracts.py` — the crawler. Standard library only; fetches only `developer.apple.com`
  over HTTPS; every page is data (JSON-parsed, capped at 4 MiB, at most 1,500 pages per root).
- `Contracts/apple/business-2.6.json`, `school-1.7.json` — endpoints (method, path, parameters with
  `allowedValues`/`maximum`, body, status codes, which examples exist), objects (properties) and enums
  (possible values). Sorted, no timestamps: a re-run that finds nothing new changes nothing.
- `Tests/Fixtures/docc/<scope>/<slug>.{request,response}.json` — every JSON example Apple wrote.
- `Contracts/mosyle/operations.json` — hand-written in Phase 7 from the plan's Appendix C, a source per row.
- `scripts/device_management_schemas.py` and `Contracts/device-management/profiles-27.0.json`: every MDM profile
  payload in apple/device-management at the pinned `09f249a0` (Release-v27.0). That is 127 payload types and 2,321
  keys, each with its path, type, value type and presence, and each payload's supported OS.
  - How it's fetched: HTTPS from `api.github.com` (the tree, once) and `raw.githubusercontent.com` (each file at
    the commit), with no redirect followed.
  - How it's checked: each file's bytes against the tree's git blob hash, then `yaml.safe_load`. Each file's SHA-256,
    a SHA-256 over all of them and Apple's MIT licence are in the output.
  - PyYAML runs only in a dev venv. The output is committed, so CI never runs the script.
  - Read since 2026-11-03 by `ProfileSchemaContractTests`, which holds `ProfileText`'s masking to it. Phase 5 adds
    the custom-setting validation the plan names.
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

## Gotchas / stub-lies traps

- Apple's own enum lists are incomplete (`AuditEventCategory`, `AuditEventSubjectType`, plan §3.3): an
  enum's contract test allows the documented gaps, listed in the test, never silently.
- Apple's Create-a-Configuration example sends `com.apple.airplay.security` with `PLATFORM_IOS`, which the
  device-management schema marks tvOS-only (plan §2.1): examples are inputs, not truths.
- Some list endpoints have no example (`GET /v1/auditEvents`, `/v1/blueprints`, `/v1/configurations`,
  `/v1/mdmDevices`): their decode tests use recorded, scrubbed responses (Phase 2).

## To do common tasks here

- Regenerate the profile schemas, which changes nothing at the same pin:
  `<a venv with PyYAML>/bin/python -I -B scripts/device_management_schemas.py --out Contracts/device-management`.
  To move the pin (the release branch is at Release-v27.2, 2026-10-27, one profile schema changed), set `COMMIT`,
  `RELEASE` and `VERSION`, then update `theContractIsThePinnedRelease`, the plan's Appendix E row and this file. It's
  the operator's decision.
- Regenerate: `python3 -I -B scripts/apple_contracts.py --out Contracts/apple --examples Tests/Fixtures/docc`,
  then `scripts/test.sh`. A version bump renames the file; update `ContractManifestTests`' arguments and
  the plan.
