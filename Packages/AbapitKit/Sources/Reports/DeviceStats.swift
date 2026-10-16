import Foundation
import JSONAPI

/// A name and how many: one row of a breakdown.
public struct Tally: Sendable, Equatable {
    public let name: String
    public let count: Int
}

/// abapit's `reports.device_stats` (held to `Tests/Fixtures/parity/reports.json`): the dashboard's counts
/// from one device listing.
public struct DeviceStats: Sendable, Equatable {
    public let total: Int
    public let byFamily: [Tally]
    public let byStatus: [Tally]
    public let topModels: [Tally]
    public let added30: Int
    public let added90: Int
    /// The last 12 calendar months (UTC), oldest first, zero-filled, by the month each device was added in the
    /// offset its timestamp was written in (abapit's `strftime("%Y-%m")`).
    public let addedByMonth: [Tally]

    public var monthMax: Int { addedByMonth.map(\.count).max() ?? 0 }
    public var familyMax: Int { byFamily.map(\.count).max() ?? 0 }

    public init(_ devices: [Resource], now: Date) {
        var family = Counter(), status = Counter(), model = Counter(), month = Counter()
        var added30 = 0, added90 = 0
        for device in devices {
            let attributes = device.attributes
            family.add(Self.orUnknown(attributes["productFamily"]))
            status.add(Self.orUnknown(attributes["status"]))
            model.add(Self.orUnknown(attributes["deviceModel"]))
            guard let added = ISODate.parse(attributes["addedToOrgDateTime"]?.string) else { continue }
            let age = now.timeIntervalSince(added.date)
            if age <= 30 * 86_400 { added30 += 1 }
            if age <= 90 * 86_400 { added90 += 1 }
            let local = added.localComponents
            month.add(String(format: "%04d-%02d", local.year ?? 0, local.month ?? 0))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let today = calendar.dateComponents([.year, .month], from: now)
        var (year, monthNumber) = (today.year ?? 1970, today.month ?? 1)
        var months: [String] = []
        for _ in 0..<12 {
            months.append(String(format: "%04d-%02d", year, monthNumber))
            monthNumber -= 1
            if monthNumber == 0 { (year, monthNumber) = (year - 1, 12) }
        }
        total = devices.count
        byFamily = family.mostCommon()
        byStatus = status.mostCommon()
        topModels = Array(model.mostCommon().prefix(10))
        self.added30 = added30
        self.added90 = added90
        addedByMonth = months.reversed().map { Tally(name: $0, count: month.count($0)) }
    }

    /// Python's `value or "Unknown"`: missing, null, empty, `false` and `0` all read as Unknown.
    static func orUnknown(_ value: JSONValue?) -> String {
        switch value {
        case .string(let text)? where !text.isEmpty: text
        case .number(let text)? where Double(text) != 0: text
        case .bool(true)?: "True"
        default: "Unknown"
        }
    }
}

/// Python's `Counter`: counts in first-seen order, and `most_common` a stable sort by count, descending.
struct Counter {
    private var order: [String] = []
    private var counts: [[UInt8]: Int] = [:]

    mutating func add(_ name: String) {
        let key = Array(name.utf8)
        if counts[key] == nil { order.append(name) }
        counts[key, default: 0] += 1
    }

    func count(_ name: String) -> Int { counts[Array(name.utf8)] ?? 0 }

    func mostCommon() -> [Tally] {
        order.enumerated().sorted { a, b in
            let ca = count(a.element), cb = count(b.element)
            return ca != cb ? ca > cb : a.offset < b.offset
        }.map { Tally(name: $0.element, count: count($0.element)) }
    }
}

/// abapit's `reports.assignment_summary`: devices per service and the unassigned ones.
public struct AssignmentSummary: Sendable, Equatable {
    public struct PerService: Sendable, Equatable {
        public let service: Resource
        public let count: Int
    }

    public let perService: [PerService]
    /// Serials no service lists, sorted by code point.
    public let unassigned: [String]
    public let assignedCount: Int

    public init(devices: [Resource], services: [Resource], deviceIDs: [String: [String]]) {
        let all = Set(devices.map(\.id))
        var assigned: Set<String> = []
        perService = services.map { service in
            let ids = Set(deviceIDs[service.id] ?? [])
            assigned.formUnion(ids)
            return PerService(service: service, count: ids.count)
        }
        unassigned = all.subtracting(assigned).filter { !$0.isEmpty }
            .sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
        assignedCount = assigned.intersection(all).count
    }
}
