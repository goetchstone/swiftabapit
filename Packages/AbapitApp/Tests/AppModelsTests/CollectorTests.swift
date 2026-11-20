import AppleBusiness
import AppleModels
import AppModels
import CryptoKit
import Foundation
import History
import JSONAPI
import Orgs
import Reports
import Testing
import TestSupport

/// The Apple snapshot collector (plan Phase 3; docs/domains/history.md, "The Apple collector"): what it keeps is the
/// operator's "Minimal" list, an allowlist; a resource that fails is a code and the rest are kept; what was read in part is
/// noted; nothing read for one org is written under another; a School org asks for nothing School lacks; and a new org
/// never takes an id the history holds. Over the strict stub, into a real `SnapshotStore`.
@MainActor
@Suite("Snapshot collector", .serialized)
struct CollectorTests {
    // MARK: the fleet

    /// Every canary a snapshot must never hold: a custom setting's Wi-Fi password, a package's download location (its
    /// `url`, whose host masking would keep) and a password written into its description, a service's IP, a user's names,
    /// email, phone, job title and department, a device's and a group's names.
    static let canaries = ["CANARYWIFIPW", "canaryhost", "CANARYURLPW", "CANARYQUERY", "CANARYDESCPW", "198.51.100.234", "CANARYFIRST", "CANARYLAST",
                           "canary.mail@example.com", "CANARYPHONE", "CANARYJOB", "CANARYDEPT", "CANARYDEVICENAME", "CANARYGROUP"]

    static let user = Resource(type: "users", id: "U1", attributes: [
        "firstName": .string("CANARYFIRST"), "lastName": .string("CANARYLAST"), "email": .string("canary.mail@example.com"),
        "managedAppleAccount": .string("u1@appleid.example.com"), "status": .string("ACTIVE"), "isExternalUser": .bool(false),
        "jobTitle": .string("CANARYJOB"), "department": .string("CANARYDEPT"), "createdDateTime": .string("2025-01-02T03:04:05Z"),
        "phoneNumbers": .array([.object(["phoneNumber": .string("+1 555 0100 CANARYPHONE"), "type": .string("WORK")])]),
    ])

    static let group = Resource(type: "userGroups", id: "G1", attributes: [
        "name": .string("CANARYGROUP"), "type": .string("STANDARD"), "status": .string("ACTIVE"), "totalMemberCount": .number("1"), "ouId": .string("OU1"),
    ])

    static let package = Resource(type: "packages", id: "P1", attributes: [
        "name": .string("Agent"), "version": .string("1.2"), "url": .string("https://deploy:CANARYURLPW@canaryhost.example.com/agent.pkg?sig=CANARYQUERY"),
        "description": .string("Mirror: https://deploy:CANARYDESCPW@mirror.example.com/agent.pkg"),
    ])

    static let configuration = Resource(type: "configurations", id: "C1", attributes: [
        "type": .string("CUSTOM_SETTING"), "name": .string("Office Wi-Fi"),
        "customSettingsValues": .object([
            "configurationProfile": .string("<plist><dict><key>Password</key><string>CANARYWIFIPW</string></dict></plist>"),
            "filename": .string("wifi.mobileconfig"),
        ]),
    ])

    static let mdmDevice = Resource(type: "mdmDevices", id: "ADEV0000000", attributes: [
        "serialNumber": .string("ADEV0000000"), "deviceName": .string("CANARYDEVICENAME"), "productFamily": .string("Mac"), "enrolledUserId": .string("U1"),
    ])

