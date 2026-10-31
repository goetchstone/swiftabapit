import AppleBusiness
import AppleModels
import Foundation
import HTTPCore
import JSONAPI
import Orgs
import Testing
import TestSupport

/// The Business-only reads against the strict stub: people, content and Apple MDM, Apple's own examples served where
/// they exist, the contract's shapes where they don't. Each read's success, and each failure the client handles.
@Suite("Business reads", .serialized)
struct BusinessReadTests {
    /// A harness whose stub serves Apple's examples: the users, groups, org units, apps, packages and the configuration.
    static func examples() async throws -> Harness {
        let harness = try await Harness()
        for name in ["get-users", "get-user-groups", "get-organizational-units", "get-apps", "get-packages", "get-configuration-information"] {
            harness.stub.add(try Harness.example(name))
        }
        return harness
    }

    @Test func peopleReadAsApplesExamplesSayAndEachOneByItsID() async throws {
        let harness = try await Self.examples()
        let users = try await Harness.all(harness.client.users())
        let first = try #require(users.first)
        #expect(users.count == 1 && first.fullName == "John A Doe" && first.status == .known(.active) && first.unreadAttributes.isEmpty)
        #expect(first.roleOuList?.first?.ouID == "OU123456" && first.phoneNumbers?.first?.type == .known(.work))
        #expect(try await harness.client.user(first.id).email == "john.doe@example.com")

        let groups = try await Harness.all(harness.client.userGroups())
        let group = try #require(groups.first)
        #expect(try await harness.client.userGroup(group.id).name == group.name)
        harness.stub.relate("userGroups", group.id, "users", to: ["U1", "U2"])
        #expect(try await Harness.all(harness.client.userGroupMemberIDs(group.id)) == ["U1", "U2"])

        let units = try await Harness.all(harness.client.organizationalUnits())
        let unit = try #require(units.first)
        #expect(try await harness.client.organizationalUnit(unit.id).name == unit.name)
        harness.stub.relate("organizationalUnits", unit.id, "users", to: ["U3"])
        #expect(try await Harness.all(harness.client.organizationalUnitMemberIDs(unit.id)) == ["U3"])
        #expect(!harness.reads.contains { $0.contains("api-school") })
    }

    @Test func contentReadsAsApplesExamplesSay() async throws {
        let harness = try await Self.examples()
        let apps = try await Harness.all(harness.client.apps())
        let app = try #require(apps.first)
        #expect(app.supportedOS?.isEmpty == false && app.unreadAttributes.isEmpty)
        #expect(try await harness.client.app(app.id).bundleID == app.bundleID)
        let packages = try await Harness.all(harness.client.packages())
        let package = try #require(packages.first)
        #expect(try await harness.client.package(package.id).hash == package.hash)
    }

    /// The configuration list sends a custom setting's profile as null (abapit); only the single read carries it, and the
    /// detail shows it through `ProfileText`.
    @Test func onlyTheSingleConfigurationReadCarriesItsProfile() async throws {
        let harness = try await Self.examples()
        let listed = try #require(try await Harness.all(harness.client.configurations()).first)
        #expect(listed.type == .known(.customSetting) && listed.customSettings == nil)
        #expect(listed.attributes["customSettingsValues"] == .null, "the list's null, read as no custom settings")
        let single = try await harness.client.configuration(listed.id)
        #expect(single.customSettings?.filename == "WiFi.mobileconfig" && single.customSettings?.profileText != nil)
    }

    /// Every public text a value can be turned into: its description, its debug description and its dump.
    static func printed(_ value: Any) -> String {
        var dumped = ""
        dump(value, to: &dumped)
        return [String(describing: value), String(reflecting: value), dumped].joined(separator: "\n")
    }

