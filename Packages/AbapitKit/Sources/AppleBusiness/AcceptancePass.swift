import AppleModels
import Foundation
import JSONAPI

/// The read-only acceptance pass (plan §7): every read this phase makes, against the org, reporting per
/// resource whether it decoded, how many items, and which attribute names and enum values this version
/// doesn't know. It reports Apple's field names and counts only, never an item's data, so its output can be
/// pasted into an issue.
public struct AcceptanceReport: Sendable, Equatable {
    public struct Line: Sendable, Equatable {
        public let resource: String
        public let ok: Bool
        public let count: Int
        public let unknownKeys: [String]
        public let unknownValues: [String]
        public let note: String?
    }

    public let lines: [Line]

    public var text: String {
        lines.map { line in
            var parts = ["\(line.ok ? "ok  " : "FAIL") \(line.resource): \(line.count)"]
            if !line.unknownKeys.isEmpty { parts.append("unknown keys \(line.unknownKeys.joined(separator: ", "))") }
            if !line.unknownValues.isEmpty { parts.append("unknown values \(line.unknownValues.joined(separator: ", "))") }
            if let note = line.note { parts.append(note) }
            return parts.joined(separator: " · ")
        }.joined(separator: "\n")
    }
}

extension AppleClient {
    /// Runs every Phase 1 read: the device list, the services and their device lists, and for up to `sample`
    /// devices the single device, its AppleCare, its Activation Lock and its assigned service; then the probes.
    public func acceptancePass(sample: Int = 5) async -> AcceptanceReport {
        var lines: [AcceptanceReport.Line] = []
        var devices: [OrgDevice] = []
        lines.append(await Self.measure("orgDevices") {
            var truncated = false
            for try await page in self.devices() { devices += page.items; truncated = page.truncated }
            let values = Set(devices.flatMap { device in
                [device.productFamily.map { "productFamily=\($0.rawValue)" }, device.status.map { "status=\($0.rawValue)" },
                 device.purchaseSourceType.map { "purchaseSourceType=\($0.rawValue)" },
                 device.migrationStatus.map { "mdmMigrationStatus=\($0.rawValue)" }].compactMap { $0 }
                    .filter { value in Self.isUnknown(value, device) }
            })
            return (devices.count, Set(devices.flatMap(\.unreadAttributes)), values, truncated ? "truncated at the page cap" : nil)
        })
        var services: [MDMService] = []
        lines.append(await Self.measure("mdmServers") {
            for try await page in self.services() { services += page.items }
            let values = Set(services.flatMap(Self.unknownValues))
            return (services.count, Set(services.flatMap(\.unreadAttributes)), values, nil)
        })
        lines.append(await Self.measure("mdmServers/{id}/relationships/devices") {
            var count = 0
            for service in services { for try await page in self.serviceDeviceIDs(service.id) { count += page.items.count } }
            return (count, [], [], nil)
        })
        let sample = Array(devices.prefix(sample))
        lines.append(await Self.measure("orgDevices/{id}") {
            var keys: Set<String> = []
            for device in sample { keys.formUnion(try await self.device(device.id).unreadAttributes) }
            return (sample.count, keys, [], nil)
        })
        lines.append(await Self.measure("orgDevices/{id}/appleCareCoverage") {
            var rows: [AppleCareCoverage] = []
            for device in sample { rows += try await self.appleCare(device.id) }
            let values = Set(rows.flatMap { row in
                [row.status.flatMap { $0.known == nil ? "status=\($0.rawValue)" : nil },
                 row.paymentType.flatMap { $0.known == nil ? "paymentType=\($0.rawValue)" : nil }].compactMap { $0 }
            })
            return (rows.count, Set(rows.flatMap(\.unreadAttributes)), values, nil)
        })
        lines.append(await Self.measure("orgDevices/{id}/activationLockStatus") {
            var keys: Set<String> = [], values: Set<String> = []
            for device in sample {
                let lock = try await self.activationLock(device.id)
                keys.formUnion(lock.unreadAttributes)
                if let type = lock.lockType, type.known == nil { values.insert("lockType=\(type.rawValue)") }
            }
            return (sample.count, keys, values, nil)
        })
        lines.append(await Self.measure("orgDevices/{id}/assignedServer") {
            var assigned = 0
            for device in sample where try await self.assignedService(device.id) != nil { assigned += 1 }
            return (assigned, [], [], "\(sample.count - assigned) of \(sample.count) unassigned")
        })
        lines.append(await Self.measure("orgDevices/{id}/relationships/assignedServer") {
            var assigned = 0
            for device in sample where try await self.assignedServiceID(device.id) != nil { assigned += 1 }
            return (assigned, [], [], nil)
        })
        for result in await probeReads() {
            lines.append(.init(resource: "probe \(result.section.rawValue)", ok: result.status == ProbeResult.ok || result.status == ProbeResult.forbidden,
                               count: 0, unknownKeys: [], unknownValues: [], note: result.status))
        }
        return AcceptanceReport(lines: lines)
    }

    /// One resource's line: what `body` counted, or why it failed.
    private static func measure(_ resource: String, _ body: () async throws -> (Int, Set<String>, Set<String>, String?)) async -> AcceptanceReport.Line {
        do {
            let (count, keys, values, note) = try await body()
            return .init(resource: resource, ok: true, count: count, unknownKeys: keys.sorted(), unknownValues: values.sorted(), note: note)
        } catch let error as AppleAPIError {
            return .init(resource: resource, ok: false, count: 0, unknownKeys: [], unknownValues: [], note: error.message)
        } catch {
            return .init(resource: resource, ok: false, count: 0, unknownKeys: [], unknownValues: [], note: "\(type(of: error))")
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
