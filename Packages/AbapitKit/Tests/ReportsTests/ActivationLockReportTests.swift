import AppleModels
import JSONAPI
import Testing
@testable import Reports

@Suite("Activation Lock report")
struct ActivationLockReportTests {
    /// Devices and their reads by id; a device with no read is one a cut sweep never reached.
    static func make(_ locks: [(String, DeviceRead<ActivationLockStatus>?)], list: ListRead = .whole, extra: [String: JSONObject] = [:]) -> ActivationLockReport {
        let devices = locks.map { Fleet.device($0.0, extra[$0.0] ?? [:]) }
        var reads: [String: DeviceRead<ActivationLockStatus>] = [:]
        for (serial, read) in locks { if let read { reads[serial] = read } }
        return ActivationLockReport(devices, reads: reads, list: list)
    }

    static func read(_ isLocked: Bool?, _ type: String?) -> DeviceRead<ActivationLockStatus> { .read(Fleet.lock(isLocked, type)) }

    static let report = make([
        ("U1", read(true, "USER")), ("M1", read(true, "MDM")), ("F1", read(true, "FUTURE_TYPE")), ("N1", read(true, "NONE")), ("T1", read(true, nil)),
        ("L1", read(false, "NONE")), ("C1", read(nil, nil)),
        ("R1", .notRead("your role can't read this")), ("R2", .notRead("the sweep was cut")),
    ])

    /// A USER lock blocks release and an MDM lock doesn't: the two never swap.
    @Test func aUserLockBlocksReleaseAndAnMdmLockDoesNot() {
        let user = Self.report.rows(group: "lock:USER"), mdm = Self.report.rows(group: "lock:MDM")
        #expect(user.map(\.device.serialNumber) == ["U1"])
        #expect(mdm.map(\.device.serialNumber) == ["M1"])
        #expect(user.allSatisfy { $0.blocksRelease })
        #expect(mdm.allSatisfy { !$0.blocksRelease })
        #expect(Self.report.blockingRelease == 1)
        #expect(ActivationLockReport.title("lock:USER").contains("blocks redeploy and release"))
        #expect(!ActivationLockReport.title("lock:MDM").contains("blocks"))
    }

    /// An unknown lock type, NONE while locked and a locked device with no type each stay visible, raw (invariant 10); the
    /// catalog's `lock:other` is every type this version doesn't know.
    @Test func unknownLockTypesAreShownRaw() {
        #expect(Self.report.rows(group: "lock:FUTURE_TYPE").map(\.device.serialNumber) == ["F1"])
        #expect(Self.report.rows(group: "lock:NONE").map(\.device.serialNumber) == ["N1"])
        #expect(Self.report.rows(group: "lock:not sent").map(\.device.serialNumber) == ["T1"])
        #expect(Self.report.rows(group: "lock:other").map(\.device.serialNumber) == ["F1", "T1"])
        #expect(Self.report.words.contains { $0.contains("lock type FUTURE_TYPE") && $0.hasSuffix(": 1") })
    }

    /// A value Apple sent in another shape is shown as it came, never "not sent".
    @Test func aNonTextLockTypeIsShownAsSent() {
        let status = ActivationLockStatus(resource: Resource(type: "activationLockStatus", id: "x", attributes: ["isLocked": .bool(true), "lockType": .number("7")]))
        let report = Self.make([("A", .read(status))])
        #expect(report.rows[0].kind == .otherLock("7"))
        let odd = ActivationLockStatus(resource: Resource(type: "activationLockStatus", id: "x", attributes: ["isLocked": .string("yes")]))
        #expect(Self.make([("B", .read(odd))]).rows[0].kind == .unclear("yes"))
    }

    /// A device whose status wasn't read is counted apart and never as unlocked (invariant 8).
    @Test func notReadIsNotUnlocked() {
        #expect(Self.report.rows(group: "not-read").map(\.device.serialNumber) == ["R1", "R2"])
        #expect(Self.report.rows(group: "unlocked").map(\.device.serialNumber) == ["L1"])
        #expect(Self.report.rows(group: "unclear").map(\.device.serialNumber) == ["C1"])
        #expect(Self.report.notRead == 2)
        #expect(Self.report.words.contains("2 devices' Activation Lock status wasn't read; they are not counted as unlocked."))
        #expect(Self.report.groups.map(\.count).reduce(0, +) == 9)
    }

