# Write path: the shapes Phase 4 builds (2026-10-16)

**Status: PROPOSED — needs the operator's review before any write code** (plan §8, Phase 4: "stop for
operator review of the `WireOperation` and Guard shapes before implementing"). Nothing here is built.
Questions for the operator are at the end; the bold answer is the recommendation.

The write path is ported from SwiftGamGui's ChangeCore (live-proven), generalized from a GAM argv to an
HTTP request, plus plan D10 (the operator's safe-actions list). Invariants it serves: **#1** one write path
(the held bytes are what runs), **#9** a model or Siri only drafts (except D10's list), **#7** bounded,
**#3** nothing secret in the audit.

## 1. The types

```swift
// Wire (pure): what a write sends. Built only by planners and *WriteBuilders (package init).
public struct WireOperation: Sendable, Hashable {
    public let kind: OperationKind          // .assignDevices, .unassignDevices, .createBlueprint, …, .mosylePlaySound
    public let host: APIHost
    public let method: HTTPMethod           // POST, PATCH, DELETE
    public let path: String                 // "/v1/orgDeviceActivities"
    public let template: String             // for logs: "/v1/blueprints/{id}/relationships/apps"
    public let contentType: String?         // "application/json"
    public let body: Data?                  // the exact bytes sent
    public let targets: [String]            // canonical IDs: serials, a blueprint id, Mosyle UDIDs
    package init(...)
}

public enum OperationKind: String, Sendable, CaseIterable {
    case assignDevices, unassignDevices, assignWithMigrationDeadline, updateMigrationDeadline, cancelMigration,
         releaseDevices, createBlueprint, updateBlueprint, deleteBlueprint, addToBlueprint, removeFromBlueprint,
         createConfiguration, updateConfiguration, deleteConfiguration, createService, updateService, deleteService,
         rotateServiceCertificate, mosyleLostModeEnable, mosyleLostModeDisable, mosylePlaySound, mosyleRequestLocation
    public var minimumRisk: Risk { … }      // deletes and release: .destructive; lost mode: .disruptive; else .low
    public var draftable: Bool { … }        // false: releaseDevices, every delete (plan §3.8 never-list)
}

// HTTPCore: the one door. package; only Executor names WriteTicket (SourceScanTests).
package struct WriteTicket: Sendable { package init(digest: String) }
package func send(_ operation: WireOperation, ticket: WriteTicket, authorizer: any Authorizer) async throws -> HTTPResponse

// Planners (pure): what a planner returns. The preview shows all of it.
public struct Plan: Sendable {
    public let changes: [Change]            // what will happen, per target, in words
    public let noOps: [NoOp]                // "already assigned to this service"
    public let unknowns: [String]           // serials Apple doesn't know
    public let blastRadius: [String]        // "3 blueprints reference this configuration"
    public let operations: [WireOperation]  // one per request (assign: one activity for up to 1000 serials)
    public let preconditions: [Precondition]
}

public enum Precondition: Sendable, Hashable {
    case deviceAssigned(serial: String, to: String?)          // nil: unassigned
    case blueprintHas(blueprint: String, relationship: String, ids: Set<String>)
    case serviceExists(id: String), serviceHasNoDevices(id: String)
    case notActivationLockedByUser(serial: String)            // release
    case mosyleDeviceSupervised(udid: String)                 // lost mode
}
```

**Auth headers are added at send time and are not part of the digest**: the digest is SHA-256 over each
operation's method, host, path, content type and body bytes, separated, in order.

## 2. Preview, confirm, run

```swift
public struct HeldPreview: Sendable, Identifiable {
    public let id: UUID
    public let plan: Plan
    public let org: String
    public let generation: Int
    public let origin: Origin               // .form, .siri, .model
    public let digest: String
    public let decision: Guard.Decision     // what the confirm must ask for
    let createdAt: ContinuousClock.Instant
    public var needsConfirmClick: Bool      // origin != .form || risk ≥ .disruptive || plan is bulk
}

public struct OperatorConfirmation: Sendable {   // made ONLY in App/ChangePreviewSheet.swift
    public var confirmed: Bool
    public var typedName: String             // deletes: the canonical name
    public var typedCount: String            // more than 25 targets: the count
    public var typedOrgName: String          // RELEASE_DEVICES: the org's name (and the count)
    public var typedDeviceName: String       // lost mode: the device's name
}

public actor Executor {
    public func preview(_ plan: Plan, org: String, origin: Origin) async -> Result<HeldPreview, PreviewRefusal>
    public func run(_ preview: HeldPreview, confirmation: OperatorConfirmation) async -> RunOutcome
    public func run(_ preview: HeldPreview, standing: StandingApproval) async -> RunOutcome     // D10 only
    public func discard(_ id: UUID)
}
```

**The Guard runs inside `run`, in this order** (plan §3.8), and the first that fails refuses with words:

1. single use (taken out of the held set before any await);
2. the org and generation still current;
3. the 15-minute TTL, on `ContinuousClock` (counts sleep);
4. capability: the last write probe for this kind isn't `forbidden`;
5. the typed confirmation (or, for D10, the standing approval's rules below);
6. no other write in flight for any of the same targets;
7. the bulk cap for the kind (assignment: 1000 serials; Apple takes arrays);
8. **re-validation reads** of every precondition, just before sending; a changed one refuses with
   "what the preview showed has changed — preview again", never a silent re-plan;
9. then, per operation: a **begin** audit record (fsynced) → `send(_:ticket:)` with the held bytes → an
   **end** record. No begin record, no send.

Writes run one at a time app-wide (the executor's write lock). Writes are never retried except on 429
(Apple rejects those before processing).

## 3. D10: the safe-actions list (new since the plan)

The operator chose: a model may run, without the preview click, a fixed set of single-device actions,
off by default and switched on per org in Settings.

```swift
/// Made ONLY by the Settings screen's switch (SourceScanTests), held by the app, handed to the executor with
/// a model- or Siri-origin preview. It names the org it was granted for.
public struct StandingApproval: Sendable { let org: String; let grantedAt: Date }
```

The executor accepts a `StandingApproval` only when **all** hold (one `ExecutorTests` case each):

- the preview's org is the approval's org, and the org's switch is still on (read from `orgs.json` at run time);
- every operation's kind is on the list: `mosylePlaySound`, `mosyleRequestLocation`, or `assignDevices`
  with exactly one serial;
- exactly one target in total;
- the preview's origin is `.model` or `.siri` (a form always shows the preview);
- the read-back was shown: the app spoke or displayed "Playing a sound on Avery's iPad" before calling `run`
  (the run takes the read-back text and audits it);
- every Guard step above except 5 still applies (TTL, generation, preconditions, audit).

**Undo:** an assignment run from the list records the device's previous service in its end record; the
status view offers "Assign it back", which is a new preview (a form, so it shows).

Never on the list, whatever the switch: release, deletes, wipes, locks, lost mode, migration, anything bulk.

## 4. Audit

`Application Support/abapit/audit/audit.jsonl`, `0600`, `O_NOFOLLOW | O_APPEND`, rolled at 16 MiB keeping 10
(SwiftGamGui's `AuditLog`, reader included). Typed fields only, never a body or a header:

`ts, org, connector (apple_business | apple_school | mosyle), kind, targets, digest, origin, approval
(confirmed | standing), phase (begin | end), http_status, apple_code, mosyle_status, activity_id,
read_back (D10 only), previous_service (D10 assignment only)`.

An unmatched begin record shows "outcome unknown — verify" at launch; the operator marks it checked.

## 5. Async outcomes and quitting

- Apple activities: polled every 5 s with backoff, at most 30 minutes, then "check later"; the status and
  sub-status go into the end record and a per-write status view. A `downloadUrl` opens in the browser.
- Mosyle lost mode: `lostmode_status` polled through `list` + `specific_columns`, bounded.
- Quitting while a send is in flight: `.terminateLater` until it ends; a quit that can't wait leaves the
  begin record unmatched (outcome unknown).

## 6. What the tests prove (Phase 4's "done when")

The adversarial review tries, by running code, and must fail to: replay a preview after an org switch;
edit after preview; double-confirm; beat the TTL (and across sleep); quit mid-write; forge a ticket from the
app target (must not compile); make a draft execute without a click outside D10's rules; run a D10 action
for another org, a second target, a non-listed kind or with the switch off; send to a non-allowlisted host.

## Questions for the operator

1. **The shapes above** (WireOperation, Plan with preconditions, the Guard order, the audit fields):
   **approve as written**, or change?
2. **D10's read-back:** spoken by Siri / shown in the app before the action runs, then run without a click —
   **yes**, or should the app also wait N seconds with a Cancel button?
3. **D10 assignment undo:** "Assign it back" as a new form preview — **yes**?
4. **The bulk cap for assignment**: **1000 serials per confirm** (Apple's array limit), or lower?
5. **Typed confirmation for assignment above 25 devices**: **type the count** (as SwiftGamGui), or a click?
