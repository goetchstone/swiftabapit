#if DEBUG
// Test and demo code only: compiled out of a Release build, so the app's Release binary carries no stub
// (scripts/check_app.sh holds that).
import Foundation
import JSONAPI

/// The demo org's content (plan §4, demo mode): 12 apps, 4 packages, 4 blueprints with their members and 8 configurations
/// of several types, for the Content screen and its snapshots. Invented: every name starts "Example", every address is
/// `example.com`, and dates are fixed against `DemoFleet.reference`, so screenshots don't move.
///
/// A blueprint's members are the demo fleet's devices (`DemoFleet.make()`, by serial) and `DemoPeople`'s users and user
/// groups by their ids (`DEMOUSER…`, `DEMOUG…`), so the detail names each from what the stub includes, as it would a
/// tenant's (`DemoTests` holds that every member names something). The Wi-Fi custom setting's profile holds `canary` as
/// its password: no real secret, and what the tests look for to prove a profile reaches no screen, CSV or description
/// unmasked (invariant 11).
public enum DemoContent {
    /// The custom setting's Wi-Fi password: invented, and never shown unmasked.
    public static let canary = "demo-canary-office-wifi-7Kq2"

    static let day: TimeInterval = 86_400

    static func date(_ daysAgo: Double) -> JSONValue { .string(DemoFleet.iso(DemoFleet.reference - daysAgo * day)) }

    /// A made-up SHA-256, the same every run.
    static func hash(_ seed: UInt64) -> String {
        var random = DemoFleet.Random(state: seed)
        return (0..<4).map { _ in String(format: "%016llx", random.next()) }.joined()
    }

    static func strings(_ values: [String]) -> JSONValue { .array(values.map { .string($0) }) }

    /// An app's Adam ID: `appID(1)` is the first app's.
    static func appID(_ number: Int) -> String { String(1_000_000_000 + number) }

    typealias App = (name: String, slug: String, version: String, platforms: [String], custom: Bool)
    static let appList: [App] = [
        ("Example Field Notes", "fieldnotes", "4.2.1", ["IOS", "IPADOS"], false),
        ("Example Timesheets", "timesheets", "2.8", ["IOS", "IPADOS", "MACOS"], false),
        ("Example Reader", "reader", "1.9.3", ["MACOS"], false),
        ("Example Scanner", "scanner", "3.0", ["IOS"], false),
        ("Example Badge", "badge", "1.0.4", ["IOS"], true),
        ("Example Help Desk", "helpdesk", "5.1", ["MACOS", "IOS"], true),
        ("Example Maps", "maps", "7.3", ["IOS", "IPADOS", "WATCHOS"], false),
        ("Example Notes", "notes", "12.0", ["MACOS", "IOS", "IPADOS", "VISIONOS"], false),
        ("Example Chat", "chat", "24.10", ["MACOS", "IOS", "IPADOS"], false),
        ("Example Slides", "slides", "3.4", ["MACOS", "IPADOS"], false),
        ("Example Signage", "signage", "2.0", ["TVOS"], true),
        ("Example Training", "training", "1.6", ["VISIONOS", "IPADOS"], false),
    ]

    public static let apps: [Resource] = appList.enumerated().map { index, app in
        let id = appID(index + 1)
        var attributes: JSONObject = [
            "name": .string(app.name), "bundleId": .string("com.example.\(app.slug)"), "version": .string(app.version),
            "supportedOS": strings(app.platforms.map { "SUPPORTED_OS_\($0)" }), "isCustomApp": .bool(app.custom),
            "websiteUrl": .string("https://www.example.com/\(app.slug)"),
        ]
        // A custom app is the organization's own: not in the public App Store.
        if !app.custom { attributes["appStoreUrl"] = .string("https://apps.example.com/app/id\(id)") }
        return Resource(type: "apps", id: id, attributes: attributes)
    }

