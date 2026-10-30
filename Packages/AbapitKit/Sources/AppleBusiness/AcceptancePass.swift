import AppleModels
import Foundation
import HTTPCore
import JSONAPI

/// The read-only acceptance pass (plan §7): every read this phase makes, against the org, reporting per
/// resource whether it ran and fully succeeded, how many items, and which attribute names and enum values this
/// version doesn't know. It reports Apple's field names and enum values (each only when it is a word), statuses, counts,
/// error codes (only when code-shaped) and documented parameter names, and this app's own words, never an item's data
/// and never Apple's `detail` prose (which may echo an identifier), so its output can be pasted into an issue.
public struct AcceptanceReport: Sendable, Equatable {
    /// How one check went. Only `.ok` is a read that ran and fully succeeded (Phase 1b review M5: with `orgDevices`
    /// forbidden the five per-device lines printed "ok … 0", and a list cut at the page cap printed "ok").
    public enum Status: Sendable, Equatable, CustomStringConvertible {
        case ok
        /// Stopped with more to come: the page cap cut the list (invariant 8), or the list it walks was itself cut short.
        /// The line's count is what was read; its note says what cut it.
        case truncated
        case forbidden
        /// Never sent: the pass was cancelled, or the read it needs failed or found nothing to read.
        case skipped(String)
        /// `error <status>`: the HTTP status or the failure's kind (`error 500`, `error transport -1009`), never prose.
        case error(String)

        public var description: String {
            switch self {
            case .ok: "ok"
            case .truncated: "truncated"
            case .forbidden: "forbidden"
            case .skipped(let why): "skipped: \(why)"
            case .error(let status): status
            }
        }
    }

    public struct Line: Sendable, Equatable {
        public let resource: String
        public let status: Status
        /// Items read, up to where the check ended; nil when nothing was sent (skipped) or nothing is counted (a probe).
        public let count: Int?
        /// Attribute names this version doesn't read, keys inside the objects it reads (`phoneNumbers.isPrimary`), and
        /// `field=value`s it doesn't know, each name and value as `acceptanceWord` shows it.
        public let unknownKeys: [String]
        public let unknownValues: [String]
        /// An audit payload's fields its type doesn't document (`AuditEventPayload.unreadFields`) and keys inside its role
        /// locations (`accountRoleLocationList.scope`), as `acceptanceWord` shows them.
        public let unknownPayloadKeys: [String]
        /// What was cut, where a loop stopped, Apple's error `code` (only when code-shaped) and `source.parameter` (only a
        /// documented one), the token endpoint's code, this app's words for a malformed answer, the Vault's guidance.
        /// Never Apple's `detail`.
        public let note: String?

        public var ok: Bool { status == .ok }
    }

    public let lines: [Line]

    public var text: String {
        lines.map { line in
            var parts = ["\(line.resource): \(line.status)" + (line.count.map { $0 == 1 ? ", 1 item" : ", \($0) items" } ?? "")]
            if !line.unknownKeys.isEmpty { parts.append("unknown keys \(line.unknownKeys.joined(separator: ", "))") }
            if !line.unknownValues.isEmpty { parts.append("unknown values \(line.unknownValues.joined(separator: ", "))") }
            if !line.unknownPayloadKeys.isEmpty { parts.append("unknown payload keys \(line.unknownPayloadKeys.joined(separator: ", "))") }
            if let note = line.note { parts.append(note) }
            return parts.joined(separator: " · ")
        }.joined(separator: "\n")
    }
}

extension AppleClient {
    /// The devices sampled one by one unless asked otherwise, and the most ever sampled: each costs five reads, so a
    /// caller's number can't turn the pass into a sweep (invariant 7; Phase 1b review: the sample was unbounded).
    public static let acceptanceSample = 5, acceptanceSampleLimit = 20

