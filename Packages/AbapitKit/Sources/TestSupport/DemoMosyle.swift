#if DEBUG
// Test and demo code only: compiled out of a Release build, so the app's Release binary carries no stub
// (scripts/check_app.sh holds that).
import Foundation
import JSONAPI
import Vault

/// The demo's Mosyle Business org (plan §4, Phase 7's demo fleet), paired with the demo Apple Business org: most of the Apple
/// fleet's devices assigned to its "Mosyle Business" service, as Mosyle lists them (one spelled in lower case, as Mosyle's
/// casing varies), a few devices Apple doesn't know, and some of Apple's assigned devices that never enrolled, so the
/// reconciliation has all three answers. Then users, user groups, device groups with members and compliance, custom device
/// attributes and an admin log. Mosyle's own shapes, numbers and booleans as strings among them (plan §2.3 defect 19), and
/// every identifier an obvious fake (`DEMO…`). Dates count back from `now`, as the stub's admin-log filter and the stale
/// report read the clock; the serials and the mix come from a seed, so the screenshots don't move.
public enum DemoMosyle {
    public static let orgID = "demo-mosyle"
    public static let name = "Example Mosyle (demo)"
    public static let account = MosyleStub.Account(accessToken: "demo-mosyle-access-token", email: "admin@example.com", password: "demo-password")
    /// The Apple fleet's service whose devices Mosyle enrolls (`DemoFleet`).
    static let service = "DEMOSVC0001"
    /// Devices Mosyle lists that Apple Business doesn't: bought outside it, or enrolled by hand.
    static let mosyleOnly = ["DEMOM0000001", "DEMOM0000002", "DEMOM0000003", "DEMOM0000004"]

    /// The two-client demo's second client: a Mosyle org with no Apple org, served by the same stub (`ABAPIT_DEMO=clients`).
    public static let secondOrgID = "demo-mosyle-second"
    public static let secondName = "Second Example (demo)"

    /// A memory Vault item set for a demo Mosyle org, written into `store` as `Vault.replaceSet` would.
    public static func storeSecrets(in store: MemoryStore, org: String = orgID) {
        for (kind, value) in [(VaultItem.Kind.mosyleAccessToken, account.accessToken), (.mosyleEmail, account.email), (.mosylePassword, account.password)] {
            if let item = VaultItem(org: org, kind: kind) { try? store.write(Data(value.utf8), as: item) }
        }
    }

    /// A stub serving the demo's Mosyle org, made from the demo Apple fleet.
    public static func make(fleet: DemoFleet.Fleet = DemoFleet.make(), now: Date = Date()) -> MosyleStub {
        let stub = MosyleStub()
        stub.register(account)
        load(into: stub, fleet: fleet, now: now)
        return stub
    }

    static let platform = ["Mac": "mac", "iPhone": "ios", "iPad": "ios", "AppleTV": "tvos", "Vision": "visionos"]
    static let versions = ["Mac": ["26.1", "26.1", "26.0.1", "15.7.2"], "iPhone": ["26.1", "26.1", "18.7.1"], "iPad": ["26.1", "26.0.1"],
                           "AppleTV": ["26.1"], "Vision": ["26.0"]]

    /// Each device's raw record, by platform: what `devices(…)` serves.
    public static func devices(fleet: DemoFleet.Fleet, now: Date) -> [String: [JSONObject]] {
        var random = DemoFleet.Random(state: 7)
        let day: TimeInterval = 86_400
        let names = DemoPeople.people.map { ($0.first, "\($0.first.lowercased()).\($0.last.lowercased())@example.com") }
        func epoch(_ date: Date) -> JSONValue { .string(String(Int(date.timeIntervalSince1970))) }
        func record(_ serial: String, model: String, family: String, index: Int) -> JSONObject {
            let (first, email) = names[index % names.count]
            let enrolled = now - Double(30 + random.below(700)) * day
            // Most checked in within a day; one in eight has been silent a month or more.
            let beat = now - (random.chance(0.12) ? Double(31 + random.below(90)) : Double(random.below(36)) / 24) * day
            var raw: JSONObject = [
                "serial_number": .string(serial), "deviceudid": .string("DEMO-UDID-\(serial)"), "device_name": .string("\(first)'s \(model)"),
                "device_model_name": .string(model), "os": .string(platform[family] ?? "ios"), "status": .string("enrolled"),
                "osversion": .string(random.pick(versions[family] ?? ["26.1"])), "date_enroll": epoch(enrolled), "date_last_beat": epoch(beat),
                "date_checkin": epoch(beat - 3_600), "date_last_push": epoch(beat - 7_200), "is_supervised": .string(random.chance(0.9) ? "1" : "0"),
                "asset_tag": .string(String(format: "DEMO-A%04d", index + 1)), "total_disk": .string("256.0000000000"),
                "available_disk": .string(String(format: "%.10f", 40 + Double(random.below(180)))),
                "enrollment_type": .string(random.chance(0.85) ? "ADE" : "User Enrollment"),
            ]
            if family == "Mac" { raw["CurrentConsoleManagedUser"] = .string(email) } else { raw["useremail"] = .string(email) }
            if ["iPhone", "iPad"].contains(family) { raw["battery"] = .string(String(format: "0.%02d", 20 + random.below(80))) }
            return raw
        }
        var byPlatform: [String: [JSONObject]] = [:]
        var index = 0
        // Apple's devices assigned to the Mosyle service, about nine in ten enrolled; one serial in lower case.
        for device in fleet.devices where fleet.assignments[device.id] == service {
            guard random.chance(0.88) else { continue }
            let family = device.attributes["productFamily"]?.string ?? "Mac"
            var serial = device.id
            if index == 3 { serial = serial.lowercased() }
            byPlatform[platform[family] ?? "ios", default: []].append(record(serial, model: device.attributes["deviceModel"]?.string ?? "Mac",
                                                                             family: family, index: index))
            index += 1
        }
        for (offset, serial) in mosyleOnly.enumerated() {
            let (model, family) = offset % 2 == 0 ? ("MacBook Air 13-inch (M3)", "Mac") : ("iPhone 16", "iPhone")
            var raw = record(serial, model: model, family: family, index: index)
            if offset == 3 { raw["date_last_beat"] = nil }   // enrolled, never checked in
            byPlatform[platform[family] ?? "ios", default: []].append(raw)
            index += 1
        }
        return byPlatform
    }

