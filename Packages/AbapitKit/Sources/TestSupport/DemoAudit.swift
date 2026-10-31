#if DEBUG
// Test and demo code only: compiled out of a Release build, so the app's Release binary carries no stub
// (scripts/check_app.sh holds that).
import Foundation
import JSONAPI

/// The demo org's audit events (plan §4, demo mode), for the Activity screen, Device 360's timeline, the Dashboard's
/// recent events and their snapshots. Invented: `example.com`, `DEMO…` and `TEST…` ids, no real person's or organization's
/// name. Sixty events over the last 30 days across forty types: device lifecycle on the demo fleet's own serials (two
/// devices released from the organization are `TEST…`, no longer in the fleet), every subscription and purchase type,
/// access and security, the types no view shows, two payloads named by their object's spelling (`Icloud`, `Applecare`)
/// where Apple's attribute keys spell `ICloud` and `AppleCare`, so `payloadProblems` shows, and one type no version knows.
///
/// The stub filters by range against its own clock, which is now, so the dates are counted back from the moment the demo
/// is made: a fixed day would drift out of "the last 7 days". Written as Apple would send them, never from the models'
/// tables: a payload key a model misreads shows as a payload problem here.
public enum DemoAudit {
    /// Adds the demo's data to `stub`; `DemoOrg.make()` calls it.
    public static func load(into stub: AppleStub) { stub.add(events(now: Date())) }

    /// Who did it: the demo's own API key, two administrators, and Apple.
    struct Actor {
        let type: String
        let id: String?
        let name: String
        static let key = Actor(type: "API_USER", id: "00000000-0000-4000-8000-00000000d3e0", name: "abapit demo key")
        static let admin = Actor(type: "USER", id: "00000000-0000-4000-8000-00000000a001", name: "IT Admin (demo)")
        static let helpDesk = Actor(type: "USER", id: "00000000-0000-4000-8000-00000000a002", name: "Help Desk (demo)")
        static let apple = Actor(type: "SYSTEM", id: nil, name: "Apple Business")
    }

    /// What it was done to.
    struct Subject {
        let type: String
        let id: String
        let name: String
        static func device(_ serial: String) -> Subject { Subject(type: "DEVICE", id: serial, name: serial) }
        static func user(_ n: Int, _ address: String) -> Subject { Subject(type: "USER", id: String(format: "00000000-0000-4000-8000-00000000b%03d", n), name: address) }
        static let org = Subject(type: "ORGANIZATION", id: "DEMO-ORG-0001", name: "Example Business (demo)")
        static let domain = Subject(type: "DOMAIN", id: "example.com", name: "example.com")
        static let demoKey = Subject(type: "API_USER", id: Actor.key.id!, name: Actor.key.name)
        static let syncKey = Subject(type: "API_USER", id: "00000000-0000-4000-8000-00000000d3e2", name: "Inventory sync key")
        static let plan = Subject(type: "SUBSCRIPTION", id: "DEMOSUB0001", name: "AppleCare+ for Business (demo)")
        static let wifi = Subject(type: "DEVICE_MANAGEMENT_SETTING", id: "DEMOCFG0001", name: "Front office Wi-Fi (demo)")
        static let collection = Subject(type: "COLLECTION", id: "DEMOCOL0001", name: "Front desk iPads")
        static let location = Subject(type: "LOCATION", id: "DEMO-LOC-0001", name: "Main office (demo)")
    }

    static let sam = Subject.user(1, "sam.sample@example.com"), lee = Subject.user(2, "lee.example@example.com"),
               kim = Subject.user(3, "kim.test@example.com"), ari = Subject.user(4, "ari.demo@example.com"),
               rae = Subject.user(5, "rae.former@example.com"), guest = Subject.user(6, "guest.partner@example.org")

    /// Apple's attribute key for a type's payload: `eventData` and the type in camel case, with `ICloud` and `AppleCare`
    /// as Apple's attribute keys spell them (its object names say `Icloud` and `Applecare`).
    static func key(_ type: String, asObjectNamesSpellIt: Bool = false) -> String {
        let camel = type.split(separator: "_").map { String($0.prefix(1)) + $0.dropFirst().lowercased() }.joined()
        let spelled = asObjectNamesSpellIt ? camel : camel.replacingOccurrences(of: "Icloud", with: "ICloud").replacingOccurrences(of: "Applecare", with: "AppleCare")
        return "eventData" + spelled
    }

