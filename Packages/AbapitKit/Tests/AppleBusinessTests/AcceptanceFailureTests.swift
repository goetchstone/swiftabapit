@testable import AppleBusiness
import AppleModels
import Foundation
import HTTPCore
import JSONAPI
import Security
import Synchronization
import Testing
import TestSupport
import Vault

/// Each way a read can fail reads as its status, never "ok" (Phase 1b verifier round 1: mapping any one of the failure
/// arms to `ok` left every test green, for a dropped connection, a token failure, a malformed or non-JSON answer, a
/// 422, a 401 and a cancellation; a malformed list read "ok, 0 items"; a cancelled walk read "ok").
@Suite("Acceptance pass failures", .serialized)
struct AcceptanceFailureTests {
    /// A failure the stub can send, and what the device list's line then reads.
    enum Arrangement: String, CaseIterable, Sendable {
        case revoked, offline, tokenServerError, tokenProse, tokenInvalidScope, tokenMalformed, tooLarge, rateLimited, unprocessable, unexpected,
             notJSON, malformed, keychain

        var bodyLimit: Int { self == .tooLarge ? 200 : HTTPClient.bodyLimit }

        func arrange(_ harness: Harness) {
            let stub = harness.stub
            switch self {
            case .revoked: stub.revokeAccount()
            case .offline: stub.failTransport(HTTPClient.attempts)
            case .tokenServerError: stub.failNextToken(500)
            case .tokenProse: stub.failNextToken(503, error: "the key for TESTD0000000 was revoked")
            case .tokenInvalidScope: stub.failNextToken(400, error: "invalid_scope")
            // A 200 with no `access_token`.
            case .tokenMalformed: stub.failNextToken(200)
            case .tooLarge: break
            case .rateLimited: for _ in 0..<HTTPClient.attempts { stub.queue(429, for: "/v1/orgDevices") }
            case .unprocessable:
                stub.queue(422, for: "/v1/orgDevices", body: AcceptancePassTests.errorBody(422, code: "ENTITY_ERROR.INVALID", detail: "DETAIL_NAMES.DEVICE"))
            case .unexpected: stub.queue(418, for: "/v1/orgDevices")
            case .notJSON: stub.queue(200, for: "/v1/orgDevices", body: "<html>TESTD0000000</html>")
            case .malformed: stub.queue(200, for: "/v1/orgDevices", body: "{}")
            case .keychain: harness.store.failNext(.sign, with: errSecInteractionNotAllowed)
            }
        }

        var status: AcceptanceReport.Status {
            switch self {
            case .revoked: .error("error 401")
            case .offline: .error("error transport -1005")
            case .tokenServerError, .tokenProse, .tokenInvalidScope, .tokenMalformed: .error("error token")
            case .tooLarge: .error("error too large")
            case .rateLimited: .error("error 429")
            case .unprocessable: .error("error 422")
            case .unexpected: .error("error 418")
            case .notJSON: .error("error not JSON")
            case .malformed: .error("error malformed")
            case .keychain: .error("error keychain")
            }
        }

        var note: String? {
            switch self {
            case .tokenServerError: "500 server_error"
            case .tokenProse: "503"
            case .tokenInvalidScope: "invalid_scope"
            case .tokenMalformed: "malformed"
            case .malformed: "a page of /v1/orgDevices"
            case .keychain: VaultError.keychain(errSecInteractionNotAllowed).guidance
            default: nil
            }
        }
    }

    /// Driven through the stub's switches (invariant 5): each failure is its status, the per-device reads are skipped
    /// saying why, and nothing of a body or a token endpoint's prose reaches the text.
    @Test(arguments: Arrangement.allCases)
    func eachFailureTheStubCanSendIsItsStatusNeverOk(_ arrangement: Arrangement) async throws {
        let harness = try await Harness(devices: 2, bodyLimit: arrangement.bodyLimit)
        arrangement.arrange(harness)
        let report = await harness.client.acceptancePass()
        let devices = try #require(report.lines.first { $0.resource == "orgDevices" })
        #expect(devices.status == arrangement.status && !devices.ok, "\(report.text)")
        #expect(devices.note == arrangement.note)
        #expect(devices.count == 0)
        for resource in AcceptancePassTests.perDevice {
            #expect(report.lines.first { $0.resource == resource }?.status == .skipped("no device to sample (orgDevices \(arrangement.status))"))
        }
        #expect(!report.text.contains("TESTD"), "\(report.text)")
        if arrangement == .revoked {
            #expect(report.lines.allSatisfy { !$0.ok })
            #expect(report.lines.filter { $0.resource.hasPrefix("probe ") }.allSatisfy { $0.status == .error("error 401") })
        }
    }