    /// Runs every read: Phase 1's device list, the services and their device lists, and for each sampled device the
    /// single device, its AppleCare, its Activation Lock and its assigned service; then each Business-only list with one
    /// item of each read alone (`businessChecks`); then the probes.
    public func acceptancePass(sample: Int = AppleClient.acceptanceSample) async -> AcceptanceReport {
        let scope = scope
        var lines: [AcceptanceReport.Line] = []
        var devices: [OrgDevice] = []
        let deviceList = await Self.check("orgDevices") { found in
            for try await page in self.devices() {
                devices += try Self.typed(page.items)
                found.count = devices.count
                found.cut(page)
            }
            found.keys = Set(devices.flatMap(\.unreadAttributes))
            for device in devices {
                found.unknown("productFamily", device.productFamily)
                found.unknown("status", device.status)
                found.unknown("purchaseSourceType", device.purchaseSourceType)
                found.unknown("mdmMigrationStatus", device.migrationStatus)
            }
        }
        lines.append(deviceList)
        var services: [MDMService] = []
        let serviceList = await Self.check("mdmServers") { found in
            for try await page in self.services() {
                services += try Self.typed(page.items)
                found.count = services.count
                found.cut(page)
            }
            found.keys = Set(services.flatMap(\.unreadAttributes))
            for service in services {
                found.unknown("serverType", service.type)
                found.unknown("status", service.status)
                for family in service.defaultProductFamilies { found.unknown("defaultProductFamilies", family) }
            }
        }
        lines.append(serviceList)
        let noService = services.isEmpty ? Self.none("service to read", serviceList) : nil
        // The services' own lists cover only the services that list read: when it stopped short, so does this line
        // (verifier round 1: it read `ok` over the 1000 services read before a 500).
        let partial = serviceList.status == .ok ? nil : "covers only the \(services.count) services mdmServers read (\(serviceList.status))"
        lines.append(await Self.check("mdmServers/{id}/relationships/devices", unless: noService) { found in
            var cut = 0
            for (index, service) in services.enumerated() {
                try found.at("service", index, of: services.count)
                // The pages themselves, as for coverage, not `serviceDeviceIDs(_:)`'s ids: each linkage's type is checked.
                guard let read = AppleRead.serviceDevices(scope, id: service.id) else { throw Self.unsafeID }
                for try await page in self.pages(read).map(OrgDevice.init) {
                    found.count += try Self.typed(page.items).count
                    if page.truncated { cut += 1 }
                }
                // A cancelled `for try await` ends without throwing: stop at this service, not after sending the rest.
                try Task.checkCancellation()
            }
            found.truncation = [cut > 0 ? "\(cut) of \(services.count) services' lists stopped at the page cap" : nil, partial]
                .compactMap { $0 }.joined(separator: " · ").nonEmpty
        })

        let sampled = Array(devices.prefix(min(max(sample, 0), Self.acceptanceSampleLimit)))
        let unsampled = devices.isEmpty ? Self.none("device to sample", deviceList)
            : sampled.isEmpty ? "no device to sample (sample size \(sample))" : nil
        lines.append(await Self.check("orgDevices/{id}", unless: unsampled) { found in
            for (index, device) in sampled.enumerated() {
                try found.at("device", index, of: sampled.count)
                let single = try await self.device(Self.sendable(device.id))
                found.keys.formUnion(try Self.typed([single], asked: device.id)[0].unreadAttributes)
                found.count += 1
            }
        })
        lines.append(await Self.check("orgDevices/{id}/appleCareCoverage", unless: unsampled) { found in
            var rows: [AppleCareCoverage] = [], cut = 0
            for (index, device) in sampled.enumerated() {
                try found.at("device", index, of: sampled.count)
                // The pages themselves, not `appleCare(_:)`'s whole list: a coverage list cut at the page cap is said.
                guard let read = AppleRead.appleCare(scope, serial: device.id) else { throw Self.unsafeID }
                for try await page in self.pages(read).map(AppleCareCoverage.init) {
                    rows += try Self.typed(page.items)
                    found.count = rows.count
                    if page.truncated { cut += 1 }
                }
                // As for the services: stop at this device.
                try Task.checkCancellation()
            }
            if cut > 0 { found.truncation = "\(cut) of \(sampled.count) devices' coverage stopped at the page cap" }
            found.keys = Set(rows.flatMap(\.unreadAttributes))
            for row in rows {
                found.unknown("status", row.status)
                found.unknown("paymentType", row.paymentType)
            }
        })
        lines.append(await Self.check("orgDevices/{id}/activationLockStatus", unless: unsampled) { found in
            for (index, device) in sampled.enumerated() {
                try found.at("device", index, of: sampled.count)
                let lock = try await Self.typed([self.activationLock(Self.sendable(device.id))])[0]
                found.keys.formUnion(lock.unreadAttributes)
                found.unknown("lockType", lock.lockType)
                found.count += 1
            }
        })
        lines.append(await Self.check("orgDevices/{id}/assignedServer", unless: unsampled) { found in
            var unassigned = 0
            for (index, device) in sampled.enumerated() {
                try found.at("device", index, of: sampled.count)
                if try await self.assignedService(Self.sendable(device.id)) == nil { unassigned += 1 }
                found.count += 1
            }
            found.note = "\(unassigned) of \(sampled.count) unassigned"
        })
        lines.append(await Self.check("orgDevices/{id}/relationships/assignedServer", unless: unsampled) { found in
            var unassigned = 0
            for (index, device) in sampled.enumerated() {
                try found.at("device", index, of: sampled.count)
                if try await self.assignedServiceID(Self.sendable(device.id)) == nil { unassigned += 1 }
                found.count += 1
            }
            found.note = "\(unassigned) of \(sampled.count) unassigned"
        })
        // The probes as checks too: a failure in the same words as the reads (`error transport -1005`, not a bare `error`),
        // a 200 that isn't a list is malformed, and a cancelled pass sends none.
        let now = Date()
        lines += await businessChecks(now: now)
        for section in probedSections {
            lines.append(await Self.check("probe \(section.rawValue)", counted: false) { _ in try await self.probe(section, now: now) })
        }
        return AcceptanceReport(lines: lines)
    }

