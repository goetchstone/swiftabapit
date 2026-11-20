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
}