    /// Org `a` with two devices in two services (one service's IP a canary), a user, a group, an app, a package, a custom
    /// setting and an Apple-managed device; org `b` with one device.
    static func world(devices: [String: Int] = ["a": 2, "b": 1], pageCap: Int = AppleClient.defaultPageCap, profiles: [OrgProfile]? = nil,
                      history: Result<SnapshotStore, SnapshotStore.Failure>? = nil) async throws -> World {
        let world = try await World.make(devices: devices, pageCap: pageCap, profiles: profiles, history: history)
        let a = world.stubs["a"]!
        var main = World.service("S1", name: "Main MDM").attributes
        main["lastConnectedIp"] = .string("198.51.100.234")
        a.add(services: [Resource(type: "mdmServers", id: "S1", attributes: main), World.service("S2", name: "Lab")])
        a.assign("ADEV0000000", to: "S1")
        a.assign("ADEV0000001", to: "S2")
        if profiles?.first?.scope != .known(.school) {
            a.add([user, group, Resource(type: "apps", id: "A1", attributes: ["name": .string("Pages"), "bundleId": .string("com.apple.Pages")]),
                   package, configuration, mdmDevice])
        }
        return world
    }

    /// Runs a snapshot of the active org and returns it as the store holds it.
    static func recorded(_ world: World) async throws -> SnapshotStore.Snapshot {
        let outcome = await world.snapshots.run()
        guard case .recorded(let id) = outcome else {
            Issue.record("not recorded: \(outcome)")
            throw CancellationError()
        }
        return try await world.history!.load(id, org: world.orgs.active!)
    }

    static func attributes(_ snapshot: SnapshotStore.Snapshot, _ resource: String, _ id: String) -> [String] {
        (snapshot.resources[resource]?.first { $0.id == id }?.attributes.keys ?? []).sorted()
    }

    // MARK: what is kept

