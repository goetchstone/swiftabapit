import AppleModels
import Foundation
import HTTPCore
import JSONAPI

/// The read-only acceptance pass (plan §7): every read this phase makes, against the org, reporting per
/// resource whether it ran and fully succeeded, how many items, and which attribute names and enum values this
/// version doesn't know. It reports Apple's field names, error codes, statuses and counts only, never an item's
/// data and never Apple's `detail` prose (which may echo an identifier), so its output can be pasted into an issue.
public struct AcceptanceReport: Sendable, Equatable {
    /// How one check went. Only `.ok` is a read that ran and fully succeeded (Phase 1b review M5: with `orgDevices`
    /// forbidden the five per-device lines printed "ok … 0", and a list cut at the page cap printed "ok").
    public enum Status: Sendable, Equatable, CustomStringConvertible {
        case ok
        /// The page cap stopped a list with more to come (invariant 8): the line's count is what was read.
        case truncated
        case forbidden
        /// Never sent: the read it needs failed or found nothing to read.
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
        public let unknownKeys: [String]
        public let unknownValues: [String]
        /// Counts and codes only: what was cut, where a loop stopped, Apple's error `code`. Never Apple's `detail`.
        public let note: String?

        public var ok: Bool { status == .ok }
    }

    public let lines: [Line]

    public var text: String {
        lines.map { line in
            var parts = ["\(line.resource): \(line.status)" + (line.count.map { $0 == 1 ? ", 1 item" : ", \($0) items" } ?? "")]
            if !line.unknownKeys.isEmpty { parts.append("unknown keys \(line.unknownKeys.joined(separator: ", "))") }
            if !line.unknownValues.isEmpty { parts.append("unknown values \(line.unknownValues.joined(separator: ", "))") }
            if let note = line.note { parts.append(note) }
            return parts.joined(separator: " · ")
        }.joined(separator: "\n")
    }
}

extension AppleClient {
    /// The devices sampled one by one unless asked otherwise, and the most ever sampled: each costs five reads, so a
    /// caller's number can't turn the pass into a sweep (invariant 7; Phase 1b review: the sample was unbounded).
    public static let acceptanceSample = 5, acceptanceSampleLimit = 20