    /// A custom setting's profile reaches no public value: not the view's resource or attributes, its custom settings'
    /// object, a description or dump of either, the list (were Apple to send the profile there), a blueprint's included
    /// configuration, or the acceptance pass's text. Only `profileText` shows it, masked (Phase 2a review M2: a key=value
    /// dump of `configuration.attributes` printed the Wi-Fi password).
    @Test func aCustomSettingsProfileReachesNoPublicValue() async throws {
        let canary = "canary-\(UUID().uuidString)"
        let profile = """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>SSID_STR</key><string>Office</string><key>Password</key><string>\(canary)</string></dict></plist>
            """
        let signed = Data(profile.utf8).base64EncodedString()
        func leaks(_ text: String) -> Bool { text.contains(canary) || text.contains(signed) }
        let values: JSONValue = .object(["configurationProfile": .string(profile), "filename": .string("Office.mobileconfig"),
                                         "signedProfile": .string(signed), "note": .null])
        let custom = Resource(type: "configurations", id: "C1", attributes: ["type": .string("CUSTOM_SETTING"), "name": .string("Office Wi-Fi"),
                                                                             "customSettingsValues": values])
        let harness = try await Harness()
        harness.stub.add([custom, Resource(type: "blueprints", id: "BP1", attributes: ["name": .string("Office")])])
        harness.stub.relate("blueprints", "BP1", "configurations", to: ["C1"])

        let configuration = try await harness.client.configuration("C1")
        #expect(!leaks(Self.printed(configuration)) && !leaks(Self.printed(configuration.resource)) && !leaks(configuration.resource.asJSON.jsonText))
        for (key, value) in configuration.attributes { #expect(!leaks(value.jsonText), "\(key)") }
        let settings = try #require(configuration.customSettings)
        #expect(!leaks(Self.printed(settings)) && !leaks(JSONValue.object(settings.object).jsonText))
        // The keys stay, for an every-attribute view and the pass; the file name and a null are as Apple sent them.
        #expect(settings.object.keys == ["configurationProfile", "filename", "signedProfile", "note"] && settings.unreadFields == ["signedProfile", "note"])
        #expect(settings.object["configurationProfile"] == .string(CustomSettingsValues.withheld) && settings.object["note"] == .null)
        #expect(settings.filename == "Office.mobileconfig" && configuration.unreadAttributes.isEmpty)
        // The detail's view of it: the profile, masked.
        let shown = try #require(settings.profileText?.text)
        #expect(shown.contains("<string>Office</string>") && shown.contains(ProfileText.mask) && !leaks(shown))

        // The list, had Apple sent the profile there too.
        harness.stub.queue(200, for: "/v1/configurations?", body: "{\"data\":[\(custom.asJSON.jsonText)]}")
        let listed = try await Harness.all(harness.client.configurations())
        #expect(listed.count == 1 && !leaks(Self.printed(listed)) && listed.first?.customSettings?.profileText?.text.contains(ProfileText.mask) == true)

        // A blueprint's included configuration.
        let read = try await harness.client.blueprint("BP1", include: [.configurations])
        let members = try BlueprintTests.members(read)
        let included = try #require(members.included.first { $0.id == "C1" })
        #expect(included.attributes["customSettingsValues"]?["configurationProfile"] == .string(CustomSettingsValues.withheld))
        #expect(!leaks(Self.printed(read)) && !leaks(JSONValue.array(members.included.map(\.asJSON)).jsonText))

        // The acceptance pass reads the custom setting alone, and its text names its keys and none of its values.
        let report = await harness.client.acceptancePass()
        #expect(harness.reads.contains { $0.hasPrefix("GET api-business.apple.com/v1/configurations/C1") })
        #expect(report.text.contains("\nconfigurations/{id}: ok, 1 item · unknown keys customSettingsValues.note, customSettingsValues.signedProfile\n"))
        #expect(!leaks(report.text) && !leaks(Self.printed(report)), "\(report.text)")
    }

    /// A custom setting whose values aren't an object, or whose profile isn't a string, reads as no profile: the pass says
    /// which with a count, on the single read and on the list, never `ok` with nothing said (verifier round 2: both read
    /// `configurations/{id}: ok, 1 item`). The contract types the values as an object holding a string profile.
    @Test func aCustomSettingOfAnotherShapeIsSaid() async throws {
        let base64 = Data("<plist version=\"1.0\"><dict><key>SSID_STR</key><string>Office</string></dict></plist>".utf8).base64EncodedString()
        for (values, said) in [(JSONValue.string(base64), "custom settings not an object"),
                               (.object(["configurationProfile": .object(["SSID_STR": .string("Office")]), "filename": .string("x.mobileconfig")]),
                                "profile not a string")] {
            let harness = try await Harness()
            func custom(_ id: String) -> Resource {
                Resource(type: "configurations", id: id, attributes: ["type": .string("CUSTOM_SETTING"), "customSettingsValues": values])
            }
            harness.stub.add([custom("C1")])
            #expect(try await harness.client.configuration("C1").customSettings?.profileText == nil)
            var report = await harness.client.acceptancePass()
            #expect(report.text.contains("\nconfigurations: ok, 1 item\n"), "the list's null is no problem: \(report.text)")
            #expect(report.text.contains("\nconfigurations/{id}: ok, 1 item · \(said) in 1 item\n"), "\(report.text)")
            // Had Apple sent them on the list: two of a kind, counted as two.
            harness.stub.queue(200, for: "/v1/configurations?", body: "{\"data\":[\(custom("C1").asJSON.jsonText),\(custom("C2").asJSON.jsonText)]}")
            report = await harness.client.acceptancePass()
            #expect(report.text.contains("\nconfigurations: ok, 2 items · \(said) in 2 items\n"), "\(report.text)")
        }
    }

    /// The Apple-managed devices and each one's posture from the documented `/details`: the stub has no route for
    /// abapit's undocumented `mdmDevices/{id}`, so a read of it would fail the test.
    @Test func anAppleManagedDevicesPostureComesFromDetails() async throws {
        let harness = try await Harness()
        harness.stub.add([Resource(type: "mdmDevices", id: "MD1", attributes: ["serialNumber": .string("TESTMD000001"), "productFamily": .string("Mac")])])
        harness.stub.setDetails("MD1", Resource(type: "mdmDeviceDetails", id: "MD1", attributes: [
            "serialNumber": .string("TESTMD000001"), "osVersion": .string("27.0"), "isFileVaultEnabled": .bool(true),
            "storageTotalCapacity": .number("994662584320"), "deviceLockStatus": .string("UNLOCKED")]))
        let device = try #require(try await Harness.all(harness.client.mdmDevices()).first)
        #expect(device.productFamily == .known(.mac))
        let details = try await harness.client.mdmDeviceDetails(device.id)
        #expect(details.isFileVaultEnabled == true && details.storageTotal == 994_662_584_320 && details.lockStatus == .known(.unlocked))
        #expect(harness.reads.last?.hasPrefix("GET api-business.apple.com/v1/mdmDevices/MD1/details") == true)
        // The undocumented read abapit sent is one the strict stub doesn't serve.
        let undocumented = try? await harness.raw("/v1/mdmDevices/MD1")
        #expect(undocumented == nil)
    }

    /// A member list whose linkages are of another type, or lack an id, is malformed on any page, never a list of
    /// someone else's ids (as an assigned server that isn't one is).
    @Test(arguments: [#"{"data":[{"type":"users","id":"U1"},{"type":"apps","id":"361309726"}]}"#, #"{"data":[{"type":"Users","id":"U1"}]}"#,
                      #"{"data":[{"type":"users","id":""}]}"#, #"{"data":[{"type":"usersX","id":"U1"}]}"#])
    func aMemberLinkageOfAnotherTypeIsMalformed(body: String) async throws {
        let harness = try await Self.examples()
        let group = try #require(try await Harness.all(harness.client.userGroups()).first)
        let unit = try #require(try await Harness.all(harness.client.organizationalUnits()).first)
        harness.stub.queue(200, for: "/v1/userGroups/\(group.id)/relationships/users", body: body)
        await #expect(throws: AppleAPIError.malformed("linkages of type users")) { _ = try await Harness.all(harness.client.userGroupMemberIDs(group.id)) }
        harness.stub.queue(200, for: "/v1/organizationalUnits/\(unit.id)/relationships/users", body: body)
        await #expect(throws: AppleAPIError.malformed("linkages of type users")) {
            _ = try await Harness.all(harness.client.organizationalUnitMemberIDs(unit.id))
        }
        // A service's device list is held the same way.
        harness.stub.add(services: [Harness.service("SVC1", name: "Mosyle")])
        harness.stub.queue(200, for: "/v1/mdmServers/SVC1/relationships/devices", body: #"{"data":[{"type":"users","id":"U1"}]}"#)
        await #expect(throws: AppleAPIError.malformed("linkages of type orgDevices")) { _ = try await Harness.all(harness.client.serviceDeviceIDs("SVC1")) }
    }

    /// A later page of members of another type is malformed too, after the pages before it.
    @Test func aLaterMemberPageOfAnotherTypeIsMalformed() async throws {
        let harness = try await Self.examples()
        let group = try #require(try await Harness.all(harness.client.userGroups()).first)
        harness.stub.relate("userGroups", group.id, "users", to: (0..<1_500).map { "U\($0)" })
        harness.stub.queue(200, for: "/v1/userGroups/\(group.id)/relationships/users?cursor=", body: #"{"data":[{"type":"userGroups","id":"G1"}]}"#)
        var read = 0
        await #expect(throws: AppleAPIError.malformed("linkages of type users")) {
            for try await page in harness.client.userGroupMemberIDs(group.id) { read += page.items.count }
        }
        #expect(read == 1_000)
    }

    /// A 403 on one section is that section's: the others still read. A 404 for an id is `.notFound`; a 429 is waited out.
    @Test func aForbiddenSectionAMissingIDAndARateLimitAreEachTheirOwn() async throws {
        let harness = try await Self.examples()
        harness.stub.forbid("/v1/users")
        await #expect(throws: AppleAPIError.forbidden(code: "FORBIDDEN_ERROR")) { _ = try await Harness.all(harness.client.users()) }
        await #expect(throws: AppleAPIError.forbidden(code: "FORBIDDEN_ERROR")) { _ = try await harness.client.user("1234567890") }
        #expect(try await Harness.all(harness.client.apps()).count == 1)
        for read in [{ _ = try await harness.client.app("999") }, { _ = try await harness.client.package("NOPE") },
                     { _ = try await harness.client.userGroup("NOPE") }, { _ = try await harness.client.organizationalUnit("NOPE") },
                     { _ = try await harness.client.configuration("NOPE") }, { _ = try await harness.client.mdmDeviceDetails("NOPE") }] as [() async throws -> Void] {
            await #expect(throws: AppleAPIError.notFound) { try await read() }
        }
        await #expect(throws: AppleAPIError.notFound) { _ = try await Harness.all(harness.client.userGroupMemberIDs("NOPE")) }
        harness.stub.queue(429, for: "/v1/packages", headers: ["Retry-After": "3"])
        #expect(try await Harness.all(harness.client.packages()).count == 1)
        #expect(harness.sleeps.all == [.seconds(3)])
    }

    /// A 2xx that isn't the documented shape is malformed: a list that isn't a list, a single read without its item.
    @Test func aMalformedListOrSingleIsNeverNone() async throws {
        let harness = try await Self.examples()
        harness.stub.queue(200, for: "/v1/apps", body: #"{"data":{"type":"apps","id":"1"}}"#)
        await #expect(throws: AppleAPIError.malformed("a page of /v1/apps")) { _ = try await Harness.all(harness.client.apps()) }
        harness.stub.queue(200, for: "/v1/packages", body: #"{"data":[{"type":"packages","id":"P1"},{"type":"packages","attributes":{}}]}"#)
        await #expect(throws: AppleAPIError.malformed("a page of /v1/packages")) { _ = try await Harness.all(harness.client.packages()) }
        harness.stub.queue(200, for: "/v1/users/1234567890", body: #"{"data":[]}"#)
        await #expect(throws: AppleAPIError.malformed("a single /v1/users/{id}")) { _ = try await harness.client.user("1234567890") }
        harness.stub.queue(200, for: "/v1/mdmDevices/MD1/details", body: #"{"data":null}"#)
        await #expect(throws: AppleAPIError.malformed("a single /v1/mdmDevices/{id}/details")) { _ = try await harness.client.mdmDeviceDetails("MD1") }
    }

    /// An id that would steer the path is never sent, by any Business read.
    @Test(arguments: ["../users", "A/B", "", "U1?limit=1", "x y", "U1#x"])
    func anIDThatWouldSteerThePathIsNeverSent(id: String) async throws {
        let harness = try await Harness()
        let reads: [() async throws -> Void] = [
            { _ = try await harness.client.user(id) }, { _ = try await harness.client.userGroup(id) }, { _ = try await harness.client.organizationalUnit(id) },
            { _ = try await harness.client.app(id) }, { _ = try await harness.client.package(id) }, { _ = try await harness.client.blueprint(id) },
            { _ = try await harness.client.blueprint(id, include: [.apps]) }, { _ = try await harness.client.configuration(id) },
            { _ = try await harness.client.mdmDeviceDetails(id) }, { _ = try await Harness.all(harness.client.userGroupMemberIDs(id)) },
            { _ = try await Harness.all(harness.client.organizationalUnitMemberIDs(id)) },
            { _ = try await Harness.all(harness.client.blueprintMemberIDs(id, .orgDevices)) },
        ]
        for read in reads { await #expect(throws: AppleAPIError.notFound) { try await read() } }
        #expect(harness.stub.requests.isEmpty)
    }

    /// School has no people, content, Apple MDM or audit endpoints (plan §2.4): each read throws `.notInScope` with its
    /// section before anything is built, so a School org sends nothing at all, not even a token request.
    @Test func aSchoolOrgSendsNoBusinessOnlyRead() async throws {
        let harness = try await Harness(scope: .school)
        let client = harness.client
        let reads: [(AppleSection, () async throws -> Void)] = [
            (.users, { _ = try await Harness.all(client.users()) }), (.users, { _ = try await client.user("U1") }),
            (.userGroups, { _ = try await Harness.all(client.userGroups()) }), (.userGroups, { _ = try await client.userGroup("G1") }),
            (.userGroups, { _ = try await Harness.all(client.userGroupMemberIDs("G1")) }),
            (.orgUnits, { _ = try await Harness.all(client.organizationalUnits()) }), (.orgUnits, { _ = try await client.organizationalUnit("O1") }),
            (.orgUnits, { _ = try await Harness.all(client.organizationalUnitMemberIDs("O1")) }),
            (.apps, { _ = try await Harness.all(client.apps()) }), (.apps, { _ = try await client.app("1") }),
            (.packages, { _ = try await Harness.all(client.packages()) }), (.packages, { _ = try await client.package("P1") }),
            (.blueprints, { _ = try await Harness.all(client.blueprints()) }), (.blueprints, { _ = try await client.blueprint("B1", include: [.apps]) }),
            (.blueprints, { _ = try await Harness.all(client.blueprintMemberIDs("B1", .apps)) }),
            (.configurations, { _ = try await Harness.all(client.configurations()) }), (.configurations, { _ = try await client.configuration("C1") }),
            (.mdmEnrolled, { _ = try await Harness.all(client.mdmDevices()) }), (.mdmEnrolled, { _ = try await client.mdmDeviceDetails("D1") }),
        ]
        for (section, read) in reads { await #expect(throws: AppleAPIError.notInScope(section)) { try await read() } }
        #expect(harness.stub.requests.isEmpty, "\(harness.stub.requests)")
        #expect(AppleAPIError.notInScope(.users).message == "Apple School Manager's API has no users to read.")
        let sections = reads.map { $0.0 }
        #expect(sections.allSatisfy { $0.businessOnly })
    }
}