    @Test func aSnapshotKeepsEachResourceAsThePolicySays() async throws {
        let world = try await Self.world()
        let snapshot = try await Self.recorded(world)
        let summary = snapshot.summary
        #expect(summary.counts == ["devices": 2, "mdm_servers": 2, "assignments": 2, "users": 1, "user_groups": 1, "apps": 1, "packages": 1,
                                   "configurations": 1, "mdm_enrolled": 1])
        #expect(summary.errors.isEmpty)
        #expect(summary.orgID == "a" && summary.deviceCount == 2)
        #expect(Self.attributes(snapshot, "devices", "ADEV0000000") == ["addedToOrgDateTime", "deviceModel", "productFamily", "serialNumber", "status"])
        #expect(Self.attributes(snapshot, "mdm_servers", "S1") == ["lastConnectedDateTime", "serverName", "serverType", "status"])
        #expect(Self.attributes(snapshot, "users", "U1") == ["createdDateTime", "isExternalUser", "managedAppleAccount", "status"])
        #expect(Self.attributes(snapshot, "user_groups", "G1") == ["status", "totalMemberCount", "type"])
        #expect(Self.attributes(snapshot, "packages", "P1") == ["description", "name", "version"])
        #expect(Self.attributes(snapshot, "mdm_enrolled", "ADEV0000000") == ["enrolledUserId", "productFamily", "serialNumber"])
        // abapit's assignments: one item per serial, the service's id and name.
        #expect(snapshot.resources["assignments"]?.map { [$0.id, $0.attributes["serverId"]?.string ?? "", $0.attributes["serverName"]?.string ?? ""] }
                == [["ADEV0000000", "S1", "Main MDM"], ["ADEV0000001", "S2", "Lab"]])
        // A package's description keeps its words, its address masked as the Content screen masks it, and the note says so.
        let description = snapshot.resources["packages"]?.first?.attributes["description"]?.string ?? ""
        #expect(description.hasPrefix("Mirror: https://") && description.contains(ProfileText.mask) && !description.contains("CANARY"), "\(description)")
        #expect(summary.notes == ["packages": "an address was masked in 1 item"])
        // The sweeps aren't run yet: tried by nothing, so in neither counts nor errors.
        for rule in SnapshotPolicy.sweeps { #expect(summary.counts[rule.name] == nil && summary.errors[rule.name] == nil) }
    }

    /// The operator's 2026-10-31 decision: a configuration is `Configuration.resource` from the list, which sends a custom
    /// setting's profile as null; the single read that carries the profile is never made for a snapshot.
    @Test func aConfigurationIsTheListsResourceNeverTheDetail() async throws {
        let world = try await Self.world()
        let snapshot = try await Self.recorded(world)
        let stored = try #require(snapshot.resources["configurations"]?.first)
        #expect(stored.attributes["customSettingsValues"] == .null)
        #expect(stored.attributes["name"]?.string == "Office Wi-Fi")
        #expect(!world.stubs["a"]!.requests.contains { $0.contains("/v1/configurations/") }, "no single configuration read")
    }

    /// Canaries for everything the operator's "Minimal" leaves out, and the profile's password, looked for in every file the
    /// history folder holds after a snapshot: the database and any journal beside it.
    @Test func noCanaryReachesTheFileOrItsJournal() async throws {
        let folder = try Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let world = try await Self.world(history: .success(try SnapshotStore(storage: .folder(folder), appVersion: "test")))
        _ = try await Self.recorded(world)
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        #expect(files.contains { $0.lastPathComponent == SnapshotStore.fileName })
        var bytes = Data()
        for file in files { bytes += try Data(contentsOf: file) }
        // The scan reads what was stored.
        for kept in ["ADEV0000000", "u1@appleid.example.com", "Office Wi-Fi", "Main MDM"] { #expect(bytes.range(of: Data(kept.utf8)) != nil, "\(kept)") }
        for canary in Self.canaries { #expect(bytes.range(of: Data(canary.utf8)) == nil, "\(canary) reached \(folder.path)") }
    }

    /// The policy is an allowlist: an attribute Apple adds is left out until a review adds it, and the note counts it,
    /// never naming it. An attribute this version knows and doesn't keep (a user's email) is left out without a note.
    @Test func anAttributeOffTheAllowlistIsLeftOut() async throws {
        let world = try await Self.world(devices: ["a": 0, "b": 0])
        let a = world.stubs["a"]!
        a.add(devices: [Resource(type: "orgDevices", id: "ZDEV0000001", attributes: [
            "serialNumber": .string("ZDEV0000001"), "status": .string("ASSIGNED"), "futureAttribute": .string("CANARYFUTURE"),
            "anotherNewOne": .object(["CANARYKEY": .number("1")]),
        ])])
        let snapshot = try await Self.recorded(world)
        #expect(Self.attributes(snapshot, "devices", "ZDEV0000001") == ["serialNumber", "status"])
        #expect(snapshot.summary.notes["devices"] == "left out 2 attributes Apple sent that this version doesn't keep until reviewed")
        #expect(snapshot.summary.notes["users"] == nil)
        #expect(!(snapshot.summary.notes.values.joined() + snapshot.summary.errors.values.joined()).contains("future"))
    }

    // MARK: failures, cuts and fields not sent

    /// A 403 on one resource is that resource's code; every other resource is read and kept (abapit's per-resource errors).
    @Test func aRefusedResourceLeavesTheRestStoredWithItsCode() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.forbid("/v1/users")
        let snapshot = try await Self.recorded(world)
        #expect(snapshot.summary.errors == ["users": "HTTP 403 FORBIDDEN_ERROR"])
        #expect(snapshot.summary.counts["users"] == nil)
        #expect(snapshot.summary.counts.keys.sorted() == ["apps", "assignments", "configurations", "devices", "mdm_enrolled", "mdm_servers", "packages", "user_groups"])
        guard case .failed(_, let error, nil)? = try await world.history!.latest("users", org: world.orgs.active!) else {
            Issue.record("the history doesn't say the users failed")
            return
        }
        #expect(error == "HTTP 403 FORBIDDEN_ERROR")
    }

    /// An error is a code: the status and Apple's `code` when it has a code's shape, never Apple's `detail`, a parameter, or
    /// a `code` that is prose or an identifier.
    @Test func anErrorIsACodeNeverApplesText() async throws {
        let world = try await Self.world()
        let a = world.stubs["a"]!
        func body(_ code: String) -> String {
            #"{"errors": [{"status": "400", "code": "\#(code)", "title": "CANARYTITLE", "detail": "CANARYDETAIL jane.doe@example.com https://x.example.com/?t=CANARYURL", "source": {"parameter": "limit"}}]}"#
        }
        a.queue(400, for: "/v1/apps", body: body("PARAMETER_ERROR.INVALID"))
        a.queue(403, for: "/v1/packages", body: body("Jane.Doe C02CANARY"))
        a.queue(400, for: "/v1/userGroups", body: body("NOT_A CANARY"))
        let snapshot = try await Self.recorded(world)
        #expect(snapshot.summary.errors == ["apps": "HTTP 400 PARAMETER_ERROR.INVALID", "packages": "HTTP 403", "user_groups": "HTTP 400"])
        #expect(!"\(snapshot.summary)".contains("CANARY"))
        #expect(SnapshotPolicy.code(AppleAPIError.badRequest(code: "PARAMETER_ERROR.ILLEGAL", parameter: "include", detail: "CANARY")) == "HTTP 400 PARAMETER_ERROR.ILLEGAL")
        for code in ["FORBIDDEN", "forbidden_error", "C02X_SERIAL1", "A__B", "_A", "A.", String(repeating: "A_", count: 40) + "A"] {
            #expect(SnapshotPolicy.code(AppleAPIError.forbidden(code: code)) == "HTTP 403", "\(code)")
        }
    }

    /// Apple refused the services' field list on 2026-11-19: the client reads Apple's default fields and says which it
    /// lacks; the snapshot notes the kept ones no service came back with.
    @Test func theServicesDefaultFieldsAreNoted() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.refuseServiceFields()
        let snapshot = try await Self.recorded(world)
        #expect(snapshot.summary.notes["mdm_servers"] == "read with Apple's default fields (Apple refused the field list); "
                + "not sent for any item: createdDateTime, defaultProductFamilies, enableMdmDisownFlag, lastConnectedDateTime, status, updatedDateTime")
        #expect(snapshot.summary.errors.isEmpty)
        #expect(Self.attributes(snapshot, "mdm_servers", "S1") == ["serverName", "serverType"])
    }

    /// A list the page cap stopped is kept as read and said (invariant 8), with Apple's total when it gave one.
    @Test func aListCutAtThePageCapIsNoted() async throws {
        let world = try await Self.world(devices: ["a": 1001, "b": 0], pageCap: 1)
        let snapshot = try await Self.recorded(world)
        #expect(snapshot.summary.counts["devices"] == 1000)
        #expect(snapshot.summary.notes["devices"] == "stopped at the page limit: 1000 read, more not read")
        #expect(snapshot.summary.errors["devices"] == nil)
        world.stubs["a"]!.reportTotals()
        let again = try await Self.recorded(world)
        #expect(again.summary.notes["devices"] == "stopped at the page limit: 1000 of 1001 read")
    }

    /// One service's device list refused leaves the other's assignments, recorded with the error so the history never takes
    /// them for a whole read; services that couldn't be read leave the assignments not read.
    @Test func assignmentsReadInPartSaySo() async throws {
        let world = try await Self.world()
        world.stubs["a"]!.forbid("/v1/mdmServers/S2/relationships/devices")
        let snapshot = try await Self.recorded(world)
        #expect(snapshot.resources["assignments"]?.map(\.id) == ["ADEV0000000"])
        #expect(snapshot.summary.errors == ["assignments": "HTTP 403 FORBIDDEN_ERROR"])
        #expect(snapshot.summary.notes["assignments"] == "1 of 2 services' device lists couldn't be read")
        guard case .failed(_, _, nil)? = try await world.history!.latest("assignments", org: world.orgs.active!) else {
            Issue.record("a part read is a good copy")
            return
        }

        let refused = try await Self.world()
        refused.stubs["a"]!.forbid("/v1/mdmServers")
        let none = try await Self.recorded(refused)
        #expect(none.summary.errors == ["mdm_servers": "HTTP 403 FORBIDDEN_ERROR", "assignments": "not read: mdm_servers failed"])
        #expect(none.summary.counts["assignments"] == nil && none.summary.counts["mdm_servers"] == nil)
    }

    /// A failure of the account stops the asking: every later read would fail the same way (and a refused Touch ID would be
    /// asked again for each), so each resource after it says it wasn't asked.
    @Test func aCredentialFailureStopsTheAsking() async throws {
        let world = try await Self.world()
        let a = world.stubs["a"]!
        a.revokeAccount()
        let snapshot = try await Self.recorded(world)
        var expected = ["devices": "HTTP 401"]
        for rule in SnapshotPolicy.lists.dropFirst() { expected[rule.name] = "not asked after HTTP 401" }
        #expect(snapshot.summary.errors == expected)
        #expect(snapshot.summary.counts.isEmpty)
        #expect(!a.requests.contains { !$0.contains("/v1/orgDevices") && !$0.contains("/auth/") }, "\(a.requests)")
    }

    // MARK: one org, captured

    /// An org switch mid-run cancels it: nothing is written, under the new org or the old one.
    @Test func anOrgSwitchMidRunWritesNothing() async throws {
        let world = try await Self.world()
        let gate = world.gates["a"]!
        gate.hold("users") { $0.path() == "/v1/users" }
        let running = Task { await world.snapshots.run() }
        await eventually("the run at the users") { gate.held == 1 }
        #expect(world.snapshots.isRunning && world.snapshots.reading == "users")
        world.orgs.select("b")
        gate.release("users")
        #expect(await running.value == .cancelled)
        #expect(try await world.history!.orgIDs().isEmpty)
        #expect(!world.snapshots.isRunning && world.snapshots.lastOutcome == .cancelled)
        // The next run reads the org now active, and records under it.
        let next = try await Self.recorded(world)
        #expect(next.summary.orgID == "b" && next.summary.counts["devices"] == 1)
        #expect(try await world.history!.orgIDs() == ["b"])
    }

    /// A client switch is an org switch: the run stops and writes nothing (the clients rule).
    @Test func aClientSwitchMidRunWritesNothing() async throws {
        let world = try await Self.world()
        let gate = world.gates["a"]!
        gate.hold("apps") { $0.path() == "/v1/apps" }
        let running = Task { await world.snapshots.run() }
        await eventually("the run at the apps") { gate.held == 1 }
        world.orgs.selectClient(try #require(world.orgs.store.client(of: "b")?.id))
        gate.release("apps")
        #expect(await running.value == .cancelled)
        #expect(try await world.history!.orgIDs().isEmpty)
    }

    @Test func cancelStopsTheRunAndWritesNothing() async throws {
        let world = try await Self.world()
        let gate = world.gates["a"]!
        gate.hold("packages") { $0.path() == "/v1/packages" }
        let running = Task { await world.snapshots.run() }
        await eventually("the run at the packages") { gate.held == 1 }
        // One run at a time.
        #expect(await world.snapshots.run() == .notRun("A snapshot is already being taken."))
        world.snapshots.cancel()
        gate.release("packages")
        #expect(await running.value == .cancelled)
        #expect(try await world.history!.orgIDs().isEmpty)
    }

    /// A snapshot records the org as the run captured it when it started: an edit that changes no account (a rename) doesn't
    /// stop the run, and the row is the captured profile's, never whatever is active when it ends.
    @Test func theSnapshotIsTheCapturedOrgs() async throws {
        let world = try await Self.world()
        let gate = world.gates["a"]!
        gate.hold("users") { $0.path() == "/v1/users" }
        let running = Task { await world.snapshots.run() }
        await eventually("the run at the users") { gate.held == 1 }
        let generation = world.orgs.generation
        var draft = OrgDraft(world.orgs.store["a"]!)
        draft.name = "Renamed"
        try await world.orgs.save(draft, key: nil, editing: "a")
        #expect(world.orgs.generation == generation, "a rename isn't a switch")
        gate.release("users")
        guard case .recorded(let id) = await running.value else {
            Issue.record("a rename stopped the run")
            return
        }
        let summary = try await world.history!.load(id, org: world.orgs.store["a"]!).summary
        #expect(summary.orgID == "a" && summary.orgName == "Org a")
    }

    /// Apple School Manager has no people, content or Apple MDM reads: a School org's snapshot asks for none of them.
    @Test func aSchoolOrgSkipsBusinessOnlyReads() async throws {
        let world = try await Self.world(profiles: [World.profile("a", scope: .school), World.profile("b")])
        let snapshot = try await Self.recorded(world)
        #expect(snapshot.summary.orgScope == "school")
        #expect(snapshot.summary.counts == ["devices": 2, "mdm_servers": 2, "assignments": 2])
        #expect(snapshot.summary.errors.isEmpty)
        let asked = world.stubs["a"]!.requests.filter { !$0.contains("/auth/") }
        #expect(!asked.isEmpty && asked.allSatisfy { $0.contains("/v1/orgDevices") || $0.contains("/v1/mdmServers") }, "\(asked)")
    }

    @Test func nothingIsReadWithoutAnOrgOrAHistory() async throws {
        let none = try await World.make(profiles: [])
        #expect(await none.snapshots.run() == .notRun(ScreenWords.noOrganization))
        let failure = SnapshotStore.Failure.notThisAppsFile(path: "/x/history.sqlite")
        let unopened = try await Self.world(history: .failure(failure))
        #expect(await unopened.snapshots.run() == .notRun(failure.message))
        #expect(unopened.stubs["a"]!.requests.isEmpty)
    }

    // MARK: ids

    /// An org's history is never inherited: ids are slugs of names and come round again, so a new org's id avoids every id
    /// the history holds, as it avoids the Keychain's (history.md).
    @Test func aNewOrgNeverTakesAnIDWithHistory() async throws {
        let world = try await World.make()
        func add(_ name: String, _ client: String) async throws -> OrgProfile {
            let key = P256.Signing.PrivateKey()
            var draft = OrgDraft()
            (draft.name, draft.clientID, draft.keyID) = (name, client, "KEY-\(client)")
            return try await world.orgs.save(draft, key: World.imported(key), editing: nil)
        }
        let acme = try await add("Acme", "BUSINESSAPI.acme-1")
        #expect(acme.id == "acme")
        try await world.history!.record(org: acme, takenAt: Date(), resources: ["devices": []])
        try await world.orgs.remove("acme", deleteSecrets: true)
        #expect(try await world.vault.inventory()["acme"] == nil, "only the history holds the id now")
        let again = try await add("ACME", "BUSINESSAPI.acme-2")
        #expect(again.id != "acme")
        #expect(try await world.history!.snapshots(org: again).isEmpty)
        #expect(try await world.history!.snapshots(org: acme).count == 1, "the removed org's history stays")
    }

    /// A history that didn't open can't say which ids it holds: an Add is refused, in words, rather than risk one.
    @Test func aHistoryThatDidntOpenRefusesAnAdd() async throws {
        let failure = SnapshotStore.Failure.hardLinked(path: "/x/history.sqlite")
        let world = try await World.make(history: .failure(failure))
        var draft = OrgDraft()
        (draft.name, draft.clientID, draft.keyID) = ("Acme", "BUSINESSAPI.acme-1", "KEY-1")
        do {
            try await world.orgs.save(draft, key: World.imported(P256.Signing.PrivateKey()), editing: nil)
            Issue.record("an org was added with no history to check its id against")
        } catch let error as OrgsModel.SaveFailure {
            #expect(error.message.hasSuffix(failure.message) && error.message.contains("couldn't be opened"), "\(error.message)")
        }
        #expect(world.orgs.store["acme"] == nil)
        #expect(try await world.vault.inventory()["acme"] == nil, "refused before the Keychain")
    }

    // MARK: the policy itself

    /// The allowlist, written out a second time: a change to what a snapshot keeps is a change to both, where review sees it.
    @Test func theAllowlistIsTheOperatorsMinimal() {
        let expected: [String: [String]] = [
            "devices": ["serialNumber", "addedToOrgDateTime", "releasedFromOrgDateTime", "updatedDateTime", "deviceModel", "productFamily", "productType",
                        "deviceCapacity", "partNumber", "orderNumber", "color", "status", "orderDateTime", "imei", "meid", "eid", "purchaseSourceId",
                        "purchaseSourceType", "wifiMacAddress", "bluetoothMacAddress", "ethernetMacAddress", "isMdmMigrationCapable", "mdmMigrationStatus",
                        "mdmMigrationDeadlineDateTime"],
            "mdm_servers": ["createdDateTime", "defaultProductFamilies", "deviceCount", "enableMdmDisownFlag", "lastConnectedDateTime", "serverName",
                            "serverType", "status", "updatedDateTime"],
            "assignments": ["serverId", "serverName"],
            "users": ["status", "managedAppleAccount", "isExternalUser", "startDateTime", "createdDateTime", "updatedDateTime"],
            "user_groups": ["status", "type", "totalMemberCount", "createdDateTime", "updatedDateTime"],
            "apps": ["name", "bundleId", "websiteUrl", "version", "supportedOS", "isCustomApp", "appStoreUrl"],
            "packages": ["name", "hash", "bundleIds", "description", "version", "createdDateTime", "updatedDateTime"],
            "configurations": ["type", "name", "configuredForPlatforms", "customSettingsValues", "createdDateTime", "updatedDateTime"],
            "mdm_enrolled": ["serialNumber", "productFamily", "enrolledUserId"],
            "applecare": ["agreementNumber", "contractCancelDateTime", "description", "endDateTime", "isCanceled", "isRenewable", "paymentType",
                          "startDateTime", "status", "serialNumber"],
            "activation_lock": ["isLocked", "lockType"],
            "mdm_details": ["serialNumber", "deviceModel", "osVersion", "platform", "lastCheckInDateTime", "isFirewallEnabled", "isFileVaultEnabled",
                            "storageFreeCapacity", "storageTotalCapacity", "deviceLockStatus", "deviceEraseStatus", "lostModeStatus"],
        ]
        #expect(SnapshotPolicy.all.map(\.name) == ["devices", "mdm_servers", "assignments", "users", "user_groups", "apps", "packages", "configurations",
                                                   "mdm_enrolled", "applecare", "activation_lock", "mdm_details"])
        for rule in SnapshotPolicy.all {
            #expect(rule.kept.map { Array($0.utf8) } == expected[rule.name]?.map { Array($0.utf8) }, "\(rule.name)")
            // Every kept attribute is one Apple documents (a typo would keep nothing), once, and none looks like a secret's
            // (the store's backstop would drop it, silently, from every row).
            #expect(Set(rule.kept).isSubset(of: rule.known) && Set(rule.kept).count == rule.kept.count, "\(rule.name)")
            #expect(!rule.kept.contains(where: ExportPolicy.isSensitive), "\(rule.name)")
        }
        // The operator's minus list, and the People line.
        let kept = Dictionary(uniqueKeysWithValues: SnapshotPolicy.all.map { ($0.name, Set($0.kept)) })
        #expect(!kept["packages"]!.contains("url") && !kept["mdm_servers"]!.contains("lastConnectedIp"))
        #expect(kept["mdm_details"]!.isDisjoint(with: ["imei", "meid", "wifiMacAddress", "bluetoothMacAddress", "ethernetMacAddress", "deviceName"]))
        #expect(kept["users"]!.isDisjoint(with: ["firstName", "middleName", "lastName", "email", "phoneNumbers", "jobTitle", "department", "employeeNumber",
                                                 "costCenter", "division", "roleOuList"]))
        #expect(!kept["user_groups"]!.contains("name") && !kept["mdm_enrolled"]!.contains("deviceName"))
        // The Business-only reads are exactly School's gaps; the sweeps aren't in the lists a run reads.
        #expect(SnapshotPolicy.all.filter(\.businessOnly).map(\.name) == ["users", "user_groups", "apps", "packages", "configurations", "mdm_enrolled", "mdm_details"])
        #expect(SnapshotPolicy.lists.count + SnapshotPolicy.sweeps.count == SnapshotPolicy.all.count)
        #expect(SnapshotPolicy.all.filter(\.masksAddresses).map(\.name) == ["packages"])
    }

    // MARK: helpers

    /// A new folder under the temporary folder, by its real path (`SQLITE_OPEN_NOFOLLOW` refuses the `/var` link).
    static func folder() throws -> URL {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path(percentEncoded: false), nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        let url = URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
            .appending(path: "swiftabapit-collector-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }
}