    typealias Package = (id: String, name: String, version: String, url: String, bundles: [String], summary: String)
    /// Two locations carry what a real one might (a signed query, a user and password): the detail masks both.
    static let packageList: [Package] = [
        ("demo-package-01", "Example Printer Driver", "2.4.0", "https://packages.example.com/drivers/printer-driver-2.4.0.pkg",
         ["com.example.printerdriver"], "Drivers for the office printers."),
        ("demo-package-02", "Example VPN Client", "6.1",
         "https://packages.example.com/vpn/vpn-client-6.1.pkg?expires=1793000000&signature=TESTSIGNATURE0001",
         ["com.example.vpnclient", "com.example.vpnclient.helper"], "The VPN client and its helper."),
        ("demo-package-03", "Example Security Agent", "3.2.7",
         "https://deploy:demo-not-a-password@packages.example.com/agent/security-agent-3.2.7.pkg",
         ["com.example.securityagent"], "Endpoint agent for the security team."),
        ("demo-package-04", "Example Fonts", "1.0", "https://packages.example.com/fonts/example-fonts-1.0.pkg",
         ["com.example.fonts"], "The brand typefaces."),
    ]

    public static let packages: [Resource] = packageList.enumerated().map { index, package in
        Resource(type: "packages", id: package.id, attributes: [
            "name": .string(package.name), "version": .string(package.version), "url": .string(package.url),
            "hash": .string(hash(UInt64(100 + index))), "bundleIds": strings(package.bundles), "description": .string(package.summary),
            "createdDateTime": date(400 - 60 * Double(index)), "updatedDateTime": date(30 - 5 * Double(index)),
        ])
    }