    /// Each Business-only list, whole, with what this version doesn't know of its items; then the first item of each read
    /// alone (a user; a group and its members; an org unit and its members; an app; a package; a blueprint with every
    /// relationship included, and each relationship's own list; a configuration, a custom setting when there is one; an
    /// Apple-managed device's details), and the last day's audit events, cursor by cursor. A School org has none of these:
    /// each line says so, and nothing is sent.
    private func businessChecks(now: Date) async -> [AcceptanceReport.Line] {
        let school = isBusiness ? nil : "not in Apple School Manager's API"
        var lines: [AcceptanceReport.Line] = []
        let users = await listCheck("users", unless: school, { self.users() }) { user, found in
            found.unknown("status", user.status)
            for phone in user.phoneNumbers ?? [] { found.unknown("phoneNumbers.type", phone.type) }
        }
        lines.append(users.line)
        lines.append(await detailCheck("users/{id}", users, "user", unless: school, { try await self.user($0) }) { user, found in
            found.unknown("status", user.status)
        })
        let groups = await listCheck("userGroups", unless: school, { self.userGroups() }) { group, found in
            found.unknown("type", group.type)
            found.unknown("status", group.status)
        }
        lines.append(groups.line)
        lines.append(await detailCheck("userGroups/{id}", groups, "user group", unless: school, { try await self.userGroup($0) }))
        lines.append(await memberCheck("userGroups/{id}/relationships/users", groups, "user group", unless: school) { self.userGroupMemberIDs($0) })
        let units = await listCheck("organizationalUnits", unless: school, { self.organizationalUnits() })
        lines.append(units.line)
        lines.append(await detailCheck("organizationalUnits/{id}", units, "org unit", unless: school, { try await self.organizationalUnit($0) }))
        lines.append(await memberCheck("organizationalUnits/{id}/relationships/users", units, "org unit", unless: school) {
            self.organizationalUnitMemberIDs($0)
        })
        let apps = await listCheck("apps", unless: school, { self.apps() }) { app, found in
            for os in app.supportedOS ?? [] { found.unknown("supportedOS", os) }
        }
        lines.append(apps.line)
        lines.append(await detailCheck("apps/{id}", apps, "app", unless: school, { try await self.app($0) }))
        let packages = await listCheck("packages", unless: school, { self.packages() })
        lines.append(packages.line)
        lines.append(await detailCheck("packages/{id}", packages, "package", unless: school, { try await self.package($0) }))
        let blueprints = await listCheck("blueprints", unless: school, { self.blueprints() }) { blueprint, found in
            found.unknown("status", blueprint.status)
        }
        lines.append(blueprints.line)
        lines.append(await blueprintCheck(blueprints, unless: school))
        for relationship in Blueprint.Relationship.allCases {
            lines.append(await memberCheck("blueprints/{id}/relationships/\(relationship.rawValue)", blueprints, "blueprint", unless: school) {
                self.blueprintMemberIDs($0, relationship)
            })
        }
        let configurations = await listCheck("configurations", unless: school, { self.configurations() }) { configuration, found in
            found.unknown("type", configuration.type)
            for platform in configuration.platforms ?? [] { found.unknown("configuredForPlatforms", platform) }
        }
        lines.append(configurations.line)
        // A custom setting's when there is one: only it carries a profile.
        let custom = configurations.items.first { $0.type?.known == .customSetting }
        let sampled = (line: configurations.line, items: custom.map { [$0] } ?? configurations.items)
        lines.append(await detailCheck("configurations/{id}", sampled, "configuration", unless: school, { try await self.configuration($0) }) {
            configuration, found in found.unknown("type", configuration.type)
        })
        let devices = await listCheck("mdmDevices", unless: school, { self.mdmDevices() }) { device, found in
            found.unknown("productFamily", device.productFamily)
        }
        lines.append(devices.line)
        // The details' id isn't checked against the device's: Apple documents neither, and gives no example.
        lines.append(await detailCheck("mdmDevices/{id}/details", devices, "Apple-managed device", unless: school, asked: false,
                                       { try await self.mdmDeviceDetails($0) }) { detail, found in
            found.unknown("deviceLockStatus", detail.lockStatus)
            found.unknown("deviceEraseStatus", detail.eraseStatus)
            found.unknown("lostModeStatus", detail.lostModeStatus)
        })
        lines.append(await Self.check("auditEvents", unless: school) { found in
            var events: [AuditEvent] = []
            for try await page in self.auditEvents(try AuditQuery.last(days: 1, now: now)) {
                events += try Self.typed(page.items)
                found.count = events.count
                found.cut(page)
            }
            found.keys = Set(events.flatMap(\.unreadAttributes))
            found.payloadKeys = Set(events.flatMap { $0.payload?.unreadFields ?? [] })
            found.unread(events.flatMap { $0.payload?.unreadNested ?? [] }, payload: true)
            for event in events {
                found.unknown("type", event.type)
                found.unknown("category", event.category)
                found.unknown("actorType", event.actorType)
                found.unknown("subjectType", event.subjectType)
                found.unknown("outcome", event.outcome)
                found.unknown("purchaseSourceType", event.payload?.purchaseSourceType)
                found.unknown("releaseEntityType", event.payload?.releaseEntityType)
                found.unknown("protocol", event.payload?.idpProtocol)
                found.unknown("vendorName", event.payload?.vendorName)
            }
            // Where a payload wasn't, in this app's words with a count: a named key that missed read `ok` with its payload
            // unread and nothing said (Phase 2a review M1).
            let problems = AuditEvent.PayloadProblem.allCases.compactMap { problem -> String? in
                let count = events.count { $0.payloadProblems.contains(problem) }
                return count == 0 ? nil : "\(problem.rawValue) in \(count) event\(count == 1 ? "" : "s")"
            }
            found.note = (problems + ["the last day"]).joined(separator: " · ")
        })
        return lines
    }

