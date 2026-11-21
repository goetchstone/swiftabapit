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
/// AppleCare read only in the newest. No tenant data: every serial, name and address is invented.
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

    /// Records the three snapshots for `org` into `store`. A store that refuses (a newer file) leaves the demo without history.
    public static func seed(_ store: SnapshotStore, org: OrgProfile) async {
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
                "applecare": [Resource(type: "applecare", id: "DEMOCARE1", attributes: ["serialNumber": .string("DEMOCHG0001"),
                                                                                         "description": .string("AppleCare+"), "status": .string("ACTIVE")])],
            ], errors: ["devices": "page cap", "users": "HTTP 403 FORBIDDEN_ERROR"],
            notes: ["devices": "stopped at the page limit: 3 of 5 read, more not read"])
        } catch {
            return
        }
    }
}
#endif
