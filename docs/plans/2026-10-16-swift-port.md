# Plan: port abapit to a native Swift macOS app

**Status: IN PROGRESS — Phase 0 under way in `goetchstone/swiftabapit` (2026-10-16).** Written
2026-10-16 at abapit `9875ee7` (branch `security-dependency-audit`) for agents with no session context.
Mark each phase's **Status** line as it lands. The operator's answers to §0.2 are recorded there.

This plan **supersedes** the draft `docs/plans/2026-10-08-native-mac-app.md`. That draft was never
committed; it exists only in the worktree `.claude/worktrees/youthful-ramanujan-2f615c`. Since it was
written:

- this Mac runs macOS 27.0.1 with Xcode 27.0 (27A266a) and Swift 6.4;
- SwiftGamGui (`../SwiftGamGui`, `bfdb494`) has built and live-verified the
  architecture the draft proposed;
- Apple's API moved to **Apple Business API 2.6** (2026-09-24) and **Apple School Manager API 1.7**
  (2026-09-15).

The draft's Google Workspace phases are **dropped**, because SwiftGamGui owns Workspace.

---

## How to execute this plan (read first)

1. **Read §0–§3 once.** After that, read your phase in §8 and the appendices it cites.
2. **One phase = one branch, one implementing session, one PR.** Name the branch
   `phase-<n>-<slug>`. The phase sections list the files each phase owns. Two sessions never edit
   the same files at once. §8.1 shows which phases can run in parallel and which files are
   serialized.
3. **Port behaviour test-first.** Every behaviour ported from abapit starts as a failing Swift test
   against a golden fixture generated from frozen abapit (§6.2). Then write the code. Prove the tests
   bite by mutating the code by hand and recording the mutants killed in the PR description.
4. **Review.** Before the PR, **one** adversarial review agent reads the diff. Fix each real finding
   with a test.
5. **Merge.** Merge after the single required check `ci-ok` is green.
6. **GitHub account.** Push and open PRs as **goetchstone**:
   `GH_TOKEN="$(gh auth token --user goetchstone)" gh …`. Check first that
   `gh api user --jq .login` prints `goetchstone`. Never switch the global `gh` account; the active
   one is a second account that must never appear in this repo.
