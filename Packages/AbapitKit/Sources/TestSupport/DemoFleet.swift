#if DEBUG
// Test and demo code only: compiled out of a Release build, so the app's Release binary carries no stub
// (scripts/check_app.sh holds that).
import Foundation
import JSONAPI

/// The demo org's fleet (plan §6.2 item 4): 84 devices from seed 42, after abapit's `demo.py` in shape (its
/// models, its 93% assigned, its 20–1100-day order dates), plus what abapit's demo lacked: Activation Lock
/// states, MDM-migration fields, service health and the AppleCare payment types. Deterministic from the seed
/// and a fixed reference date, so screenshots don't move. Every identifier is an obvious fake (`DEMO…`).
public enum DemoFleet {
    public static let reference = Date(timeIntervalSince1970: 1_792_152_000)   // 2026-10-16T12:00:00Z

    /// SplitMix64: small, seedable, the same everywhere.
    struct Random {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func below(_ bound: Int) -> Int { Int(next() % UInt64(bound)) }
        mutating func chance(_ p: Double) -> Bool { Double(next() >> 11) / Double(1 << 53) < p }
        mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
    }

    static let models: [(model: String, family: String, type: String, capacities: [String], colors: [String])] = [
        ("MacBook Air 13-inch (M3)", "Mac", "Mac15,12", ["256GB", "512GB"], ["Midnight", "Starlight", "Silver"]),
        ("MacBook Pro 14-inch (M4)", "Mac", "Mac16,1", ["512GB", "1TB"], ["Space Black", "Silver"]),
        ("Mac mini (M4)", "Mac", "Mac16,10", ["256GB", "512GB"], ["Silver"]),
        ("iMac 24-inch (M4)", "Mac", "Mac16,2", ["512GB"], ["Blue", "Green", "Silver"]),
        ("iPhone 16", "iPhone", "iPhone17,3", ["128GB", "256GB"], ["Black", "White", "Teal"]),
        ("iPhone 15", "iPhone", "iPhone15,4", ["128GB"], ["Black", "Blue"]),
        ("iPad Air 11-inch (M2)", "iPad", "iPad14,8", ["128GB", "256GB"], ["Space Gray", "Blue"]),
        ("iPad Pro 13-inch (M4)", "iPad", "iPad16,5", ["256GB", "512GB"], ["Space Black"]),
        ("Apple TV 4K (3rd gen)", "AppleTV", "AppleTV14,1", ["128GB"], ["Black"]),
        ("Apple Vision Pro", "Vision", "RealityDevice14,1", ["512GB"], ["Silver"]),
    ]

    public struct Fleet: Sendable {
        public let devices: [Resource]
        public let services: [Resource]
        public let assignments: [String: String]
        public let coverage: [String: [Resource]]
        public let locks: [String: (isLocked: Bool, lockType: String)]
    }

    static func iso(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format.string(from: date)
    }