    /// Every arm of `acceptanceFailure`, the ones the pass can't reach through the stub included (another host, another
    /// error type): never `ok`, and a note holds only a code-shaped code or parameter, this app's words, or the Vault's.
    @Test func everyFailureIsItsStatusWithOnlyCodes() {
        let cases: [(any Error, AcceptanceReport.Status, String?)] = [
            (AppleAPIError.unauthorized, .error("error 401"), nil),
            (AppleAPIError.forbidden(code: "FORBIDDEN_ERROR"), .forbidden, "FORBIDDEN_ERROR"),
            (AppleAPIError.forbidden(code: "TESTD0000001 is forbidden"), .forbidden, nil),
            (AppleAPIError.forbidden(code: nil), .forbidden, nil),
            (AppleAPIError.notFound, .error("error 404"), nil),
            (AppleAPIError.conflict(code: "STATE_ERROR.CONFLICT", detail: "DETAIL_NAMES.DEVICE"), .error("error 409"), "STATE_ERROR.CONFLICT"),
            (AppleAPIError.conflict(code: "TESTD0000001", detail: nil), .error("error 409"), nil),
            (AppleAPIError.unprocessable(pointer: "/data/attributes/serialNumber", detail: "DETAIL_NAMES.DEVICE"), .error("error 422"), nil),
            (AppleAPIError.badRequest(code: "PARAMETER_ERROR.INVALID", parameter: "fields[orgDevices]", detail: "DETAIL_NAMES.DEVICE"),
             .error("error 400"), "PARAMETER_ERROR.INVALID fields[orgDevices]"),
            (AppleAPIError.badRequest(code: "PARAMETER_ERROR.INVALID", parameter: "TESTD0000001", detail: nil), .error("error 400"), "PARAMETER_ERROR.INVALID"),
            (AppleAPIError.badRequest(code: "TESTD0000001", parameter: "limit", detail: nil), .error("error 400"), "limit"),
            (AppleAPIError.badRequest(code: nil, parameter: nil, detail: "DETAIL_NAMES.DEVICE"), .error("error 400"), nil),
            (AppleAPIError.rateLimited, .error("error 429"), nil),
            (AppleAPIError.server(status: 503), .error("error 503"), nil),
            (AppleAPIError.unexpected(status: 418), .error("error 418"), nil),
            (AppleAPIError.notJSON(bytes: 12), .error("error not JSON"), nil),
            (AppleAPIError.malformed("a single /v1/orgDevices/{id}"), .error("error malformed"), "a single /v1/orgDevices/{id}"),
            (AppleAPIError.http(.transport(code: -1009)), .error("error transport -1009"), nil),
            (HTTPFailure.transport(code: -1001), .error("error transport -1001"), nil),
            (HTTPFailure.tooLarge(limit: 10), .error("error too large"), nil),
            (HTTPFailure.refusedHost("example.com"), .error("error refused host"), nil),
            (AppleAPIError.token(.status(500, "server_error")), .error("error token"), "500 server_error"),
            (AppleAPIError.token(.status(503, "TESTD0000001 revoked")), .error("error token"), "503"),
            (AppleAPIError.token(.invalidClient), .error("error token"), "invalid_client"),
            (AppleAPIError.token(.rateLimited), .error("error token"), "429"),
            // Verifier round 2: these three codes could be dropped or swapped with every test green.
            (AppleAPIError.token(.notConfigured), .error("error token"), "not configured"),
            (AppleAPIError.token(.invalidScope), .error("error token"), "invalid_scope"),
            (AppleAPIError.token(.malformed), .error("error token"), "malformed"),
            (AppleAPIError.token(.invalidRequest), .error("error token"), "invalid_request"),
            (AppleAPIError.token(.unauthorizedClient), .error("error token"), "unauthorized_client"),
            (AppleAPIError.vault("Touch ID was cancelled."), .error("error keychain"), "Touch ID was cancelled."),
            (AppleAPIError.wrongHost("api-school.apple.com"), .error("error wrong host"), nil),
            (CancellationError(), .error("error cancelled"), nil),
            (AppleStub.StubFailure.unhandled("GET /v1/x"), .error("error StubFailure"), nil),
        ]
        for (error, status, note) in cases {
            let failed = AppleClient.acceptanceFailure(error)
            #expect(failed.status == status, "\(error)")
            #expect(failed.note == note, "\(error)")
        }
    }

