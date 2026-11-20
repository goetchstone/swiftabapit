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
        #expect(Self.make([("B", .read(odd))]).rows[0].kind == .unclear("\"yes\""))
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

    /// The blocksRelease cell is yes or no only where the lock was read and Apple's answer can be judged; every value Apple sent
    /// (`isLocked`, `lockType`) is written as sent, whatever the row's state.
    @Test func theBlocksReleaseCellIsNeverNoForWhatWasNotRead() throws {
        let text = CSV.text(Self.report.csvItems, columns: ExportPolicy.activationLockReport)
        #expect(Fleet.header(text) == "id,listRead,serialNumber,deviceModel,productFamily,state,isLocked,lockType,blocksRelease,note")
        let table = Fleet.table(text)
        func cell(_ id: String, _ column: String) throws -> String { try #require(table[id])[column] ?? "<missing>" }
        #expect(try cell("U1", "blocksRelease") == "yes")
        #expect(try cell("M1", "blocksRelease") == "no")
        #expect(try cell("L1", "blocksRelease") == "no")
        #expect(try cell("R1", "blocksRelease") == "not read")
        #expect(try cell("C1", "blocksRelease") == "unknown")
        #expect(try cell("F1", "blocksRelease") == "unknown")
        #expect(try cell("T1", "blocksRelease") == "unknown")
        #expect(try cell("R1", "note") == "your role can't read this")
        #expect(try cell("R1", "state").contains("Not read: not counted as unlocked"))
        #expect(try cell("F1", "lockType") == "FUTURE_TYPE")
        #expect(try cell("L1", "lockType") == "NONE")
        #expect(try cell("L1", "isLocked") == "false")
        #expect(try cell("T1", "lockType") == "")
        #expect(try cell("R1", "lockType") == "")
    }

    /// A lock type sent with an unreadable `isLocked`, and one on an unlocked row, still reach the CSV.
    @Test func aLockTypeSentOnAnUnclearOrUnlockedRowIsWritten() throws {
        let unclear = ActivationLockStatus(resource: Resource(type: "activationLockStatus", id: "x", attributes: ["isLocked": .string("maybe"), "lockType": .string("USER")]))
        let future = ActivationLockStatus(resource: Resource(type: "activationLockStatus", id: "x", attributes: ["isLocked": .bool(false), "lockType": .string("FUTURE_TYPE")]))
        let report = Self.make([("A", .read(unclear)), ("B", .read(future))])
        let table = Fleet.table(CSV.text(report.csvItems, columns: ExportPolicy.activationLockReport))
        #expect(table["A"]?["lockType"] == "USER" && table["A"]?["isLocked"] == "\"maybe\"" && table["A"]?["blocksRelease"] == "unknown")
        #expect(table["B"]?["lockType"] == "FUTURE_TYPE" && table["B"]?["blocksRelease"] == "no")
    }

    /// A list that wasn't read exports no judgment cells and says so in the first column; a partial one says that.
    @Test func theCSVCarriesTheListsReadState() throws {
        let read = Self.make([("U1", Self.read(true, "USER"))], list: .notRead("your role can't read this"))
        let table = Fleet.table(CSV.text(read.csvItems, columns: ExportPolicy.activationLockReport))
        let row = try #require(table["U1"])
        #expect(row["listRead"] == "not read: your role can't read this")
        #expect(row["blocksRelease"] == "not read" && row["state"] == "not read")
        #expect(row["lockType"] == "" && row["isLocked"] == "")
        let part = Self.make([("U1", Self.read(true, "USER"))], list: .partly("showing 1 of at least 5"))
        #expect(Fleet.table(CSV.text(part.csvItems, columns: ExportPolicy.activationLockReport))["U1"]?["listRead"] == "read in part: showing 1 of at least 5")
        #expect(Fleet.table(CSV.text(Self.report.csvItems, columns: ExportPolicy.activationLockReport))["U1"]?["listRead"] == "read in full")
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