    static func iso(_ date: Date) -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime]
        return format.string(from: date)
    }

    /// The sixty events, dated back from `now`.
    public static func events(now: Date) -> [Resource] {
        let fleet = DemoFleet.make()
        let serials = fleet.devices.map(\.id).sorted()
        let names = Dictionary(uniqueKeysWithValues: fleet.services.map { ($0.id, $0.attributes["serverName"]?.string ?? $0.id) })
        func service(_ serial: String) -> String { fleet.assignments[serial].flatMap { names[$0] } ?? "Mosyle Business" }
        var events: [Resource] = []
        func add(_ hoursAgo: Double, _ type: String, _ category: String, by actor: Actor, on subject: Subject, outcome: String = "SUCCESS",
                 group: String? = nil, payload: JSONObject = [:], named: String? = nil) {
            var attributes: JSONObject = [
                "eventDateTime": .string(iso(now.addingTimeInterval(-hoursAgo * 3_600))), "type": .string(type), "category": .string(category),
                "actorType": .string(actor.type), "actorName": .string(actor.name), "subjectType": .string(subject.type),
                "subjectId": .string(subject.id), "subjectName": .string(subject.name), "outcome": .string(outcome),
            ]
            if let id = actor.id { attributes["actorId"] = .string(id) }
            if let group { attributes["groupId"] = .string(group) }
            attributes["eventDataPropertyKey"] = .string(named ?? key(type))
            attributes[key(type)] = .object(payload)
            events.append(Resource(type: "auditEvents", id: String(format: "DEMOAUDIT%04d", events.count + 1), attributes: attributes))
        }
        func added(_ hoursAgo: Double, _ serial: String, from source: String = "APPLE", group: String? = nil) {
            add(hoursAgo, "DEVICE_ADDED_TO_ORG", "DEVICE_INVENTORY", by: .apple, on: .device(serial), group: group, payload: [
                "serialNumber": .string(serial), "purchaseSourceType": .string(source), "purchaseSourceId": .string(source == "APPLE" ? "100200" : "300400"),
            ])
        }
        func assigned(_ hoursAgo: Double, _ serial: String, to name: String? = nil, by actor: Actor = .key, outcome: String = "SUCCESS", group: String? = nil) {
            add(hoursAgo, "DEVICE_ASSIGNED_TO_SERVER", "DEVICE_MANAGEMENT", by: actor, on: .device(serial), outcome: outcome, group: group, payload: [
                "serialNumber": .string(serial), "targetServerName": .string(name ?? service(serial)),
            ])
        }
        func unassigned(_ hoursAgo: Double, _ serial: String) {
            add(hoursAgo, "DEVICE_UNASSIGNED_FROM_SERVER", "DEVICE_MANAGEMENT", by: .admin, on: .device(serial), payload: ["serialNumber": .string(serial)])
        }
        func released(_ hoursAgo: Double, _ serial: String, by entity: String, id: String) {
            add(hoursAgo, "DEVICE_REMOVED_FROM_ORG", "DEVICE_INVENTORY", by: .admin, on: .device(serial), payload: [
                "serialNumber": .string(serial), "releaseEntityType": .string(entity), "releaseEntityId": .string(id),
            ])
        }
        let day = 24.0

        // Device lifecycle: the first serials as the Devices table sorts them, so Device 360's timeline has events.
        assigned(2, serials[0])
        added(3, serials[0])
        assigned(8, serials[10])
        assigned(1.1 * day, serials[1], by: .admin)
        added(1.2 * day, serials[1], from: "RESELLER")
        assigned(2.0 * day, serials[2], to: "Mosyle Business", by: .admin)
        unassigned(2.05 * day, serials[2])
        assigned(2.1 * day, serials[2], to: "Jamf Pro (old)", by: .admin)
        assigned(2.15 * day, serials[11])
        added(2.2 * day, serials[11])
        assigned(3.2 * day, serials[12], outcome: "FAILURE")
        add(4 * day, "DEVICE_IS_ERASED", "DEVICE_MANAGEMENT", by: .helpDesk, on: .device(serials[3]))
        released(5 * day, "TESTREL00001", by: "USER", id: Actor.admin.id!)
        for (n, serial) in serials[4...7].enumerated() {
            added(9 * day + Double(n) * 0.1, serial, group: "DEMOGRP0001")
            assigned(8.9 * day + Double(n) * 0.1, serial, group: "DEMOGRP0001")
        }
        released(15 * day, "TESTREL00002", by: "RESELLER", id: "300400")
        unassigned(20 * day, serials[8])
        added(28 * day, serials[9])

        // Subscriptions and purchases: every type, two named by their object's spelling (Phase 2a review M1).
        add(6, "SUBJECT_HAS_APPLECARE_PURCHASE_ADDED", "PURCHASING", by: .apple, on: sam, payload: ["subscriptionId": .string("DEMOSUB0002")],
            named: key("SUBJECT_HAS_APPLECARE_PURCHASE_ADDED", asObjectNamesSpellIt: true))
        add(1 * day, "SUBJECT_HAS_ICLOUD_STORAGE_PURCHASE_ADDED", "PURCHASING", by: .apple, on: lee, payload: ["subscriptionId": .string("DEMOSUB0003")],
            named: key("SUBJECT_HAS_ICLOUD_STORAGE_PURCHASE_ADDED", asObjectNamesSpellIt: true))
        add(3 * day, "SUBSCRIPTION_CREATED", "PURCHASING", by: .admin, on: .plan, payload: ["planCaption": .string("AppleCare+ for Business, 3 years")])
        add(8 * day, "SUBSCRIPTION_UPDATED", "PURCHASING", by: .admin, on: .plan, payload: ["planCaption": .string("AppleCare+ for Business, 3 years, 120 seats")])
        add(12 * day, "SUBJECT_HAS_ICLOUD_STORAGE_PURCHASE_REMOVED", "PURCHASING", by: .apple, on: kim, payload: ["subscriptionId": .string("DEMOSUB0004")])
        add(18 * day, "SUBJECT_HAS_APPLECARE_PURCHASE_REMOVED", "PURCHASING", by: .apple, on: sam, payload: ["subscriptionId": .string("DEMOSUB0005")])
        add(25 * day, "SUBSCRIPTION_DELETED", "PURCHASING", by: .admin, on: .plan, payload: ["planCaption": .string("AppleCare+ for Business, 1 year")])

        // Access and security.
        add(1, "API_ACCOUNT_KEY_GENERATED", "ACCOUNT_ACTIVITY", by: .admin, on: .demoKey, payload: ["keyId": .string("DEMOKEY0002")])
        add(5, "ACCOUNT_PASSWORD_CHANGED", "ACCOUNT_ACTIVITY", by: .helpDesk, on: sam, payload: ["activityId": .string("DEMOACT0001")])
        add(12, "ACCOUNT_ROLE_LOCATION_CHANGED", "ACCOUNT_ACTIVITY", by: .admin, on: lee, payload: [
            "accountRoleLocationList": .array([.object(["roleName": .string("Staff"), "locationUniqueIdentifier": .string(Subject.location.id)])]),
        ])
        add(2 * day, "ROLE_UPDATED", "ORGANIZATION", by: .admin, on: .org, payload: [
            "privilegesAdded": .array([.string("Manage devices")]), "privilegesRemoved": .array([.string("Manage apps and books")]),
        ])
        add(2.5 * day, "API_ACCOUNT_KEY_REVOKED", "ACCOUNT_ACTIVITY", by: .admin, on: .demoKey, payload: ["keyId": .string("DEMOKEY0000")])
        add(3.5 * day, "ACCOUNT_ADDED", "ACCOUNT_ACTIVITY", by: .admin, on: ari)
        add(6 * day, "TERMS_ACCEPTED", "ORGANIZATION", by: .admin, on: .org, payload: ["termsName": .string("Apple Business Agreement (demo)")])
        add(6.5 * day, "APPLE_SERVICES_SETTINGS_UPDATED", "ORGANIZATION", by: .admin, on: .org, payload: [
            "settingsEnabled": .array([.string("FaceTime"), .string("iMessage")]), "settingsDisabled": .array([.string("Game Center")]),
        ])
        add(10 * day, "DOMAIN_ADDED", "ORGANIZATION", by: .admin, on: .domain)
        add(9.9 * day, "DOMAIN_VERIFIED", "ORGANIZATION", by: .apple, on: .domain)
        add(11 * day, "DOMAIN_FEDERATION_ENABLED", "ORGANIZATION", by: .admin, on: .domain, payload: [
            "activityId": .string("DEMOACT0002"), "scimActivityId": .string("DEMOACT0003"),
        ])
        add(11.1 * day, "IDP_CREATED", "ORGANIZATION", by: .admin, on: .org, payload: ["protocol": .string("OIDC"), "vendorName": .string("GENERIC_IDP")])
        add(13 * day, "IDP_ACCOUNT_SYNC_ENABLED", "ORGANIZATION", by: .admin, on: .org, payload: [
            "activityId": .string("DEMOACT0004"), "vendorName": .string("GENERIC_IDP"),
        ])
        add(14 * day, "API_ACCOUNT_CREATED_WITH_KEY", "ACCOUNT_ACTIVITY", by: .admin, on: .syncKey, payload: ["keyId": .string("DEMOKEY0003")])
        add(16 * day, "API_ACCOUNT_ROLE_LOCATION_CHANGED", "ACCOUNT_ACTIVITY", by: .admin, on: .syncKey, payload: [
            "apiAccountRoleLocationList": .array([.object(["roleName": .string("Device Enrollment Manager"), "locationUniqueIdentifier": .string(Subject.location.id)])]),
        ])
        add(17 * day, "API_ACCOUNT_NAME_CHANGED", "ACCOUNT_ACTIVITY", by: .admin, on: .syncKey, payload: ["newName": .string("Inventory sync key")])
        add(19 * day, "ROLE_CREATED", "ORGANIZATION", by: .admin, on: .org, payload: ["privileges": .array([.string("View devices"), .string("View people")])])
        add(21 * day, "BATCH_PASSWORD_RESET_INITIATED", "ACCOUNT_ACTIVITY", by: .admin, on: .location, payload: ["activityId": .string("DEMOACT0005")])
        add(22 * day, "EXTERNAL_ACCOUNT_INVITED", "ACCOUNT_ACTIVITY", by: .admin, on: guest)
        add(23 * day, "ACCOUNT_DELETED", "ACCOUNT_ACTIVITY", by: .admin, on: rae)
        add(24 * day, "ACCOUNT_ROLE_LOCATION_CHANGED", "ACCOUNT_ACTIVITY", by: .helpDesk, on: kim, outcome: "FAILURE", payload: [
            "accountRoleLocationList": .array([.object(["roleName": .string("Administrator"), "locationUniqueIdentifier": .string(Subject.location.id)])]),
        ])
        add(26 * day, "EXTERNAL_ACCOUNT_ASSOCIATED", "ACCOUNT_ACTIVITY", by: .apple, on: guest)
        add(27 * day, "API_ACCOUNT_DELETED", "ACCOUNT_ACTIVITY", by: .admin, on: Subject(type: "API_USER", id: "00000000-0000-4000-8000-00000000d3e1", name: "Old export key"))

        // The types no view shows.
        add(7, "CONFIG_SETTINGS_UPDATED", "DEVICE_MANAGEMENT", by: .admin, on: .wifi, payload: [
            "configId": .string(Subject.wifi.id), "configType": .string("CUSTOM_SETTING"), "configVersion": .string("3"),
        ])
        add(4.5 * day, "COLLECTION_CREATED", "DEVICE_MANAGEMENT", by: .admin, on: .collection, payload: [
            "name": .string(Subject.collection.name), "description": .string("Shared iPads at reception"),
        ])
        add(13.5 * day, "CONFIG_SETTINGS_CREATED", "DEVICE_MANAGEMENT", by: .admin, on: .wifi, payload: [
            "configId": .string(Subject.wifi.id), "configType": .string("CUSTOM_SETTING"), "configVersion": .string("1"),
        ])
        add(20.5 * day, "ACCOUNT_IMAGE_SET", "ACCOUNT_ACTIVITY", by: .helpDesk, on: lee)
        add(29 * day, "COLLECTION_UPDATED", "DEVICE_MANAGEMENT", by: .admin, on: .collection, payload: [
            "name": .string(Subject.collection.name), "description": .string("Shared iPads at reception and the lobby"),
        ])

        // A type Apple adds after this version: shown raw, in Other types, never dropped (invariant 10).
        add(1.5 * day, "DEMO_TYPE_NOT_YET_DOCUMENTED", "ORGANIZATION", by: .apple, on: .org, payload: [
            "note": .string("A type this version doesn't know"), "count": .number("3"),
        ])
        return events
    }
}
#endif
