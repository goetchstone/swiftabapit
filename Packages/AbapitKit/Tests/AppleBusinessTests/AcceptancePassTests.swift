@testable import AppleBusiness
import AppleModels
import Foundation
import JSONAPI
import Security
import Testing
import TestSupport

/// The acceptance pass says "ok" only for a read that ran and fully succeeded (Phase 1b review M5: a forbidden device
/// list left five per-device lines "ok … 0", a list cut at the page cap read "ok", and of its mutants "sample unbounded",
/// "failure as ok", "any probe ok", "truncation unsaid" and "lock reads one device only" survived). The failure kinds,
/// the code filters and cancellation are in `AcceptanceFailureTests`.
@Suite("Acceptance pass", .serialized)
struct AcceptancePassTests {
    static let perDevice = ["orgDevices/{id}", "orgDevices/{id}/appleCareCoverage", "orgDevices/{id}/activationLockStatus",
                            "orgDevices/{id}/assignedServer", "orgDevices/{id}/relationships/assignedServer"]

    /// The whole text the operator copies, line by line: each read's count, the attribute names and enum values this
    /// version doesn't know (plan §7's purpose), the unassigned counts, and probes without a count. No item's data.
    /// Verifier round 1: dropping the notes, the unknown keys or the unknown values from the text, inverting the
    /// unassigned counts, reporting known values, losing the single device's, the coverage's or the lock's keys,
    /// overwriting the per-service count and counting probes all left every test green.
    @Test func aGreenPassReadsLineByLine() async throws {
        let harness = try await Harness(devices: 4)
        harness.stub.add(devices: [Resource(type: "orgDevices", id: "TESTNEW00001", attributes: [
            "serialNumber": .string("TESTNEW00001"), "productFamily": .string("Glasses"), "brandNewField": .string("secret-ish")])])
        harness.stub.add(services: [Harness.service("SVC1", name: "Mosyle"), Resource(type: "mdmServers", id: "SVC2", attributes: [
            "serverName": .string("Jamf"), "serverType": .string("FUTURE_MDM"), "status": .string("ACTIVE")])])
        harness.stub.assign("TESTD0000000", to: "SVC1")
        harness.stub.assign("TESTD0000001", to: "SVC2")
        harness.stub.assign("TESTD0000002", to: "SVC2")
        harness.stub.setCoverage("TESTD0000000", [
            Resource(type: "appleCareCoverage", id: "C1", attributes: ["status": .string("ACTIVE"), "paymentType": .string("PAID_UP_FRONT")]),
            Resource(type: "appleCareCoverage", id: "C2", attributes: ["status": .string("PAUSED"), "paymentType": .string("NONE"),
                                                                       "futureField": .string("secret-ish")]),
        ])
        for serial in Self.firstSerials(4) + ["TESTNEW00001"] { harness.stub.setLock(serial, isLocked: false, lockType: "NONE") }
        harness.stub.queue(200, for: "/v1/orgDevices/TESTD0000001/activationLockStatus", body: #"""
            {"data":{"type":"activationLockStatus","id":"TESTD0000001","attributes":{"isLocked":true,"lockType":"MDM","newLockField":"secret-ish"}}}
            """#)
        let report = await harness.client.acceptancePass(sample: 5)
        #expect(report.text == """
            orgDevices: ok, 5 items · unknown keys brandNewField · unknown values productFamily=Glasses
            mdmServers: ok, 2 items · unknown values serverType=FUTURE_MDM
            mdmServers/{id}/relationships/devices: ok, 3 items
            orgDevices/{id}: ok, 5 items · unknown keys brandNewField
            orgDevices/{id}/appleCareCoverage: ok, 2 items · unknown keys futureField · unknown values status=PAUSED
            orgDevices/{id}/activationLockStatus: ok, 5 items · unknown keys newLockField
            orgDevices/{id}/assignedServer: ok, 5 items · 2 of 5 unassigned
            orgDevices/{id}/relationships/assignedServer: ok, 5 items · 2 of 5 unassigned
            probe devices: ok
            probe mdm_servers: ok
            probe mdm_enrolled: ok
            probe users: ok
            probe user_groups: ok
            probe org_units: ok
            probe apps: ok
            probe packages: ok
            probe blueprints: ok
            probe configurations: ok
            probe audit_events: ok
            """)
        #expect(report.lines.allSatisfy { $0.status == .ok }, "\(report.text)")
        for data in ["secret-ish", "TESTD", "TESTNEW", "SVC", "Mosyle", "Jamf"] { #expect(!report.text.contains(data), "\(data)") }
    }

    /// Review ACC1: with `/v1/orgDevices` forbidden there is no device to sample, so each per-device read is skipped,
    /// says why, and isn't sent.
    @Test func aForbiddenDeviceListSkipsEveryPerDeviceRead() async throws {
        let harness = try await Harness(devices: 3)
        harness.stub.forbid("/v1/orgDevices")
        let report = await harness.client.acceptancePass()
        let devices = try #require(report.lines.first { $0.resource == "orgDevices" })
        #expect(devices.status == .forbidden && !devices.ok)
        #expect(devices.note == "FORBIDDEN_ERROR", "Apple's code, not its detail")
        for resource in Self.perDevice {
            let line = try #require(report.lines.first { $0.resource == resource })
            #expect(line.status == .skipped("no device to sample (orgDevices forbidden)"), "\(resource)")
            #expect(line.count == nil && !line.ok)
        }
        #expect(report.lines.first { $0.resource == "probe devices" }?.status == .forbidden)
        #expect(!harness.stub.requests.contains { $0.contains("/v1/orgDevices/") }, "a skipped read is never sent")
        #expect(report.text.contains("orgDevices/{id}: skipped: no device to sample (orgDevices forbidden)"))
        #expect(!report.text.contains("role doesn't allow"), "the stub's detail")
    }

    /// An org with no service: the per-service device lists are skipped, not "ok, 0".
    @Test func noServiceSkipsTheServiceDeviceLists() async throws {
        let harness = try await Harness(devices: 1)
        harness.stub.setLock("TESTD0000000", isLocked: false, lockType: "NONE")
        let report = await harness.client.acceptancePass()
        #expect(report.lines.first { $0.resource == "mdmServers" }?.status == .ok)
        #expect(report.lines.first { $0.resource == "mdmServers/{id}/relationships/devices" }?.status
            == .skipped("no service to read (mdmServers has none)"))
    }

    /// Review ACC2: a list the page cap cut is "truncated" with what was read, the device list, a service's device
    /// list and a device's coverage alike.
    @Test func aListCutAtThePageCapIsTruncatedWithItsCount() async throws {
        let harness = try await Harness(devices: 1_001, pageCap: 1)
        harness.stub.reportTotals()
        harness.stub.add(services: [Harness.service("SVC1", name: "Mosyle")])
        for index in 0..<1_001 { harness.stub.assign(String(format: "TESTD%07d", index), to: "SVC1") }
        harness.stub.setLock("TESTD0000000", isLocked: false, lockType: "NONE")
        harness.stub.setCoverage("TESTD0000000", (0..<1_001).map { Resource(type: "appleCareCoverage", id: "C\($0)", attributes: ["status": .string("ACTIVE")]) })
        let report = await harness.client.acceptancePass(sample: 1)
        let devices = try #require(report.lines.first { $0.resource == "orgDevices" })
        #expect(devices.status == .truncated && !devices.ok)
        #expect(devices.count == 1_000)
        #expect(devices.note == "stopped at the page cap with more to come (Apple's total 1001)")
        let linked = try #require(report.lines.first { $0.resource == "mdmServers/{id}/relationships/devices" })
        #expect(linked.status == .truncated && linked.count == 1_000)
        #expect(linked.note == "1 of 1 services' lists stopped at the page cap")
        let coverage = try #require(report.lines.first { $0.resource == "orgDevices/{id}/appleCareCoverage" })
        #expect(coverage.status == .truncated && coverage.count == 1_000)
        #expect(report.lines.first { $0.resource == "mdmServers" }?.status == .ok)
        #expect(report.text.contains("orgDevices: truncated, 1000 items"))
    }

    /// Invariant 8 for the service list itself and for what depends on it: a service list the page cap cut is
    /// "truncated", and the services' device lists say they cover only the services read (verifier round 1, N16).
    @Test func aServiceListCutAtThePageCapIsSaidAndSoIsWhatDependsOnIt() async throws {
        let harness = try await Harness(pageCap: 1)
        harness.stub.reportTotals()
        harness.stub.add(services: (0..<1_001).map { Harness.service("SVC\($0)", name: "S\($0)") })
        let report = await harness.client.acceptancePass()
        let services = try #require(report.lines.first { $0.resource == "mdmServers" })
        #expect(services.status == .truncated && services.count == 1_000)
        #expect(services.note == "stopped at the page cap with more to come (Apple's total 1001)")
        let linked = try #require(report.lines.first { $0.resource == "mdmServers/{id}/relationships/devices" })
        #expect(linked.status == .truncated && linked.count == 0)
        #expect(linked.note == "covers only the 1000 services mdmServers read (truncated)")
        #expect(report.text.contains("mdmServers: truncated, 1000 items · stopped at the page cap with more to come (Apple's total 1001)"))
    }

    /// A list that fails part-way keeps what it read, and what depends on it says it covers only that (verifier round
    /// 1: a services list failing on page 2 left the per-service lists `ok`; N20 lost the device list's count).
    @Test func aListThatFailsPartWayKeepsItsCountAndSaysSo() async throws {
        let harness = try await Harness(devices: 1_500)
        for serial in Self.firstSerials(5) { harness.stub.setLock(serial, isLocked: false, lockType: "NONE") }
        harness.stub.add(services: (0..<1_500).map { Harness.service("SVC\($0)", name: "S\($0)") })
        harness.stub.queue(500, for: "/v1/orgDevices?cursor=")
        harness.stub.queue(500, for: "/v1/mdmServers?cursor=")
        let report = await harness.client.acceptancePass()
        let devices = try #require(report.lines.first { $0.resource == "orgDevices" })
        #expect(devices.status == .error("error 500") && devices.count == 1_000)
        let services = try #require(report.lines.first { $0.resource == "mdmServers" })
        #expect(services.status == .error("error 500") && services.count == 1_000)
        let linked = try #require(report.lines.first { $0.resource == "mdmServers/{id}/relationships/devices" })
        #expect(linked.status == .truncated && linked.note == "covers only the 1000 services mdmServers read (error 500)")
        #expect(report.lines.first { $0.resource == "orgDevices/{id}" }?.status == .ok, "the sample came from the 1000 read")
        #expect(report.text.hasPrefix("orgDevices: error 500, 1000 items\nmdmServers: error 500, 1000 items\n"))
    }

    /// Two services' device lists add up, and one that fails says which (verifier round 1: `=` for `+=` and an
    /// off-by-one position survived).
    @Test func theServicesDeviceListsAddUpAndAFailureSaysWhichService() async throws {
        let harness = try await Harness(devices: 3)
        harness.stub.add(services: [Harness.service("SVC1", name: "Mosyle"), Harness.service("SVC2", name: "Jamf")])
        harness.stub.assign("TESTD0000000", to: "SVC1")
        harness.stub.assign("TESTD0000001", to: "SVC2")
        harness.stub.assign("TESTD0000002", to: "SVC2")
        for serial in Self.firstSerials(3) { harness.stub.setLock(serial, isLocked: false, lockType: "NONE") }
        harness.stub.queue(500, for: "/v1/mdmServers/SVC2/relationships/devices")
        let report = await harness.client.acceptancePass()
        let linked = try #require(report.lines.first { $0.resource == "mdmServers/{id}/relationships/devices" })
        #expect(linked.status == .error("error 500") && linked.count == 1 && linked.note == "at service 2 of 2")
        #expect(report.text.contains("mdmServers/{id}/relationships/devices: error 500, 1 item · at service 2 of 2"))
    }

    /// Each failure is its status, with how far a loop got and Apple's code, never Apple's `detail` (review LOW: the
    /// note carried `AppleAPIError.message`, which quotes it). The details here are code-shaped, so one let through the
    /// code filter would show (verifier round 1, N10).
    @Test func aFailureIsItsStatusWithCodesButNeverApplesDetail() async throws {
        let harness = try await Harness(devices: 3)
        harness.stub.add(services: [Harness.service("SVC1", name: "Mosyle")])
        harness.stub.setLock("TESTD0000000", isLocked: false, lockType: "NONE")
        harness.stub.setLock("TESTD0000001", isLocked: false, lockType: "NONE")
        harness.stub.queue(400, for: "/v1/mdmServers",
                           body: Self.errorBody(400, code: "PARAMETER_ERROR.INVALID", detail: "DETAIL_NAMES.DEVICE", parameter: "limit"))
        // The single read comes first of TESTD0000001's reads: the coverage read takes the second queued 500.
        harness.stub.queue(500, for: "/v1/orgDevices/TESTD0000001")
        harness.stub.queue(500, for: "/v1/orgDevices/TESTD0000001/appleCareCoverage")
        harness.stub.queue(409, for: "/v1/orgDevices/TESTD0000000/assignedServer",
                           body: Self.errorBody(409, code: "STATE_ERROR.CONFLICT", detail: "DETAIL_NAMES.DEVICE"))
        harness.stub.queue(422, for: "/v1/orgDevices/TESTD0000000/relationships/assignedServer",
                           body: Self.errorBody(422, code: "ENTITY_ERROR.UNPROCESSABLE", detail: "DETAIL_NAMES.DEVICE"))
        let report = await harness.client.acceptancePass(sample: 3)
        func line(_ resource: String) throws -> AcceptanceReport.Line { try #require(report.lines.first { $0.resource == resource }) }

        #expect(try line("mdmServers").status == .error("error 400"))
        #expect(try line("mdmServers").note == "PARAMETER_ERROR.INVALID limit")
        #expect(try line("mdmServers/{id}/relationships/devices").status == .skipped("no service to read (mdmServers error 400)"))
        #expect(try line("orgDevices/{id}").status == .error("error 500"))
        #expect(try line("orgDevices/{id}").count == 1)
        #expect(try line("orgDevices/{id}").note == "at device 2 of 3", "the stub's QUEUED is one word, so not a code")
        #expect(try line("orgDevices/{id}/appleCareCoverage").status == .error("error 500"))
        #expect(try line("orgDevices/{id}/appleCareCoverage").note == "at device 2 of 3")
        // TESTD0000002 has no lock: Apple's 404, after two read.
        #expect(try line("orgDevices/{id}/activationLockStatus").status == .error("error 404"))
        #expect(try line("orgDevices/{id}/activationLockStatus").count == 2)
        #expect(try line("orgDevices/{id}/activationLockStatus").note == "at device 3 of 3")
        #expect(try line("orgDevices/{id}/assignedServer").status == .error("error 409"))
        #expect(try line("orgDevices/{id}/assignedServer").note == "at device 1 of 3 · STATE_ERROR.CONFLICT")
        #expect(try line("orgDevices/{id}/relationships/assignedServer").status == .error("error 422"))
        #expect(try line("orgDevices/{id}/relationships/assignedServer").note == "at device 1 of 3", "a 422's note has no detail")
        #expect(try line("orgDevices").status == .ok)
        #expect(report.lines.filter { if case .error = $0.status { true } else { false } }.allSatisfy { !$0.ok })
        for prose in ["A failure the test queued", "Queued failure", "Apple refused", "Apple's service failed", "DETAIL_NAMES"] {
            #expect(!report.text.contains(prose), "\(prose)")
        }
    }

    /// Review mutant "any probe ok": a forbidden probe reads forbidden and a failed one its status.
    @Test func aProbeSaysForbiddenOrItsErrorNeverOk() async throws {
        let harness = try await Harness(devices: 1)
        harness.stub.setLock("TESTD0000000", isLocked: false, lockType: "NONE")
        harness.stub.forbid("/v1/users")
        harness.stub.queue(500, for: "/v1/apps")
        let report = await harness.client.acceptancePass()
        let probes = report.lines.filter { $0.resource.hasPrefix("probe ") }
        #expect(probes.count == AppleSection.allCases.count)
        #expect(probes.first { $0.resource == "probe users" }?.status == .forbidden)
        #expect(probes.first { $0.resource == "probe apps" }?.status == .error("error 500"))
        #expect(probes.filter { !["probe users", "probe apps"].contains($0.resource) }.allSatisfy { $0.ok }, "\(report.text)")
        #expect(report.text.contains("probe users: forbidden · FORBIDDEN_ERROR\n") && report.text.contains("probe apps: error 500\n"))
    }

    /// A School org's pass reads School's host for every read, the AppleCare walk included, and only School's
    /// sections (verifier round 1, N25: AppleCare asked of the Business host read "error wrong host").
    @Test func aSchoolPassReadsOnlySchoolsHostAndSections() async throws {
        let harness = try await Harness(scope: .school, devices: 2)
        harness.stub.add(services: [Harness.service("SVC1", name: "Mosyle")])
        harness.stub.setCoverage("TESTD0000000", [Resource(type: "appleCareCoverage", id: "C1", attributes: ["status": .string("ACTIVE")])])
        for serial in Self.firstSerials(2) { harness.stub.setLock(serial, isLocked: false, lockType: "NONE") }
        let report = await harness.client.acceptancePass()
        #expect(report.lines.allSatisfy { $0.status == .ok }, "\(report.text)")
        #expect(report.lines.first { $0.resource == "orgDevices/{id}/appleCareCoverage" }?.count == 1)
        #expect(report.lines.filter { $0.resource.hasPrefix("probe ") }.map(\.resource)
            == AppleSection.allCases.filter { !$0.businessOnly }.map { "probe \($0.rawValue)" })
        let reads = harness.stub.requests.filter { !$0.hasPrefix("POST ") }
        #expect(!reads.isEmpty && reads.allSatisfy { $0.hasPrefix("GET api-school.apple.com/") }, "\(reads)")
    }

    /// Review mutants "sample unbounded" and "lock reads one device only": every per-device read covers each sampled
    /// device once, and the sample never passes its limit, whatever the caller asks.
    @Test func everyPerDeviceReadCoversTheWholeSampleAndTheSampleIsBounded() async throws {
        let harness = try await Harness(devices: 30)
        for index in 0..<30 { harness.stub.setLock(String(format: "TESTD%07d", index), isLocked: false, lockType: index == 3 ? "NEW_LOCK" : "NONE") }
        let report = await harness.client.acceptancePass(sample: 4)
        let sampled = Self.firstSerials(4)
        for suffix in ["", "/appleCareCoverage", "/activationLockStatus", "/assignedServer", "/relationships/assignedServer"] {
            #expect(Self.serials(harness.stub.requests, suffix) == sampled, "orgDevices/{id}\(suffix)")
        }
        let lock = try #require(report.lines.first { $0.resource == "orgDevices/{id}/activationLockStatus" })
        #expect(lock.count == 4 && lock.unknownValues == ["lockType=NEW_LOCK"], "the fourth device's lock was read")
        #expect(report.lines.first { $0.resource == "orgDevices/{id}" }?.count == 4)

        let greedy = try await Harness(devices: 30)
        for index in 0..<30 { greedy.stub.setLock(String(format: "TESTD%07d", index), isLocked: false, lockType: "NONE") }
        _ = await greedy.client.acceptancePass(sample: .max)
        #expect(Self.serials(greedy.stub.requests, "").count == AppleClient.acceptanceSampleLimit)
        #expect(AppleClient.acceptanceSampleLimit == 20 && AppleClient.acceptanceSample == 5)

        let standard = try await Harness(devices: 30)
        for index in 0..<30 { standard.stub.setLock(String(format: "TESTD%07d", index), isLocked: false, lockType: "NONE") }
        _ = await standard.client.acceptancePass()
        #expect(Self.serials(standard.stub.requests, "/activationLockStatus").count == AppleClient.acceptanceSample)

        let none = try await Harness(devices: 3)
        let skipped = await none.client.acceptancePass(sample: -1)
        #expect(skipped.lines.first { $0.resource == "orgDevices/{id}" }?.status == .skipped("no device to sample (sample size -1)"))
        #expect(Self.serials(none.stub.requests, "").isEmpty)
    }

    /// A Keychain refusal while signing is said in the Vault's words, and what needs no device still runs.
    @Test func aKeychainRefusalIsTheVaultsGuidance() async throws {
        let harness = try await Harness(devices: 1)
        harness.store.failNext(.sign, with: errSecUserCanceled)
        let report = await harness.client.acceptancePass()
        let devices = try #require(report.lines.first { $0.resource == "orgDevices" })
        #expect(devices.status == .error("error keychain"))
        #expect(devices.note?.contains("Touch ID") == true)
        #expect(report.lines.first { $0.resource == "orgDevices/{id}" }?.status == .skipped("no device to sample (orgDevices error keychain)"))
        #expect(report.lines.first { $0.resource == "mdmServers" }?.status == .ok, "the next signature went through")
    }

    /// Apple's `code` reaches a note only as a code: words of letters joined by `_` or `.`. Prose, which may name a
    /// device, and anything an identifier could be (a digit, a `-`, a single word) are dropped (verifier round 1: a
    /// newline, `/`, `:` and the length bound were untested, and `C02XSERIAL99` passed).
    @Test func onlyACodeReachesANote() {
        let longest = String(repeating: "A", count: 31) + "_" + String(repeating: "B", count: 32)
        #expect(longest.utf8.count == 64)
        for code in ["FORBIDDEN_ERROR", "PARAMETER_ERROR.INVALID", "ENTITY_ERROR.ATTRIBUTE.INVALID", "server_error", "a.b", longest] {
            #expect(AppleClient.acceptanceCode(code) == code)
        }
        for prose in ["Device TESTD0000001 not found", "TESTD0000001", "TESTSERIAL", "QUEUED", "C02X_SERIAL", "NOT-FOUND_ERROR", "a,b", "a b",
                      "A_B\nFAKE_LINE", "A_B\r", "A_B\t", "\nA_B", "A_B/C", "A_B:C", "fields[orgDevices]", "_A", "A_", "A__B", "A._B", ".",
                      "X\u{301}_Y", "\u{FF34}OKEN_ERROR", "", longest + "C", nil] {
            #expect(AppleClient.acceptanceCode(prose) == nil, "\(String(describing: prose))")
        }
    }

    /// Apple's `source.parameter` reaches a note only when it names a query parameter: a value echoed there (a serial)
    /// is dropped (verifier round 1: `C02XSERIAL99` reached the note).
    @Test func onlyAParameterNameReachesANote() {
        let longest = "fields[" + String(repeating: "a", count: 56) + "]"
        #expect(longest.utf8.count == 64)
        for name in ["limit", "cursor", "fields[orgDevices]", "filter[startTimestamp]", longest] {
            #expect(AppleClient.acceptanceParameter(name) == name)
        }
        for value in ["TESTD0000001", "TESTSERIAL", "Limit", "limit2", "fields[OrgDevices]", "fields[org2]", "fields[]", "[orgDevices]",
                      "fields[orgDevices", "fields[org Devices]", "fields[orgDevices]x", "fields[a[b]]", "fields[orgDevices],limit", "limit\n",
                      "lim\u{301}it", "", "fields[a" + String(repeating: "a", count: 56) + "]", nil] {
            #expect(AppleClient.acceptanceParameter(value) == nil, "\(String(describing: value))")
        }
    }

    /// Apple's `ErrorResponse` with the given fields, for `AppleStub.queue(_:for:body:)`.
    static func errorBody(_ status: Int, code: String, detail: String, parameter: String? = nil) -> String {
        var item: [String: Any] = ["status": String(status), "code": code, "title": "Refused", "detail": detail]
        if let parameter { item["source"] = ["parameter": parameter] }
        let data = (try? JSONSerialization.data(withJSONObject: ["errors": [item]], options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// The harness's first `count` serials.
    static func firstSerials(_ count: Int) -> [String] { (0..<count).map { String(format: "TESTD%07d", $0) } }

    /// The serials requested for `orgDevices/{id}<suffix>`, in order.
    static func serials(_ requests: [String], _ suffix: String) -> [String] {
        requests.compactMap { request in
            guard let slash = request.firstIndex(of: "/") else { return nil }
            let path = String(request[slash...].prefix { $0 != "?" })
            let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4, parts[1] == "v1", parts[2] == "orgDevices", "/" + parts.dropFirst(4).joined(separator: "/") == (suffix.isEmpty ? "/" : suffix)
            else { return nil }
            return parts[3]
        }
    }
}