    /// Runs every Phase 1 read: the device list, the services and their device lists, and for each sampled device
    /// the single device, its AppleCare, its Activation Lock and its assigned service; then the probes.
    public func acceptancePass(sample: Int = AppleClient.acceptanceSample) async -> AcceptanceReport {
        let scope = scope
        var lines: [AcceptanceReport.Line] = []
        var devices: [OrgDevice] = []
        let deviceList = await Self.check("orgDevices") { found in
            for try await page in self.devices() {
                devices += page.items
                found.count = devices.count
                found.cut(page)
            }
            found.keys = Set(devices.flatMap(\.unreadAttributes))
            found.values = Set(devices.flatMap { device in
                [device.productFamily.map { "productFamily=\($0.rawValue)" }, device.status.map { "status=\($0.rawValue)" },
                 device.purchaseSourceType.map { "purchaseSourceType=\($0.rawValue)" },
                 device.migrationStatus.map { "mdmMigrationStatus=\($0.rawValue)" }].compactMap { $0 }
                    .filter { value in Self.isUnknown(value, device) }
            })
        }
        lines.append(deviceList)
        var services: [MDMService] = []
        let serviceList = await Self.check("mdmServers") { found in
            for try await page in self.services() {
                services += page.items
                found.count = services.count
                found.cut(page)
            }
            found.keys = Set(services.flatMap(\.unreadAttributes))
            found.values = Set(services.flatMap(Self.unknownValues))
        }
        lines.append(serviceList)
        let noService = services.isEmpty ? Self.none("service to read", serviceList) : nil
        lines.append(await Self.check("mdmServers/{id}/relationships/devices", unless: noService) { found in
            var cut = 0
            for (index, service) in services.enumerated() {
                found.position = "at service \(index + 1) of \(services.count)"
                for try await page in self.serviceDeviceIDs(service.id) {
                    found.count += page.items.count
                    if page.truncated { cut += 1 }
                }
            }
            if cut > 0 { found.truncation = "\(cut) of \(services.count) services' lists stopped at the page cap" }
        })

        let sampled = Array(devices.prefix(min(max(sample, 0), Self.acceptanceSampleLimit)))
        let unsampled = devices.isEmpty ? Self.none("device to sample", deviceList)
            : sampled.isEmpty ? "no device to sample (sample size \(sample))" : nil
        lines.append(await Self.check("orgDevices/{id}", unless: unsampled) { found in
            for (index, device) in sampled.enumerated() {
                found.position = "at device \(index + 1) of \(sampled.count)"
                found.keys.formUnion(try await self.device(device.id).unreadAttributes)
                found.count += 1
            }
        })
        lines.append(await Self.check("orgDevices/{id}/appleCareCoverage", unless: unsampled) { found in
            var rows: [AppleCareCoverage] = [], cut = 0
            for (index, device) in sampled.enumerated() {
                found.position = "at device \(index + 1) of \(sampled.count)"
                // The pages themselves, not `appleCare(_:)`'s whole list: a coverage list cut at the page cap is said.
                guard let read = AppleRead.appleCare(scope, serial: device.id) else { throw AppleAPIError.notFound }
                for try await page in self.pages(read).map(AppleCareCoverage.init) {
                    rows += page.items
                    found.count = rows.count
                    if page.truncated { cut += 1 }
                }
            }
            if cut > 0 { found.truncation = "\(cut) of \(sampled.count) devices' coverage stopped at the page cap" }
            found.keys = Set(rows.flatMap(\.unreadAttributes))
            found.values = Set(rows.flatMap { row in
                [row.status.flatMap { $0.known == nil ? "status=\($0.rawValue)" : nil },
                 row.paymentType.flatMap { $0.known == nil ? "paymentType=\($0.rawValue)" : nil }].compactMap { $0 }
            })
        })
        lines.append(await Self.check("orgDevices/{id}/activationLockStatus", unless: unsampled) { found in
            for (index, device) in sampled.enumerated() {
                found.position = "at device \(index + 1) of \(sampled.count)"
                let lock = try await self.activationLock(device.id)
                found.keys.formUnion(lock.unreadAttributes)
                if let type = lock.lockType, type.known == nil { found.values.insert("lockType=\(type.rawValue)") }
                found.count += 1
            }
        })
        lines.append(await Self.check("orgDevices/{id}/assignedServer", unless: unsampled) { found in
            var unassigned = 0
            for (index, device) in sampled.enumerated() {
                found.position = "at device \(index + 1) of \(sampled.count)"
                if try await self.assignedService(device.id) == nil { unassigned += 1 }
                found.count += 1
            }
            found.note = "\(unassigned) of \(sampled.count) unassigned"
        })
        lines.append(await Self.check("orgDevices/{id}/relationships/assignedServer", unless: unsampled) { found in
            var unassigned = 0
            for (index, device) in sampled.enumerated() {
                found.position = "at device \(index + 1) of \(sampled.count)"
                if try await self.assignedServiceID(device.id) == nil { unassigned += 1 }
                found.count += 1
            }
            found.note = "\(unassigned) of \(sampled.count) unassigned"
        })
        for result in await probeReads() {
            let status: AcceptanceReport.Status = switch result.status {
            case ProbeResult.ok: .ok
            case ProbeResult.forbidden: .forbidden
            default: .error(result.status)
            }
            lines.append(.init(resource: "probe \(result.section.rawValue)", status: status, count: nil, unknownKeys: [], unknownValues: [], note: nil))
        }
        return AcceptanceReport(lines: lines)
    }

    /// What a check found so far: kept when it fails part-way, so its line says how far it got.
    private struct Found {
        var count = 0
        var keys: Set<String> = []
        var values: Set<String> = []
        /// What the page cap cut, in counts; when set, the check is `.truncated`.
        var truncation: String?
        /// Where a loop is ("at device 3 of 5"): said only if it fails there.
        var position: String?
        /// Counts said on success ("1 of 4 unassigned").
        var note: String?

        mutating func cut<Item>(_ page: Page<Item>) {
            guard page.truncated else { return }
            truncation = "stopped at the page cap with more to come" + (page.total.map { " (Apple's total \($0))" } ?? "")
        }
    }

