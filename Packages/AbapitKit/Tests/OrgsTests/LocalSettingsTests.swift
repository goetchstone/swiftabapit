import Foundation
import JSONAPI
import Testing
@testable import Orgs

@Suite("Local settings")
struct LocalSettingsTests {
    static func folder() throws -> URL {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path(percentEncoded: false), nil) else { throw CocoaError(.fileNoSuchFile) }
        defer { free(resolved) }
        let url = URL(filePath: String(cString: resolved), directoryHint: .isDirectory).appending(path: "swiftabapit-settings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return url
    }

    static func write(_ text: String, in folder: URL) throws {
        try Data(text.utf8).write(to: folder.appending(path: LocalSettings.fileName))
    }

    static func read(_ folder: URL) throws -> Data { try Data(contentsOf: folder.appending(path: LocalSettings.fileName)) }

    @Test func noFileGivesTheProposedDefaultsAndCanBeSaved() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let settings = LocalSettings.load(from: dir)
        #expect(settings.blocked == nil)
        #expect(settings.thresholds.checkInDays == 30 && settings.thresholds.appleCareExpiringDays == 90)
        #expect(settings.thresholds.migrationDeadlineDays == 14 && settings.thresholds.quietServiceDays == 30)
        try settings.save(to: dir)
        #expect(LocalSettings.load(from: dir) == settings)
    }

    @Test func settingsRoundTripAndKeepUnknownKeys() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.write(#"{"version": 1, "future": {"a": [1, 2]}, "attention": {"check_in_days": 45, "later": true}}"#, in: dir)
        var settings = LocalSettings.load(from: dir)
        #expect(settings.blocked == nil && settings.thresholds.checkInDays == 45 && settings.thresholds.quietServiceDays == 30)
        settings.thresholds.appleCareExpiringDays = 120
        try settings.save(to: dir)
        let root = try #require(JSONValue.parse(String(decoding: try Self.read(dir), as: UTF8.self))?.object)
        #expect(root["future"] == .object(["a": .array([.number("1"), .number("2")])]))
        #expect(root["attention"]?["later"] == .bool(true))
        #expect(root["attention"]?["check_in_days"]?.int == 45 && root["attention"]?["applecare_expiring_days"]?.int == 120)
        #expect(root["version"]?.int == 1)
        let again = LocalSettings.load(from: dir)
        #expect(again.thresholds.appleCareExpiringDays == 120 && again.thresholds.checkInDays == 45)
    }

    @Test(arguments: ["0", "-5", "3651", "\"30\"", "2.5", "null"])
    func aThresholdOutOfRangeReadsAsTheDefault(value: String) throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.write(#"{"version": 1, "attention": {"check_in_days": \#(value)}}"#, in: dir)
        let settings = LocalSettings.load(from: dir)
        #expect(settings.blocked == nil && settings.thresholds.checkInDays == 30)
    }

    @Test func theFileIsPrivateAndWrittenAtomically() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        var settings = LocalSettings()
        try settings.save(to: dir)
        let path = dir.appending(path: LocalSettings.fileName).path
        var info = stat()
        #expect(stat(path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        let before = try Self.read(dir)
        // A crash after the temporary file is written and before the rename: the old file is whole and unchanged.
        settings.thresholds.checkInDays = 99
        #expect(throws: LocalSettings.Failure.unwritable(errno: EIO)) {
            try settings.save(to: dir) { () throws(LocalSettings.Failure) in
                let left = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(".settings.json.") }
                #expect(left.count == 1)
                #expect((try? Self.read(dir)) == before)
                throw .unwritable(errno: EIO)
            }
        }
        #expect(try Self.read(dir) == before)
        #expect(LocalSettings.load(from: dir).thresholds.checkInDays == 30)
        try settings.save(to: dir)
        #expect(stat(path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        // The temporary file the simulated crash left is the only other thing there; the finished save leaves none.
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { !$0.hasPrefix(".settings.json.") }
        #expect(names == [LocalSettings.fileName])
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2)
    }

    @Test func aSymlinkIsRefusedToReadAndToWrite() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appending(path: "elsewhere.json")
        try Data(#"{"version": 1, "attention": {"check_in_days": 7}}"#.utf8).write(to: target)
        let link = dir.appending(path: LocalSettings.fileName).path
        #expect(symlink(target.path, link) == 0)
        let settings = LocalSettings.load(from: dir)
        #expect(settings.blocked == .link)
        #expect(settings.thresholds.checkInDays == 30, "the link's target was not read")
        #expect(throws: LocalSettings.Failure.link) { try settings.save(to: dir) }
        // Even a settings value that isn't blocked (made before the link appeared) doesn't replace the link.
        #expect(throws: LocalSettings.Failure.link) { try LocalSettings().save(to: dir) }
        var info = stat()
        #expect(lstat(link, &info) == 0 && info.st_mode & S_IFMT == S_IFLNK)
        #expect(try String(contentsOf: target, encoding: .utf8).contains("7"))
    }

    @Test(arguments: ["not json", "[1, 2]", "{\"attention\": {}}", "", "{\"version\": \"1\"}"])
    func anUnreadableFileIsNeverOverwritten(text: String) throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.write(text, in: dir)
        var settings = LocalSettings.load(from: dir)
        #expect(settings.blocked == .notASettingsFile)
        settings.thresholds.checkInDays = 5
        #expect(throws: LocalSettings.Failure.notASettingsFile) { try settings.save(to: dir) }
        #expect(try Self.read(dir) == Data(text.utf8))
    }

    @Test func aFileThatIsNotAFileIsLeftAlone() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appending(path: LocalSettings.fileName), withIntermediateDirectories: false)
        let settings = LocalSettings.load(from: dir)
        #expect(settings.blocked != nil)
        #expect(throws: (any Error).self) { try settings.save(to: dir) }
        var isDirectory: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: LocalSettings.fileName).path, isDirectory: &isDirectory) && isDirectory.boolValue)
    }

    @Test func aNewerFileIsReadAndNeverWrittenOver() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = #"{"version": 2, "attention": {"check_in_days": 12}, "extra": 1}"#
        try Self.write(text, in: dir)
        var settings = LocalSettings.load(from: dir)
        #expect(settings.blocked == .newerVersion(2) && settings.thresholds.checkInDays == 12)
        settings.thresholds.checkInDays = 3
        #expect(throws: LocalSettings.Failure.newerVersion(2)) { try settings.save(to: dir) }
        #expect(try Self.read(dir) == Data(text.utf8))
        #expect(LocalSettings.Failure.newerVersion(2).message.contains("newer"))
    }

    /// `load` reads a bad stored value as its default; `save` never writes one.
    @Test(arguments: [0, -1, 3651, Int.max])
    func saveRefusesAThresholdOutOfRange(days: Int) throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try LocalSettings().save(to: dir)
        let before = try Self.read(dir)
        var settings = LocalSettings()
        settings.thresholds.quietServiceDays = days
        #expect(throws: LocalSettings.Failure.thresholdOutOfRange("quiet_service_days")) { try settings.save(to: dir) }
        #expect(try Self.read(dir) == before)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [LocalSettings.fileName])
        settings.thresholds.quietServiceDays = days == 0 ? 1 : 3650
        try settings.save(to: dir)
    }

    /// `save` reads the file again: a "reset to defaults", or a value loaded before the file changed, can't overwrite one
    /// that isn't this version's to change.
    @Test func saveRefusesAFileThatIsUnreadableOrNewerNow() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fresh = LocalSettings.load(from: dir)  // no file: not blocked
        #expect(fresh.blocked == nil)
        for (text, failure) in [("not json", LocalSettings.Failure.notASettingsFile),
                                (#"{"version": 9, "attention": {"check_in_days": 3}}"#, .newerVersion(9))] {
            try Self.write(text, in: dir)
            #expect(throws: failure) { try fresh.save(to: dir) }
            #expect(try Self.read(dir) == Data(text.utf8))
        }
        // A file written after load by a newer version.
        try FileManager.default.removeItem(at: dir.appending(path: LocalSettings.fileName))
        let loaded = LocalSettings.load(from: dir)
        try loaded.save(to: dir)
        let newer = #"{"version": 2, "attention": {}}"#
        try Self.write(newer, in: dir)
        #expect(throws: LocalSettings.Failure.newerVersion(2)) { try loaded.save(to: dir) }
        #expect(try Self.read(dir) == Data(newer.utf8))
        // A directory where the file should be.
        try FileManager.default.removeItem(at: dir.appending(path: LocalSettings.fileName))
        try FileManager.default.createDirectory(at: dir.appending(path: LocalSettings.fileName), withIntermediateDirectories: false)
        #expect(throws: LocalSettings.Failure.notASettingsFile) { try fresh.save(to: dir) }
    }

    @Test(arguments: ["1", "null", "[1]", "\"x\""])
    func anAttentionValueThatIsNotAnObjectBlocksTheFile(value: String) throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = #"{"version": 1, "attention": \#(value)}"#
        try Self.write(text, in: dir)
        var settings = LocalSettings.load(from: dir)
        #expect(settings.blocked == .notASettingsFile)
        settings.thresholds.checkInDays = 7
        #expect(throws: LocalSettings.Failure.notASettingsFile) { try settings.save(to: dir) }
        #expect(try Self.read(dir) == Data(text.utf8))
    }

    // MARK: which service is each client's Mosyle org (the operator's Q7)

    /// None by default; set per client, the service's id with the Mosyle org it was set for; kept beside the thresholds and the keys
    /// this version doesn't know; cleared, the key goes with its last entry.
    @Test func theMosyleServiceIsPerClientAndNoneByDefault() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.write(#"{"version": 1, "future": true, "attention": {"check_in_days": 45}}"#, in: dir)
        var settings = LocalSettings.load(from: dir)
        #expect(settings.mosyleService(for: "acme") == .none)
        try settings.setMosyleService("1F97349736CF4614A94F624E705841AD", mosyleOrg: "acme-mosyle", for: "acme")
        try settings.save(to: dir)
        let root = try #require(JSONValue.parse(String(decoding: try Self.read(dir), as: UTF8.self))?.object)
        #expect(root["mosyle_services"] == .object(["acme": .object(["service": .string("1F97349736CF4614A94F624E705841AD"), "mosyle_org": .string("acme-mosyle")])]))
        #expect(root["future"] == .bool(true) && root["attention"]?["check_in_days"]?.int == 45)
        var again = LocalSettings.load(from: dir)
        #expect(again.mosyleService(for: "acme") == .set(service: "1F97349736CF4614A94F624E705841AD", mosyleOrg: "acme-mosyle"))
        #expect(again.mosyleService(for: "other") == .none)
        try again.setMosyleService(nil, mosyleOrg: "acme-mosyle", for: "acme")
        try again.save(to: dir)
        let cleared = try #require(JSONValue.parse(String(decoding: try Self.read(dir), as: UTF8.self))?.object)
        #expect(cleared["mosyle_services"] == nil && LocalSettings.load(from: dir).mosyleService(for: "acme") == .none)
    }

    /// An entry in the earlier shape (the service's id alone) is read as that, never as set; one of another shape couldn't be read,
    /// and is never written over: setting that client is refused, dropping leaves it, and every entry is written back as it was.
    @Test func anEntryOfAnotherShapeIsUnreadableAndNeverWrittenOver() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.write(#"{"version": 1, "mosyle_services": {"acme": {"id": "S1"}, "beta": "", "gamma": "two words", "delta": "S4", "eps": {"service": "S5", "mosyle_org": "M5"}, "zeta": {"service": "S6", "mosyle_org": "M6", "extra": 1}}}"#, in: dir)
        var settings = LocalSettings.load(from: dir)
        #expect(settings.blocked == nil)
        #expect(["acme", "beta", "gamma", "zeta"].allSatisfy { settings.mosyleService(for: $0) == .unreadable })
        #expect(settings.mosyleService(for: "delta") == .earlierShape(service: "S4") && settings.mosyleService(for: "eps") == .set(service: "S5", mosyleOrg: "M5"))
        #expect(throws: LocalSettings.Failure.serviceUnreadable) { try settings.setMosyleService("S1", mosyleOrg: "M1", for: "acme") }
        #expect(throws: LocalSettings.Failure.serviceUnreadable) { try settings.setMosyleService(nil, mosyleOrg: "M1", for: "gamma") }
        #expect(!settings.dropMosyleService(for: "acme") && settings.dropMosyleService(for: "delta"))
        try settings.setMosyleService("S7", mosyleOrg: "M7", for: "eta")
        try settings.save(to: dir)
        let services = try #require(JSONValue.parse(String(decoding: try Self.read(dir), as: UTF8.self))?["mosyle_services"]?.object)
        #expect(services["acme"] == .object(["id": .string("S1")]) && services["beta"] == .string("") && services["gamma"] == .string("two words"))
        #expect(services["delta"] == nil && services["eps"] == .object(["service": .string("S5"), "mosyle_org": .string("M5")]))
        #expect(services["zeta"]?["extra"]?.int == 1 && services["eta"] == .object(["service": .string("S7"), "mosyle_org": .string("M7")]))
    }

    /// A name or words are never set as an id, for the service or the Mosyle org, nor an entry with no client.
    @Test(arguments: ["", "two words", "tab\tid", "rlo\u{202E}id", String(repeating: "x", count: 257)])
    func aServiceThatIsNotAnIDIsRefused(id: String) throws {
        var settings = LocalSettings()
        #expect(throws: LocalSettings.Failure.notAServiceID) { try settings.setMosyleService(id.isEmpty ? " " : id, mosyleOrg: "M1", for: "acme") }
        #expect(throws: LocalSettings.Failure.notAServiceID) { try settings.setMosyleService("S1", mosyleOrg: id.isEmpty ? " " : id, for: "acme") }
        #expect(throws: LocalSettings.Failure.notAServiceID) { try settings.setMosyleService("S1", mosyleOrg: "M1", for: "") }
        #expect(settings.mosyleService(for: "acme") == .none)
    }

    /// `mosyle_services` that isn't an object: no entry is read, the file is never written over, and the thresholds are still read.
    @Test(arguments: ["1", "null", "[1]", "\"x\""])
    func aServicesValueThatIsNotAnObjectBlocksTheFileButNotTheThresholds(value: String) throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        let text = #"{"version": 1, "attention": {"check_in_days": 45}, "mosyle_services": \#(value)}"#
        try Self.write(text, in: dir)
        var settings = LocalSettings.load(from: dir)
        #expect(settings.blocked == .notASettingsFile && settings.mosyleServicesUnreadable)
        #expect(settings.thresholds.checkInDays == 45, "one bad value never costs the thresholds")
        #expect(settings.mosyleService(for: "acme") == .unreadable)
        #expect(throws: LocalSettings.Failure.serviceUnreadable) { try settings.setMosyleService("S1", mosyleOrg: "M1", for: "acme") }
        settings.thresholds.checkInDays = 7
        #expect(throws: LocalSettings.Failure.notASettingsFile) { try settings.save(to: dir) }
        #expect(try Self.read(dir) == Data(text.utf8))
    }

    /// A file that couldn't be read at all holds no setting this version can use: every client's reads as unreadable, never none.
    @Test func aFileThatCouldntBeReadHasNoSettingToUse() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.write("not json", in: dir)
        #expect(LocalSettings.load(from: dir).mosyleService(for: "acme") == .unreadable)
        try Self.write(#"{"version": 9, "mosyle_services": {"acme": {"service": "S1", "mosyle_org": "M1"}}}"#, in: dir)
        #expect(LocalSettings.load(from: dir).mosyleService(for: "acme") == .set(service: "S1", mosyleOrg: "M1"), "a newer file's values are read")
    }
}
