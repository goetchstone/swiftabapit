#if DEBUG
// Demo and test code only: compiled out of a Release build, so the app's Release binary carries no fake history
// (scripts/check_app.sh holds the same for the stubs).
import Foundation
import History
import JSONAPI
import Orgs

/// The demo org's snapshot history (plan §6.5: the Changes screen's screenshot draws a real-looking diff): three snapshots,
/// two weeks apart, of obviously fake devices (`DEMOCHG…`), services and people. Between the last two: one device changed, two
/// not read because the device list was cut at the page limit (partial), People refused (not read), a service changed, and
/// AppleCare and Activation Lock read only in the newest (so the Reports screen draws them from it, with its part-read device
/// list). No tenant data: every serial, name and address is invented.
public enum DemoHistory {
    public static let first = Date(timeIntervalSince1970: 1_792_152_000)       // 2026-10-16T12:00:00Z
    public static let second = Date(timeIntervalSince1970: 1_793_361_600)      // +14 days
    public static let third = Date(timeIntervalSince1970: 1_794_571_200)       // +28 days

    static func device(_ index: Int, status: String = "ASSIGNED") -> Resource {
        let serial = String(format: "DEMOCHG%04d", index)
        let models = ["MacBook Air 13-inch (M3)", "iPhone 16", "iPad Air 11-inch (M2)", "Mac mini (M4)", "MacBook Pro 14-inch (M4)", "iPhone 16"]
        return Resource(type: "devices", id: serial, attributes: [
            "serialNumber": .string(serial), "deviceModel": .string(models[(index - 1) % models.count]), "productFamily": .string(index % 3 == 0 ? "iPad" : "Mac"),
            "status": .string(status), "addedToOrgDateTime": .string("2026-01-0\(index)T09:00:00Z"),
            // Ordered years back, so Out of warranty has an estimate to label and Fleet age has candidates.
            "orderDateTime": .string("202\(index % 3 + 2)-0\(index)-15T09:00:00Z"),
        ])
    }

    static func service(_ id: String, name: String, connected: String) -> Resource {
        Resource(type: "mdm_servers", id: id, attributes: ["serverName": .string(name), "serverType": .string("MDM"), "status": .string("ACTIVE"),
                                                            "lastConnectedDateTime": .string(connected)])
    }

    static func managed(_ index: Int) -> Resource {
        let serial = String(format: "DEMOCHG%04d", index)
        return Resource(type: "mdm_enrolled", id: "DEMOMDM\(index)", attributes: ["serialNumber": .string(serial), "deviceName": .string("Demo Mac \(index)"),
                                                                                 "productFamily": .string("Mac")])
    }

    static func person(_ index: Int) -> Resource {
        Resource(type: "users", id: "DEMOUSER\(index)", attributes: ["managedAppleAccount": .string("demo.user\(index)@example.com"), "status": .string("ACTIVE"),
                                                                       "isExternalUser": .bool(false)])
    }

    static func iso(_ date: Date) -> String { date.formatted(Date.ISO8601FormatStyle(timeZone: TimeZone(secondsFromGMT: 0)!)) }

    /// An AppleCare record of a fake device; `ends` is relative to `now`, so the demo's expiring coverage is always in its window.
    static func care(_ serial: String, _ id: String, status: String, ends: Date) -> Resource {
        Resource(type: "applecare", id: id, attributes: ["serialNumber": .string(serial), "description": .string("AppleCare+ (demo)"), "status": .string(status),
                                                         "paymentType": .string("PAID_UP_FRONT"), "isRenewable": .bool(true), "endDateTime": .string(iso(ends))])
    }

    static func lock(_ index: Int, locked: Bool, type: String?) -> Resource {
        let serial = String(format: "DEMOCHG%04d", index)
        var attributes: JSONObject = ["isLocked": .bool(locked)]
        if let type { attributes["lockType"] = .string(type) }
        return Resource(type: "activation_lock", id: serial, attributes: attributes)
    }

    /// Records the three snapshots for `org` into `store`. A store that refuses (a newer file) leaves the demo without history.
    /// `now` places the AppleCare records' end dates (twelve and two hundred days on, and one that has ended).
    public static func seed(_ store: SnapshotStore, org: OrgProfile, now: Date = Date()) async {
        let day = 86_400.0
        do {
            try await store.record(org: org, takenAt: first, resources: [
                "devices": (1...5).map { device($0) },
                "mdm_servers": [service("DEMOSVC1", name: "Demo MDM", connected: "2026-10-15T08:00:00Z")],
                "users": [person(1), person(2)],
                "mdm_enrolled": [managed(1), managed(4)],
            ])
            try await store.record(org: org, takenAt: second, resources: [
                // One added (6), one removed (4), one changed (2 became unassigned).
                "devices": [device(1), device(2, status: "UNASSIGNED"), device(3), device(5), device(6)],
                "mdm_servers": [service("DEMOSVC1", name: "Demo MDM", connected: "2026-10-29T08:00:00Z")],
                "users": [person(1), person(2), person(3)],
                "mdm_enrolled": [managed(1), managed(4)],
            ])
            try await store.record(org: org, takenAt: third, resources: [
                // The device list stopped at the page limit: three of five read, so devices 5 and 6 are not read, never removed.
                "devices": [device(1), device(2), device(3)],
                "mdm_servers": [service("DEMOSVC1", name: "Demo MDM", connected: "2026-11-12T08:00:00Z")],
                "mdm_enrolled": [managed(1), managed(4)],
                // The device list was cut, so both sweeps covered only the devices listed and are part reads (the collector marks them so):
                // Every device listed was read (`unread` is recorded, and empty for both), so device 3's having no AppleCare record is
                // judged as "no record", not "not read".
                "applecare": [care("DEMOCHG0001", "DEMOCARE1", status: "ACTIVE", ends: now + 12 * day),
                              care("DEMOCHG0001", "DEMOCARE2", status: "ACTIVE", ends: now + 200 * day),
                              care("DEMOCHG0002", "DEMOCARE3", status: "INACTIVE", ends: now - 40 * day)],
                "activation_lock": [lock(1, locked: true, type: "USER"), lock(2, locked: false, type: nil), lock(3, locked: true, type: "MDM")],
            ], errors: ["devices": "page cap", "users": "HTTP 403 FORBIDDEN_ERROR", "applecare": "page cap", "activation_lock": "page cap"],
            notes: ["devices": "stopped at the page limit: 3 of 5 read, more not read",
                    "applecare": "covers only the devices listed: devices stopped at the page limit",
                    "activation_lock": "covers only the devices listed: devices stopped at the page limit"],
            unread: ["applecare": [], "activation_lock": []])
        } catch {
            return
        }
    }
}
#endif