    /// A list's line and its items: every page, each item of `View`'s type, what the page cap cut, and the attribute names
    /// and enum values (`values`) this version doesn't know. The stream is made only when the check runs: making one sends.
    private func listCheck<View: ResourceView>(_ resource: String, unless skip: String?, _ stream: () -> AsyncThrowingStream<Page<View>, any Error>,
                                               values: (View, inout Found) -> Void = { _, _ in }) async -> (line: AcceptanceReport.Line, items: [View]) {
        var items: [View] = []
        let line = await Self.check(resource, unless: skip) { found in
            for try await page in stream() {
                items += try Self.typed(page.items)
                found.count = items.count
                found.cut(page)
            }
            found.keys = Set(items.flatMap(\.unreadAttributes))
            found.unread(items.flatMap(\.unreadNested))
            for item in items { values(item, &found) }
        }
        return (line, items)
    }

    /// The first of a list's items read alone, by its id: the item asked for (`asked`, unless Apple's id for the answer
    /// isn't documented as the same), of `View`'s type, with what this version doesn't know of it. `View` is the list's own
    /// type but for an Apple-managed device, whose details are another resource.
    private func detailCheck<Item: ResourceView, View: ResourceView>(_ resource: String, _ list: (line: AcceptanceReport.Line, items: [Item]), _ what: String,
                                                 unless skip: String?, asked: Bool = true, _ read: (String) async throws -> View,
                                                 values: (View, inout Found) -> Void = { _, _ in }) async -> AcceptanceReport.Line {
        await Self.check(resource, unless: skip ?? (list.items.isEmpty ? Self.none("\(what) to read", list.line) : nil)) { found in
            let id = list.items[0].id
            let item = try Self.typed([await read(Self.sendable(id))], asked: asked ? id : nil)[0]
            found.count = 1
            found.keys = Set(item.unreadAttributes)
            found.unread(item.unreadNested)
            values(item, &found)
        }
    }

