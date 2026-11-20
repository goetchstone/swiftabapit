import Foundation
import JSONAPI
import Orgs
import SQLite3
import Synchronization
@testable import History

/// What the history tests share: a scratch folder by its real path, synthetic orgs and items, file modes, and a second
/// connection that looks at the file from outside the store. No tenant data: serials, names and IDs are made up.
enum Scratch {
    /// A new folder for one test under the real temporary folder: `/var` is a link on macOS, and the store refuses a
    /// path through one.
    static func folder() throws -> URL {
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path(percentEncoded: false), nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        defer { free(resolved) }
        let url = URL(filePath: String(cString: resolved), directoryHint: .isDirectory)
            .appending(path: "swiftabapit-history-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    static func path(_ url: URL) -> String { url.path(percentEncoded: false) }

    /// The permission bits of `path` itself (a link's own, not its target's); nil when nothing is there.
    static func mode(_ path: String) -> mode_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode & 0o777 : nil
    }

    static func exists(_ path: String) -> Bool { mode(path) != nil }

    static func apple(_ id: String, clientID: String = "BUSINESSAPI.00000000-0000-0000-0000-000000000000") -> OrgProfile {
        var org = OrgProfile(id: id, name: "Example \(id)", provider: .apple)
        org.scope = .known(.business)
        org.clientID = clientID
        org.keyID = "00000000-0000-0000-0000-000000000001"
        return org
    }

    static func device(_ serial: String, model: String = "MacBook Air", status: String = "ASSIGNED") -> Resource {
        Resource(type: "orgDevices", id: serial, attributes: [
            "serialNumber": .string(serial), "deviceModel": .string(model), "productFamily": .string("Mac"),
            "status": .string(status), "addedToOrgDateTime": .string("2025-01-02T03:04:05Z"),
        ])
    }

    static let noon = Date(timeIntervalSince1970: 1_795_000_000)  // 2026-11-18T11:06:40Z

    /// A connection of the test's own to the store's file.
    static func open(_ file: String) throws -> SQLiteDatabase {
        try SQLiteDatabase(path: file, flags: SQLITE_OPEN_READWRITE)
    }

    static func count(_ database: SQLiteDatabase, _ sql: String) throws -> Int64 {
        try database.rows(sql) { $0.integer(0) }.first ?? -1
    }
}

/// A value a `@Sendable` hook can change and the test read after.
final class Shared<Value: Sendable>: Sendable {
    private let mutex: Mutex<Value>

    init(_ value: Value) { mutex = Mutex(value) }

    var value: Value { mutex.withLock { $0 } }

    func set(_ value: Value) { mutex.withLock { $0 = value } }
}

/// A value a hook can set and the test read, for a type that isn't `Sendable` (a second connection). Hooks run on the
/// store's caller, one at a time, so nothing reaches it at once.
final class Unchecked<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) { self.value = value }
}
