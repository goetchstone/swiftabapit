@testable import AppleBusiness
import AppleModels
import Foundation
import JSONAPI
import Security
import Testing
import TestSupport

/// The acceptance pass says "ok" only for a read that ran and fully succeeded (Phase 1b review M5: a forbidden device
/// list left five per-device lines "ok … 0", a list cut at the page cap read "ok", and of its mutants "sample unbounded",
/// "failure as ok", "any probe ok", "truncation unsaid" and "lock reads one device only" survived).
@Suite("Acceptance pass", .serialized)
struct AcceptancePassTests {
    static let perDevice = ["orgDevices/{id}", "orgDevices/{id}/appleCareCoverage", "orgDevices/{id}/activationLockStatus",
                            "orgDevices/{id}/assignedServer", "orgDevices/{id}/relationships/assignedServer"]

    @Test func itReportsCountsAndWhatThisVersionDoesntKnowButNoData() async throws {
        let harness = try await Harness(devices: 3)
        harness.stub.add(devices: [Resource(type: "orgDevices", id: "TESTNEW00001", attributes: [
            "serialNumber": .string("TESTNEW00001"), "productFamily": .string("Glasses"), "brandNewField": .string("secret-ish")])])
        harness.stub.add(services: [Harness.service("SVC1", name: "Mosyle")])
        for index in 0..<4 { harness.stub.setLock(index < 3 ? String(format: "TESTD%07d", index) : "TESTNEW00001", isLocked: false, lockType: "NONE") }
        let report = await harness.client.acceptancePass(sample: 4)
        let devices = try #require(report.lines.first { $0.resource == "orgDevices" })
        #expect(devices.ok && devices.count == 4)
        #expect(devices.unknownKeys == ["brandNewField"])
        #expect(devices.unknownValues == ["productFamily=Glasses"])
        #expect(!report.text.contains("secret-ish") && !report.text.contains("TESTNEW00001"))
        #expect(report.lines.allSatisfy { $0.status == .ok }, "\(report.text)")
        #expect(report.text.contains("orgDevices: ok, 4 items"))
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

    /// Each failure is its status, with how far a loop got and Apple's code, never Apple's `detail` (review LOW: the
    /// note carried `AppleAPIError.message`, which quotes it).
    @Test func aFailureIsItsStatusWithCodesButNeverApplesDetail() async throws {
        let harness = try await Harness(devices: 3)
        harness.stub.add(services: [Harness.service("SVC1", name: "Mosyle")])
        harness.stub.setLock("TESTD0000000", isLocked: false, lockType: "NONE")
        harness.stub.setLock("TESTD0000001", isLocked: false, lockType: "NONE")
        harness.stub.queue(400, for: "/v1/mdmServers")
        harness.stub.queue(500, for: "/v1/orgDevices/TESTD0000001/appleCareCoverage")
        harness.stub.queue(409, for: "/v1/orgDevices/TESTD0000000/assignedServer")
        let report = await harness.client.acceptancePass(sample: 3)
        func line(_ resource: String) throws -> AcceptanceReport.Line { try #require(report.lines.first { $0.resource == resource }) }

        #expect(try line("mdmServers").status == .error("error 400"))
        #expect(try line("mdmServers").note == "QUEUED")
        #expect(try line("mdmServers/{id}/relationships/devices").status == .skipped("no service to read (mdmServers error 400)"))
        #expect(try line("orgDevices/{id}/appleCareCoverage").status == .error("error 500"))
        #expect(try line("orgDevices/{id}/appleCareCoverage").note == "at device 2 of 3")
        // TESTD0000002 has no lock: Apple's 404, after two read.
        #expect(try line("orgDevices/{id}/activationLockStatus").status == .error("error 404"))
        #expect(try line("orgDevices/{id}/activationLockStatus").count == 2)
        #expect(try line("orgDevices/{id}/activationLockStatus").note == "at device 3 of 3")
        #expect(try line("orgDevices/{id}/assignedServer").status == .error("error 409"))
        #expect(try line("orgDevices/{id}/assignedServer").note == "at device 1 of 3 · QUEUED")
        #expect(try line("orgDevices/{id}").status == .ok && line("orgDevices").status == .ok)
        #expect(report.lines.filter { if case .error = $0.status { true } else { false } }.allSatisfy { !$0.ok })
        for prose in ["A failure the test queued", "Queued failure", "Apple refused", "Apple's service failed"] {
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
        #expect(report.text.contains("probe users: forbidden") && report.text.contains("probe apps: error 500"))
    }

    /// Review mutants "sample unbounded" and "lock reads one device only": every per-device read covers each sampled
    /// device once, and the sample never passes its limit, whatever the caller asks.
    @Test func everyPerDeviceReadCoversTheWholeSampleAndTheSampleIsBounded() async throws {
        let harness = try await Harness(devices: 30)
        for index in 0..<30 { harness.stub.setLock(String(format: "TESTD%07d", index), isLocked: false, lockType: index == 3 ? "NEW_LOCK" : "NONE") }
        let report = await harness.client.acceptancePass(sample: 4)
        let sampled = (0..<4).map { String(format: "TESTD%07d", $0) }
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

    /// Apple's `code` and `source.parameter` reach a note only as codes: prose, which may name a device, is dropped.
    @Test func onlyACodeReachesANote() {
        for code in ["FORBIDDEN_ERROR", "PARAMETER_ERROR.INVALID", "fields[orgDevices]", "NOT-FOUND_2"] {
            #expect(AppleClient.acceptanceCode(code) == code)
        }
        for prose in ["Device C02X1234 not found", "a,b", "x\u{301}", "\u{FF34}OKEN", "", String(repeating: "A", count: 65), nil] {
            #expect(AppleClient.acceptanceCode(prose) == nil, "\(String(describing: prose))")
        }
    }

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