    /// The first of a list's items' members, every page: linkages of the members' type (the client checks each).
    private func memberCheck<View: ResourceView>(_ resource: String, _ list: (line: AcceptanceReport.Line, items: [View]), _ what: String,
                                                 unless skip: String?, _ members: (String) -> AsyncThrowingStream<Page<String>, any Error>)
        async -> AcceptanceReport.Line {
        await Self.check(resource, unless: skip ?? (list.items.isEmpty ? Self.none("\(what) to read", list.line) : nil)) { found in
            for try await page in members(try Self.sendable(list.items[0].id)) {
                found.count += page.items.count
                found.cut(page)
            }
        }
    }

    /// The first blueprint with every relationship included. When Apple refused the include and the blueprint was read
    /// without it, the line is that refusal's status, never `ok`: its members weren't read (invariant 8). A relationship the
    /// include's limit cut, or one Apple didn't list, is `truncated`.
    private func blueprintCheck(_ list: (line: AcceptanceReport.Line, items: [Blueprint]), unless skip: String?) async -> AcceptanceReport.Line {
        await Self.check("blueprints/{id}", unless: skip ?? (list.items.isEmpty ? Self.none("blueprint to read", list.line) : nil)) { found in
            let id = list.items[0].id
            let read = try await self.blueprint(Self.sendable(id), include: Set(Blueprint.Relationship.allCases))
            let blueprint = try Self.typed([read.blueprint], asked: id)[0]
            found.count = 1
            found.keys = Set(blueprint.unreadAttributes)
            found.unknown("status", blueprint.status)
            if let refused = read.includeRefused {
                let failed = Self.acceptanceFailure(refused)
                found.status = failed.status
                found.note = ["the include was refused, so the blueprint was read without its members", failed.note].compactMap { $0 }.joined(separator: " · ")
                return
            }
            let all = Blueprint.Relationship.allCases
            let cut = all.filter { read.related[$0]?.isTruncated == true }.map(\.rawValue), unlisted = all.filter { read.related[$0] == nil }.map(\.rawValue)
            found.truncation = [cut.isEmpty ? nil : "\(cut.joined(separator: ", ")) cut at the include's limit",
                                unlisted.isEmpty ? nil : "\(unlisted.joined(separator: ", ")) not listed"].compactMap { $0 }.joined(separator: " · ").nonEmpty
            found.note = all.map { "\($0.rawValue) \(read.related[$0]?.linkages.count ?? 0)" }.joined(separator: ", ")
        }
    }

    /// What a check found so far: kept when it fails part-way, so its line says how far it got.
    private struct Found {
        var count = 0
        var keys: Set<String> = []
        var payloadKeys: Set<String> = []
        /// The status a read that returned says, when not `ok` or `truncated`: a blueprint read again without its include.
        var status: AcceptanceReport.Status?
        /// `field=value`s as the text shows them; only `unknown(_:_:)` adds one.
        private(set) var values: Set<String> = []
        /// What the page cap cut, in counts; when set, the check is `.truncated`.
        var truncation: String?
        /// Where a loop is ("at device 3 of 5"): said only if it fails there.
        var position: String?
        /// Counts said on success ("1 of 4 unassigned").
        var note: String?