7. **Stop and hand to the operator** for any of these. Write what is needed in the PR or the plan
   Status line and move on to something unblocked.
   - Anything that needs Touch ID, an Allow dialog, or a signing team in Xcode.
   - Any read or write against a live tenant.
   - Any design change to the write path (ChangeCore's executor, `WriteTicket`, Guard).
   - Any operator decision in §0.2 that is still open.
8. **Never launch the real app on the operator's screen.** Verify UI through the env-var
   screenshot harness (§6.5) or in CI.
9. **Keep it simple.** If a phase grows past its scope, stop and propose a split. Don't widen the
   phase.

---

## 0. Decisions

### 0.1 Locked (do not revisit without the operator)

| # | Decision | Why |
|---|---|---|
| L1 | Native SwiftUI app, **macOS 27.0 only**, Swift 6 language mode, Xcode 27 | macOS only; no `#available` branches |
| L2 | **No local HTTP server.** Outbound HTTPS to an allowlist only. **App Sandbox on** | Removes abapit's whole loopback/CSRF class (Host check, Origin check, `Sec-Fetch-Site`) |
| L3 | **One write path enforced by the compiler**: planner → held preview → operator confirm → Guard inside the executor → audited send of the **held bytes** | SwiftGamGui's ChangeCore, proven live; closes abapit's "confirm re-plans from the form" defect |
| L4 | **Secrets only in the Keychain** (data-protection keychain, this device only, user presence). Bearer tokens and JWTs live only in memory | abapit keeps PEMs on disk, Mosyle passwords in plaintext `config.json`, and tokens in `tokens.json` |
| L5 | **Zero third-party dependencies.** Apple first-party packages also stay out of the app (Appendix D). The only exception is dev-time scripts, whose output is committed | Supply chain; SwiftGamGui has the same rule |
| L6 | **Hand-written HTTP clients and Codable models**, checked against a **contract manifest** generated from Apple's DocC JSON (§3.10). No swift-openapi-generator | Apple publishes **no OpenAPI spec** for these APIs, and a generated client would hide the request bytes the preview must hold |
| L7 | **Snapshot history in SQLite through the system `SQLite3` module, using abapit's schema**, not SwiftData | Keeps "query it with `sqlite3`/Datasette" and lets abapit's `history.sqlite` be imported as is; SwiftData's Z-prefixed schema can't do either |
| L8 | **No separate CLI binary.** Scripting goes through App Intents and `/usr/bin/shortcuts run` | A CLI can't share the app's Keychain access group without its own provisioning. abapit's `token` and `assign --yes` are deliberately dropped |
| L9 | **Copy, don't share, SwiftGamGui code.** Adapt it into this repo's own package, with a provenance comment `// Adapted from SwiftGamGui <path> @ bfdb494` | `package` access is scoped to one SwiftPM package; a shared package would lose the compile-time chokepoint |

### 0.2 Operator decisions (answered 2026-10-16)

The operator answered on 2026-10-16: **D1** is repo **`goetchstone/swiftabapit`** (lowercase, public;
the Xcode project is `SwiftAbapit.xcodeproj`), display name "abapit", bundle ID
`io.github.goetchstone.swiftabapit`; **D2–D9: every bold default accepted**; **D10** added below. The
repo is set up like SwiftGamGui: rulesets (PR gate on `ci-ok` and CodeQL; no deletion or force-push on
`main`), the libFuzzer job, OpenSSF Scorecard, CodeQL, Dependabot (actions), secret scanning with push
protection, private vulnerability reporting, read-only workflow tokens.

| # | Question | Default |
|---|---|---|
| D1 | Repo, app name, bundle ID. Keychain items and the sandbox container bind to the bundle ID, so it's permanent | **Repo `goetchstone/SwiftAbapit`, display name "abapit", bundle ID `io.github.goetchstone.swiftabapit`** |
| D2 | A separate app, or a module inside SwiftGamGui? | **Separate app.** It can be sandboxed (SwiftGamGui runs unsandboxed and spawns the vendored GAM), it keeps the ABM-key blast radius apart from Google super-admin credentials, and it releases on its own schedule |
| D3 | Which Apple writes to build? | **Parity writes** (assign/unassign; blueprint, configuration and MDM-service CRUD; blueprint relationships) **plus** MDM migration activities and MDM-service certificate rotation. **RELEASE_DEVICES** gets built last, behind a per-org switch that is **off by default** |
| D4 | Which Mosyle device actions to build? | **iOS/iPadOS lost-device set**: lost mode on/off, play sound, request location. **Not built**: wipe, lock, restart, shutdown, Activation Lock on/off, `change_to_limbo`, anything sent to `groups[]`. macOS has no MDM Lost Mode; Macs get an explanation, not `lock_device` |
| D5 | Unattended scheduled snapshots? They need a key that can sign without Touch ID | **Opt-in.** A *second*, read-only API account per org. Its key is stored without the user-presence ACL. It's accepted only when every write probe returns 403 (§3.4.4) |
| D6 | Touch ID cadence | **One authentication per 600 s session**, as in SwiftGamGui. Phase 1's assertion-reuse check may lower prompts further (§3.4.2) |
| D7 | Private Cloud Compute for Foundation Models | **Off.** Serials, names and emails stay on the Mac |
| D8 | Throwaway targets for live verification | Operator lists them: a spare ABM device, scratch blueprint/configuration/MDM service, a Mosyle test iPhone, an ASM tenant if any. **With no ASM tenant, School stays stub-verified only** |
| D9 | abapit (Python) during the port | **Fixes only** from the start of Phase 1; archived with a pointer after Phase 10 |
| D10 | How much may the in-app AI do on its own? (added 2026-10-16: the operator wants to "use AI in this app to do things") | **Answered: drafts, plus a safe-actions list.** A model may read and draft any change for the operator's confirm. In addition, an **off-by-default, per-org safe-actions list** of single-device actions may run without the preview click: Mosyle **play sound** and **request location**, and **assigning one device** to a service (undo: assign it back). Each is read back first, audited with `origin = model`, and goes through the same `Executor` and Guard. Never on the list: release, deletes, wipes, locks, lost mode, migration, anything bulk. **Models: on-device Foundation Models only** (D7 stands: no Private Cloud Compute, no cloud model) |

---

## 1. Starting point

### 1.1 abapit today: the specification

abapit 0.2.0 is Python, FastAPI and Jinja: about 7.2k lines, 37 templates and 124 collected tests.
It is the reference for behaviour, not for structure. The full route-by-route parity checklist is
**Appendix B**. In summary:

- **Apple Business/School reads**:
  - devices, AppleCare, assigned MDM service, MDM services and their device lists;
  - Apple-MDM-enrolled devices;
  - users, user groups, org units, apps, packages, blueprints (with `include` and a fallback when
    the role can't read an include), configurations;
  - audit events, plus the Subscriptions and Device Lifecycle views derived from them.
- **Apple writes**:
  - assign/unassign through `orgDeviceActivities`, with activity tracking;
  - blueprint CRUD and add/remove on its 6 relationships;
  - configuration CRUD (`CUSTOM_SETTING`);
  - MDM-service create/rename/delete;
  - empirical capability probes (read probes, and write probes against the zero UUID).
- **Mosyle Business reads**:
  - devices, iterated per OS;
  - users, user groups, device groups;
  - Logs Stream (compliance, zero trust, admin actions, AV, DNS), drained into a local store.
- **Cross-provider**:
  - ABM↔Mosyle reconciliation;
  - Device 360, which merges ABM ownership, AppleCare and the assigned MDM with Mosyle's live state
    and a timeline;
  - Mosyle OS breakdown and stale check-ins.
- **History**:
  - SQLite snapshots with tables `snapshots` and `items`, plus views `devices_view` and
    `applecare_view`;
  - diffs between snapshots;
  - coverage and fleet-age reports;
  - warm start from the latest snapshot behind a visible "stale" banner.
- **Exports**: CSV everywhere, guarded against formula injection.
- **Settings**: multiple orgs, add/edit/test/probe/delete, and a demo org (84 fake devices,
  seed 42).

The pure modules port almost line for line: `assign.py`, `blueprint_plan.py`, `reports.py`,
`history.py`'s diff, and `mosyle.py`'s adapters. Treat the 124 Python tests as specifications. §6.3
maps each test file to its Swift suite.

### 1.2 SwiftGamGui: what to reuse

SwiftGamGui has 654 Swift Testing tests, a write chokepoint enforced by the compiler, and live-proven
Keychain handling. Copy and adapt the files below (L9). Paths are under `../SwiftGamGui`.

| Area | Copy from | Adapt how |
|---|---|---|
| Write chokepoint | `Packages/GamKit/Sources/ChangeCore/ChangeCore.swift`: `Origin` :14, `WriteStep`, `HeldPreview` :172 (`needsConfirmClick` :197, digest :199), `actor Executor` :269, `unfinished`/`acknowledge` :910-942. `Guard.swift`: `Risk`, `Change`, `OperatorConfirmation`, `Guard.evaluate`/`refusal` | Replace the argv with `WireOperation` (§3.8). Drop GAM-only parts: listed tasks, new-account waits, sweep tolerance, `aliasRefusal`, `deletedAccount`. Set the audit `connector` to `apple_business` / `apple_school` / `mosyle` |
| Audit | `ChangeCore/AuditLog.swift` (JSONL, `0600`, `O_NOFOLLOW\|O_APPEND`, rolls at 16 MiB keeping 10, backward chunked reader, two-layer redaction), `AuditScreen.swift` | Typed fields only; no server bodies |
| Ticket | `GamEngine/GamCommand.swift:52-54`, `package struct WriteTicket { package init() }` | Moves to `HTTPCore` |
| Source-scan tests | `Tests/GamEngineTests/WriteRouteTests.swift` (9 tests, `:45`-`:138`) | New list: who may build `WireOperation`, mint `WriteTicket`, call `send(_:ticket:)`, create `OperatorConfirmation`, touch `URLSession` |
| Keychain | `Vault/SecretStore.swift`, `KeychainStore.swift` (data-protection, `WhenUnlockedThisDeviceOnly` + `.userPresence`, shared `LAContext` in a `Mutex`, name-only index, CAS write-back, whole-or-absent sets), `Vault.swift` (600 s session on `ContinuousClock`), `Credential.swift` `Secret` :51-62, `MemoryStore.failNext` | Generalize the item key away from `Domain`/`Credential`. Add an EC **key** item kind (§3.4.1). Keep the OSStatus rule: only `errSecItemNotFound` means absent |
| Keychain gotchas | `docs/domains/secrets.md` | Read it before Phase 1. Every listed defect becomes a test |
| Siri drafts | `App/SiriIntents.swift`, `App/SiriDrafts.swift`, `App/AppShortcuts.xcstrings` | Same pattern: an intent stores a draft in an `@Observable` via `AppDependencyManager` |
| Preview UI | `App/ChangePreviewSheet.swift` (the only place an `OperatorConfirmation` is made) | Same rule |
| Composition, quit | `App/AppServices.swift` (`make()`/`demo()`), `App/AppDelegate.swift` | No GAM child processes. `.terminateLater` while the executor is busy |
| Tables | `ColumnWidths` in `App/GamGUIApp.swift`; failure-log entry 10-10 table-saved-its-own-widths | Persist hidden columns only |
| Screenshots | `App/Spikes.swift:73-115` (env-var snapshot harness), `scripts/screenshots.sh` (includes `narrow-*` smallest-window runs) | Same env-var scheme with the prefix `ABAPIT_` |
| Build, signing | `Config/Base.xcconfig` (ad-hoc default, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS[config=Release] = NO`, `#include? "Local.xcconfig"`), `Config/*-Team.entitlements`, hand-written `project.pbxproj` with a synchronized `App` folder and a local package | Add the sandbox entitlements (§3.9) |
| CI | `.github/workflows/ci.yml` (hygiene on ubuntu; `runs-on: xcode-27`; a Linux fuzz container; `ci-ok` aggregator; actions pinned by SHA; `permissions: contents: read`), `codeql.yml`, `scorecard.yml`, `dependabot.yml` (actions only) | Drop the GAM steps |
| Release gate | `scripts/check_app.sh`, `scripts/check_text.py` | Exact entitlements list (§3.9). No GAM checks |
| Process | `CLAUDE.md`, `docs/FRAMEWORK.md`, failure-log format, `docs/RULE-FEEDBACK.md`, domains-runbook template, `.claude/skills/*` (start-session, pre-commit, post-failure, end-of-session, improve-rules, live-verify), `.claude/hooks/*` (credential-guard, pre-commit-check, private-terms-check, session-start-check, rules-improver-check), the `gam-command-reviewer` agent | Rename and retarget: credential paths become `*.pem`, `~/.config/abapit/**`, and the Mosyle tokens |

**Do not reuse:**

- GamEngine's GAM half: builders, `GamError`, `GamOutput`, the Python HTML and Unicode tables, `GamRunner`/`posix_spawn`, `EphemeralConfig`.
- `mock_gam.sh` and the GAM pin scripts.
- The Setup, Directory and Stores feature modules.
- The empty `Assist`, `Catalog` and `Jobs` placeholders.

Failure-log entries in SwiftGamGui that apply here:

- display name must match the bundle name;
- a parity oracle can be wrong, so take inputs from the real producer;
- inspector plus split view crashes in narrow windows on macOS 27;
- Siri phrases need `AppShortcuts.xcstrings`;
- a Table saved its own widths;
- a mock failure was invented from convention, not from the real implementation;
- two parallel branches each bent a shared mock;
- load each panel as its own `Result`;
- fail closed on unknown targets, and a quit means "outcome unknown";
- measure time bounds with thread CPU time.

Read each one before the phase that touches its area.

---

## 2. What is missing: the gap register

Research for these tables was done on 2026-10-16. Sources are in Appendix F. **[A]** = Apple docs;
**[3P]** = third party or inference; **[OD]**/**[PM]**/**[LV]** = Mosyle official docs, Mosyle's
Postman collection, live behaviour.

### 2.1 Apple API features abapit does not use

| Feature | Endpoint / field [A] | Value | Phase |
|---|---|---|---|
| **Activation Lock status** (Business 2.5, School 1.7) | `GET orgDevices/{id}/activationLockStatus` → `isLocked`, `lockType` (`MDM`, `USER`, `NONE`) | Shows which devices are locked to a person's Apple Account and so can't be redeployed or released. Can error on an internal-only lock state [A] | 1 (detail), 3 (sweep and report) |
| **Apple-MDM device details** | `GET mdmDevices/{id}/details` (type `mdmDeviceDetails`): OS, last check-in, FileVault, firewall, storage in bytes, lock/erase/lost-mode status | Posture for devices on Apple's built-in management. **abapit calls `mdmDevices/{id}`, which is undocumented**; fix it | 2 |
| App and package detail | `GET apps/{id}` (id = Adam ID), `GET packages/{id}` | Detail pages | 2 |
| User detail and full attributes | `GET users/{id}`; `roleOuList`, `employeeNumber`, `costCenter`, `division`, `phoneNumbers`, `startDateTime` | Person page; abapit never calls `user()` | 2 |
| Org-unit membership | `organizationalUnits/{id}/relationships/users` (abapit fetches it but never shows it) | OU page with members | 2 |
| Linkage-only assigned server | `GET orgDevices/{id}/relationships/assignedServer` → `{type,id}` | Cheaper in sweeps and in the Guard's re-validation reads | 1 |
| Sparse fieldsets | `fields[orgDevices]`, `fields[mdmServers]`, `fields[auditEvents]`, … on every GET (abapit uses none) | Smaller list payloads. `fields[orgDevices]` excludes the 3 migration fields, so request those separately | 1–2 |
| Blueprint include limits | `limit[apps\|packages\|configurations\|orgDevices\|users\|userGroups]` (max 1000 each) | Large blueprints | 2 |
| Audit: server-side filters | `filter[actorId]`, `filter[subjectId]` (one value each), `cursor`, `fields[auditEvents]`. abapit filters by subject on the client | Device 360 and person timelines, by actor ("what did this API key do?") | 2 |
| Audit: 2.6 event types and typed payloads | 50 types; 2.6 adds 17 enum values (its changelog says 18) (`ROLE_*`, `IDP_*`, `DOMAIN_FEDERATION_*`, `BATCH_PASSWORD_RESET_INITIATED`, `ACCOUNT_PASSWORD_CHANGED`, `TERMS_ACCEPTED`, `APPLE_SERVICES_SETTINGS_UPDATED`, `EXTERNAL_ACCOUNT_INVITED`, `ACCOUNT_IMAGE_*`). The payload lives in `eventData<Type>`, keyed by `eventDataPropertyKey` | New **Access & Security** view: roles, API keys created/revoked, IdP and federation changes | 2 |
| MDM-service health fields | `status`, `deviceCount`, `lastConnectedDateTime`, `lastConnectedIp`, `defaultProductFamilies` | "MDM service hasn't connected in N days" on the dashboard | 1 (read), 5 (write) |
| MDM-service certificate rotation and defaults | PATCH `serverCertificate {name, data(base64)}`, `defaultProductFamilies` (`APPLE_TV`, `IPAD`, `IPHONE`, `IPOD`, `MAC`, `VISION`, `WATCH`) | Rotate a service's token certificate without delete/recreate | 5 |
| OrgDevice fields | `releasedFromOrgDateTime` (single GET only), `purchaseSourceType`/`purchaseSourceId`, `productType`, `partNumber`, `isMdmMigrationCapable`, `mdmMigrationStatus` (`REQUESTED`, `STARTED`, `SUCCESS`, `FAILED`), `mdmMigrationDeadlineDateTime` | Inspector, migration report | 1 |
| AppleCare fields | `isCanceled`, `contractCancelDateTime`, `agreementNumber`, payment type `ABE_SUBSCRIPTION` | Coverage report accuracy | 1, 3 |
| **MDM migration activities** (Business 2.3, School 1.6) | `ASSIGN_DEVICES_WITH_MDM_MIGRATION_DEADLINE` (`activityTypeMetadata.mdmMigrationDeadlineDateTime`, ≤ 90 days ahead), `UPDATE_MDM_MIGRATION_DEADLINE`, `CANCEL_MDM_MIGRATION` (no `mdmServer`) | Planned MDM moves with a deadline (for example Jamf → Mosyle) | 6 |
| **Release devices** (Business 2.4 only) | `RELEASE_DEVICES`: removes devices from the org, unenrolls them from built-in management, drops them from blueprints. **Irreversible** | Retirement and resale | 6 (D3) |
| Activity status detail | status `COMPLETED`, `IN_PROGRESS`, `STOPPED`, `FAILED`; 10 `subStatus` values; `downloadUrl` (present only when COMPLETED); activities kept 30 days | Accurate tracking UI | 4 |
| Read-only built-in configuration types | 22 types besides `CUSTOM_SETTING` (WIFI, FILE_VAULT, SOFTWARE_UPDATE, …) | Show them as typed but read-only; only `CUSTOM_SETTING` is writable | 2 |
| Profile validation for `CUSTOM_SETTING` | apple/device-management `mdm/profiles/*.yaml` at `release` commit `09f249a0` ("Release-v27.0") | Catch bad payload keys and platform mismatches before upload. Apple's own Create-a-Configuration example sends `com.apple.airplay.security` with `PLATFORM_IOS`, which the schema marks tvOS-only | 5 |

### 2.2 Mosyle Business features abapit does not use

These rows follow D4. The full matrix is in Appendix C.

| Feature | Operation | Phase |
|---|---|---|
| Admin audit log (non-consuming, filterable) | `/adminlogs` (no `operation`; `filter_options {start_date, end_date, idusers[]}`) [OD] | 7 |
| Device-group members and compliance | `/devicegroups` `get_info` (`options.iddevicegroup`, `security_compliance_status`) [OD, PM] | 7 |
| Custom device attributes (read) | `/devices` `list_custom_device_attributes` (top-level `os`) [OD] | 7 |
| Server-side device filters | `/devices` `list` options: `serial_numbers[]`, `deviceudids[]`, `tags[]`, `osversions[]`, `models[]`, `enrolldate_*`, `updatedate_*`, `supervised`, `specific_columns[]` [OD] | 7 |
| Lost-device actions (iOS/iPadOS, supervised) | `/lostmode` `enable` (message, phone_number, footnote), `disable`, `play_sound`, `request_location` (read back latitude/longitude via `list` + `specific_columns`) [OD, PM] | 8 |
| Device metadata and user assignment (D4: optional) | `update_device` (asset tag, tags, name, notes), `assign_device_user` [OD, PM] | 8 (if D4) |
| **Not built** (D4) | `wipe_devices`, `lock_device`, `restart_devices`, `shutdown_devices`, `enable/disable_activationlock`, `change_to_limbo`, `/variables` writes, user and user-group writes, any `groups[]` fan-out | — |

### 2.3 abapit defects the port must not inherit

| # | Defect (abapit file:line) | Swift design that prevents it | Phase |
|---|---|---|---|
| 1 | **Mosyle `activation_bypass` / `activation_bypass_mdm` (Activation Lock bypass codes) flow into pages and CSV**, because `adapt_device` passes every raw key through and `items_to_csv` exports the union of keys | Field **allowlist** in the Mosyle adapter. Request the list with `specific_columns` that excludes them. A redaction test fails if any `activation_bypass*` key reaches a model, a view, the audit log or a CSV | 7 |
| 2 | Mosyle users, user groups and device groups stop paging when a page has fewer than 500 rows, but the server may cap pages at 50, so rows after 50 are **silently dropped** (`mosyle.py` `_list_objects`) | Page until the `rows`/`rows_count` total is reached (it can be an int or a string), or until `DEVICES_NOTFOUND` | 7 |
| 3 | Mosyle errors inside HTTP 200 (`MISSING_DATA`, `DEVICES_NOTFOUND`, `UNKNOWN_COLUMNS`, …) become empty lists, and probe/ping report "ok" (`mosyle.py:350-368, 413-424`) | Classify `response[0].status` (or `response.status`) with typed codes. `COMMAND_SENT` and `COMMAND_SENDED` both mean success | 7 |
| 4 | Logs Stream drains **page 1 only**, with no retry. Reads consume events (confirmed live), so unread pages may be lost | Drain every page until `TotalLogs` is 0 or `TotalPages` is reached. **Persist each batch before requesting the next.** Retry with backoff | 7 |
| 5 | Logs Stream compliance timestamps (`"01:00 PM - 03/12/2024"`, no timezone) are left unparsed | Dedicated parser, documented as local time | 7 |
| 6 | `abapit snapshot` and web POST `/changes/snapshot` crash on a Mosyle org (`history.py:127-128`) | Per-provider collectors; a test runs a snapshot on each provider | 3, 7 |
| 7 | Missing server-side write checks: the blueprint relationship POST, and `/assign`, which ignores the probed capability; `guard()` ignores probed read denials | The Guard checks capability inside the executor. Reads denied by a probe show "your role can't read this" | 1, 4 |
| 8 | Confirm **re-plans from the posted form** (assign, blueprint relationships) | Confirm sends the held `WireOperation` bytes (§3.8) | 4 |
| 9 | No token single-flight; `tokens.json` on disk; `abapit token` bypasses the cache | `TokenBroker` actor, memory only. No token printing | 1 |
| 10 | Secrets on disk: PEMs in `~/.config/abapit/keys/`, Mosyle token/email/password/logs token in plaintext `config.json` | Keychain (L4) | 1, 7 |
| 11 | `GET mdmDevices/{id}` is undocumented | `mdmDevices/{id}/details` | 2 |
| 12 | Audit filtered client-side by subject; demo audit types `DEVICE_ASSIGNED_TO_MDM`/`…_FROM_MDM` are wrong (Apple's are `…_TO_SERVER`/`…_FROM_SERVER`) | `filter[subjectId]`; demo data checked against the contract manifest | 1–2 |
| 13 | `latest_resource` skips a resource that legitimately became empty and serves an older non-empty copy | Latest means the latest snapshot that **collected** that resource without error, even if empty | 3 |
| 14 | Config quirks: strict `Org(**json)` breaks on new fields; editing a Mosyle org wipes its role; the logs token can't be cleared; `team_id` is not settable; removing an org orphans tokens, history and logs; demo mode writes the real config | Versioned, tolerant `orgs.json`. Every field is editable and clearable. Removing an org offers to delete its Keychain items, history and logs. Demo uses an in-memory store | 1 |
| 15 | Configuration platforms can't be cleared on edit; the configuration delete "blast radius" is only a platform count | PATCH sends the full platform list; blast radius = blueprints that reference the configuration | 5 |
| 16 | List truncation at `max_pages` is only logged | Shown in the UI as "showing N of ≥M" | 1 |
| 17 | Device 360 merges with the **first** org of the other provider | The operator picks the paired org (remembered per org) | 7 |
| 18 | No local record of the app's own writes | Audit begin/end records (§3.8) | 4 |
| 19 | Mosyle disk-size unit unclear, and numbers/booleans arrive as strings (`"is_supervised":"1"`, `"battery":"0.81"`, `"total_disk":"64.0000000000"` GB). Several fields are JSON inside strings | Typed adapter with explicit units; JSON-in-string fields decoded | 7 |
| 20 | Write probes treat 400/404/409/422 as "allowed": a heuristic | Keep it, but label it "inferred". Run it only on an explicit **Permissions** click, because POSTs may be rate-limited hard (§3.3) | 4 |

### 2.4 Not offered by the APIs (don't build; watch for these)

- **Apple**:
  - no webhooks or notifications;
  - no `sort`;
  - no filters on lists other than audit;
  - **no user or group writes** (WWDC26 session 206 announced them, but the docs at 2.6 are read-only);
  - no subscription or AppleCare+ plan management (only audit events and `paymentType`);
  - app subscription licensing is "coming later";
  - no permissions endpoint (probe empirically);
  - no OpenAPI spec;
  - School has no people, classes, rosters or locations endpoints.

  The contract drift job (§3.10) flags any of these the day Apple documents it.
- **Apps and Books (VPP) licences** are a separate API. One content token binds to one MDM, so
  driving it from this app would revoke Mosyle's licences. Out of scope; show only the blueprint
  `appLicenseDeficient` flag.
- **Mosyle**:
  - no app or profile inventory, clear passcode, bulk endpoint, accounts or classes in Business (those are Mosyle Manager);
  - Mosyle Manager (`managerapi.mosyle.com/v2`) is a different API and out of scope.

### 2.5 Platform features to use

Each symbol was checked against this Mac's `MacOSX27.0.sdk` (Appendix E).

| Feature | Use | Phase |
|---|---|---|
| SwiftUI `Table` + `TableColumnCustomization`, `.searchable`, `.inspector`, `NavigationSplitView` | Device, people and content lists; Device 360 as an inspector | 1–2 |
| `alert(error:)`, `confirmationDialog`, `fileExporter` | Errors; confirms; CSV export through the sandbox's user-selected write access | 1 |
| Liquid Glass (`glassEffect`, `GlassEffectContainer`, `ToolbarSpacer`) | Standard controls only; adopt automatically. **No custom glass over dense tables** | 1 |
| Swift Charts (`BarMark`, `SectorMark`, vectorized `BarPlot`/`LinePlot`) | Dashboard, fleet age, OS breakdown. Skip `Chart3D` | 2–3 |
| `Observations` (macOS 26) | Bridge `@Observable` models to async pipelines (activity polling, Logs Stream drain) | 4, 7 |
| CryptoKit `P256.Signing` (PEM import; DER↔raw signature) + Security `SecKey` | ES256 client assertion (§3.4) | 1 |
| LocalAuthentication `LAContext` | One Touch ID per session | 1 |
| `SMAppService.mainApp` + `MenuBarExtra` + `NSBackgroundActivityScheduler` | Opt-in scheduled snapshots while logged in (D5) | 3 |
| `UNUserNotificationCenter` | Opt-in "N changes since last snapshot" | 3 |
| App Intents: `IntentModes`/`supportedModes`, `SnippetIntent`, `IndexedEntity`/`IndexedEntityQuery`, `@ComputedProperty`/`@DeferredProperty`, `TransientAppEntity`, `AppShortcutsProvider` | Read intents, snippets, Shortcuts scripting (replaces the CLI) | 9 |
| Foundation Models (`SystemLanguageModel.availability`, `@Generable`, `Tool`, `LanguageModelError`) | Drafts only (§5) | 9 |
| `Evaluations`, `AppIntentsTesting` (Xcode 27 frameworks) | Model-quality suite; intent definition tests | 9 |
| Swift Testing: exit tests, attachments (6.2); warnings, image attachments, `Test.cancel` (6.3); per-test-case repetitions (6.4) | §6 | all |
| `os.Logger` with `.private` interpolation | Logging (§3.9) | all |

---

## 3. Architecture

### 3.1 Repository layout

```
SwiftAbapit/                          (D1)
  App/                                synchronized folder; thin SwiftUI layer, MainActor by default
    AbapitApp.swift                   @main, scenes (main window, Settings, MenuBarExtra), Section enum
    AppServices.swift                 composition root: make() real / demo() (DEBUG) stubs + MemoryStore
    AppDelegate.swift                 .terminateLater while Executor busy; unfinished-write banner
    Screens/…                         one file per screen (§4)
    ChangePreviewSheet.swift          the ONLY place an OperatorConfirmation is created
    Intents/…                         App Intents, AppShortcutsProvider, AppShortcuts.xcstrings
    Debug/Snapshots.swift             env-var screenshot harness (DEBUG only)
  Packages/AbapitKit/Package.swift    one local package; the app sits outside it (L9)
    Sources/JSONAPI/                  pure: Document, Resource, Linkage, OpenEnum, ErrorResponse, Paging
    Sources/AppleModels/              pure: attribute structs + enums for Business 2.6 / School 1.7
    Sources/MosyleModels/             pure: envelope, status codes, adapters (with field allowlist)
    Sources/Wire/                     pure: WireOperation, ReadRequest, Host (shared by Planners, HTTPCore, ChangeCore)
    Sources/Planners/                 pure: assign, migration, release, blueprint rel, config, mdm svc, lost mode
    Sources/Reports/                  pure: stats, coverage, fleet age, activation lock, migration,
                                      reconciliation, timeline, OS/stale, audit digests, CSV writer
    Sources/ProfileSchema/            pure: device-management schema validation (Phase 5)
    Sources/Vault/                    Keychain store, Vault session actor, Secret, key import, JWS signing
    Sources/HTTPCore/                 Transport, HostAllowlist, RateLimiter, RetryPolicy, Paginator,
                                      WriteTicket, send(_:ticket:)
    Sources/AppleBusiness/            TokenBroker, AppleClient (reads), AppleWriteBuilders, probes
    Sources/Mosyle/                   MosyleSession, MosyleClient (reads), MosyleWriteBuilders, LogsStream
    Sources/History/                  SnapshotStore (SQLite3), LogsStore, abapit import
    Sources/ChangeCore/               HeldPreview, Guard, Executor (actor), AuditLog, AuditScreen
    Sources/Assist/                   DraftProvider protocol + FoundationModels impl (imports Planners only)
    Sources/TestSupport/              StubURLProtocol, AppleStub, MosyleStub, Fixtures, MemoryStore, FakeClock
    Tests/<Module>Tests/              one Swift Testing target per module + SourceScanTests
  Packages/AbapitApp/                 the screen models' package: AbapitKit's public API only, as the app sees it
    Sources/AppModels/                @MainActor screen models (orgs, devices, inspector)
    Tests/AppModelsTests/             invariant 8's screen-model tests
  Contracts/apple/                    business-2.6.json, school-1.7.json (generated, committed; §3.10)
  Contracts/device-management/        profiles-27.0.json (generated from apple/device-management, Phase 5)
  Tests/Fixtures/                     parity/ (golden from frozen abapit), docc/ (Apple examples),
                                      recorded/ (scrubbed live), demo/
  Config/  Signing/  Fuzz/  scripts/  .github/  .claude/
  docs/plans/  docs/failure-log/  docs/domains/  docs/RULE-FEEDBACK.md  docs/FRAMEWORK.md  docs/screenshots/
  CLAUDE.md  README.md  SECURITY.md  LICENSE (MIT)
```

### 3.2 Modules, dependency direction, access control

`JSONAPI`, `AppleModels`, `MosyleModels`, `Wire`, `Planners`, `Reports` and `ProfileSchema` import only
Foundation. No CryptoKit, Security, SwiftUI or OSLog. That keeps them buildable on Linux for the fuzz
job (§6.6).

```
App → {ChangeCore, AppleBusiness, Mosyle, History, Reports, Planners, Assist, AppModels, Vault(public API only)}
AppModels → {AppleBusiness, AppleModels, Orgs, Vault, Reports}   the screen models, in Packages/AbapitApp (AbapitKit's
                                                               products: its public API only); never HTTPCore, Wire or ChangeCore
ChangeCore → {HTTPCore, Wire, Planners, Vault}
AppleBusiness → {HTTPCore, Wire, Vault, AppleModels, JSONAPI}
Mosyle → {HTTPCore, Wire, Vault, MosyleModels}
HTTPCore → {Wire}
History → {AppleModels, MosyleModels, Reports}
Planners → {AppleModels, MosyleModels, JSONAPI, Wire}  (builds WireOperation via package init)
Reports → {AppleModels, MosyleModels, JSONAPI}
Assist → {Planners, Reports}                            never a client, HTTPCore or ChangeCore
```

A test parses `Package.swift` and fails on any edge not in this list. **Phase 0 change:** `WireOperation`
lives in a pure `Wire` module rather than `HTTPCore`, because Planners (pure) must build one and can't
depend on the transport (RULE-FEEDBACK 2026-10-16). `WriteTicket` and `send(_:ticket:)` stay in
`HTTPCore`.

**Access-control chokepoints.** These are `package`, so the app target can't see them.

- `WireOperation.init`. Built only by `Planners`/`*WriteBuilders`.
- `WriteTicket.init`. Minted only by `Executor`.
- `HTTPCore.send(_:ticket:)`.
- `Secret.bytes` and the `SecretStore` read methods.
- `MosyleRead`/`AppleRead` initializers. Only the read builders construct them; the read allowlist is
  in §3.3.

Source-scan tests (§6.4) back this up for what the compiler can't see.

### 3.3 HTTP core

- **Transport**:
  - one ephemeral `URLSession` per org, with cookies off (Mosyle sets `PHPSESSID`) and no URL cache;
  - HTTP/2 negotiated automatically (abapit's HTTP/1.1 `Transfer-Encoding` issue is moot);
  - `Transport` is a protocol, so tests inject `StubURLProtocol`.
- **Host allowlist**:
  - allowed: `account.apple.com`, `api-business.apple.com`, `api-school.apple.com`,
    `businessapi.mosyle.com`, `businessapilogs.mosyle.com`;
  - redirects are refused unless the target is on the list (`willPerformHTTPRedirection`);
  - the activity `downloadUrl` (presigned, unknown host) is **opened in the browser** with
    `NSWorkspace`, never fetched.
- **Read classification**:
  - Apple reads are GETs.
  - Mosyle reads are POSTs whose `(path, operation)` is on a hand-curated allowlist: `devices/list`,
    `devices/list_custom_device_attributes`, `users/list_users`, `usergroups/list_usergroup`,
    `devicegroups/list_devicegroup`, `devicegroups/get_info`, `/adminlogs`, `/login`.
  - Logs Stream `/logsstream` is a read that **consumes**: it runs only from the drain task, never
    automatically on view (§3.5).
  - Everything else is a write and needs a ticket.
- **Rate limiting**:
  - one `RateLimiter` actor per credential, with separate GET and POST budgets;
  - Apple documents 429 but **no numbers and no `Retry-After`** [A]. Third-party reports say about
    20 GET/min and 10 POST/hour, with `Retry-After` in seconds [3P, unverified];
  - so the limiter adapts: it starts conservative, halves on 429, recovers slowly, and stores the
    learned rate per org in `orgs.json` (not a secret);
  - Phase 1's live check measures the real rate and records it here.
- **Retry policy**:
  - **reads**: transport errors up to 4 retries with backoff; 429 honours `Retry-After` (seconds or
    an HTTP date, capped at 60 s), else exponential backoff;
  - **any request**: 401 → refresh the token once → retry once;
  - **writes**: never retried, except on 429 (Apple rejects those before processing).
- **Pagination**:
  - follow `links.next`, or `meta.paging.nextCursor` with `cursor` (audit);
  - `limit` max 1000;
  - a page cap (default 200 pages); hitting it is **shown in the UI**;
  - streams pages as an `AsyncThrowingStream` so tables fill progressively.
- **Errors**:
  - decode `ErrorResponse {errors:[{id,status,code,title,detail,source{pointer|parameter},links,meta}]}`;
  - classify on HTTP status **plus** the dot-separated `code`, never on prose;
  - `APIError` cases: `.unauthorized`, `.forbidden(section)`, `.notFound`, `.conflict`,
    `.unprocessable(pointer)`, `.rateLimited(retryAfter)`, `.server`, `.transport`,
    `.mosyle(status)`.
- **Decoding** (Apple's stated forward-compatibility rule):
  - unknown keys are ignored;
  - every enum is `OpenEnum<Known>`, where an unknown value becomes `.unknown(String)` and the UI
    shows the raw value;
  - Apple's own enum lists are incomplete (`AuditEventCategory`, `AuditEventSubjectType`) [A].

### 3.4 Apple auth

#### 3.4.1 Key import and storage

1. The operator picks the `.pem` through `NSOpenPanel` (user-selected read).
2. Read it **once**: regular file only, size ≤ 16 KiB, read by descriptor (`O_NOFOLLOW`) as in
   SwiftGamGui's `CredentialFolder`.
3. Normalize, porting abapit's `normalize_private_key`:
   - CRLF/CR → LF, then strip;
   - try the label as given; on failure swap the `EC PRIVATE KEY` and `PRIVATE KEY` labels and retry;
   - golden fixtures cover SEC1, PKCS#8, mislabelled and garbage keys.
4. Parse with `P256.Signing.PrivateKey(pemRepresentation:)`.
5. Turn it into a `SecKey` (`SecKeyCreateWithData` on `x963Representation`,
   `kSecAttrKeyTypeECSECPrimeRandom`, `kSecAttrKeyClassPrivate`).
6. Store it as a `kSecClassKey` item with these attributes:
   - `kSecUseDataProtectionKeychain`;
   - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`;
   - a `.userPresence` access control;
   - not synchronizable.

   This follows Apple's "Storing CryptoKit keys in the Keychain".
7. Zero the local buffers.
8. Tell the operator where the original file is, and offer to move it to the Trash. That is a
   separate confirm.

#### 3.4.2 Client assertion

- **Header**: `{"alg":"ES256","kid":<keyID>,"typ":"JWT"}`.
- **Claims**:
  - `iss` = team ID if set, else client ID (abapit's rule);
  - `sub` = client ID;
  - `aud` = `https://account.apple.com/auth/oauth2/v2/token` (**v2**, unlike the POST URL);
  - `iat`;
  - `exp` < `iat` + 180 days;
  - `jti` = a UUID.
- **Encoding**: base64url without padding. `.base64URLAlphabet` wasn't found in the SDK headers; if
  it's absent, write the 3-line encoder.
- **Signing**: `SecKeyCreateSignature(.ecdsaSignatureMessageX962SHA256)` returns **DER**. Convert it
  with `P256.Signing.ECDSASignature(derRepresentation:).rawRepresentation` to raw r‖s. The strict
  stub verifies the signature with the test key's public half; DER-in-JWS is the classic ES256 bug.
- **Phase 1 live check, assertion reuse**: does Apple accept the same assertion (same `jti`) for a
  second token request?
  - If yes: sign one assertion per Vault session (memory only, `exp` = 8 h). Hourly token refreshes
    then need no Touch ID.
  - If no: sign per token mint, which means at most one prompt per hour of use within D6.
  - Record the answer here.

#### 3.4.3 TokenBroker

- **Shape**: an actor per org. It merges concurrent requests into one in-flight `Task`.
- **Request**: `POST https://account.apple.com/auth/oauth2/token` with a form-encoded **body**
  (Apple's curl puts it in the query string; don't). Fields:
  - `grant_type=client_credentials`
  - `client_id`
  - `client_assertion_type=urn:ietf:params:oauth:client-assertion-type:jwt-bearer`
  - `client_assertion`
  - `scope=business.api|school.api`
- **Token lifetime**: the token lasts 3600 s. Refresh 60 s early. Invalidate on 401.
- **Rate limits**: the token endpoint rate-limits too, which is why requests are single-flight.

#### 3.4.4 Unattended read-only key (D5)

- A second API account per org whose Apple role has only View permissions. Apple allows up to 50 API
  accounts with per-category permissions [A].
- Accepted only when Phase 4's write probes return **403 for every write category**: assign,
  migration, release, blueprints, configurations, MDM services.
- Stored `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` **without** user presence.
- Wrapped in `ReadOnlyAppleClient`, a type with no path to `HTTPCore.send(_:ticket:)`. A source-scan
  test enforces this.
- Used only by the scheduled snapshot task.

### 3.5 Mosyle client

- **Secrets**: per org, four Keychain generic passwords with the §3.4.1 ACL: access token, admin
  email, admin password, and the optional Logs Stream token.
- **Login**:
  - `POST /v1/login` with header `accessToken` and body `{email,password}`;
  - the JWT comes back in the **response** `Authorization` header;
  - its lifetime comes from the JWT `exp` claim, falling back to 23 h;
  - **ignore the `Expires` header** (PHP's fixed 1981 date);
  - single-flight `MosyleSession` actor;
  - re-login once on 401.
  - Tokens can be IP-restricted [3P], so show that hint on 401 after a fresh login.
- **Envelope**:
  - read `response[0].status`, or `response.status` for `devicegroups` and `logsstream`, which return
    an object;
  - the top-level `"status":"OK"` is meaningless;
  - typed codes: `MISSING_DATA`, `DEVICES_NOTFOUND`, `UNKNOWN_COLUMNS`, `NO_DEVICE_UPDATED`,
    `USERGROUP_NOTFOUND`, `LOSTMODE_NOTENABLED`, `COMMAND_SENT`/`COMMAND_SENDED`, `DEVICE_UPDATED`,
    `DEVICE_ASSIGNED`;
  - `rows`/`rows_count` may be an int or a string;
  - HTTP errors: 401 `{"error":…}`, 405 `INVALID_METHOD`; the Logs host uses a different 401 shape.
- **Devices**:
  - iterate `os ∈ {ios, mac, tvos, visionos}`;
  - `page_size` 500, paging until the `rows` total is reached;
  - **`specific_columns` = the adapter's allowlist** (defect 1);
  - dedupe by serial, else UDID.
- **Logs Stream**: a single `LogsDrain` task per org, run on demand and on the scheduler.
  - It is bounded: at most N pages per run, with a time budget.
  - Each run: request all enabled `LogType`s, take page *p*, **commit the batch to `LogsStore`
    (SQLite, deduped on `kind|when|label|device|user`)**, then *p* + 1, until `TotalLogs` = 0 or
    `TotalPages` is reached.
  - Retention is configurable (default 90 days or 50k rows).
  - CSV export.

### 3.6 Concurrency

- **Package**: Swift 6 language mode, complete strict checking, explicit isolation (as in
  SwiftGamGui), plus `.enableUpcomingFeature("NonisolatedNonsendingByDefault")`. JSON decoding and
  report functions that run long are marked `@concurrent`.
- **App target**: `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, `SWIFT_APPROACHABLE_CONCURRENCY = YES`.
- Decide this in Phase 0 and never flip it later. Copied SwiftGamGui code may need small isolation
  annotations.
- **Actors**: clients and `TokenBroker`/`MosyleSession` (per org), `RateLimiter` (per credential),
  `Vault`, `Executor` (app-wide; writes run one at a time), `SnapshotStore`, `LogsStore`.
- **Bounded fan-out**: AppleCare and Activation Lock sweeps run in task groups at the limiter's rate,
  then a slow sequential retry pass (abapit's pattern). They can be cancelled, report progress, and
  run only in snapshots or on an explicit "Fetch for all", never on page load.
- **Time**: TTLs and sessions use `ContinuousClock`, which keeps counting through sleep.
- **CF types** never leave the `Vault` actor.

### 3.7 State and storage

| State | Where | Lifetime |
|---|---|---|
| Apple keys (interactive; D5 unattended), Mosyle token/email/password/logs token | Keychain (§3.4.1, §3.5) | Until the operator removes them |
| Org profiles: id, name, provider, scope, client ID, key ID, team ID, role, capabilities + probed date, learned rate limit, paired org | `Application Support/<App>/orgs.json`. Versioned, tolerant decode, `0600`, atomic write (SwiftGamGui's `SignatureStore` pattern) | Persistent; **no secrets** |
| Bearer tokens, Mosyle JWTs, signed assertions | Actor memory | ≤ 1 h / 24 h / 8 h; gone on quit |
| Read caches | Memory, keyed `(orgID, generation, resource)` with `fetchedAt`; LRU-bounded | Session. **Stale data always shows its age** |
| Held previews | Inside `Executor`. Single use, 15-minute TTL, at most 8 held, cleared when the generation changes | Memory |
| Audit log (this app's writes) | `Application Support/<App>/audit/*.jsonl` | Persistent |
| Snapshots | `Application Support/<App>/history.sqlite`. abapit schema + `schema_version` + `org_id` column; views `devices_view`, `applecare_view`, plus new `activation_lock_view` | Persistent; retention keeps N per org |
| Mosyle logs | `LogsStore` tables in the same SQLite file | Retention (§3.5) |
| Model drafts | Memory | Never persisted; the audit records only the `origin` |

The storage root is **injected** and never read from a global, so tests can't touch the real
container (SwiftGamGui failure-log 2026-09-25).

### 3.8 ChangeCore: the only write path

This is ported from SwiftGamGui and generalized from argv to HTTP.

- **`WireOperation`** is a fully built request:
  - method, host, path and query;
  - content type and body **bytes**;
  - target canonical IDs (serials, blueprint ID, Mosyle UDIDs);
  - a `kind` (e.g. `.assignDevices`, `.releaseDevices`, `.lostModeEnable`) with a `minimumRisk`.

  Auth headers are added at send time and are excluded from the digest.
- **`Plan`** = changes + no-ops + unknowns + blast radius + `[WireOperation]` + **preconditions**
  (for example, "C02X is assigned to server A" or "blueprint B has app X").
- **`HeldPreview`** = plan + org ID + generation + origin (`form`/`siri`/`model`) + creation instant
  + SHA-256 digest of the serialized operations. `needsConfirmClick = origin != .form || risk ≥ .high`.
- **Confirm** names a preview ID and nothing else. Typed confirmation:
  - the canonical name, for deletes;
  - the device count, above 25 targets;
  - the org name plus count, for `RELEASE_DEVICES`;
  - the device name, for lost mode.

  **The executor sends the held bytes.** It never rebuilds.
- **Guard** (inside `Executor`) checks, in order:
  1. single use;
  2. org and generation;
  3. TTL;
  4. capability (from probes);
  5. typed confirmation;
  6. in-flight target lock;
  7. a bulk hard cap, configurable per kind (the default for assignment is 1000 serials, because
     Apple accepts arrays);
  8. a **re-validation read** of each precondition. If any changed, refuse and ask for a new preview.
- **Audit**:
  - a begin record (fsynced) before the send and an end record after;
  - typed fields: org, connector, kind, target IDs, digest, origin, HTTP status, Apple error `code`,
    Mosyle status, activity ID;
  - an unmatched begin means an **"outcome unknown — verify"** banner at launch.
- **Async outcomes**:
  - Apple activities are polled every 5 s with backoff, for at most 30 min, then "check later".
  - Mosyle lost-mode state is polled through `list` + `specific_columns lostmode_status`
    (`PENDINGTOENABLE` → `ENABLED`), bounded.
  - Results go into the audit end record and a per-write status view.
- **Quitting**: `applicationShouldTerminate` returns `.terminateLater` while a send is in flight.
- **Safe-actions list (D10)**: a preview whose `origin` is `.model` or `.siri` may run without the
  confirm click only when the org's switch is on, its `kind` is on the list (`mosylePlaySound`,
  `mosyleRequestLocation`, `assignDevices` with exactly one serial), it has exactly one target, and the
  read-back was shown. The Executor checks every condition; the switch's standing approval is created
  only by the Settings screen (a source-scan test, like `OperatorConfirmation`'s). Its write-path
  design is part of Phase 4's operator review.
- **Never-list for drafts** (model or Siri can't even draft these): `RELEASE_DEVICES`, deletes, and
  any destructive Mosyle command.

### 3.9 Security

- **Entitlements, exactly**:
  - Ad-hoc/CI build: `com.apple.security.app-sandbox`, `com.apple.security.network.client`,
    `com.apple.security.files.user-selected.read-write`.
  - Team build (`Local.xcconfig`): the same three plus `keychain-access-groups =
    $(AppIdentifierPrefix)$(PRODUCT_BUNDLE_IDENTIFIER)`, and the `application-identifier` and
    `team-identifier` Xcode adds when it provisions the group. `check_app.sh` compares keys **and values**
    (Phase 0's review: a sandbox set to `0` passed a names-only check); the team values are pinned from
    the operator's first team build (S1).
  - `check_app.sh` diffs `codesign -d --entitlements` against these lists.
- **Hardened runtime**: on, with no exceptions. Release builds are not debuggable.
- **Signing**:
  - Personal Team for real use (SwiftGamGui's spike result: ad-hoc gets `errSecMissingEntitlement`
    (-34018) on every data-protection call).
  - A Personal Team build expires after 7 days.
  - Moving to a paid team changes the access group, so secrets must be re-imported once; the app's
    "credentials missing" path walks the operator through it.
- **Logging**: `os.Logger` with `.private` by default. Never log headers, bodies, assertions or JWTs.
  Each API call logs method, host, path template, status and latency (abapit parity) at `.info`.
- **Sensitive fields**: an allowlist for CSV export (no `activation_bypass*`, no tokens). Apple's
  `lastConnectedIp` is shown but not exported by default.
- **Fixtures**: scrubbed (§6.2). A private-terms hook and a scrub-check test.

### 3.10 API contracts and drift detection

Apple publishes no OpenAPI spec, but its DocC pages are machine-readable JSON
(`https://developer.apple.com/tutorials/data/documentation/applebusinessapi/<slug>.json`, with
`restEndpoint`, `restParameters` including `allowedValues`/`maximum`, `restBody`, `restResponses` and
`properties`).

- **`scripts/apple_contracts.py`** (dev-time; run with `python3 -I`; downloads into a fresh scratch
  directory and treats them as data):
  - crawls both doc roots and writes `Contracts/apple/business-<ver>.json` and `school-<ver>.json`:
    endpoints, params, enums, schemas, and **every example request and response**;
  - the example JSON also becomes `Tests/Fixtures/docc/`.
- **Contract tests**:
  - every `AppleModels` type decodes every DocC example for its resource;
  - every Swift enum's known cases equal Apple's `allowedValues` (excluding the documented gaps);
  - every endpoint the client calls exists in the manifest with the same method and params;
  - every `fields[…]` value we send is allowed.
- **Drift job**: a weekly scheduled GitHub workflow re-runs the crawler and opens an issue (not a PR)
  with the diff. Its first job is to detect user/group writes and app licensing when Apple ships them.
- **Mosyle**: no machine-readable docs exist.
  - `Contracts/mosyle/operations.json` is hand-written from Appendix C, with a source per row.
  - Recorded, scrubbed live responses back each read.
  - Write shapes come only from the official doc and the Postman collection.
  - The "lock_device posted to /variables" Postman bug is noted as untrusted.
- **apple/device-management** (Phase 5):
  - `scripts/device_management_schemas.py` converts `mdm/profiles/*.yaml` at the pinned commit
    `09f249a0` into `Contracts/device-management/profiles-27.0.json`;
  - PyYAML runs only in a dev venv;
  - the output is committed;
  - the commit pin and SHA-256 are recorded in the file header.

---

## 4. UI

- **Window**: `NavigationSplitView` with the sidebar sections Overview, Devices, People, Content,
  Activity, Reports, Settings, mirroring abapit's NAV.
  - Sections are hidden by provider and scope.
  - A section a probe found forbidden shows a lock and "your role can't read this", with **Re-check**.
- **Toolbar**:
  - org switcher (`name · role`), which bumps the generation;
  - **Refresh** (forces live);
  - **Find** (⌘L): exact identifier lookup over serial, IMEI, MEID, EID, order number and
    Wi-Fi/Bluetooth/Ethernet MACs; one hit opens Device 360, several filter the table (abapit
    `/find`);
  - a stale banner, "snapshot data from <time> — refreshing", whenever cached or snapshot data is
    shown.
- **Tables**:
  - `Table` with sort, `.searchable` and filter tokens (family, status, assigned service, Activation
    Lock, migration status);
  - column customization that **persists hidden columns only**;
  - progressive page loading;
  - each list exports CSV through `fileExporter`.
- **Device 360**:
  - an inspector (bound the column widths; snapshot the smallest window) with ABM ownership, AppleCare,
    Activation Lock, assigned MDM service, migration state, Mosyle live posture and the timeline;
  - each panel loads as its own `Result`;
  - actions: Move to MDM, Lost device (if D4), Release (if enabled).
- **Write flows**: always a form, then **ChangePreviewSheet** showing exact changes, no-ops, unknowns
  and blast radius, then the typed confirm, then a status view.
- **Settings**:
  - add/edit/remove org (Apple: name, scope, client ID, key ID, optional team ID, role, key import;
    Mosyle: name, token, email, password, optional logs token);
  - **Test**, **Permissions** (probe), the optional unattended key (D5), login item and scheduled
    snapshot toggles, retention, history import from abapit.
- **Accessibility**: every control has a unique identifier and label. A UI test asserts labels within
  a list are distinct.
- **Demo mode**: launch with `ABAPIT_DEMO=1` (DEBUG) or the Settings "Open demo org" item. Demo uses
  the strict stubs and `MemoryStore`, never real config.

---

## 5. Assist, App Intents and Spotlight (Phase 9)

- **The rule**: a model or Siri only fills a draft, except the D10 safe-actions list (§3.8). `Assist` imports `Planners`/`Reports` only. A
  deterministic resolver validates every field against live data. Serials always come from the
  deterministic parser, never from model output. Only the operator's click on the preview confirms.
  A test proves no intent or Assist symbol reaches `Executor`/`send` (SwiftGamGui's
  `noIntentReachesAWrite`).
- **Foundation Models**, on device only (D7):
  - `DeviceFilter @Generable` for "Macs not checked in for 30 days that ABM says are assigned to
    Mosyle" becomes editable filter tokens;
  - `AssignmentDraft {action, targetServerName}` from pasted text;
  - `LostDeviceDraft {personHint, deviceHint, action}` (iOS only).
  - Tools are read-only lookups into in-memory caches, with no network.
  - Gate on `SystemLanguageModel.default.availability`; SwiftGamGui's spike saw `.modelNotReady`.
  - Every flow works with no model.
  - An `Evaluations` suite runs about 30 phrasings per draft type; it is recorded, not a gate.
- **App Intents**:
  - read intents with `supportedModes = .background`: count unassigned; look up serial (returns a
    `DeviceEntity` + `SnippetIntent`); stale Macs; coverage expiring in N days; Activation-locked
    devices; export a resource as CSV (returns a file); take snapshot (`LongRunningIntent`, D5).
  - Write-shaped intents use `.foreground` and only open the preview.
  - Org data needs `authenticationPolicy = .requiresLocalDeviceAuthentication`; verify what it does on
    a Mac.
  - `AppShortcuts.xcstrings`; every phrase contains `\(.applicationName)`.
  - `AppIntentsTesting` tests.
  - Scripting replaces the CLI (L8): `shortcuts run "Export devices CSV"`.
- **Spotlight**: `IndexedEntity` for devices is **off by default** (it puts serials in the system
  index); a Settings toggle turns it on.

---

## 6. Testing

### 6.1 Frameworks

- Swift Testing only, for unit and integration tests in the package. Use `.serialized` where a stub
  keeps state.
- XCUIAutomation only if a flow can't be covered through models plus screenshots.
- `swift test --package-path Packages/AbapitKit` runs in CI. `xcodebuild test` runs locally.

### 6.2 Fixtures

1. **Parity goldens from frozen abapit.** `scripts/gen_fixtures.py` runs abapit at a pinned commit in
   its own venv. Hypothesis strategies with `@seed` produce `Tests/Fixtures/parity/*.json` for:
   - `parse_serials`, `assign.plan`, `plan_relationship`;
   - every `reports.py` function with a fixed `now`;
   - `items_to_csv` **bytes** (CRLF, the `'` formula guard, Python-repr dicts: decide here whether to
     keep the repr or emit JSON, and list it as a deviation);
   - `diff_snapshots`;
   - `normalize_private_key`;
   - `adapt_device`, `adapt_user`, `adapt_group`, `normalize_logs`, `_to_iso`;
   - auth claims (without the signature).

   Where abapit is wrong (defects 1–5, 12, 13), the generator records the **corrected** expectation and
   keeps abapit's output in an `abapit` field. A test keeps that deviation list short. Compare bytes,
   never `String ==`. Never edit a fixture to make a test pass.
2. **DocC examples** (§3.10), one per Apple resource and error shape.
3. **Recorded live reads**:
   - captured by the operator with a DEBUG "Record fixtures" command into a folder they choose;
   - `FixtureScrubber` maps serials, UUIDs and IDs to format-preserving fakes, names and emails to
     `example.com`, and drops tokens and `activation_bypass*`;
   - a scrub-check test fails on JWT-shaped strings, non-example email domains or real-looking
     serials;
   - the private-terms hook adds the operator's denylist.
4. **Demo data**: abapit's demo fleet (84 devices, seed 42), with the audit types fixed, subscription
   events added, the new fields (Activation Lock, migration) added, and a **Mosyle demo fleet** (new).

### 6.3 Strict stubs

An unhandled request fails the test. Write each failure mode from the real implementation's
documented behaviour, never from convention (SwiftGamGui failure-log 10-12).

- **AppleStub** (`StubURLProtocol`, keyed per test session):
  - The token endpoint **verifies the ES256 signature** and checks `alg`, `kid`, `iss`/`sub`, `aud`
    (v2) and `exp` < 180 days. Anything else gets `invalid_client`. It can rate-limit.
  - Resources check the bearer and return:
    - 401 once;
    - 403 per section;
    - 400 for a forbidden `include`;
    - 404 for an unassigned `assignedServer`;
    - 409 deleting an MDM service with devices;
    - 422 for malformed write bodies (wrong `type`, missing relationships, a migration deadline more
      than 90 days out, `RELEASE_DEVICES` on School);
    - 429 with and without `Retry-After`.
  - Real cursors and real `ErrorResponse` bodies.
- **MosyleStub**:
  - POST only; both headers required;
  - login returns the JWT in the **response header** plus a 1981 `Expires`;
  - a missing `os` gets `MISSING_DATA` in HTTP 200;
  - past the last page gets `DEVICES_NOTFOUND`;
  - pages are capped at 50 for users and groups;
  - devicegroups and logsstream return an object;
  - Logs Stream **removes what it returns**;
  - unknown operations fail.
- **MemoryStore.failNext** raises the real OSStatus codes:
  - -25300 not found
  - -128 cancelled
  - -25293 auth failed
  - -25308 interaction not allowed (also the locked-Mac case)
  - -34018 missing entitlement

### 6.4 Source-scan tests (backstop only)

The compiler is the boundary; these tests cover only what it can't see.

- Only `Executor.swift` writes `WriteTicket(`.
- Only `Planners/` and `*WriteBuilders.swift` write `WireOperation(`.
- Only `HTTPCore/Transport.swift` names `URLSession`.
- Only `App/ChangePreviewSheet.swift` creates `OperatorConfirmation`, and that file imports no
  intents or models.
- No `@testable` in `App/`.
- `ReadOnlyAppleClient` never mentions `send(`.
- No `activation_bypass` outside the adapter's deny list and its tests.
- An anti-vacuity check proves the scan actually sees these files.

### 6.5 UI verification

- Thin views; logic lives in `@Observable` models covered by unit tests.
- The env-var screenshot harness (`ABAPIT_SNAPSHOT`, `_SCREEN`, `_SELECT`, `_WINDOW`, `_DEMO`)
  renders each screen from the demo org to a PNG and quits. It includes `narrow-*` smallest-window
  runs and the layout tripwires `columnsTooNarrow` and `controlsOutsideTheWindow`.
- CI uploads the PNGs. A PR that changes a screen commits the refreshed image to `docs/screenshots/`.

### 6.6 Generated-input and fuzz tests

From day one:

- property tests for the serial parser, CSV writer, JSON:API decoding/pagination, Mosyle envelopes
  and dates, and the compliance timestamp parser;
- libFuzzer targets for the same parsers in the Linux CI container (the pure modules build on Linux,
  §3.2).

### 6.7 abapit's tests as specifications

| abapit file (count) | Swift suite | Phase |
|---|---|---|
| test_auth (3), test_token_cache (2) | VaultTests, AppleBusinessTests.Auth (disk persistence becomes memory-only) | 1 |
| test_client (16) | AppleBusinessTests.Client, HTTPCoreTests | 1–2, 5 |
| test_config (7) | OrgStoreTests, VaultTests.Import | 1 |
| test_assign (7) | PlannersTests.Assign, ChangeCoreTests.Probe | 4 |
| test_blueprint_plan (5) | PlannersTests.BlueprintRelationships | 5 |
| test_reports (13) | ReportsTests | 2–3, 7 |
| test_history (6) | HistoryTests | 3 |
| test_mosyle (39) | MosyleTests, ReportsTests.Reconcile | 7 |
| test_web (26) | Screen-model tests plus screenshot specs; the loopback/CSRF cases are retired by L2 and listed as such | 1–7 |

---

## 7. Process

Copied from SwiftGamGui and adapted in Phase 0.

**`CLAUDE.md` invariants.** Numbered; a retired number is never reused. Each one names its enforcement
home.

1. One write path (§3.8): the held bytes are what runs; there is a package ticket.
2. Reads are classified by type, not HTTP method. Only allowlisted reads run automatically. Logs
   Stream drains only from the drain task.
3. Secrets only in the Keychain. Tokens only in memory. `Secret` never prints.
4. No listener. Sandbox on. Host allowlist. Zero third-party dependencies.
5. The stubs fail like the APIs.
6. Parity is a test; deviations from abapit are listed.
7. Bound everything polled, streamed or swept.
8. Stale or truncated data is never silent.
9. A model or Siri only drafts, except the off-by-default safe-actions list (D10). The never-list can't
   be drafted.
10. Decoding is forward-compatible (unknown keys and enum values survive).
11. Sensitive fields never leave the app: bypass codes, tokens, assertions.

**Rules of engagement**:

- no tenant mutation without the operator's per-action yes;
- never touch the operator's credentials (spikes use `swiftabapit-spike*` items only);
- tenant data never enters the repo;
- commits only through PRs with a green `ci-ok`, as goetchstone.

**Other process**:

- **Failure log**: `docs/failure-log/`, one file per incident, five fields (Symptom, Cause, Why not
  caught, Fix, Prevention). A `fix:` commit needs an entry (hook).
- **RULE-FEEDBACK → improve-rules loop**: sessions never edit invariants directly.
- **Runbooks**: `docs/domains/` per area (auth-keychain, apple-reads, apple-writes, mosyle,
  logs-stream, history, change-core, assist-intents), using SwiftGamGui's template.
- **README live-verification table**: one row per write. Status values:
  - `confirmed (YYYY-MM-DD)` from this app's audit log;
  - `request-identical to abapit's live-proven call`;
  - `not yet`.

  Scratch objects only.
- **Read-only acceptance pass**: a DEBUG command the operator runs. It performs every read against
  the real tenant and reports decode success per resource, including counts of unknown enum values
  and unknown keys.

---

## 8. Phases

Sizes are changed lines, excluding generated fixtures and contract JSON. Calibration from the
2026-10-08 draft: about 1.2–1.6% of a weekly usage limit per 100 lines on a new Swift codebase, plus
20–30% for UI polish.

| Phase | Scope | Est. lines | Depends on |
|---|---|---|---|
| 0 | Scaffold, process, spikes, contract and parity generators | 700–1,000 | §0.2 answered |
| 1 | Apple core: Vault, auth, HTTPCore, devices, MDM services, Device inspector, demo, Settings | 2,200–2,800 | 0 |
| 2 | Apple read parity + new reads (people, content, Apple-MDM details, typed audit) | 1,500–2,000 | 1 |
| 3 | History, reports, scheduled snapshots | 1,500–2,000 | 2 |
| 4 | ChangeCore + assign/unassign + write probes | 1,600–2,100 | 1 |
| 5 | Blueprint, configuration, MDM-service writes + profile validation | 1,300–1,800 | 2, 4 |
| 6 | MDM migration activities + release | 700–1,000 | 3, 4 |
| 7 | Mosyle reads, Logs Stream, reconciliation, Device 360 merge | 1,900–2,400 | 1 (3 for snapshots) |
| 8 | Mosyle lost-device actions (D4) | 600–900 | 4, 7 |
| 9 | Assist, App Intents, Spotlight | 1,000–1,400 | 2, 4, 7 |
| 10 | Docs, distribution prep, abapit retirement | 200–400 | all |
| **Total** | | **~13k–18k** | |

### 8.1 Parallel tracks and file ownership

After Phase 1 merges, three tracks can run, each in its own `git worktree`:

- **Track A** (Apple reads): 2 → 3 → 6.
- **Track B** (writes): 4 → 5 (after 2) → 8 (after 7).
- **Track C** (Mosyle): 7.
- Phase 9 waits for 2, 4 and 7.

Shared files are **serialized**: `App/AbapitApp.swift` (Section enum, sidebar), `App/AppServices.swift`,
`Package.swift`, `CLAUDE.md` and `README.md`. The second track to touch one rebases after the first
merges and never stacks a PR on a branch that `--delete-branch` will remove. Each phase owns its
module directories (listed per phase). Stubs in `TestSupport` are per-provider files, so Apple and
Mosyle tracks don't bend a shared mock.

### Phase 0: scaffold, process, spikes, generators

**Status:** merged 2026-10-16 (PR #1). Built: repo, project, package graph (with the pure
`Wire` module, §3.2), process files and skills, CI (hygiene, macOS, libFuzzer, `ci-ok`), CodeQL, Scorecard,
the drift job, `check_app.sh`; **S2** contracts: Business 2.6 = 57 endpoints, School 1.7 = 11; **S3** goldens
from abapit `3890091` (main; its pure modules are identical to `9875ee7`), deterministic across runs, with the serial parser ported as the pilot (5/5 mutants
killed); **S4**: `.unavailable(.modelNotReady)`, 24 languages; **S1 ad-hoc, sandboxed**: every data-protection
call returns -34018 and the spike prints the "sign with your team" guidance. **Pending the operator: S1 with
a Personal Team** (one Xcode build, one Touch ID; steps in `docs/domains/auth-keychain.md`). The review's
findings are fixed in the same PR (failure-log 2026-10-16, "the gate checked names, not values"). **Open for
the operator:** a PR can change its own `ci.yml`, `check_app.sh` or `check_graph.py`, and so its own `ci-ok`;
with one maintainer, a CODEOWNERS review rule would block every merge (RULE-FEEDBACK 2026-10-16).

**Owns:** everything. Nothing runs in parallel with Phase 0.

1. **Repo.** Create the D1 repo as goetchstone, MIT licensed. Copy this plan into `docs/plans/`.
2. **Project.** A hand-written `project.pbxproj`:
   - one app target, a synchronized `App/` folder, the local package `Packages/AbapitKit`;
   - `MACOSX_DEPLOYMENT_TARGET = 27.0`, hardened runtime, `ENABLE_APP_SANDBOX = YES`;
   - the §3.6 concurrency settings;
   - `Config/Base.xcconfig` (ad-hoc), a gitignored `Config/Local.xcconfig` (Personal Team), and the
     two entitlement files from §3.9;
   - command-line builds go to `build/DerivedData.noindex`, so Spotlight and Siri don't index them.
3. **Package.** `Package.swift`, tools 6.2, `platforms: [.macOS("27.0")]`, every target from §3.1 as an
   empty module with one smoke test, and the dependency-edge test (§3.2).
4. **Process files.** `CLAUDE.md` (§7), `docs/FRAMEWORK.md`, failure-log README, `RULE-FEEDBACK.md`,
   domains README; `.claude/skills`, `agents` (retarget `gam-command-reviewer` as
   `abapit-write-reviewer`) and `hooks` (credential paths `*.pem`, `~/.config/abapit/**`,
   `~/.local/share/abapit/**`); a `.claude/settings.json` deny-list.
5. **CI.** `ci.yml` (hygiene, `xcode-27` macOS job, Linux fuzz container, `ci-ok`), `codeql.yml`,
   `scorecard.yml`, `dependabot.yml` (actions only). Plus `scripts/check_app.sh`, `check_text.py`,
   `screenshots.sh` and `test.sh`.
6. **Spike S1, sandbox + Keychain.** SwiftGamGui proved Personal Team + `keychain-access-groups`
   **without** the sandbox. Repeat it **with** `app-sandbox`, using a throwaway `swiftabapit-spike`
   item:
   - add a `kSecClassKey` P-256 item with `.userPresence`;
   - sign;
   - read again within the reuse window;
   - delete;
   - confirm the ad-hoc sandboxed build fails cleanly with -34018 and a "sign with your team"
     message.

   **Stop for the operator** (one build in Xcode, Touch ID). Write the result into §3.4 and §3.9.
7. **Spike S2, contracts.** Write `scripts/apple_contracts.py`. Generate `Contracts/apple/*.json` and
   `Tests/Fixtures/docc/`. Write a test that loads the manifest and asserts 57 Business and 11 School
   endpoints. Add the weekly drift workflow.
8. **Spike S3, parity generator.** Write `scripts/gen_fixtures.py` against abapit at a pinned commit
   (record it). Emit the §6.2 goldens.
9. **Spike S4, model availability.** Log `SystemLanguageModel.default.availability` once (DEBUG).

**Done when**:

- `xcodebuild build`/`test` and `swift test` pass from the CLI;
- CI is green, including `ci-ok`;
- `check_app.sh` passes for an ad-hoc build;
- S1's result is recorded;
- the manifest and goldens are committed;
- one review agent has read the S1 code.

### Phase 1: Apple core

**Status:** split in two for review size (2026-10-16). **1a** (package: Vault, Orgs, Wire, HTTPCore, JSONAPI,
AppleModels for devices/coverage/locks/services, AppleBusiness reads and probes, the strict AppleStub): on
branch `phase-1a-apple-core`. **1b** (the app: Devices, Find, inspector, services, minimal dashboard,
Settings with key import, CSV with the allowlist, the demo org, the acceptance pass): next. Live checks wait
for S1's team build.

**Owns:** `Vault/`, `HTTPCore/`, `JSONAPI/`, `AppleModels/` (device + MDM-service types),
`AppleBusiness/`, `TestSupport/AppleStub*`, `App/Screens/{Devices,DeviceInspector,MDMServices,Settings,Dashboard(stub)}`.

**Scope**:

- **Vault**: §3.4.1 import and storage, Mosyle generic-password items (for Phase 7), the 600 s
  session, `MemoryStore`, the OSStatus rule.
- **Org store**: `orgs.json` with the defect-14 fixes, client-ID uniqueness, abapit's slug rules.
- **HTTPCore**: all of §3.3.
- **Auth**: TokenBroker and the assertion (§3.4.2–3).
- **Reads**:
  - `orgDevices` (sparse fields for the list), a single device (all fields, including migration and
    `releasedFromOrgDateTime`);
  - AppleCare (new fields);
  - **activationLockStatus**;
  - assignedServer (full and linkage);
  - `mdmServers` (+ health fields) and `relationships/devices`.
- **Read probes** for every section, `limit=1` each.
- **UI**:
  - Devices table, Find (⌘L), Device inspector (ABM half), MDM services list with health, a minimal
    Dashboard;
  - Settings: add/edit/remove/Test/Permissions (read probes only);
  - CSV export with the allowlist and formula guard (golden bytes);
  - org switching (generation), the stale banner, truncation notices.
- **Demo**: the Apple demo org on AppleStub.
- **Stub**: the strict AppleStub (§6.3, token and device paths).
- **Acceptance pass**: covers the Phase 1 reads.

**Live checks (operator)**:

1. Import a real key. A check the operator runs finds no PEM header in the container, and the
   original file is untouched.
2. Mint a token.
3. The device count and a 20-serial sample match abapit for the same org.
4. **Assertion reuse** (§3.4.2).
5. **Rate measurement**: an Activation Lock fetch for 20 serials, and the 429 behaviour (record
   whether `Retry-After` appears).
6. A role-forbidden section reads "your role can't read this".

**Done when** all of the above hold, every stub is strict, and the review agent has read Vault and
the JWS code.

### Phase 2: Apple read parity and new reads

**Status:** not started.

**Owns:** `AppleModels/` (remaining types), `AppleBusiness/` reads, `Reports/{stats,audit}`,
`App/Screens/{People,Content,AppleMDM,Audit,Dashboard}`.

**Scope**:

- **People**: users (all attributes), **user detail**; user groups + members; org units +
  **members**.
- **Content**:
  - apps + **app detail**; packages + **package detail**;
  - blueprints (+ `include`, `limit[rel]`, and abapit's fallback when an include is rejected);
  - configurations (the detail shows `customSettingsValues` plist, pretty-printed; read-only built-in
    types shown typed).
- **Apple MDM**: the `mdmDevices` list + **`/details`** posture columns.
- **Audit**:
  - typed `AuditEvent` with all 50 types and typed `eventData*` payloads;
  - server-side `filter[type|actorId|subjectId]` and cursor paging;
  - views: Subscriptions & Purchases, Device Lifecycle (correct type names), **Access & Security**
    (new);
  - Device 360's ABM timeline uses `filter[subjectId]`.
- **Dashboard** (Swift Charts):
  - counts by family and status;
  - added per month (12 months);
  - per MDM service;
  - unassigned devices;
  - **services not connected in N days**;
  - recent audit events.
- School scope: sections gated per §2.4.

**Done when**:

- every Appendix B read row has a counterpart that matches the live org;
- contract tests decode every DocC example;
- the acceptance pass covers every read and reports zero unknown keys for known types (or lists them).

### Phase 3: history, reports, scheduled snapshots

**Status:** not started.

**Owns:** `History/`, `Reports/{coverage,fleetAge,activationLock,migration,diff}`,
`App/Screens/{Changes,Reports}`, `App/Scheduling/`.

**Scope**:

- **SnapshotStore** (SQLite3): abapit's schema + `schema_version` + `org_id`; foreign keys on; dir
  `0700`, file `0600`.
- **Import abapit history**: the operator picks `~/.local/share/abapit/history.sqlite` (the open
  panel shows hidden files). Open it read-only, copy rows, map client IDs to org IDs. **Export a
  copy** for sqlite3/Datasette.
- **Collectors per provider** (Apple now; Mosyle in Phase 7):
  - devices, mdm_servers, assignments, people, content, mdm_enrolled (+ details);
  - **AppleCare sweep** and **Activation Lock sweep** (§3.6);
  - per-resource errors recorded rather than aborting.
- **Diff** (golden parity) and the Changes screen.
- **Reports**:
  - coverage (with the new AppleCare fields);
  - fleet age;
  - **Activation Lock** (locked devices by `lockType`; `USER` locks flagged "blocks redeploy and
    release");
  - **MDM migration status** (capable / requested / started / failed, deadline countdown);
  - **MDM service health**.
  - Each has a CSV export.
- **Warm start** from the latest snapshot, with the banner.
- **Scheduled snapshots (D5)**:
  - the unattended read-only key (§3.4.4);
  - a login item through `SMAppService.mainApp`;
  - a `MenuBarExtra` (last snapshot, next run, Snapshot now);
  - a daily `NSBackgroundActivityScheduler`;
  - retention: keep N;
  - an opt-in change notification.

**Done when**:

- abapit's own `history.sqlite` imports and the Changes screen shows the same diff abapit shows for
  the same pair;
- reports match the goldens;
- a scheduled run completes with **no Touch ID prompt**, using only the read-only key;
- the review agent has read the unattended-key path.

### Phase 4: ChangeCore and device assignment

**Status:** not started. **Write-path design: stop for operator review of the `WireOperation` and
Guard shapes before implementing** (SwiftGamGui unattended-workflow rule).

**Owns:** `ChangeCore/`, `HTTPCore/{WireOperation,WriteTicket,send}`, `Planners/{assign,probes}`,
`AppleBusiness/AppleWriteBuilders.swift`, `App/ChangePreviewSheet.swift`, `App/Screens/{Assign,Activity,AuditLog}`.

**Scope**:

- **ChangeCore** (§3.8), ported from SwiftGamGui.
- **Audit**: AuditLog + audit screen + CSV.
- **Unfinished-write banner** and `.terminateLater`.
- **Assign/unassign**:
  - the planner (golden parity, including "already assigned" and "not assigned to this service"
    no-ops and unknown serials);
  - a precondition re-read through linkage or the server's device relationships;
  - a bounded activity tracker (status/subStatus);
  - `downloadUrl` opens in the browser.
- **Write probes** in one exemption file. They run only on a Permissions click, and a test guards
  that.
- **Source-scan tests** (§6.4).

**Done when**:

- **One adversarial review agent** tried, by running code, and failed to:
  - replay a preview after an org switch;
  - edit after preview;
  - double-confirm;
  - beat the TTL;
  - quit mid-write;
  - forge a ticket from the app target (must not compile);
  - make a draft execute;
  - send to a non-allowlisted host.
- The lid-close test confirms the TTL counts across sleep.
- After the operator's per-action yes, assign and unassign on a **throwaway device** succeed live. The
  audit digests match the previews, the activity reaches COMPLETED, and the README rows read
  **confirmed**.

### Phase 5: blueprint, configuration, MDM-service writes; profile validation

**Status:** not started.

**Owns:** `Planners/{blueprint,configuration,mdmService}`, `ProfileSchema/`,
`Contracts/device-management/`, `App/Screens/{BlueprintEdit,ConfigurationEdit,MDMServiceEdit}`.

**Scope**:

- **Blueprints**: create (name required; description optional, unlike abapit), update, delete;
  6-relationship add/remove through the planner (golden parity). Apple silently drops invalid IDs, so
  the precondition read verifies membership after the write.
- **Configurations** (`CUSTOM_SETTING`): create, update, delete. Filename must end `.mobileconfig`;
  a PATCH carries at least one field; platforms can be cleared; delete's blast radius = blueprints
  that reference it.
- **MDM services**:
  - create (name + certificate `{name, data(base64)}`, parsed with `SecCertificateCreateWithData` and
    shown before sending);
  - rename;
  - **certificate rotation**;
  - **`defaultProductFamilies`**;
  - `enableMdmDisownFlag`;
  - delete (blocked while devices are assigned; pre-check and explain).
- **ProfileSchema**: parse the plist (`PropertyListSerialization`); check `PayloadType`, key types and
  presence, and platform support against `configuredForPlatforms`; warn about supervised-only keys.
  Warnings don't block, but they appear in the preview.

**Done when** each write is confirmed live on scratch objects, the strict stubs reject every malformed
body shape, and the AirPlay-security example from Apple's docs produces the platform warning.

### Phase 6: MDM migration and release

**Status:** not started.

**Owns:** `Planners/{migration,release}`, `App/Screens/{Migration,Release}`.

**Scope**:

- **Migration**: `ASSIGN_DEVICES_WITH_MDM_MIGRATION_DEADLINE` (only for `isMdmMigrationCapable`
  devices; deadline ≤ 90 days, validated with the time zone shown), `UPDATE_MDM_MIGRATION_DEADLINE`
  and `CANCEL_MDM_MIGRATION`, on both scopes. Uses the Phase 3 migration report as its dashboard.
- **`RELEASE_DEVICES`** (Business only; D3):
  - a per-org switch, off by default;
  - on the never-list for drafts;
  - typed org name + device count;
  - blast radius: AppleCare in force, blueprints, Apple-MDM enrollment, and Activation Lock (fetch
    status first; **refuse while `lockType = USER`** unless the operator overrides per device).

**Done when** migration is confirmed live on a throwaway device. Release stays `not yet` until the
operator has a device they mean to release; a strict-stub test is the only coverage until then.

### Phase 7: Mosyle reads, Logs Stream, reconciliation, Device 360

**Status:** not started.

**Owns:** `Mosyle/`, `MosyleModels/`, `Reports/{reconcile,mosylePosture,timeline}`,
`History/{LogsStore,mosyleCollectors}`, `TestSupport/MosyleStub*`, `App/Screens/{Mosyle*,Reconciliation,Device360}`.

**Scope**:

- **Client** (§3.5): `MosyleSession`, envelope classification, pagination by total.
- **Devices** with the field allowlist (defect 1) and typed adapters (defect 19).
- **Users, user groups (+ members), device groups (+ `get_info` members and the compliance filter),
  custom device attributes (read), `/adminlogs`** (new).
- **Logs Stream drain** (defect 4) into `LogsStore`, with a CSV export and the compliance timestamp
  parser.
- **Reports**: OS breakdown, stale check-ins (golden parity), reconciliation (golden parity), and a
  device-group compliance view.
- **Device 360 merge** with an operator-chosen paired org.
- **Mosyle snapshot collectors** (defect 6).
- **Mosyle demo fleet.**

**Done when**:

- the acceptance pass is green on the live tenant;
- reconciliation numbers match abapit for the same org pair;
- the user and group counts match Mosyle's console (proving defect 2 is fixed);
- the redaction test passes;
- a drain on a live tenant loses no events across two pages (operator-run).

### Phase 8: Mosyle lost-device actions (D4)

**Status:** not started.

**Owns:** `Planners/lostMode`, `Mosyle/MosyleWriteBuilders.swift`, `App/Screens/LostDevice`.

**Scope**:

- **The flow**: pick a device (or a person, then their devices), then show eligibility:
  - iOS/iPadOS supervised only;
  - macOS gets "no MDM Lost Mode on Mac; use Find My or lock from Mosyle".
- **Actions** through ChangeCore:
  - **enable lost mode** (message required, phone, footnote);
  - **play sound**;
  - **request location**, then read back latitude/longitude through `list` + `specific_columns`,
    shown on a map snapshot with no external tile fetch (or as coordinates only);
  - **disable**.
- **Status polling** of `lostmode_status`. A `LOSTMODE_NOTENABLED` response is classified, not
  guessed.
- **Optional** `update_device` / `assign_device_user` if D4 includes them.

**Done when** each action is confirmed live on the operator's named test device.

### Phase 9: Assist, App Intents, Spotlight

**Status:** not started.

**Owns:** `Assist/`, `App/Intents/`.

**Scope**: §5.

**Done when**:

- every assisted flow passes with the model forced unavailable;
- the Evaluations suite reports field accuracy;
- the intent → executor isolation test passes;
- the read intents work from Siri and from `shortcuts run`;
- `check_app.sh` verifies the App Intents metadata and the phrase catalog.

### Phase 10: docs, distribution prep, abapit retirement

**Status:** not started.

- README: build from source (Xcode 27, Personal Team), the live-verification table, history import,
  and a migration note from abapit.
- Developer ID notarization stays deferred until the Developer Program is bought.
- abapit: final release, README pointer, archive.
- Close the open rows in §9.

---

## 9. Risks

1. **Apple rate limits are undocumented.** The third-party reports (about 20 GET/min, 10 POST/hour)
   would make a 1,000-device AppleCare or Activation Lock sweep take close to an hour. Mitigation: the
   adaptive limiter, sweeps only in background snapshots, the linkage-only endpoints, and Phase 1's
   measurement.
2. **The sandbox + Keychain combination** is unproven (SwiftGamGui runs unsandboxed). Phase 0 S1
   settles it. Fallback: sandbox off, with the entitlement check still exact. That is an operator
   decision.
3. **Touch ID friction** if Apple rejects assertion reuse. Mitigation: session reuse (D6) and the
   unattended read-only key for background work.
4. **Personal Team builds expire after 7 days**, and a team change forces re-import. Plan for it in
   the README and the "credentials missing" path.
5. **Mosyle contract uncertainty.** Page sizes, the `remove` key for device groups, `lock_device`'s
   path, `Retry-After` and the Logs Stream page size are unknown. Recorded fixtures and the acceptance
   pass resolve them; never trust Postman examples alone.
6. **Apple API drift.** Apple shipped 7 versions in 6 months. The drift job and `OpenEnum` absorb
   additive changes; breaking changes surface as contract-test failures.
7. **Model availability.** The spike saw `.modelNotReady`. Every flow has a no-model path.
8. **Two apps during the port.** abapit is frozen to fixes; parity goldens pin its behaviour.
9. **The agent sees UI only as images.** Mitigated by thin views, model tests, the screenshot harness
   and the demo org.
10. **App Shortcuts registration for source builds** is unverified (SwiftGamGui confirmed it through
    Shortcuts, but the spoken check is still open).

---

## Appendix A. Apple endpoint matrix

Business = `https://api-business.apple.com/v1/`, School = `https://api-school.apple.com/v1/`.

- `limit` max is 1000.
- Every GET accepts `fields[<type>]`.
- Errors return `ErrorResponse`.
- Doc slug: `developer.apple.com/documentation/applebusinessapi/<slug>`.

| Method and path | B | S | abapit | Phase |
|---|---|---|---|---|
| GET orgDevices; GET orgDevices/{id} | ✓ | ✓ | used | 1 |
| GET orgDevices/{id}/appleCareCoverage | ✓ | ✓ | used | 1 |
| GET orgDevices/{id}/activationLockStatus | ✓ | ✓ | **missing** | 1, 3 |
| GET orgDevices/{id}/assignedServer (404 when unassigned) | ✓ | ✓ | used | 1 |
| GET orgDevices/{id}/relationships/assignedServer | ✓ | ✓ | **missing** | 1 |
| GET mdmServers; GET mdmServers/{id}; GET …/relationships/devices | ✓ | ✓ | used | 1 |
| POST mdmServers; PATCH mdmServers/{id}; DELETE mdmServers/{id} | ✓ | — | used (PATCH: name only) | 5 |
| POST orgDeviceActivities: ASSIGN/UNASSIGN_DEVICES | ✓ | ✓ | used | 4 |
| POST orgDeviceActivities: ASSIGN_DEVICES_WITH_MDM_MIGRATION_DEADLINE, UPDATE_MDM_MIGRATION_DEADLINE, CANCEL_MDM_MIGRATION | ✓ | ✓ | **missing** | 6 |
| POST orgDeviceActivities: RELEASE_DEVICES | ✓ | — | **missing** | 6 |
| GET orgDeviceActivities/{id} | ✓ | ✓ | used | 4 |
| GET mdmDevices | ✓ | — | used | 2 |
| GET mdmDevices/{id}/details | ✓ | — | **missing** (abapit calls undocumented `mdmDevices/{id}`) | 2 |
| GET users; GET users/{id} | ✓ | — | used (`users/{id}` unused) | 2 |
| GET userGroups; GET userGroups/{id}; GET …/relationships/users | ✓ | — | used | 2 |
| GET organizationalUnits; GET …/{id}; GET …/relationships/users | ✓ | — | used (members unused) | 2 |
| GET apps; GET apps/{id} | ✓ | — | list only | 2 |
| GET packages; GET packages/{id} | ✓ | — | list only | 2 |
| GET blueprints (include, limit[rel]); GET blueprints/{id} | ✓ | — | used (no limit[rel]) | 2 |
| POST blueprints; PATCH/DELETE blueprints/{id} | ✓ | — | used | 5 |
| GET/POST/DELETE blueprints/{id}/relationships/{apps,configurations,packages,orgDevices,users,userGroups} (18) | ✓ | — | used | 2 (GET), 5 |
| GET configurations; GET configurations/{id} | ✓ | — | used | 2 |
| POST configurations; PATCH/DELETE configurations/{id} (CUSTOM_SETTING only) | ✓ | — | used | 5 |
| GET auditEvents (filter[startTimestamp], filter[endTimestamp] required; filter[type], filter[actorId], filter[subjectId], cursor) | ✓ | — | used (type only) | 2 |
| POST account.apple.com/auth/oauth2/token | ✓ | ✓ | used | 1 |

### Status codes

| Request | Codes |
|---|---|
| GET list | 200/400/401/403/429 |
| GET one | adds 404 |
| POST | 201/400/401/403/409/422/429 |
| PATCH | 200/400/401/403/404/409/422/429 |
| DELETE blueprint or configuration | 204/400/401/403/404/409/429 |
| DELETE mdmServer | 204/400/401/403/404/429 |
| Relationship POST/DELETE | 204/401/403/404/409/422/429 |

### Key enums

The full set is in `Contracts/apple/*.json`.

| Enum | Values |
|---|---|
| OrgDevice `status` | ASSIGNED, UNASSIGNED |
| `productFamily` | iPhone, iPad, Mac, AppleTV, Watch, Vision |
| `purchaseSourceType` | APPLE, RESELLER, MANUALLY_ADDED |
| Activity status | COMPLETED, IN_PROGRESS, STOPPED, FAILED |
| Activity subStatus | SUBMITTED, PRE_PROCESSING, PENDING, PROCESSING, POST_PROCESSING, STOPPING, COMPLETED_WITH_SUCCESS, COMPLETED_WITH_ERROR, COMPLETED_WITH_FAILURE, COMPLETED_POST_PROCESSING_FAILED |
| `lockType` | MDM, USER, NONE |
| AppleCare `status` | ACTIVE, INACTIVE |
| AppleCare `paymentType` | ABE_SUBSCRIPTION, PAID_UP_FRONT, SUBSCRIPTION, NONE |
| MdmServer `serverType` | MDM, APPLE_CONFIGURATOR, APPLE_MDM |
| MdmServer `status` | ACTIVE, INACTIVE, DELETED |
| User `status` | NEW, RELEASED, ACTIVE, DEACTIVATED, LOCKED, LOCKED_FOR_SHARED_IPAD |
| UserGroup `type` | STANDARD, SMART |
| BlueprintStatus | ACTIVE, TO_BE_DELETED |
| ConfigurationPlatform | PLATFORM_MACOS, PLATFORM_IOS (also covers iPadOS), PLATFORM_TVOS, PLATFORM_VISIONOS |
| SupportedOS | SUPPORTED_OS_{UNSPECIFIED, IOS, IPADOS, MACOS, TVOS, WATCHOS, VISIONOS} |
| AuditEventActorType | USER, API_USER, SYSTEM |
| Audit `outcome` | SUCCESS, FAILURE |
| ConfigurationType (23) | AIR_DROP, AIR_PRINT, APP_ACCESS, APPLE_INTELLIGENCE_SIRI, APPLICATION_LAYER_FIREWALL, AUTHENTICATION_SCREEN_LOCK, CERTIFICATE, CONFERENCE_ROOM_DISPLAY, CONTENT_CACHING, CUSTOM_PROFILE, CUSTOM_SETTING, DATA_MANAGEMENT, ENERGY_SAVER, FILE_VAULT, GATE_KEEPER, ICLOUD, LOGIN_WINDOW, MEDIA_MANAGEMENT, SOFTWARE_UPDATE, VPN, WEB_CLIP, WEB_FILTER, WIFI |

## Appendix B. abapit parity checklist

Routes are in `abapit/web/app.py`. **Retired** means L2/L8 removes the feature by design.

| abapit | Swift | Phase |
|---|---|---|
| `/` dashboard | Overview › Dashboard (+ service health) | 1–2 |
| `/devices`, `/find`, `/devices/{id}` (Device 360) | Devices table, Find ⌘L, inspector (ABM half in 1; Mosyle merge in 7) | 1, 7 |
| `/mdm-servers` list/detail/new/edit/delete | Devices › MDM services (read 1; writes 5) | 1, 5 |
| `/mdm-enrolled` list/detail | Devices › Apple MDM (with `/details`) | 2 |
| `/users`, `/user-groups[/{id}]`, `/org-units[/{id}]` | People (+ user detail, OU members) | 2 |
| `/apps`, `/packages` | Content (+ detail pages) | 2 |
| `/blueprints` list/detail/new/edit/delete/relationships | Content › Blueprints (read 2; writes 5) | 2, 5 |
| `/configurations` list/detail/new/edit/delete | Content › Configurations (read 2; writes 5) | 2, 5 |
| `/audit-events`, `/subscriptions`, `/device-lifecycle` | Activity › Audit, Subscriptions, Lifecycle, **Access & Security** | 2 |
| `/changes`, `/changes/snapshot` | Activity › Changes; Snapshot now | 3 |
| `/assign`, `/activities/{id}` | Devices › Assign; activity status | 4 |
| `/reports/coverage`, `/reports/fleet-age` | Reports (+ Activation Lock, Migration, Service health) | 3 |
| `/reports/mosyle-os-breakdown`, `/reports/mosyle-stale`, `/reports/reconciliation` | Reports › Mosyle posture, Reconciliation | 7 |
| `/device-groups`, `/mosyle-activity` | Mosyle › Device groups (+ members/compliance), Activity & Compliance (+ admin logs) | 7 |
| `/export/{resource}.csv` (all resources and reports) | `fileExporter` on every list and report | 1–7 |
| `/settings` add/edit/activate/delete/probe/test | Settings | 1 |
| `/refresh`, stale banner, warm start | Toolbar Refresh; banner; warm start | 1, 3 |
| CLI `export`, `changes --json`, `snapshot`, `probe`, `orgs` | App Intents via `shortcuts run`; scheduled snapshots | 3, 9 |
| CLI `serve`, `install-app`, `restart-app`, `uninstall-app`, `build_app.sh` | **Retired** (native app; login item in 3) | — |
| CLI `token`, `assign --yes` | **Retired** (L8: no bearer printing; writes only through the preview) | — |
| TrustedHost, cross-origin POST block, `Sec-Fetch-Site` checks | **Retired** (L2: no listener) | — |

## Appendix C. Mosyle Business operation matrix

Host `https://businessapi.mosyle.com/v1`, POST only. Confidence: OD = Mosyle official doc, PM = Postman,
LV = live, 3P = third party, G = guess.

| Path / operation | R/W | Risk | abapit | Port | Conf |
|---|---|---|---|---|---|
| /login | auth | — | used | 7 | OD, PM, LV |
| /devices `list` (os required; filters; `specific_columns`) | R | — | used (os/page only) | 7 | OD, PM, LV |
| /devices `list_custom_device_attributes` | R | — | — | 7 | OD |
| /users `list_users`; /usergroups `list_usergroup` | R | — | used (paging bug) | 7 | PM, OD |
| /devicegroups `list_devicegroup` (os required; object response) | R | — | used | 7 | PM, LV |
| /devicegroups `get_info` (members; compliance filter) | R | — | — | 7 | OD, PM |
| /adminlogs (no operation; date/user filters) | R | — | — | 7 | OD |
| logs host /login, /logsstream (consuming) | R* | consumes | used (page 1) | 7 | OD, LV |
| /lostmode `enable`, `disable`, `play_sound`, `request_location` | W | disruptive / benign | — | 8 (D4) | OD, PM |
| /devices `update_device`, `assign_device_user` | W | low | — | 8 if D4 | OD, PM |
| /devices `change_to_limbo`, `restart_devices`, `shutdown_devices` | W | disruptive | — | not built | OD, PM |
| /devices `wipe_devices`, `lock_device`, `enable/disable_activationlock` | W | **destructive** | — | not built | OD, PM (lock: PM path bug), 3P |
| /devices `create_custom_device_attributes`; /variables `save`/`delete`/`list` | W/R | low–medium | — | not built | OD, PM |
| /users `create_user`/`update_user`; /usergroups `create`/`update`/`insert_users`/`remove_users`; /devicegroups `update_devices` | W | medium | — | not built | PM |

## Appendix D. Apple first-party packages: verdicts

Releases as of 2026-10-16. Verdicts apply to this app (L5).

| Package | Verdict |
|---|---|
| swift-openapi-generator 1.14.1 / runtime 1.13.1 / urlsession 1.3.2 | **Avoid** (no official spec; hides request bytes) |
| swift-http-types 1.8.0, swift-http-structured-headers 1.7.0 | Avoid |
| swift-crypto 5.0.1 / `_CryptoExtras`, swift-asn1 1.7.3, swift-certificates 1.21.0 | Avoid (system CryptoKit + Security cover ES256, PEM and DER certificates) |
| swift-argument-parser 1.8.2 | Avoid (no CLI, L8) |
| swift-async-algorithms 1.1.7, swift-collections 1.7.3 | Avoid (hand-write debounce and ordered keys) |
| swift-log, swift-configuration, swift-system, swift-service-lifecycle, swift-nio, async-http-client | Avoid (os.Logger, URLSession, system frameworks) |
| swift-subprocess 1.0.2 | Avoid (no subprocesses) |
| swift-testing, swift-format | Use the **toolchain** copies; check in a `.swift-format` |
| apple/device-management `release` @ `09f249a0` (Release-v27.0) | **Use as vendored data** (Phase 5) |
| apple/apple-ads-platform-api-swift v1.109.0 | **Read as a reference** for Apple's own ES256 / client-credentials / single-flight token code; don't depend on it |
| apple/foundation-models-utilities 1.1.0-beta1 | Revisit after it leaves beta |

## Appendix E. SDK symbols checked on this Mac (2026-10-16)

Checked against `MacOSX27.0.sdk` (Xcode 27.0 27A266a, Swift 6.4).

| Area | Present |
|---|---|
| Observation | `Observations` (macOS 26) |
| SwiftData | `#Index`, `#Unique`, `HistoryDescriptor`, `fetchHistory` (macOS 15). Not used (L7) |
| SwiftUI | `Table`, `TableColumnCustomization`, `MenuBarExtra`, `inspector`, `searchable`, `ToolbarSpacer`, `alert(error:)`, `tableStyle` |
| Liquid Glass | `glassEffect(_:in:)`, `GlassEffectContainer` |
| Charts | `BarMark`, `SectorMark`, `LinePlot`, `AreaPlot`, `Chart3D` (macOS 26) |
| AppIntents | `IndexedEntity`, `IndexedEntityQuery`, `SnippetIntent`, `IntentModes`, `TransientAppEntity`, `UniqueAppEntityQuery`, `EntityPropertyQuery`, `URLRepresentableEntity`, `AppIntentsPackage`, `@ComputedProperty`/`@DeferredProperty` (with Spotlight `indexingKey`) |
| CoreSpotlight | `CSSearchableIndex.isIndexingAvailable` |
| ServiceManagement | `SMAppService` (`mainApp`, `loginItem(identifier:)`, `agent(plistName:)`) |
| Foundation | `NSBackgroundActivityScheduler` |
| Xcode 27 test frameworks | `Testing`, `XCTest`, `XCUIAutomation`, `AppIntentsTesting`, `Evaluations`, `_Testing_AppKit` |

The 2026-10-08 draft's Appendix A also verified FoundationModels, AppIntents modes, Security, CryptoKit
and LocalAuthentication symbols; Phase 0 re-runs that list.

**Not found or not verified:**

- `Data.Base64EncodingOptions.base64URLAlphabet` (not found by header grep; the fallback is in §3.4.2);
- `ProgressManager`;
- Shortcuts automations on macOS;
- `.requiresLocalDeviceAuthentication` behaviour on a Mac.

## Appendix F. Sources (fetched 2026-10-16)

**Apple API documentation and announcements**

- Apple Business API docs: https://developer.apple.com/documentation/applebusinessapi. The old
  `applebusinessmanagerapi` path returns 404.
- Apple School Manager API: https://developer.apple.com/documentation/appleschoolmanagerapi
- Changelog: https://developer.apple.com/documentation/apple-school-and-business-manager-api/apple-school-manager-and-apple-business-api-changelog
- OAuth: https://developer.apple.com/documentation/apple-school-and-business-manager-api/implementing-oauth-for-the-apple-school-manager-and-apple-business-api
- Permissions: https://support.apple.com/guide/business/axm33189f66a/web
- Release notes: https://support.apple.com/guide/business/release-notes-axm357705f83/web
- WWDC26 session 206: https://developer.apple.com/videos/play/wwdc2026/206
- Apple Business announcement: https://www.apple.com/nz/newsroom/2026/03/introducing-apple-business/

**Rate limits (third party)**

- https://pkg.go.dev/github.com/neilmartin83/terraform-provider-axm
- https://pkg.go.dev/github.com/hitoshiichikawa/apple-business-go

**Apple open source**

- https://github.com/apple/device-management (`release` branch)
- https://github.com/apple/apple-ads-platform-api-swift
- https://github.com/apple/swift-openapi-generator

**Mosyle**

- Postman collection: https://mybusiness.mosyle.com/downloads/api-docs/API%20Business.json
- Mosyle's in-console API doc, as captured in the 2026-06-18 abapit session
- Third-party clients: https://github.com/grokability/snipe-it/issues/19790, https://github.com/SMillerDev/terraform-provider-mosyle, JasonRobertson/PS-Mosyle, christovic/mosyle2snipe
- Integration docs: https://support.1password.com/saas-manager-mosyle/, https://docs.axonius.com/docs/mosyle

**Local reference code**

- SwiftGamGui at `bfdb494`: `CLAUDE.md`, `docs/plans/2026-10-08-native-gamgui.md`, `docs/plans/2026-10-09-write-path-options.md`, `docs/domains/secrets.md`, `docs/failure-log/`
- abapit at `9875ee7`