    /// One resource's line: not sent when `skip` says why; else what `body` found, cut short, or how it failed.
    private static func check(_ resource: String, unless skip: String? = nil,
                              _ body: (inout Found) async throws -> Void) async -> AcceptanceReport.Line {
        if let skip { return .init(resource: resource, status: .skipped(skip), count: nil, unknownKeys: [], unknownValues: [], note: nil) }
        var found = Found()
        let status: AcceptanceReport.Status
        let notes: [String?]
        do {
            try await body(&found)
            status = found.truncation == nil ? .ok : .truncated
            notes = [found.truncation, found.note]
        } catch {
            let failed = failure(error)
            status = failed.status
            notes = [found.position, failed.note]
        }
        let note = notes.compactMap { $0 }.joined(separator: " · ")
        return .init(resource: resource, status: status, count: found.count, unknownKeys: found.keys.sorted(),
                     unknownValues: found.values.sorted(), note: note.isEmpty ? nil : note)
    }

    /// Why a check that reads `prerequisite`'s items has none: it failed, or it found none.
    private static func none(_ what: String, _ prerequisite: AcceptanceReport.Line) -> String {
        switch prerequisite.status {
        case .ok, .truncated: "no \(what) (\(prerequisite.resource) has none)"
        default: "no \(what) (\(prerequisite.resource) \(prerequisite.status))"
        }
    }

    /// A failure as a status and a note of codes. Not `AppleAPIError.message`: that carries Apple's `detail`
    /// (Phase 1b review: the pass's note did, and Apple's prose may echo an identifier).
    private static func failure(_ error: any Error) -> (status: AcceptanceReport.Status, note: String?) {
        switch error {
        case AppleAPIError.forbidden(let code): (.forbidden, acceptanceCode(code))
        case AppleAPIError.conflict(let code, _): (.error("error 409"), acceptanceCode(code))
        case AppleAPIError.badRequest(let code, let parameter, _):
            (.error("error 400"), [acceptanceCode(code), acceptanceCode(parameter)].compactMap { $0 }.joined(separator: " ").nonEmpty)
        case AppleAPIError.unprocessable: (.error("error 422"), nil)
        case AppleAPIError.notJSON: (.error("error not JSON"), nil)
        // This app's own words: which shape was expected.
        case AppleAPIError.malformed(let what): (.error("error malformed"), what)
        case AppleAPIError.http(let failure), let failure as HTTPFailure: (.error(transportStatus(failure)), nil)
        case AppleAPIError.token(let failure): (.error("error token"), tokenCode(failure))
        // The Vault's guidance is this app's own words too (a cancelled Touch ID, a locked Mac), never Apple's.
        case AppleAPIError.vault(let guidance): (.error("error keychain"), guidance)
        case AppleAPIError.wrongHost: (.error("error wrong host"), nil)
        case let error as AppleAPIError: (.error(probeStatus(error)), nil)
        case is CancellationError: (.error("error cancelled"), nil)
        default: (.error("error \(type(of: error))"), nil)
        }
    }

    /// Apple's `code` or `source.parameter` when it is a code (`FORBIDDEN_ERROR`, `PARAMETER_ERROR.INVALID`,
    /// `fields[orgDevices]`); anything else, prose included, is dropped.
    static func acceptanceCode(_ text: String?) -> String? {
        guard let text, (1...64).contains(text.utf8.count), text.utf8.allSatisfy(codeBytes.contains) else { return nil }
        return text
    }

    private static let codeBytes = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-[]".utf8)

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

    private static func unknownValues(_ service: MDMService) -> [String] {
        var found: [String] = []
        if let type = service.type, type.known == nil { found.append("serverType=\(type.rawValue)") }
        if let status = service.status, status.known == nil { found.append("status=\(status.rawValue)") }
        for family in service.defaultProductFamilies where family.known == nil { found.append("defaultProductFamilies=\(family.rawValue)") }
        return found
    }

    private static func isUnknown(_ value: String, _ device: OrgDevice) -> Bool {
        switch value.split(separator: "=").first {
        case "productFamily": device.productFamily?.known == nil
        case "status": device.status?.known == nil
        case "purchaseSourceType": device.purchaseSourceType?.known == nil
        case "mdmMigrationStatus": device.migrationStatus?.known == nil
        default: false
        }
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