        /// On to a loop's next item: where the line says it stopped if it fails there, and nothing more is sent once the
        /// pass is cancelled (verifier round 2: over a transport that answers anyway, as the stub does, a check cancelled
        /// at its first device sent all twenty reads and said it stopped at the last).
        mutating func at(_ what: String, _ index: Int, of total: Int) throws {
            position = "at \(what) \(index + 1) of \(total)"
            try Task.checkCancellation()
        }

        /// Adds `field=value` when this version doesn't know `value`, the value as `acceptanceWord` shows it. The field is
        /// this file's own name and stays apart from Apple's value until here (verifier round 3: the field was found again
        /// by the first `=` Character of one string, and a value led by a combining mark joined that `=` into one
        /// Character, so Apple's whole value was taken for the field and copied raw, forging lines and naming a serial,
        /// and a device's such value was dropped from the report).
        mutating func unknown<Known>(_ field: String, _ value: OpenEnum<Known>?) {
            guard let value, value.known == nil else { return }
            values.insert("\(field)=\(AppleClient.acceptanceWord(value.rawValue))")
        }

        mutating func cut<Item>(_ page: Page<Item>) {
            guard page.truncated else { return }
            truncation = "stopped at the page cap with more to come" + (page.total.map { " (Apple's total \($0))" } ?? "")
        }

        /// Keys inside the objects a view reads (`phoneNumbers.isPrimary`), as the text shows them; `payload` puts them
        /// with the payload's keys. The attribute and Apple's key stay apart until here, each shown as `acceptanceWord`
        /// shows it, so a key can't forge a line as a `.`-joined string would (Phase 2a review L1: nested objects'
        /// unknown keys were never counted).
        private(set) var nestedKeys: Set<String> = [], nestedPayloadKeys: Set<String> = []
        mutating func unread(_ keys: [NestedKey], payload: Bool = false) {
            let shown = keys.map { "\(AppleClient.acceptanceWord($0.attribute)).\(AppleClient.acceptanceWord($0.key))" }
            if payload { nestedPayloadKeys.formUnion(shown) } else { nestedKeys.formUnion(shown) }
        }
    }

    /// One resource's line: not sent when the pass was cancelled or `skip` says why; else what `body` found, cut short, or
    /// how it failed. `counted` false (a probe) leaves the count out.
    private static func check(_ resource: String, unless skip: String? = nil, counted: Bool = true,
                              _ body: (inout Found) async throws -> Void) async -> AcceptanceReport.Line {
        if let skip = Task.isCancelled ? "the pass was cancelled" : skip {
            return .init(resource: resource, status: .skipped(skip), count: nil, unknownKeys: [], unknownValues: [], unknownPayloadKeys: [], note: nil)
        }
        var found = Found()
        let status: AcceptanceReport.Status
        let notes: [String?]
        do {
            try await body(&found)
            // A cancelled `for try await` over a stream ends without throwing (Phase 1b review H2): without this, a walk
            // the cancellation cut short read `ok` with what it had (verifier round 1).
            try Task.checkCancellation()
            status = found.status ?? (found.truncation == nil ? .ok : .truncated)
            notes = [found.truncation, found.note]
        } catch {
            let failed = acceptanceFailure(error)
            status = failed.status
            notes = [found.position, failed.note]
        }
        let note = notes.compactMap { $0 }.joined(separator: " · ")
        return .init(resource: resource, status: status, count: counted ? found.count : nil,
                     unknownKeys: Set(found.keys.map(acceptanceWord)).union(found.nestedKeys).sorted(), unknownValues: found.values.sorted(),
                     unknownPayloadKeys: Set(found.payloadKeys.map(acceptanceWord)).union(found.nestedPayloadKeys).sorted(),
                     note: note.isEmpty ? nil : note)
    }

    /// Why a check that reads `prerequisite`'s items has none: it found none, or it stopped short, failed or cut at the
    /// page cap before an item came (verifier round 2: "has none" there contradicted the `truncated` line above it).
    private static func none(_ what: String, _ prerequisite: AcceptanceReport.Line) -> String {
        "no \(what) (\(prerequisite.resource) \(prerequisite.status == .ok ? "has none" : "\(prerequisite.status)"))"
    }