    /// A cut sweep: 2 of 5 devices read; the other three have no entry and are said, never unlocked.
    @Test func aDeviceTheSweepNeverReachedIsNotRead() {
        let report = Self.make([("A", Self.read(true, "USER")), ("B", Self.read(false, nil)), ("C", nil), ("D", nil), ("E", nil)],
                               list: .partly("2 of 5 read"))
        #expect(report.rows.count == 5)
        #expect(report.rows(group: "not-read").map(\.device.serialNumber) == ["C", "D", "E"])
        #expect(report.rows(group: "unlocked").map(\.device.serialNumber) == ["B"])
        #expect(report.words.contains("3 devices' Activation Lock status wasn't read; they are not counted as unlocked."))
        #expect(report.rows(group: "not-read").allSatisfy { $0.blocksReleaseWords == "not read" })
    }

    @Test func groupsComeInOrder() {
        #expect(Self.report.groups.map(\.key) == ["lock:USER", "lock:MDM", "lock:FUTURE_TYPE", "lock:NONE", "lock:not sent", "unlocked", "unclear", "not-read"])
    }

    @Test func theListsReadIsSaid() {
        #expect(Self.report.words.first == "Read in full.")
        let partial = Self.make([("U1", Self.read(true, "USER"))], list: .partly("showing 500 of at least 800"))
        #expect(partial.words.first?.contains("showing 500 of at least 800") == true)
        #expect(partial.words.first?.contains("only what was read") == true)
        // A list not read says that and prints no counts, even with devices handed in.
        let none = Self.make([("U1", Self.read(true, "USER"))], list: .notRead("your role can't read this"))
        #expect(none.words == ["Not read: your role can't read this. Nothing below can be judged."])
    }

    @Test func aUserLockThatIsNotLockedDoesNotBlock() {
        let report = Self.make([("X", Self.read(false, "USER"))])
        #expect(report.rows.first?.group == "unlocked")
        #expect(report.blockingRelease == 0)
    }

    /// The blocksRelease cell is yes or no only where the lock was read and Apple's answer can be judged.
    @Test func theBlocksReleaseCellIsNeverNoForWhatWasNotRead() throws {
        let text = CSV.text(Self.report.csvItems, columns: ExportPolicy.activationLockReport)
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[0] == "id,serialNumber,deviceModel,productFamily,state,lockType,blocksRelease,note")
        func cells(_ id: String) throws -> [String] { Fleet.fields(try #require(lines.first { $0.hasPrefix("\(id),") })) }
        #expect(try cells("U1")[6] == "yes")
        #expect(try cells("M1")[6] == "no")
        #expect(try cells("L1")[6] == "no")
        #expect(try cells("R1")[6] == "not read")
        #expect(try cells("C1")[6] == "unknown")
        #expect(try cells("F1")[6] == "unknown")
        #expect(try cells("T1")[6] == "unknown")
        let unread = try #require(lines.first { $0.hasPrefix("R1,") })
        #expect(unread.contains("Not read: not counted as unlocked"))
        #expect(unread.contains("your role can't read this"))
        #expect(!unread.contains("Not locked"))
    }

    /// A bypass code, a token and a key Apple adds never leave, nested or not (invariant 11).
    @Test func noSecretLeavesTheCSV() {
        let device: JSONObject = ["activationLockBypassCode": .string("canary-bypass"), "nested": .object(["accessToken": .string("canary-token")]),
                                  "futureKey": .string("canary-future")]
        let status = ActivationLockStatus(resource: Resource(type: "activationLockStatus", id: "S1", attributes: [
            "isLocked": .bool(true), "lockType": .string("MDM"), "activation_bypass": .string("canary-bypass2"),
        ]))
        let text = CSV.text(Self.make([("S1", .read(status))], extra: ["S1": device]).csvItems, columns: ExportPolicy.activationLockReport)
        for canary in ["canary-bypass", "canary-token", "canary-future", "canary-bypass2"] { #expect(!text.contains(canary)) }
    }
}