    public static func make(count: Int = 84, seed: UInt64 = 42) -> Fleet {
        var random = Random(state: seed)
        let day: TimeInterval = 86_400
        let services: [Resource] = [
            ("DEMOSVC0001", "Mosyle Business", "MDM", 1.0), ("DEMOSVC0002", "Jamf Pro (old)", "MDM", 47.0),
            ("DEMOSVC0003", "Apple Configurator", "APPLE_CONFIGURATOR", 3.0),
        ].map { id, name, type, daysAgo in
            Resource(type: "mdmServers", id: id, attributes: [
                "serverName": .string(name), "serverType": .string(type), "status": .string("ACTIVE"),
                "createdDateTime": .string(iso(reference - 700 * day)), "updatedDateTime": .string(iso(reference - 2 * day)),
                "lastConnectedDateTime": .string(iso(reference - daysAgo * day)), "lastConnectedIp": .string("192.0.2.\(Int(daysAgo))"),
                "defaultProductFamilies": .array(type == "MDM" && name.hasPrefix("Mosyle") ? [.string("MAC"), .string("IPHONE"), .string("IPAD")] : []),
                "enableMdmDisownFlag": .bool(false),
            ])
        }
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ0123456789")
        var devices: [Resource] = [], assignments: [String: String] = [:], coverage: [String: [Resource]] = [:]
        var locks: [String: (isLocked: Bool, lockType: String)] = [:]
        for _ in 0..<count {
            let spec = random.pick(models)
            let serial = "DEMO" + String((0..<8).map { _ in random.pick(alphabet) })
            let ordered = reference - Double(20 + random.below(1080)) * day
            let added = ordered + Double(1 + random.below(13)) * day
            var attributes: JSONObject = [
                "serialNumber": .string(serial), "addedToOrgDateTime": .string(iso(added)),
                "updatedDateTime": .string(iso(added + Double(random.below(90)) * day)),
                "deviceModel": .string(spec.model), "productFamily": .string(spec.family), "productType": .string(spec.type),
                "deviceCapacity": .string(random.pick(spec.capacities)), "partNumber": .string("Z\(1000 + random.below(9000))LL/A"),
                "orderNumber": .string("DEMO\(1_000_000 + random.below(9_000_000))"), "color": .string(random.pick(spec.colors)),
                "orderDateTime": .string(iso(ordered)),
                "purchaseSourceType": .string(random.chance(0.8) ? "APPLE" : "RESELLER"),
                "purchaseSourceId": .string(String(100_000 + random.below(900_000))),
                "wifiMacAddress": .string((0..<6).map { _ in String(format: "%02X", random.below(256)) }.joined(separator: ":")),
            ]
            if ["iPhone", "iPad"].contains(spec.family) {
                attributes["imei"] = .array([.string("35\(String(format: "%013d", random.below(1_000_000_000)))")])
            }
            let assigned = random.chance(0.93)
            attributes["status"] = .string(assigned ? "ASSIGNED" : "UNASSIGNED")
            if assigned {
                assignments[serial] = random.chance(0.75) ? "DEMOSVC0001" : (random.chance(0.6) ? "DEMOSVC0002" : "DEMOSVC0003")
            }
            if spec.family == "Mac" {
                attributes["isMdmMigrationCapable"] = .bool(true)
                if assignments[serial] == "DEMOSVC0002", random.chance(0.3) {
                    attributes["mdmMigrationStatus"] = .string(random.pick(["REQUESTED", "STARTED"]))
                    attributes["mdmMigrationDeadlineDateTime"] = .string(iso(reference + Double(10 + random.below(60)) * day))
                }
            }
            devices.append(Resource(type: "orgDevices", id: serial, attributes: attributes))
            var rows = [Resource(type: "appleCareCoverage", id: serial, attributes: [
                "description": .string("Limited Warranty"), "status": .string(reference < ordered + 365 * day ? "ACTIVE" : "INACTIVE"),
                "startDateTime": .string(iso(ordered)), "endDateTime": .string(iso(ordered + 365 * day)), "paymentType": .string("NONE"),
                "isCanceled": .bool(false), "isRenewable": .bool(false), "agreementNumber": .null, "contractCancelDateTime": .null])]
            if random.chance(0.4) {
                let subscription = random.chance(0.5)
                rows.append(Resource(type: "appleCareCoverage", id: "DEMO\(random.below(1_000_000_000))", attributes: [
                    "description": .string(subscription ? "AppleCare+ for Business" : "AppleCare+"),
                    "status": .string("ACTIVE"), "startDateTime": .string(iso(ordered)),
                    "endDateTime": subscription ? .null : .string(iso(ordered + 1095 * day)),
                    "paymentType": .string(subscription ? "ABE_SUBSCRIPTION" : "PAID_UP_FRONT"),
                    "isCanceled": .bool(false), "isRenewable": .bool(subscription),
                    "agreementNumber": .string(String(format: "%09d", random.below(1_000_000_000))), "contractCancelDateTime": .null]))
            }
            coverage[serial] = rows
            let roll = random.below(100)
            locks[serial] = roll < 4 ? (true, "USER") : roll < 30 ? (true, "MDM") : (false, "NONE")
        }
        return Fleet(devices: devices, services: services, assignments: assignments, coverage: coverage, locks: locks)
    }
}

extension AppleStub {
    /// The demo fleet, served as Apple would serve it.
    public func load(_ fleet: DemoFleet.Fleet) {
        add(devices: fleet.devices)
        add(services: fleet.services)
        for (serial, service) in fleet.assignments { assign(serial, to: service) }
        for (serial, rows) in fleet.coverage { setCoverage(serial, rows) }
        for (serial, lock) in fleet.locks { setLock(serial, isLocked: lock.isLocked, lockType: lock.lockType) }
    }
}
#endif