    /// Apple's codes and parameters reach a note through the stub only as codes and parameter names: one that is
    /// prose or names a device is dropped where it's read, not only by the filter on its own (verifier round 1: each
    /// call site's filter could be bypassed with every test green).
    @Test func applesCodesReachANoteOnlyAsCodes() async throws {
        let harness = try await Harness(devices: 1)
        harness.stub.queue(403, for: "/v1/orgDevices", body: AcceptancePassTests.errorBody(403, code: "Device TESTD0000000 is forbidden", detail: "TESTD0000000"))
        harness.stub.queue(400, for: "/v1/mdmServers", body: AcceptancePassTests.errorBody(400, code: "PARAMETER_ERROR.INVALID", detail: "TESTD0000000",
                                                                                            parameter: "TESTD0000000"))
        let report = await harness.client.acceptancePass()
        let devices = try #require(report.lines.first { $0.resource == "orgDevices" })
        #expect(devices.status == .forbidden && devices.note == nil)
        let services = try #require(report.lines.first { $0.resource == "mdmServers" })
        #expect(services.status == .error("error 400") && services.note == "PARAMETER_ERROR.INVALID")
        #expect(!report.text.contains("TESTD"), "\(report.text)")
    }

    /// A 200 that isn't a list (no `data`, `null`, one object, items without an `id`, Apple's `errors` sent with 200) is
    /// malformed, never "ok, 0 items", and the per-device reads don't say the org has none (verifier round 1).
    @Test(arguments: [#"{}"#, #"{"data":null}"#, #"{"data":[{"type":"orgDevices"},{"type":"orgDevices","attributes":{}}]}"#,
                      #"{"data":{"type":"orgDevices","id":"TESTD0000000"}}"#, #"{"errors":[{"status":"500","code":"SERVER_ERROR"}]}"#])
    func aListBodyThatIsntAListIsMalformed(body: String) async throws {
        let harness = try await Harness(devices: 3)
        harness.stub.queue(200, for: "/v1/orgDevices", body: body)
        let report = await harness.client.acceptancePass()
        let devices = try #require(report.lines.first { $0.resource == "orgDevices" })
        #expect(devices.status == .error("error malformed") && devices.count == 0 && devices.note == "a page of /v1/orgDevices", "\(report.text)")
        for resource in AcceptancePassTests.perDevice {
            #expect(report.lines.first { $0.resource == resource }?.status == .skipped("no device to sample (orgDevices error malformed)"))
        }
    }

    /// A later page that isn't a list is malformed too, with what the pages before it held, never "ok" over what came
    /// (verifier round 2: checking only the first page left every test green, and a 1500-device org then read
    /// `ok, 1000 items`).
    @Test func aLaterPageThatIsntAListIsMalformedWithWhatCameBefore() async throws {
        let harness = try await Harness(devices: 1_500)
        for serial in AcceptancePassTests.firstSerials(5) { harness.stub.setLock(serial, isLocked: false, lockType: "NONE") }
        harness.stub.queue(200, for: "/v1/orgDevices?cursor=", body: "{}")
        let report = await harness.client.acceptancePass()
        #expect(report.text.hasPrefix("orgDevices: error malformed, 1000 items · a page of /v1/orgDevices\n"), "\(report.text)")
        #expect(harness.stub.requests.filter { $0.hasPrefix("GET api-business.apple.com/v1/orgDevices?") }.count == 2 + 1, "two pages and the probe")
    }

    /// The single reads, the coverage list and a probe say malformed too, in this app's words with no identifier.
    @Test func aMalformedSingleReadCoverageOrProbeIsAnError() async throws {
        let harness = try await Harness(devices: 2)
        for serial in AcceptancePassTests.firstSerials(2) { harness.stub.setLock(serial, isLocked: false, lockType: "NONE") }
        // The single read comes first of TESTD0000000's reads, so it takes the first of these.
        harness.stub.queue(200, for: "/v1/orgDevices/TESTD0000000", body: #"{"data":[]}"#)
        harness.stub.queue(200, for: "/v1/orgDevices/TESTD0000000/appleCareCoverage", body: #"{"data":{"type":"appleCareCoverage"}}"#)
        harness.stub.queue(200, for: "/v1/orgDevices/TESTD0000000/activationLockStatus", body: #"{"data":null}"#)
        harness.stub.queue(200, for: "/v1/orgDevices/TESTD0000000/assignedServer", body: #"{"data":{"type":"orgDevices","id":"TESTD0000000"}}"#)
        harness.stub.queue(200, for: "/v1/orgDevices/TESTD0000000/relationships/assignedServer", body: "{}")
        harness.stub.queue(200, for: "/v1/users", body: "{}")
        let report = await harness.client.acceptancePass()
        let expected = [
            "orgDevices/{id}": "a single /v1/orgDevices/{id}",
            "orgDevices/{id}/appleCareCoverage": "a page of /v1/orgDevices/{id}/appleCareCoverage",
            "orgDevices/{id}/activationLockStatus": "a single /v1/orgDevices/{id}/activationLockStatus",
            "orgDevices/{id}/assignedServer": "an assigned server",
            "orgDevices/{id}/relationships/assignedServer": "an assigned-server linkage",
        ]
        for (resource, what) in expected {
            let line = try #require(report.lines.first { $0.resource == resource })
            #expect(line.status == .error("error malformed") && line.count == 0 && line.note == "at device 1 of 2 · \(what)", "\(resource)")
        }
        let users = try #require(report.lines.first { $0.resource == "probe users" })
        #expect(users.status == .error("error malformed") && users.count == nil && users.note == "a page of /v1/users")
        #expect(!report.text.contains("TESTD"), "\(report.text)")
    }

    /// A pass cancelled before it starts sends nothing and says so on every line (verifier round 1).
    @Test func aPassCancelledBeforeItStartsSendsNothing() async throws {
        let harness = try await Harness(devices: 3)
        let client = harness.client
        let task = Task { () -> AcceptanceReport in
            while !Task.isCancelled { await Task.yield() }
            return await client.acceptancePass()
        }
        task.cancel()
        let report = await task.value
        #expect(!report.lines.isEmpty && report.lines.allSatisfy { $0.status == .skipped("the pass was cancelled") }, "\(report.text)")
        #expect(harness.stub.requests.isEmpty)
    }

    /// A pass cancelled while it walks the device list: that line is "error cancelled" with what it had read, never
    /// "ok", and nothing after it is sent. A cancelled `for try await` over a stream ends without throwing (Phase 1b
    /// review H2), so the line read "ok" and the per-device reads said the org had no device (verifier round 1).
    @Test func aPassCancelledMidWalkIsNeverOk() async throws {
        let harness = try await Harness(devices: 2_500)
        let pass = PassBox()
        let sent = Mutex<[String]>([])
        let transport = Interceptor(stub: harness.stub) { request in
            sent.withLock { $0.append(request.url?.absoluteString ?? "?") }
            guard request.url?.query()?.contains("cursor=") == true else { return }
            while pass.task.withLock({ $0 }) == nil { await Task.yield() }
            pass.task.withLock { $0 }?.cancel()
        }
        let client = AppleClient(account: await harness.client.account, vault: harness.vault, transport: transport, limiter: harness.limiter,
                                 sleep: { _ in })
        let task = Task { await client.acceptancePass() }
        pass.task.withLock { $0 = task }
        let report = await task.value
        let devices = try #require(report.lines.first { $0.resource == "orgDevices" })
        #expect(devices.status == .error("error cancelled"), "\(report.text)")
        // Page 1 may or may not have reached the loop before the cancellation did: what was read, never the whole list.
        #expect(devices.count.map { $0 < 2_500 } == true, "\(report.text)")
        #expect(report.lines.dropFirst().allSatisfy { $0.status == .skipped("the pass was cancelled") }, "\(report.text)")
        #expect(!harness.stub.requests.contains { $0.contains("/v1/mdmServers") || $0.contains("/v1/orgDevices/") })
        // The walk stops before page 3 (verifier round 2: without its own check it fetched every page after the cancel).
        // It runs in its own task, which can outlive the pass, so a page 3 is given time to show.
        func pages() -> Int { sent.withLock { $0 }.filter { $0.contains("/v1/orgDevices?") }.count }
        for _ in 0..<30 where pages() == 2 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(pages() == 2, "\(sent.withLock { $0 })")
    }

    /// A check cancelled inside its loop stops there: the read in flight is the last request sent, and the line says the
    /// item it stopped at (verifier round 2: over the stub, which answers a cancelled read as a transport that ignores
    /// cancellation would, a check cancelled at its first device sent the other nineteen reads and said "at device 20
    /// of 20", and one cancelled at its first service walked all fifty services' lists and said "at service 50 of 50").
    @Test(arguments: [
        ("/v1/orgDevices/TESTD0000000", "orgDevices/{id}: error cancelled, 1 item · at device 2 of 5"),
        ("/v1/orgDevices/TESTD0000000/appleCareCoverage", "orgDevices/{id}/appleCareCoverage: error cancelled, 0 items · at device 1 of 5"),
        ("/v1/orgDevices/TESTD0000000/activationLockStatus", "orgDevices/{id}/activationLockStatus: error cancelled, 1 item · at device 2 of 5"),
        ("/v1/orgDevices/TESTD0000000/assignedServer", "orgDevices/{id}/assignedServer: error cancelled, 1 item · at device 2 of 5"),
        ("/v1/orgDevices/TESTD0000000/relationships/assignedServer",
         "orgDevices/{id}/relationships/assignedServer: error cancelled, 1 item · at device 2 of 5"),
        ("/v1/mdmServers/SVC0/relationships/devices", "mdmServers/{id}/relationships/devices: error cancelled, 0 items · at service 1 of 5"),
    ])
    func aCheckCancelledInItsLoopStopsWhereItWas(path: String, line: String) async throws {
        let harness = try await Harness(devices: 5)
        harness.stub.add(services: (0..<5).map { Harness.service("SVC\($0)", name: "S\($0)") })
        for serial in AcceptancePassTests.firstSerials(5) { harness.stub.setLock(serial, isLocked: false, lockType: "NONE") }
        let pass = PassBox()
        // Logged before the cancel: a list's read runs in its walk's task, which the stub may record after the pass ends.
        let sent = Mutex<[String]>([])
        let transport = Interceptor(stub: harness.stub) { request in
            sent.withLock { $0.append(request.url?.path() ?? "?") }
            guard request.url?.path() == path else { return }
            while pass.task.withLock({ $0 }) == nil { await Task.yield() }
            pass.task.withLock { $0 }?.cancel()
        }
        let client = AppleClient(account: await harness.client.account, vault: harness.vault, transport: transport, limiter: harness.limiter,
                                 sleep: { _ in })
        let task = Task { await client.acceptancePass() }
        pass.task.withLock { $0 = task }
        let report = await task.value
        let resource = String(line.prefix { $0 != ":" })
        #expect(report.text.contains(line + "\n"), "\(report.text)")
        let after = report.lines.drop { $0.resource != resource }.dropFirst()
        #expect(!after.isEmpty && after.allSatisfy { $0.status == .skipped("the pass was cancelled") }, "\(report.text)")
        let paths = sent.withLock { $0 }
        #expect(paths.last == path && paths.filter { $0 == path }.count == 1, "nothing is sent after the read in flight: \(paths.suffix(3))")
    }
}

/// The pass a test cancels from inside the transport.
final class PassBox: Sendable {
    let task = Mutex<Task<AcceptanceReport, Never>?>(nil)
}

/// The strict stub with `before` run ahead of each request: where a test cancels a pass mid-walk.
struct Interceptor: Transport {
    let stub: AppleStub
    let before: @Sendable (URLRequest) async -> Void

    func send(_ request: URLRequest, limit: Int) async throws -> (Data, HTTPURLResponse) {
        await before(request)
        return try await stub.send(request, limit: limit)
    }
}
