import AppleBusiness
import AppleModels
import CryptoKit
import Foundation
import HTTPCore
import JSONAPI
import Orgs
import Testing
import TestSupport
import Vault
import Wire

@Suite("Apple client against the strict stub", .serialized)
struct AppleClientTests {
    @Test func aTokenIsMintedWithAVerifiedAssertionAndDevicesArrive() async throws {
        let harness = try await Harness(devices: 3)
        let devices = try await harness.allDevices()
        #expect(devices.map(\.serialNumber) == ["TESTD0000000", "TESTD0000001", "TESTD0000002"])
        #expect(harness.stub.mints == 1)
        // The form went in the body: the token request's URL has no query.
        #expect(harness.stub.requests.first == "POST account.apple.com/auth/oauth2/token")
    }

    @Test func aWrongKeyIsInvalidClientAndSaysWhatToCheck() async throws {
        let harness = try await Harness(devices: 1, registerKey: P256.Signing.PrivateKey())
        await #expect(throws: AppleAPIError.token(.invalidClient)) { _ = try await harness.allDevices() }
        #expect(AppleAPIError.token(.invalidClient).message.contains("key ID"))
    }

    @Test func concurrentReadsShareOneMint() async throws {
        let harness = try await Harness(devices: 5)
        try await withThrowingTaskGroup(of: OrgDevice.self) { group in
            for index in 0..<5 { group.addTask { try await harness.client.device(String(format: "TESTD%07d", index)) } }
            for try await _ in group {}
        }
        #expect(harness.stub.mints == 1)
        #expect(await harness.client.mints == 1)
    }

    @Test func a401DropsTheTokenAndRetriesOnce() async throws {
        let harness = try await Harness(devices: 1)
        _ = try await harness.allDevices()
        harness.stub.expireTokensOnce()
        _ = try await harness.client.device("TESTD0000000")
        #expect(harness.stub.mints == 2)
    }

    @Test func a429WaitsForRetryAfterThenBacksOff() async throws {
        let harness = try await Harness(devices: 1)
        harness.stub.queue(429, for: "/v1/orgDevices/TESTD0000000", headers: ["Retry-After": "7"])
        harness.stub.queue(429, for: "/v1/orgDevices/TESTD0000000")
        harness.stub.queue(429, for: "/v1/orgDevices/TESTD0000000", headers: ["Retry-After": "600"])
        _ = try await harness.client.device("TESTD0000000")
        #expect(harness.sleeps.all == [.seconds(7), .seconds(4), .seconds(60)])
        #expect(await harness.limiter.readsPerMinute < 600)
    }

    @Test func rateLimitedPastTheRetriesIsSaid() async throws {
        let harness = try await Harness(devices: 1)
        for _ in 0..<HTTPClient.attempts { harness.stub.queue(429, for: "/v1/orgDevices/TESTD0000000") }
        await #expect(throws: AppleAPIError.rateLimited) { _ = try await harness.client.device("TESTD0000000") }
    }

    @Test func pagesFollowNextLinksAndTheCapIsShown() async throws {
        let harness = try await Harness(devices: 2_500)
        var pages: [Page<OrgDevice>] = []
        for try await page in harness.client.devices() { pages.append(page) }
        #expect(pages.map(\.items.count) == [1000, 1000, 500])
        #expect(pages.allSatisfy { !$0.truncated })
        #expect(Set(pages.flatMap(\.items).map(\.serialNumber)).count == 2_500)

        let capped = try await Harness(devices: 2_500, pageCap: 2)
        var last: Page<OrgDevice>?
        for try await page in capped.client.devices() { last = page }
        #expect(last?.number == 2)
        #expect(last?.truncated == true)
    }

    @Test func anUnassignedDeviceHasNoServiceAndAnAssignedOneDoes() async throws {
        let harness = try await Harness(devices: 2)
        harness.stub.add(services: [Harness.service("SVC1", name: "Mosyle")])
        harness.stub.assign("TESTD0000001", to: "SVC1")
        #expect(try await harness.client.assignedService("TESTD0000000") == nil)
        #expect(try await harness.client.assignedServiceID("TESTD0000000") == nil)
        #expect(try await harness.client.assignedService("TESTD0000001")?.name == "Mosyle")
        #expect(try await harness.client.assignedServiceID("TESTD0000001") == "SVC1")
        var serials: [String] = []
        for try await page in harness.client.serviceDeviceIDs("SVC1") { serials += page.items }
        #expect(serials == ["TESTD0000001"])
    }

    @Test func coverageAndActivationLockRead() async throws {
        let harness = try await Harness(devices: 1)
        harness.stub.setCoverage("TESTD0000000", [Resource(type: "appleCareCoverage", id: "C1",
                                                           attributes: ["status": .string("ACTIVE"), "paymentType": .string("ABE_SUBSCRIPTION")])])
        harness.stub.setLock("TESTD0000000", isLocked: true, lockType: "USER")
        let coverage = try await harness.client.appleCare("TESTD0000000")
        #expect(coverage.first?.paymentType == .known(.abeSubscription))
        let lock = try await harness.client.activationLock("TESTD0000000")
        #expect(lock.blocksRelease)
    }

    /// An identifier that would steer the path is never sent.
    @Test(arguments: ["../mdmServers", "A/B", "", ".hidden", "C02X?limit=1", "x y", String(repeating: "A", count: 129)])
    func anIdentifierThatWouldSteerThePathIsRefused(id: String) async throws {
        let harness = try await Harness(devices: 1)
        await #expect(throws: AppleAPIError.notFound) { _ = try await harness.client.device(id) }
        await #expect(throws: AppleAPIError.notFound) { _ = try await harness.client.service(id) }
        #expect(harness.stub.requests.isEmpty)
    }

    @Test func aForbiddenSectionProbesAsForbiddenAndSchoolSkipsBusinessSections() async throws {
        let harness = try await Harness(devices: 1)
        harness.stub.forbid("/v1/users")
        let results = await harness.client.probeReads()
        #expect(results.count == AppleSection.allCases.count)
        #expect(results.first { $0.section == .users }?.status == ProbeResult.forbidden)
        #expect(results.filter { $0.section != .users }.allSatisfy { $0.status == ProbeResult.ok }, "\(results)")

        let school = try await Harness(scope: .school, devices: 1)
        #expect(await school.client.probeReads().map(\.section) == [.devices, .mdmServers])
    }

    @Test func aSchoolTokenIsntSentToTheBusinessHost() async throws {
        let harness = try await Harness(scope: .school, devices: 1)
        _ = try await harness.allDevices()
        #expect(harness.stub.requests.contains { $0.hasPrefix("GET api-school.apple.com/v1/orgDevices") })
        #expect(!harness.stub.requests.contains { $0.contains("api-business") })
    }

    @Test func aTokenServiceRateLimitIsSaid() async throws {
        let harness = try await Harness(devices: 1)
        harness.stub.failNextToken(429)
        await #expect(throws: AppleAPIError.token(.rateLimited)) { _ = try await harness.allDevices() }
    }
}