    /// `items`, when each is `View`'s type and, given `id` (the single device read), the item asked for. A list, a linkage
    /// list or a single read answered with another resource (`users` for `mdmServers`, a next link that walked off to a
    /// collection of another type, another device) is malformed, never `ok` (verifier round 2: each read `ok`). The types
    /// are the contract's (`OrgDevice`, `MdmServer`, `MdmServerDevicesLinkagesResponse.Data`, `AppleCareCoverage`,
    /// `ActivationLockStatus`). Byte for byte, as `OpenEnum` matches: `String ==` folds Unicode equivalents, so an id with
    /// U+212A KELVIN SIGN read as the `K` serial asked for (verifier round 3). The lock's `id` isn't checked: the
    /// contract types it as a string, and only Apple's example makes it the serial (invariant 5: never from convention).
    private static func typed<View: ResourceView>(_ items: [View], asked id: String? = nil) throws -> [View] {
        func same(_ one: String, _ other: String) -> Bool { one.utf8.elementsEqual(other.utf8) }
        guard items.allSatisfy({ item in same(item.resource.type, View.resourceType) && (id.map { same(item.id, $0) } ?? true) }) else {
            throw AppleAPIError.malformed(id == nil ? "items of type \(View.resourceType)" : "the \(View.resourceType) item asked for")
        }
        return items
    }

    /// An id the client won't put in a path (`AppleRead.isPathSafe`) is never sent, and is said as what it is: Apple sent
    /// an id of a shape it doesn't document. Through `device(_:)` and the others it read `error 404`, which Apple never
    /// sent, and the coverage walk could pass over it and read `ok` (verifier round 2).
    private static let unsafeID = AppleAPIError.malformed("an id that can go in a path")

    private static func sendable(_ id: String) throws -> String {
        guard AppleRead.isPathSafe(id) else { throw unsafeID }
        return id
    }

    /// An attribute name or enum value Apple sent that this version doesn't know, as the text shows it. Apple's
    /// vocabulary is ASCII words (`brandNewField`, `FUTURE_MDM`, `AppleTV`): a letter, then letters, digits or `_`, at
    /// most 64 bytes. Anything else (a newline that would forge a line, prose naming a device, 5000 bytes) is said as
    /// `(not shown)`, never copied (verifier round 2: a newline in an attribute name forged an `ok` line).
    static func acceptanceWord(_ text: some StringProtocol) -> String {
        let bytes = text.utf8
        guard let first = bytes.first, letters.contains(first), bytes.count <= 64,
              bytes.allSatisfy({ letters.contains($0) || digits.contains($0) || $0 == UInt8(ascii: "_") }) else { return "(not shown)" }
        return String(text)
    }

    /// A failure as a status and a note of codes. Not `AppleAPIError.message`: that carries Apple's `detail`
    /// (Phase 1b review: the pass's note did, and Apple's prose may echo an identifier). Every arm is a status that
    /// isn't `ok`; `AcceptanceFailureTests` holds each.
    static func acceptanceFailure(_ error: any Error) -> (status: AcceptanceReport.Status, note: String?) {
        switch error {
        case AppleAPIError.forbidden(let code): (.forbidden, acceptanceCode(code))
        case AppleAPIError.conflict(let code, _): (.error("error 409"), acceptanceCode(code))
        case AppleAPIError.badRequest(let code, let parameter, _):
            (.error("error 400"), [acceptanceCode(code), acceptanceParameter(parameter)].compactMap { $0 }.joined(separator: " ").nonEmpty)
        case AppleAPIError.unprocessable: (.error("error 422"), nil)
        case AppleAPIError.notJSON: (.error("error not JSON"), nil)
        // This app's own words: which shape was expected.
        case AppleAPIError.malformed(let what): (.error("error malformed"), what)
        case AppleAPIError.http(let failure), let failure as HTTPFailure: (.error(transportStatus(failure)), nil)
        case AppleAPIError.token(let failure): (.error("error token"), tokenCode(failure))
        // The Vault's guidance is this app's own words too (a cancelled Touch ID, a locked Mac), never Apple's.
        case AppleAPIError.vault(let guidance): (.error("error keychain"), guidance)
        case AppleAPIError.wrongHost: (.error("error wrong host"), nil)
        // Never sent: the read isn't in the org's API.
        case AppleAPIError.notInScope: (.skipped("not in Apple School Manager's API"), nil)
        case let error as AppleAPIError: (.error(probeStatus(error)), nil)
        case is CancellationError: (.error("error cancelled"), nil)
        default: (.error("error \(type(of: error))"), nil)
        }
    }

