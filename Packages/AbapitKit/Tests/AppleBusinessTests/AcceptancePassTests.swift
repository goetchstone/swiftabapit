@testable import AppleBusiness
import AppleModels
import Foundation
import JSONAPI
import Orgs
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
    /// overwriting the per-service count and counting probes all left every test green; round 3: so did dropping the
    /// services' unknown attribute names.
    @Test func aGreenPassReadsLineByLine() async throws {
        let harness = try await Harness(devices: 4)
        harness.stub.add(devices: [Resource(type: "orgDevices", id: "TESTNEW00001", attributes: [
            "serialNumber": .string("TESTNEW00001"), "productFamily": .string("Glasses"), "brandNewField": .string("secret-ish")])])
        harness.stub.add(services: [Harness.service("SVC1", name: "Mosyle"), Resource(type: "mdmServers", id: "SVC2", attributes: [
            "serverName": .string("Jamf"), "serverType": .string("FUTURE_MDM"), "status": .string("ACTIVE"), "futureServiceField": .string("secret-ish")])])
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
            mdmServers: ok, 2 items · unknown keys futureServiceField · unknown values serverType=FUTURE_MDM
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

    /// Every unknown attribute name and enum value the pass looks for is reported (plan §7's purpose), the single
    /// device's keys from every sampled device, and each only as a word: a newline that would forge a line, prose naming
    /// a device or 5000 bytes is `(not shown)` (verifier round 2: dropping the device status, purchase source, migration
    /// status, service status, default product family or payment type report left every test green, so did keeping only
    /// the last device's keys, and an attribute name with a newline forged an `ok` line; round 3: two names that aren't
    /// words read `(not shown), (not shown)` with every test green).
    @Test func everyUnknownNameAndValueIsReportedAsAWordOrNotShown() async throws {
        let harness = try await Harness()
        let forged = "x\norgDevices/{id}/activationLockStatus: ok, 5 items\nC02SECRETSERIAL owned by jane@example.com"
        harness.stub.add(devices: [
            Resource(type: "orgDevices", id: "TESTU0000001", attributes: [
                "serialNumber": .string("TESTU0000001"), "productFamily": .string("Glasses"), "status": .string("HELD"),
                "purchaseSourceType": .string("FUTURE_SOURCE"), "mdmMigrationStatus": .string("PAUSED"), "brandNewField": .string("secret-ish"),
                "bad key": .string("v")]),
            Resource(type: "orgDevices", id: "TESTU0000002", attributes: [
                "serialNumber": .string("TESTU0000002"), "productFamily": .string("Glasses\nprobe users: ok"),
                "status": .string(String(repeating: "Z", count: 5_000)), forged: .string("v"), "otherNewField": .string("secret-ish")]),
        ])
        harness.stub.add(services: [
            Resource(type: "mdmServers", id: "SVC1", attributes: ["serverName": .string("Mosyle"), "serverType": .string("MDM"),
                                                                  "status": .string("SUSPENDED"), "defaultProductFamilies": .array([.string("MAC"), .string("GLASSES")])]),
            Resource(type: "mdmServers", id: "SVC2", attributes: ["serverName": .string("Jamf"), "serverType": .string("HELD for C02SECRETSERIAL"),
                                                                  "status": .string("ACTIVE"), "defaultProductFamilies": .array([.string("IPAD")])]),
        ])
        harness.stub.setCoverage("TESTU0000001", [
            Resource(type: "appleCareCoverage", id: "C1", attributes: ["status": .string("ACTIVE"), "paymentType": .string("FUTURE_PAYMENT")]),
            Resource(type: "appleCareCoverage", id: "C2", attributes: ["status": .string("PAUSED"), "paymentType": .string("NONE")]),
        ])
        for serial in ["TESTU0000001", "TESTU0000002"] { harness.stub.setLock(serial, isLocked: false, lockType: "NONE") }
        let report = await harness.client.acceptancePass()
        let lines = report.text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 8 + AppleSection.allCases.count, "no forged line")
        #expect(lines.prefix(8).joined(separator: "\n") == """
            orgDevices: ok, 2 items · unknown keys (not shown), brandNewField, otherNewField · unknown values mdmMigrationStatus=PAUSED, \
            productFamily=(not shown), productFamily=Glasses, purchaseSourceType=FUTURE_SOURCE, status=(not shown), status=HELD
            mdmServers: ok, 2 items · unknown values defaultProductFamilies=GLASSES, serverType=(not shown), status=SUSPENDED
            mdmServers/{id}/relationships/devices: ok, 0 items
            orgDevices/{id}: ok, 2 items · unknown keys (not shown), brandNewField, otherNewField
            orgDevices/{id}/appleCareCoverage: ok, 2 items · unknown values paymentType=FUTURE_PAYMENT, status=PAUSED
            orgDevices/{id}/activationLockStatus: ok, 2 items
            orgDevices/{id}/assignedServer: ok, 2 items · 2 of 2 unassigned
            orgDevices/{id}/relationships/assignedServer: ok, 2 items · 2 of 2 unassigned
            """, "\(report.text)")
        for data in ["C02SECRET", "jane@", "ZZZZ", "secret-ish", "TESTU"] { #expect(!report.text.contains(data), "\(data)") }
        #expect(report.text.components(separatedBy: "probe users: ok").count == 2, "the real probe line only")
    }

    /// An enum value led by a combining mark is `(not shown)` like any other that isn't a word, on each of the ten fields
    /// whose values the pass reports, and forges no line (verifier round 3: the mark joined the `=` the field was found
    /// by into one `Character`, so a service's, a coverage's or the lock's value went into the text raw, forging two
    /// lines and naming a serial and an email, and a device's was dropped from the report).
    @Test func aValueLedByACombiningMarkIsNotShownAndForgesNoLine() async throws {
        let harness = try await Harness()
        let mark = "\u{301}"
        harness.stub.add(devices: [Resource(type: "orgDevices", id: "TESTU0000001", attributes: [
            "serialNumber": .string("TESTU0000001"), "productFamily": .string(mark + "Glasses jane@example.com"),
            "status": .string(mark + "HELD\nprobe users: ok"), "purchaseSourceType": .string(mark + "C02SECRETSERIAL"),
            "mdmMigrationStatus": .string(mark + "X\norgDevices/{id}: ok, 9 items"), mark + "newField": .string("v")])])
        harness.stub.add(services: [Resource(type: "mdmServers", id: "SVC1", attributes: [
            "serverName": .string("Mosyle"), "serverType": .string(mark + "HELD for C02SECRETSERIAL\nprobe users: ok"),
            "status": .string(mark + "jane@example.com"), "defaultProductFamilies": .array([.string("MAC"), .string(mark + "MAC C02SECRETSERIAL")])])])
        harness.stub.setCoverage("TESTU0000001", [Resource(type: "appleCareCoverage", id: "C1", attributes: [
            "status": .string(mark + "ACTIVE\nprobe apps: ok"), "paymentType": .string(mark + "PAID by jane@example.com")])])
        harness.stub.setLock("TESTU0000001", isLocked: false, lockType: mark + "X\norgDevices/{id}/assignedServer: ok, 9 items")
        let report = await harness.client.acceptancePass()
        let lines = report.text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 8 + AppleSection.allCases.count, "no forged line: \(report.text)")
        #expect(lines.prefix(8).joined(separator: "\n") == """
            orgDevices: ok, 1 item · unknown keys (not shown) · unknown values mdmMigrationStatus=(not shown), productFamily=(not shown), \
            purchaseSourceType=(not shown), status=(not shown)
            mdmServers: ok, 1 item · unknown values defaultProductFamilies=(not shown), serverType=(not shown), status=(not shown)
            mdmServers/{id}/relationships/devices: ok, 0 items
            orgDevices/{id}: ok, 1 item · unknown keys (not shown)
            orgDevices/{id}/appleCareCoverage: ok, 1 item · unknown values paymentType=(not shown), status=(not shown)
            orgDevices/{id}/activationLockStatus: ok, 1 item · unknown values lockType=(not shown)
            orgDevices/{id}/assignedServer: ok, 1 item · 1 of 1 unassigned
            orgDevices/{id}/relationships/assignedServer: ok, 1 item · 1 of 1 unassigned
            """, "\(report.text)")
        for data in ["C02SECRET", "jane@", "Glasses", "HELD", "PAID", "9 items"] { #expect(!report.text.contains(data), "\(data)") }
        #expect(!report.text.unicodeScalars.contains("\u{301}"), "the mark itself")
    }

    /// An attribute name or enum value reaches the text only as a word: an ASCII letter, then letters, digits or `_`, at
    /// most 64 bytes.
    @Test func onlyAWordIsShownAsAnUnknownNameOrValue() {
        let longest = "a" + String(repeating: "B", count: 63)
        for word in ["brandNewField", "FUTURE_MDM", "AppleTV", "Watch2", "x", longest] { #expect(AppleClient.acceptanceWord(word) == word) }
        for text in ["", "_X", "2X", "A B", "A\nB", "A\rB", "A\tB", "A-B", "A.B", "A=B", "a@example.com", "Caf\u{E9}", "\u{FF34}OKEN", "A\u{301}",
                     "\u{301}A", longest + "C"] {
            #expect(AppleClient.acceptanceWord(text) == "(not shown)", "\(text.debugDescription)")
        }
    }

    /// Each of the 128 ASCII bytes, against the word and the code filters, from ranges written here and not from their
    /// tables (verifier round 3: a table missing `z` or `9` left every test green, and one missing `K` was caught only
    /// by the one test value that holds it).
    @Test func theWordAndCodeFiltersKnowEveryASCIIByte() {
        for byte in UInt8(0)...127 {
            let char = String(UnicodeScalar(byte)), upper = (65...90).contains(byte), lower = (97...122).contains(byte)
            let inWord = upper || lower || (48...57).contains(byte) || byte == 95
            #expect(AppleClient.acceptanceWord(char) == (upper || lower ? char : "(not shown)"), "byte \(byte) first")
            #expect(AppleClient.acceptanceWord("A" + char) == (inWord ? "A" + char : "(not shown)"), "byte \(byte) after a letter")
            #expect(AppleClient.acceptanceCode("A_" + char) == (upper ? "A_" + char : nil), "byte \(byte) in an upper-case code")
            #expect(AppleClient.acceptanceCode("a_" + char) == (lower ? "a_" + char : nil), "byte \(byte) in a lower-case code")
        }
    }

    /// An id the client won't put in a path is never sent, and each read that needs it says what it is, not Apple's 404
    /// (verifier round 2: the five per-device lines read `error 404` with nothing sent, and the coverage walk could
    /// pass over the device and read `ok`; round 3: only a space was tried, so a guard refusing only a space left every
    /// test green, and `A/B`, `..` or `A?B` would then read Apple's 404 again).
    @Test(arguments: ["A B", "A/B", "..", "A?B", "A%2FB", "A#B"])
    func anIDThatCantGoInAPathIsNeverSentAndSaysSo(id: String) async throws {
        let harness = try await Harness()
        harness.stub.add(devices: [Resource(type: "orgDevices", id: id, attributes: ["serialNumber": .string(id)])])
        harness.stub.add(services: [Harness.service(id, name: "Mosyle")])
        let report = await harness.client.acceptancePass()
        for resource in Self.perDevice + ["mdmServers/{id}/relationships/devices"] {
            let line = try #require(report.lines.first { $0.resource == resource })
            let at = resource.hasPrefix("mdmServers") ? "at service 1 of 1" : "at device 1 of 1"
            #expect(line.status == .error("error malformed") && line.count == 0 && line.note == "\(at) · an id that can go in a path", "\(resource)")
        }
        #expect(!harness.stub.requests.contains { $0.contains("/v1/orgDevices/") || $0.contains("/v1/mdmServers/") }, "\(harness.stub.requests)")
    }

    /// A list, a linkage list or a single read answered with another resource is malformed, never `ok`: a page of
    /// `users` for `mdmServers`, a next link that walked off to the services, a linkage to a user, another device, a
    /// lock or a coverage of another type (verifier round 2: each read `ok`).
    @Test func anAnswerOfAnotherTypeOrItemIsMalformed() async throws {
        let walked = try await Harness(devices: 1)
        walked.stub.add(services: [Harness.service("SVC1", name: "Mosyle")])
        walked.stub.setLock("TESTD0000000", isLocked: false, lockType: "NONE")
        walked.stub.queue(200, for: "/v1/orgDevices?", body: #"""
            {"data":[{"type":"orgDevices","id":"TESTD0000000"}],"links":{"next":"https://api-business.apple.com/v1/mdmServers"}}
            """#)
        walked.stub.queue(200, for: "/v1/mdmServers/SVC1/relationships/devices", body: #"{"data":[{"type":"users","id":"U1"}]}"#)
        let first = await walked.client.acceptancePass()
        #expect(first.text.hasPrefix("""
            orgDevices: error malformed, 1 item · items of type orgDevices
            mdmServers: ok, 1 item
            mdmServers/{id}/relationships/devices: error malformed, 0 items · at service 1 of 1 · items of type orgDevices

            """), "\(first.text)")

        let harness = try await Harness(devices: 2)
        for serial in Self.firstSerials(2) { harness.stub.setLock(serial, isLocked: false, lockType: "NONE") }
        harness.stub.queue(200, for: "/v1/mdmServers", body: #"{"data":[{"type":"users","id":"U1"}]}"#)
        harness.stub.queue(200, for: "/v1/orgDevices/TESTD0000001", body: #"{"data":{"type":"orgDevices","id":"TESTD0000009"}}"#)
        harness.stub.queue(200, for: "/v1/orgDevices/TESTD0000000/appleCareCoverage", body: #"{"data":[{"type":"orgDevices","id":"C1"}]}"#)
        harness.stub.queue(200, for: "/v1/orgDevices/TESTD0000000/activationLockStatus",
                           body: #"{"data":{"type":"orgDevices","id":"TESTD0000000","attributes":{"isLocked":false}}}"#)
        let report = await harness.client.acceptancePass()
        #expect(report.text.hasPrefix("""
            orgDevices: ok, 2 items
            mdmServers: error malformed, 0 items · items of type mdmServers
            mdmServers/{id}/relationships/devices: skipped: no service to read (mdmServers error malformed)
            orgDevices/{id}: error malformed, 1 item · at device 2 of 2 · the orgDevices item asked for
            orgDevices/{id}/appleCareCoverage: error malformed, 0 items · at device 1 of 2 · items of type appleCareCoverage
            orgDevices/{id}/activationLockStatus: error malformed, 0 items · at device 1 of 2 · items of type activationLockStatus
            orgDevices/{id}/assignedServer: ok, 2 items · 2 of 2 unassigned

            """), "\(report.text)")
    }

    /// A lookalike is another resource too, compared byte for byte: a type or an id that only begins like the one asked
    /// for or differs in case, a page with one item of another type among its own, and an id equal to the serial asked
    /// for only under Unicode equivalence (verifier round 3: checking the type or the id by prefix or without case, or
    /// a page by any one item, left every test green, and `String ==` reads U+212A KELVIN SIGN as `K`).
    @Test func aLookalikeTypeOrIDOrAMixedPageIsMalformed() async throws {
        let list = "orgDevices: error malformed, 0 items · items of type orgDevices"
        let single = "orgDevices/{id}: error malformed, 0 items · at device 1 of 1 · the orgDevices item asked for"
        let cases: [(serial: String, path: String, body: String, line: String)] = [
            ("TESTD0000000", "/v1/orgDevices?", #"{"data":[{"type":"orgDevices","id":"TESTD0000000"},{"type":"users","id":"U1"}]}"#, list),
            ("TESTD0000000", "/v1/orgDevices?", #"{"data":[{"type":"users","id":"U1"},{"type":"orgDevices","id":"TESTD0000000"}]}"#, list),
            ("TESTD0000000", "/v1/orgDevices?", #"{"data":[{"type":"orgDevicesX","id":"TESTD0000000"}]}"#, list),
            ("TESTD0000000", "/v1/orgDevices?", #"{"data":[{"type":"OrgDevices","id":"TESTD0000000"}]}"#, list),
            ("TESTD0000000", "/v1/orgDevices/TESTD0000000", #"{"data":{"type":"orgDevices","id":"TESTD00000001"}}"#, single),
            ("TESTD0000000", "/v1/orgDevices/TESTD0000000", #"{"data":{"type":"orgDevices","id":"testd0000000"}}"#, single),
            ("TESTK0000000", "/v1/orgDevices/TESTK0000000", "{\"data\":{\"type\":\"orgDevices\",\"id\":\"TEST\u{212A}0000000\"}}", single),
        ]
        for (serial, path, body, line) in cases {
            let harness = try await Harness()
            harness.stub.add(devices: [Resource(type: "orgDevices", id: serial, attributes: ["serialNumber": .string(serial)])])
            harness.stub.setLock(serial, isLocked: false, lockType: "NONE")
            harness.stub.queue(200, for: path, body: body)
            let report = await harness.client.acceptancePass()
            #expect(report.text.contains(line + "\n"), "\(body): \(report.text)")
        }
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
    /// list and a device's coverage alike, and the services' and the coverage's notes count each list cut and only
    /// those (verifier round 2: with one list ever cut, `cut = 1` for `cut += 1` survived in both).
    @Test func aListCutAtThePageCapIsTruncatedWithItsCount() async throws {
        let harness = try await Harness(devices: 2_003, pageCap: 1)
        harness.stub.reportTotals()
        harness.stub.add(services: [Harness.service("SVC1", name: "Mosyle"), Harness.service("SVC2", name: "Jamf"), Harness.service("SVC3", name: "Kandji")])
        for index in 0..<2_003 { harness.stub.assign(String(format: "TESTD%07d", index), to: index < 1_001 ? "SVC1" : index < 2_002 ? "SVC2" : "SVC3") }
        for serial in Self.firstSerials(3) { harness.stub.setLock(serial, isLocked: false, lockType: "NONE") }
        for (serial, rows) in zip(Self.firstSerials(3), [1_001, 1_001, 1]) {
            harness.stub.setCoverage(serial, (0..<rows).map { Resource(type: "appleCareCoverage", id: "C\($0)", attributes: ["status": .string("ACTIVE")]) })
        }
        let report = await harness.client.acceptancePass(sample: 3)
        let devices = try #require(report.lines.first { $0.resource == "orgDevices" })
        #expect(devices.status == .truncated && !devices.ok)
        #expect(devices.count == 1_000)
        #expect(devices.note == "stopped at the page cap with more to come (Apple's total 2003)")
        let linked = try #require(report.lines.first { $0.resource == "mdmServers/{id}/relationships/devices" })
        #expect(linked.status == .truncated && linked.count == 2_001)
        #expect(linked.note == "2 of 3 services' lists stopped at the page cap")
        let coverage = try #require(report.lines.first { $0.resource == "orgDevices/{id}/appleCareCoverage" })
        #expect(coverage.status == .truncated && coverage.count == 2_001)
        #expect(coverage.note == "2 of 3 devices' coverage stopped at the page cap")
        #expect(report.lines.first { $0.resource == "mdmServers" }?.status == .ok)
        #expect(report.text.contains("orgDevices: truncated, 1000 items"))
    }

    /// A list the page cap cut before any item came (a page with a next link and no data) is "truncated, 0 items", and
    /// what reads its items says that, not that the org has none (verifier round 2: N24 wasn't equivalent, and the
    /// skip reason contradicted the line above it).
    @Test func aListCutBeforeAnyItemCameIsWhatDependsOnItsReason() async throws {
        let harness = try await Harness(devices: 3, pageCap: 1)
        harness.stub.queue(200, for: "/v1/orgDevices", body: #"{"data":[],"links":{"next":"https://api-business.apple.com/v1/orgDevices?cursor=0"}}"#)
        harness.stub.queue(200, for: "/v1/mdmServers", body: #"{"data":[],"links":{"next":"https://api-business.apple.com/v1/mdmServers?cursor=0"}}"#)
        let report = await harness.client.acceptancePass()
        #expect(report.text.hasPrefix("""
            orgDevices: truncated, 0 items · stopped at the page cap with more to come
            mdmServers: truncated, 0 items · stopped at the page cap with more to come
            mdmServers/{id}/relationships/devices: skipped: no service to read (mdmServers truncated)
            orgDevices/{id}: skipped: no device to sample (orgDevices truncated)

            """), "\(report.text)")
        for resource in Self.perDevice {
            #expect(report.lines.first { $0.resource == resource }?.status == .skipped("no device to sample (orgDevices truncated)"))
        }

        // The same for a service's device list and a device's coverage (verifier round 3: counting a cut only on a page
        // with items read both `ok`).
        let inner = try await Harness(devices: 1, pageCap: 1)
        inner.stub.setLock("TESTD0000000", isLocked: false, lockType: "NONE")
        inner.stub.add(services: [Harness.service("SVC1", name: "Mosyle")])
        inner.stub.queue(200, for: "/v1/mdmServers/SVC1/relationships/devices", body: #"""
            {"data":[],"links":{"next":"https://api-business.apple.com/v1/mdmServers/SVC1/relationships/devices?cursor=1"}}
            """#)
        inner.stub.queue(200, for: "/v1/orgDevices/TESTD0000000/appleCareCoverage", body: #"""
            {"data":[],"links":{"next":"https://api-business.apple.com/v1/orgDevices/TESTD0000000/appleCareCoverage?cursor=1"}}
            """#)
        let cut = await inner.client.acceptancePass()
        #expect(cut.text.contains("\nmdmServers/{id}/relationships/devices: truncated, 0 items · 1 of 1 services' lists stopped at the page cap\n"),
                "\(cut.text)")
        #expect(cut.text.contains("\norgDevices/{id}/appleCareCoverage: truncated, 0 items · 1 of 1 devices' coverage stopped at the page cap\n"),
                "\(cut.text)")
    }

    /// Invariant 8 for the service list itself and for what depends on it: a service list the page cap cut is
    /// "truncated", and the services' device lists say they cover only the services read (verifier round 1, N16), after
    /// how many of their own lists the cap cut (round 3: the two in the other order left every test green).
    @Test func aServiceListCutAtThePageCapIsSaidAndSoIsWhatDependsOnIt() async throws {
        let harness = try await Harness(pageCap: 1)
        harness.stub.reportTotals()
        harness.stub.add(services: (0..<1_001).map { Harness.service("SVC\($0)", name: "S\($0)") })
        harness.stub.queue(200, for: "/v1/mdmServers/SVC0/relationships/devices", body: #"""
            {"data":[],"links":{"next":"https://api-business.apple.com/v1/mdmServers/SVC0/relationships/devices?cursor=1"}}
            """#)
        let report = await harness.client.acceptancePass()
        let services = try #require(report.lines.first { $0.resource == "mdmServers" })
        #expect(services.status == .truncated && services.count == 1_000)
        #expect(services.note == "stopped at the page cap with more to come (Apple's total 1001)")
        let linked = try #require(report.lines.first { $0.resource == "mdmServers/{id}/relationships/devices" })
        #expect(linked.status == .truncated && linked.count == 0)
        #expect(linked.note == "1 of 1000 services' lists stopped at the page cap · covers only the 1000 services mdmServers read (truncated)")
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

    /// Apple's `code` reaches a note only as a code: words of letters joined by `_` or `.`, in one case, and joined by
    /// `.` only when upper-case. Prose, which may name a device, anything an identifier could be (a digit, a `-`, a
    /// single word) and a name (`John.Smith`, `jane.doe`) are dropped (verifier round 1: a newline, `/`, `:` and the
    /// length bound were untested, and `C02XSERIAL99` passed; round 2: names passed, and so would a character whose UTF-8
    /// bytes each read as a Latin-1 letter, U+07EA's `DF AA`, if a byte were tested as a `Character`).
    @Test func onlyACodeReachesANote() {
        let longest = String(repeating: "A", count: 31) + "_" + String(repeating: "B", count: 32)
        #expect(longest.utf8.count == 64)
        for code in ["FORBIDDEN_ERROR", "PARAMETER_ERROR.INVALID", "ENTITY_ERROR.ATTRIBUTE.INVALID", "server_error", "invalid_scope", "A.B", longest] {
            #expect(AppleClient.acceptanceCode(code) == code)
        }
        for prose in ["Device TESTD0000001 not found", "TESTD0000001", "TESTSERIAL", "QUEUED", "C02X_SERIAL", "NOT-FOUND_ERROR", "a,b", "a b",
                      "A_B\nFAKE_LINE", "A_B\r", "A_B\t", "\nA_B", "A_B/C", "A_B:C", "fields[orgDevices]", "_A", "A_", "A__B", "A._B", ".",
                      "X\u{301}_Y", "\u{FF34}OKEN_ERROR", "A\u{EA}_B", "\u{EA}a_b", "a_b\u{7EA}", "", longest + "C", "a.b", "jane.doe", "John.Smith", "John_Smith",
                      "Server_ERROR", "server_ERROR", nil] {
            #expect(AppleClient.acceptanceCode(prose) == nil, "\(String(describing: prose))")
        }
    }

    /// Apple's `source.parameter` reaches a note only when it is a query parameter Apple documents, and the list is the
    /// contracts' own: a value echoed there, a serial or a name, is dropped (verifier round 1: `C02XSERIAL99` reached the
    /// note; round 2: `janedoe` had a parameter's shape).
    @Test func onlyADocumentedParameterReachesANote() {
        let documented = Set([Scope.business, .school].flatMap { scope in
            ReadContractTests.endpoints(scope).flatMap { ($0["parameters"] as? [[String: Any]] ?? []) }
                .filter { $0["in"] as? String == "query" }.compactMap { $0["name"] as? String }
        })
        #expect(documented.count > 20 && AppleClient.acceptanceParameters == documented,
                "\(documented.symmetricDifference(AppleClient.acceptanceParameters).sorted())")
        for name in documented { #expect(AppleClient.acceptanceParameter(name) == name) }
        for value in ["TESTD0000001", "TESTSERIAL", "janedoe", "john", "serialNumber", "Limit", "limit2", "fields[OrgDevices]", "fields[org2]",
                      "fields[]", "[orgDevices]", "fields[orgDevices", "fields[orgDevices]x", "fields[orgDevices],limit", "limit\n", " limit",
                      "lim\u{301}it", "lim\u{EA}t", "", nil] {
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