    /// The Wi-Fi profile a custom setting carries, `canary` its password.
    static let wifiProfile = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>PayloadContent</key>
            <array>
                <dict>
                    <key>AutoJoin</key>
                    <true/>
                    <key>EncryptionType</key>
                    <string>WPA2</string>
                    <key>Password</key>
                    <string>\(canary)</string>
                    <key>PayloadIdentifier</key>
                    <string>com.example.wifi.office.payload</string>
                    <key>PayloadType</key>
                    <string>com.apple.wifi.managed</string>
                    <key>PayloadUUID</key>
                    <string>00000000-0000-4000-8000-00000000f002</string>
                    <key>PayloadVersion</key>
                    <integer>1</integer>
                    <key>SSID_STR</key>
                    <string>Example Office</string>
                </dict>
            </array>
            <key>PayloadDisplayName</key>
            <string>Example Office Wi-Fi</string>
            <key>PayloadIdentifier</key>
            <string>com.example.wifi.office</string>
            <key>PayloadType</key>
            <string>Configuration</string>
            <key>PayloadUUID</key>
            <string>00000000-0000-4000-8000-00000000f001</string>
            <key>PayloadVersion</key>
            <integer>1</integer>
        </dict>
        </plist>
        """

    typealias Setting = (id: String, name: String, type: String, platforms: [String])
    static let configurationList: [Setting] = [
        ("demo-config-01", "Example Office Wi-Fi (profile)", "CUSTOM_SETTING", ["MACOS", "IOS"]),
        ("demo-config-02", "Example Guest Wi-Fi", "WIFI", ["IOS", "MACOS"]),
        ("demo-config-03", "Example FileVault", "FILE_VAULT", ["MACOS"]),
        ("demo-config-04", "Example Software Updates", "SOFTWARE_UPDATE", ["MACOS", "IOS"]),
        ("demo-config-05", "Example Screen Lock", "AUTHENTICATION_SCREEN_LOCK", ["MACOS", "IOS"]),
        ("demo-config-06", "Example VPN", "VPN", ["IOS", "MACOS"]),
        ("demo-config-07", "Example Intranet Web Clip", "WEB_CLIP", ["IOS"]),
        ("demo-config-08", "Example Lobby Display", "CONFERENCE_ROOM_DISPLAY", ["TVOS"]),
    ]

    public static let configurations: [Resource] = configurationList.enumerated().map { index, setting in
        var attributes: JSONObject = [
            "type": .string(setting.type), "name": .string(setting.name), "configuredForPlatforms": strings(setting.platforms.map { "PLATFORM_\($0)" }),
            "createdDateTime": date(500 - 40 * Double(index)), "updatedDateTime": date(20 + 3 * Double(index)),
        ]
        // Only a custom setting has a profile; the stub's list sends it as null, as Apple's does, and the single read whole.
        if setting.type == "CUSTOM_SETTING" {
            attributes["customSettingsValues"] = .object(["configurationProfile": .string(wifiProfile), "filename": .string("office-wifi.mobileconfig")])
        }
        return Resource(type: "configurations", id: setting.id, attributes: attributes)
    }

    typealias Plan = (id: String, name: String, summary: String, status: String, deficient: Bool)
    static let blueprintList: [Plan] = [
        ("demo-blueprint-01", "Example Office Macs", "The Macs on the office floors.", "ACTIVE", false),
        ("demo-blueprint-02", "Example Field iPads", "iPads for the field teams.", "ACTIVE", false),
        ("demo-blueprint-03", "Example Shared iPhones", "Shift phones, shared at the front desk.", "ACTIVE", true),
        ("demo-blueprint-04", "Example Lobby Displays", "Apple TVs in the lobbies.", "TO_BE_DELETED", false),
    ]

    public static let blueprints: [Resource] = blueprintList.enumerated().map { index, plan in
        Resource(type: "blueprints", id: plan.id, attributes: [
            "name": .string(plan.name), "description": .string(plan.summary), "status": .string(plan.status),
            "appLicenseDeficient": .bool(plan.deficient), "createdDateTime": date(600 - 90 * Double(index)),
            "updatedDateTime": date(10 + 7 * Double(index)),
        ])
    }

    /// Each blueprint's members, by relationship, as `relate(_:_:_:to:)` files them: `fleet`'s devices of a family, the
    /// first ones in its order.
    static func members(fleet: [Resource]) -> [(blueprint: String, relationship: String, ids: [String])] {
        func devices(_ family: String, _ count: Int) -> [String] {
            Array(fleet.filter { $0.attributes["productFamily"]?.string == family }.prefix(count).map(\.id))
        }
        /// `DemoPeople`'s users: the field teams carry the field iPads, operations the front desk's shared iPhones.
        func people(_ matching: (DemoPeople.Person) -> Bool, _ count: Int) -> [String] {
            Array(DemoPeople.people.filter(matching).prefix(count).map(\.id))
        }
        return [
            ("demo-blueprint-01", "apps", [1, 3, 8, 9, 10].map(appID)),
            ("demo-blueprint-01", "packages", ["demo-package-01", "demo-package-03", "demo-package-04"]),
            ("demo-blueprint-01", "configurations", ["demo-config-01", "demo-config-03", "demo-config-04", "demo-config-05"]),
            ("demo-blueprint-01", "orgDevices", devices("Mac", 12)),
            ("demo-blueprint-01", "userGroups", ["DEMOUG01"]),
            ("demo-blueprint-02", "apps", [1, 4, 7, 12].map(appID)),
            ("demo-blueprint-02", "configurations", ["demo-config-02", "demo-config-07"]),
            ("demo-blueprint-02", "orgDevices", devices("iPad", 8)),
            ("demo-blueprint-02", "users", people({ $0.department == "Field" }, 6)),
            ("demo-blueprint-02", "userGroups", ["DEMOUG02"]),
            ("demo-blueprint-03", "apps", [2, 4, 5, 9].map(appID)),
            ("demo-blueprint-03", "packages", ["demo-package-02"]),
            ("demo-blueprint-03", "configurations", ["demo-config-05", "demo-config-06"]),
            ("demo-blueprint-03", "orgDevices", devices("iPhone", 10)),
            ("demo-blueprint-03", "users", people({ $0.department == "Operations" }, 3)),
            ("demo-blueprint-04", "apps", [11].map(appID)),
            ("demo-blueprint-04", "configurations", ["demo-config-08"]),
            ("demo-blueprint-04", "orgDevices", devices("AppleTV", 4)),
        ]
    }

    /// Adds the demo's data to `stub`; `DemoOrg.make()` calls it. The blueprints' devices are `fleet`'s, the demo fleet's
    /// unless a test gives its own.
    public static func load(into stub: AppleStub, fleet: [Resource] = DemoFleet.make().devices) {
        stub.add(apps + packages + configurations + blueprints)
        for member in members(fleet: fleet) { stub.relate("blueprints", member.blueprint, member.relationship, to: member.ids) }
    }
}
#endif