    /// Apple's error `code` (`FORBIDDEN_ERROR`, `PARAMETER_ERROR.INVALID`) or the token endpoint's OAuth `error`
    /// (`server_error`) when it has a code's shape: two or more words of ASCII letters joined by `_` or `.`, at most 64
    /// bytes, in one case, and joined by `_` only when lower-case (OAuth's codes are). Anything else is dropped: prose,
    /// which may name a device; whatever could be an identifier, since a serial, a UUID or a number has a digit, a `-` or
    /// no join (verifier round 1: `C02XSERIAL99` reached a note); and a name, `John.Smith` or `jane.doe` (round 2).
    static func acceptanceCode(_ text: String?) -> String? {
        guard let text, text.utf8.count <= 64 else { return nil }
        var words = 1, length = 0, upper = false, lower = false, dotted = false
        for byte in text.utf8 {
            if byte == UInt8(ascii: "_") || byte == UInt8(ascii: ".") {
                guard length > 0 else { return nil }
                if byte == UInt8(ascii: ".") { dotted = true }
                words += 1
                length = 0
            } else if lowercase.contains(byte) {
                lower = true
                length += 1
            } else if uppercase.contains(byte) {
                upper = true
                length += 1
            } else {
                return nil
            }
        }
        return words >= 2 && length > 0 && !(upper && lower) && !(lower && dotted) ? text : nil
    }

    /// Apple's `source.parameter` when it is a query parameter Apple documents: a value echoed there instead, a serial or
    /// a name, is dropped (verifier round 2: `janedoe` had a parameter's shape and reached the note).
    static func acceptanceParameter(_ text: String?) -> String? {
        text.flatMap { acceptanceParameters.contains($0) ? $0 : nil }
    }

    /// Every query parameter `Contracts/apple` documents, both scopes (`AcceptancePassTests` holds it to the contracts).
    static let acceptanceParameters: Set<String> = [
        "cursor", "include", "limit", "limit[apps]", "limit[configurations]", "limit[orgDevices]", "limit[packages]", "limit[userGroups]",
        "limit[users]", "fields[activationLockStatus]", "fields[appleCareCoverage]", "fields[apps]", "fields[auditEvents]",
        "fields[blueprints]", "fields[configurations]", "fields[mdmDeviceDetails]", "fields[mdmDevices]", "fields[mdmServers]",
        "fields[orgDeviceActivities]", "fields[orgDevices]", "fields[organizationalUnits]", "fields[packages]", "fields[userGroups]",
        "fields[users]", "filter[actorId]", "filter[endTimestamp]", "filter[startTimestamp]", "filter[subjectId]", "filter[type]",
    ]

    private static let lowercase = Set("abcdefghijklmnopqrstuvwxyz".utf8), uppercase = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ".utf8)
    private static let letters = lowercase.union(uppercase), digits = Set("0123456789".utf8)

    private static func transportStatus(_ failure: HTTPFailure) -> String {
        switch failure {
        case .transport(let code): "error transport \(code)"
        case .refusedHost: "error refused host"
        case .tooLarge: "error too large"
        }
    }

    private static func tokenCode(_ failure: TokenFailure) -> String? {
        switch failure {
        case .notConfigured: "not configured"
        case .invalidClient: "invalid_client"
        case .invalidRequest: "invalid_request"
        case .unauthorizedClient: "unauthorized_client"
        case .invalidScope: "invalid_scope"
        case .rateLimited: "429"
        case .malformed: "malformed"
        case .status(let status, let code): ["\(status)", acceptanceCode(code)].compactMap { $0 }.joined(separator: " ")
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