    /// Fills `stub` with the demo's Mosyle data.
    public static func load(into stub: MosyleStub, fleet: DemoFleet.Fleet, now: Date) {
        let devices = devices(fleet: fleet, now: now)
        for (os, records) in devices { stub.add(devices: records, os: os) }
        stub.add(users: DemoPeople.people.prefix(14).map { person in
            ["iduser": .string(String(format: "DEMOMU%02d", person.number)), "name": .string("\(person.first) \(person.last)"),
             "email": .string("\(person.first.lowercased()).\(person.last.lowercased())@example.com"),
             "identifier": .string("\(person.first.lowercased()).\(person.last.lowercased())"), "type": .string(person.external ? "GUEST" : "STAFF")]
        })
        stub.add(userGroups: [
            ["idusergroup": .string("DEMOMUG1"), "name": .string("Field technicians"), "identifier": .string("field"),
             "idusers_primary": .array(["DEMOMU02", "DEMOMU04", "DEMOMU07"].map(JSONValue.string))],
            ["idusergroup": .string("DEMOMUG2"), "name": .string("Design studio"), "identifier": .string("studio"),
             "idusers_primary": .array(["DEMOMU03", "DEMOMU09"].map(JSONValue.string))],
            ["idusergroup": .string("DEMOMUG3"), "name": .string("Everyone"), "identifier": .string("all"), "members": .number("14")],
        ])
        // Device groups by platform, each with its members' UDIDs, most of them compliant.
        let groups: [(os: String, id: String, name: String, take: Int)] = [
            ("mac", "DEMODG01", "Studio Macs", 6), ("mac", "DEMODG02", "Loaner Macs", 3), ("ios", "DEMODG03", "Field iPhones", 5),
            ("ios", "DEMODG04", "Lab iPads", 4), ("tvos", "DEMODG05", "Meeting rooms", 2),
        ]
        var random = DemoFleet.Random(state: 11)
        for group in groups {
            let udids = (devices[group.os] ?? []).prefix(group.take).compactMap { $0["deviceudid"]?.string }
            stub.add(deviceGroups: [["iddevicegroup": .string(group.id), "name": .string(group.name), "device_numbers": .string(String(udids.count))]],
                     os: group.os)
            stub.add(members: udids.map { ($0, random.chance(0.8)) }, toGroup: group.id)
        }
        // A member Mosyle lists that the device list doesn't: shown by its UDID.
        stub.add(members: [("DEMO-UDID-RETIRED01", false)], toGroup: "DEMODG02")
        stub.add(customAttributes: [["name": .string("Cost centre"), "id": .string("DEMOCA01"), "value": .string("Operations"), "source": .string("Manual")],
                                    ["name": .string("Kiosk mode"), "id": .string("DEMOCA02"), "value": .string("No"), "source": .string("Manual")]], os: "ios")
        stub.add(customAttributes: [["name": .string("Cost centre"), "id": .string("DEMOCA03"), "value": .string("Design"), "source": .string("Manual")],
                                    ["name": .string("Warranty tier"), "id": .string("DEMOCA04"), "value": .string("AppleCare+"), "source": .string("Import")]],
                                   os: "mac")
        let actions = ["Signed in", "Updated profile \"Wi-Fi (office)\"", "Added devices to device group \"Loaner Macs\"", "Sent an OS update to 12 devices",
                       "Changed the Lab iPads restrictions", "Signed in", "Exported the device list", "Assigned a user to DEMOM0000002"]
        let admins = ["ada.fernhill@example.com", "admin@example.com", "cleo.varga@example.com"]
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyy-MM-dd HH:mm:ss"
        stub.add(adminLogs: actions.enumerated().map { offset, action in
            ["date": .string(format.string(from: now - Double(offset) * 2.6 * 86_400 - 3_600)), "user": .string(admins[offset % admins.count]),
             "action": .string(action), "ip": .string("192.0.2.\(10 + offset)")]
        })
    }
}
#endif
