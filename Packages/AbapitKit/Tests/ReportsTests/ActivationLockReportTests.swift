import AppleModels
import JSONAPI
import Testing
@testable import Reports

@Suite("Activation Lock report")
struct ActivationLockReportTests {
    static func entry(_ serial: String, _ isLocked: Bool?, _ type: String?) -> ActivationLockReport.Entry {
        .init(device: Fleet.device(serial), lock: .read(Fleet.lock(isLocked, type)))
    }

    static let report = ActivationLockReport([
        entry("U1", true, "USER"), entry("M1", true, "MDM"), entry("F1", true, "FUTURE_TYPE"), entry("N1", true, "NONE"), entry("T1", true, nil),
        entry("L1", false, "NONE"), entry("C1", nil, nil),
        .init(device: Fleet.device("R1"), lock: .notRead("your role can't read this")),
        .init(device: Fleet.device("R2"), lock: .notRead("the sweep was cut")),
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

    /// An unknown lock type, NONE while locked and a locked device with no type each stay visible, raw (invariant 10).
    @Test func unknownLockTypesAreShownRaw() {
        #expect(Self.report.rows(group: "lock:FUTURE_TYPE").map(\.device.serialNumber) == ["F1"])
        #expect(Self.report.rows(group: "lock:NONE").map(\.device.serialNumber) == ["N1"])
        #expect(Self.report.rows(group: "lock:not sent").map(\.device.serialNumber) == ["T1"])
        #expect(Self.report.words.contains { $0.contains("lock type FUTURE_TYPE") && $0.hasSuffix(": 1") })
        #expect(Self.report.rows.allSatisfy { !$0.blocksRelease || $0.device.serialNumber == "U1" })
    }

    /// A device whose status wasn't read is counted apart and never as unlocked (invariant 8).
    @Test func notReadIsNotUnlocked() {
        #expect(Self.report.rows(group: "not-read").map(\.device.serialNumber) == ["R1", "R2"])
        #expect(Self.report.rows(group: "unlocked").map(\.device.serialNumber) == ["L1"])
        #expect(Self.report.rows(group: "unclear").map(\.device.serialNumber) == ["C1"])
        #expect(Self.report.notRead == 2)
        #expect(Self.report.words.contains("2 devices' Activation Lock status wasn't read; they are not counted as unlocked."))
        // Every device is in exactly one group.
        #expect(Self.report.groups.map(\.count).reduce(0, +) == 9)
    }

    @Test func groupsComeInOrder() {
        #expect(Self.report.groups.map(\.key) == ["lock:USER", "lock:MDM", "lock:FUTURE_TYPE", "lock:NONE", "lock:not sent", "unlocked", "unclear", "not-read"])
    }

    @Test func theListsReadIsSaid() {
        #expect(Self.report.words.first == "Read in full.")
        let partial = ActivationLockReport([Self.entry("U1", true, "USER")], list: .partly("showing 500 of at least 800"))
        #expect(partial.words.first?.contains("showing 500 of at least 800") == true)
        #expect(partial.words.first?.contains("only what was read") == true)
        let none = ActivationLockReport([], list: .notRead("your role can't read this"))
        #expect(none.words.first == "Not read: your role can't read this. Nothing below can be judged.")
        #expect(none.rows.isEmpty)
    }

    @Test func aUserLockThatIsNotLockedDoesNotBlock() {
        let report = ActivationLockReport([Self.entry("X", false, "USER")])
        #expect(report.rows.first?.group == "unlocked")
        #expect(report.blockingRelease == 0)
    }

    @Test func theCSVSaysWhatWasRead() throws {
        let items = Self.report.csvItems
        let text = CSV.text(items, columns: ExportPolicy.activationLockReport)
        let lines = text.components(separatedBy: "\r\n")
        #expect(lines[0] == "id,serialNumber,deviceModel,productFamily,state,lockType,blocksRelease,notRead")
        let user = try #require(lines.first { $0.hasPrefix("U1,") })
        #expect(user.contains(",USER,yes,"))
        let unread = try #require(lines.first { $0.hasPrefix("R1,") })
        #expect(unread.contains("Not read: not counted as unlocked"))
        #expect(unread.hasSuffix("your role can't read this") || unread.contains("\"your role can't read this\"") || unread.contains("your role can't read this"))
        #expect(!unread.contains("Not locked"))
    }

    /// A bypass code, a token and a key Apple adds never leave, nested or not (invariant 11).
    @Test func noSecretLeavesTheCSV() {
        let device = Fleet.device("S1", ["activationLockBypassCode": .string("canary-bypass"), "nested": .object(["accessToken": .string("canary-token")]),
                                         "futureKey": .string("canary-future")])
        let status = ActivationLockStatus(resource: Resource(type: "activationLockStatus", id: "S1", attributes: [
            "isLocked": .bool(true), "lockType": .string("MDM"), "activation_bypass": .string("canary-bypass2"),
        ]))
        let text = CSV.text(ActivationLockReport([.init(device: device, lock: .read(status))]).csvItems, columns: ExportPolicy.activationLockReport)
        for canary in ["canary-bypass", "canary-token", "canary-future", "canary-bypass2"] { #expect(!text.contains(canary)) }
    }
}
