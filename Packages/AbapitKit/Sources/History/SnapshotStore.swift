import Darwin
import Foundation
import JSONAPI
import Orgs
import SQLite3

/// Snapshot history: point-in-time copies of what an org's reads returned, in one SQLite file on abapit's schema (plan
/// L7, §3.7, Phase 3). A `snapshots` row per run and an `items` row per resource item, its attributes as JSON; every row
/// carries the org's id, and every query asks for one org's rows only.
///
/// The file is an inventory of the org (serials, people, services), so it is the owner's alone: the folder `0700`, the
/// database `0600` from the moment it exists (never made and then narrowed), and its journal takes the database's mode
/// (SQLite gives a journal or WAL file the mode of its database). Neither the folder, the file nor any folder above them
/// may be a symbolic link: the store refuses one it can see, and SQLite (`SQLITE_OPEN_NOFOLLOW`) refuses one put there
/// after the store looked.
///
/// What it never holds: a secret, and a custom setting's profile (operator, 2026-10-31: what can be read again from Apple
/// isn't kept; a collector stores `Configuration.resource`, the profile withheld). It stores what it is given; the
/// collectors decide what that is.
public actor SnapshotStore {
    public enum Storage: Sendable {
        /// `history.sqlite` in this folder (the app's: `Application Support/abapit`, inside the sandbox container).
        case folder(URL)
        /// A database in memory, gone with the store: the demo and the tests.
        case memory
    }

    public enum Access: Sendable, Equatable {
        case readWrite
        /// The file was written by a newer version of the app (its schema `version`): read, never written.
        case readOnly(version: Int32)
    }

    public enum Failure: Error, Equatable, Sendable {
        /// A symbolic link where the store's folder or file, or a folder above them, should be.
        case link(path: String)
        case notAFolder(path: String)
        case notAFile(path: String)
        case unopenable(path: String, errno: Int32)
        /// SQLite's extended result code and message.
        case database(code: Int32, message: String)
        /// Written by a newer version: this one doesn't change it.
        case readOnly(version: Int32)
        /// The org has no id, so its rows couldn't be told from another's.
        case noOrg
        /// No snapshot with that id for that org (there may be one for another org: it isn't said).
        case noSnapshot(Int64)
        /// A row whose JSON doesn't read: the file was changed outside this app.
        case corrupt(String)

        public var message: String {
            switch self {
            case .link(let path): "The snapshot history wasn't opened: \(path) is or passes through a symbolic link."
            case .notAFolder(let path): "The snapshot history wasn't opened: \(path) isn't a folder."
            case .notAFile(let path): "The snapshot history wasn't opened: \(path) isn't a file."
            case .unopenable(let path, let code): "The snapshot history at \(path) couldn't be opened (\(String(cString: strerror(code))))."
            case .database(_, let message): "The snapshot history couldn't be read or written (\(message))."
            case .readOnly(let version):
                "The snapshot history was written by a newer abapit (schema version \(version)); this one reads it and won't change it."
            case .noOrg: "The organization has no id, so its snapshots can't be kept apart from another's."
            case .noSnapshot(let id): "There's no snapshot \(id) for this organization."
            case .corrupt(let what): "The snapshot history holds a row this app can't read (\(what)); it was changed outside abapit."
            }
        }
    }

    /// One snapshot's row.
    public struct Summary: Sendable, Equatable, Identifiable {
        public let id: Int64
        /// As abapit writes it: UTC, to the second (`2026-11-20T08:00:00Z`).
        public let takenAt: String
        public let orgID: String
        public let orgName: String
        /// `business` or `school` for an Apple org; the provider's name (`mosyle`) for another.
        public let orgScope: String
        /// The Apple API account's client ID; empty for a Mosyle org.
        public let clientID: String
        /// What wrote the row: `swiftabapit <version>`, or abapit's version for a row abapit wrote.
        public let writtenBy: String
        /// Per resource, why it wasn't read (abapit's `errors`).
        public let errors: [String: String]
        /// Per resource, what was read only in part (`Schema.additions`).
        public let notes: [String: String]
        /// Items recorded as `devices`, as abapit's list counts them.
        public let deviceCount: Int

        public var date: Date? { ISODate.parse(takenAt)?.date }
    }

    public struct Snapshot: Sendable, Equatable {
        public let summary: Summary
        /// Each resource's items, ordered by id (by bytes, as SQLite and Python compare them); an item's attributes in
        /// abapit's stored order (keys sorted). A resource recorded with no items isn't here, as in abapit.
        public let resources: [String: [Resource]]
    }

    public static let fileName = "history.sqlite"
    /// The resource name `activation_lock_view` reads: one item per device, keyed by serial number, attributes as Apple's
    /// `ActivationLockStatus` has them.
    public static let activationLockResource = "activation_lock"

    public nonisolated let access: Access
    private let database: SQLiteDatabase
    private let writer: String
    private let hook: Hook?

    /// Where a test can stop the store, as a crash or a failing disk would (`hook`). Never set outside the tests.
    enum Step: Sendable, Equatable {
        /// The database file has just been made: nothing written to it yet.
        case created(path: String)
        /// The folder and file are checked; SQLite opens the path next.
        case opening(path: String)
        /// Inside `record`'s transaction: the snapshot row and `items` items are written.
        case recording(items: Int)
    }

    typealias Hook = @Sendable (Step) throws(Failure) -> Void

    /// Opens (and makes, the first time) the store. `appVersion` is this app's version, written on each snapshot as
    /// `swiftabapit <appVersion>` where abapit wrote its own.
    public init(storage: Storage, appVersion: String) throws(Failure) {
        try self.init(storage: storage, appVersion: appVersion, hook: nil)
    }

    init(storage: Storage, appVersion: String, hook: Hook?) throws(Failure) {
        let database: SQLiteDatabase
        switch storage {
        case .memory:
            database = try Self.guarded { try SQLiteDatabase(path: ":memory:", flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) }
        case .folder(let folder):
            database = try Self.openFile(in: folder, hook: hook)
        }
        access = try Self.prepare(database)
        self.database = database
        writer = "swiftabapit \(appVersion)"
        self.hook = hook
    }

    // MARK: writing

    /// Records one snapshot of `org`: a row taken at `takenAt` (an import passes the original time), and an item per
    /// resource item, its attributes as abapit stores them (`StoredJSON`; its relationships aren't kept, as abapit kept
    /// none). Whole or not at all: a failure part way leaves no row. Two items of a resource with one id keep the last
    /// (abapit's `INSERT OR REPLACE`). Returns the snapshot's id.
    @discardableResult
    public func record(org: OrgProfile, takenAt: Date, resources: [String: [Resource]], errors: [String: String] = [:],
                       notes: [String: String] = [:]) throws(Failure) -> Int64 {
        try writable()
        let orgID = try Self.id(of: org)
        let scope = org.provider == .known(.apple) ? org.scope.rawValue : org.provider.rawValue
        return try Self.guarded {
            try database.transaction {
                try database.run("""
                    INSERT INTO snapshots (taken_at, org_client_id, org_name, org_scope, abapit_version, errors, org_id, notes) \
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.text(Schema.takenAt(takenAt)), .text(org.clientID), .text(org.name), .text(scope), .text(writer),
                          .text(Self.words(errors)), .text(orgID), .text(Self.words(notes))])
                let snapshot = database.lastInsertRowID
                var written = 0
                try hook?(.recording(items: written))
                let insert = try database.prepare("INSERT OR REPLACE INTO items VALUES (?, ?, ?, ?)")
                for name in resources.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
                    for item in resources[name] ?? [] {
                        try insert.run([.integer(snapshot), .text(name), .text(item.id), .text(StoredJSON.text(.object(item.attributes)))])
                        written += 1
                        try hook?(.recording(items: written))
                    }
                }
                return snapshot
            }
        }
    }

    /// Keeps the newest `keep` snapshots of `org`, by id (the order they were recorded, whatever their `takenAt`), and
    /// removes the rest with their items. A negative `keep` removes nothing. Returns the snapshots removed.
    @discardableResult
    public func prune(org: OrgProfile, keep: Int) throws(Failure) -> Int {
        try writable()
        let orgID = try Self.id(of: org)
        guard keep >= 0 else { return 0 }
        return try Self.guarded {
            try database.transaction {
                try database.run("""
                    DELETE FROM snapshots WHERE org_id = ? AND id NOT IN (\
                    SELECT id FROM snapshots WHERE org_id = ? ORDER BY id DESC LIMIT ?)
                    """, [.text(orgID), .text(orgID), .integer(Int64(keep))])
                return database.changes
            }
        }
    }

    /// Removes every snapshot of `org` and their items (the org was removed and the operator chose to delete its
    /// history). Returns the snapshots removed.
    @discardableResult
    public func removeAll(org: OrgProfile) throws(Failure) -> Int {
        try writable()
        let orgID = try Self.id(of: org)
        return try Self.guarded {
            try database.transaction {
                try database.run("DELETE FROM snapshots WHERE org_id = ?", [.text(orgID)])
                return database.changes
            }
        }
    }

    // MARK: reading

    /// `org`'s snapshots, newest first (by id), at most `limit` (abapit's list).
    public func snapshots(org: OrgProfile, limit: Int = 100) throws(Failure) -> [Summary] {
        let orgID = try Self.id(of: org)
        return try Self.guarded {
            try database.rows(Self.summarySQL + "WHERE s.org_id = ? ORDER BY s.id DESC LIMIT ?",
                              [.text(orgID), .integer(Int64(max(limit, 0)))], Self.summary)
        }
    }

    /// One of `org`'s snapshots with every item. Another org's snapshot is refused as one that isn't there.
    public func load(_ id: Int64, org: OrgProfile) throws(Failure) -> Snapshot {
        let orgID = try Self.id(of: org)
        return try Self.guarded {
            try database.reading {
                guard let summary = try database.rows(Self.summarySQL + "WHERE s.id = ? AND s.org_id = ?", [.integer(id), .text(orgID)],
                                                      Self.summary).first else { throw Failure.noSnapshot(id) }
                var resources: [String: [Resource]] = [:]
                let rows = try database.rows("SELECT resource, item_id, attributes FROM items WHERE snapshot_id = ? ORDER BY resource, item_id",
                                             [.integer(id)]) { row in try Self.item(row, resource: row.text(0) ?? "", from: 1) }
                for item in rows { resources[item.type, default: []].append(item) }
                return Snapshot(summary: summary, resources: resources)
            }
        }
    }

    /// The newest of `org`'s snapshots that holds `resource`, with that resource's items ordered by id (abapit's
    /// `latest_resource`: a snapshot that recorded no items of it, or failed to read it, is passed over), or nil.
    public func latest(_ resource: String, org: OrgProfile) throws(Failure) -> (summary: Summary, items: [Resource])? {
        let orgID = try Self.id(of: org)
        return try Self.guarded {
            try database.reading {
                guard let id = try database.rows("""
                    SELECT DISTINCT s.id FROM snapshots s JOIN items i ON i.snapshot_id = s.id AND i.resource = ? \
                    WHERE s.org_id = ? ORDER BY s.id DESC LIMIT 1
                    """, [.text(resource), .text(orgID)], { $0.integer(0) }).first,
                      let summary = try database.rows(Self.summarySQL + "WHERE s.id = ?", [.integer(id)], Self.summary).first
                else { return nil }
                let items = try database.rows("SELECT item_id, attributes FROM items WHERE snapshot_id = ? AND resource = ? ORDER BY item_id",
                                              [.integer(id), .text(resource)]) { row in try Self.item(row, resource: resource, from: 0) }
                return (summary, items)
            }
        }
    }

    // MARK: opening

    /// Checks and makes the folder and the file, then opens the file with SQLite. See the type's comment for the rules.
    private static func openFile(in folder: URL, hook: Hook?) throws(Failure) -> SQLiteDatabase {
        // The path as given, never `standardizedFileURL`: Foundation drops `/private` from `/private/var/…` there, which
        // puts a link (`/var`) back into the path. A `.` or `..` is refused rather than resolved.
        let given = folder.path(percentEncoded: false)
        let components = given.split(separator: "/")
        guard folder.isFileURL, given.hasPrefix("/"), !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw .notAFolder(path: given)
        }
        let path = "/" + components.joined(separator: "/")
        try prepareFolder(path)
        let file = (path == "/" ? "" : path) + "/" + fileName
        try prepareFile(file, hook: hook)
        try hook?(.opening(path: file))
        do throws(SQLiteDatabase.Failure) {
            // No SQLITE_OPEN_CREATE: the file exists, made above with its mode.
            return try SQLiteDatabase(path: file, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW)
        } catch {
            if error.code == SQLiteDatabase.cantOpenSymlink { throw .link(path: file) }
            throw .database(code: error.code, message: error.message)
        }
    }

    /// Every folder from `/` down to `path`: made `0700` where missing, refused where it is a link or not a folder. The
    /// store's own folder is then narrowed to `0700` if it was wider.
    private static func prepareFolder(_ path: String) throws(Failure) {
        var prefix = ""
        for component in path.split(separator: "/") {
            prefix += "/" + component
            var info = stat()
            if lstat(prefix, &info) != 0 {
                guard errno == ENOENT else { throw .unopenable(path: prefix, errno: errno) }
                guard mkdir(prefix, 0o700) == 0 || errno == EEXIST else { throw .unopenable(path: prefix, errno: errno) }
                guard lstat(prefix, &info) == 0 else { throw .unopenable(path: prefix, errno: errno) }
            }
            if info.st_mode & S_IFMT == S_IFLNK { throw .link(path: prefix) }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw .notAFolder(path: prefix) }
        }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ELOOP ? .link(path: path) : .unopenable(path: path, errno: errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .unopenable(path: path, errno: errno) }
        if info.st_mode & 0o077 != 0, fchmod(fd, 0o700) != 0 { throw .unopenable(path: path, errno: errno) }
    }

    /// The database file: made `0600` by `open` itself when it isn't there (`O_EXCL`, so never through a link), else
    /// opened without following a link, held to a regular file, and narrowed to `0600` if it was wider.
    private static func prepareFile(_ path: String, hook: Hook?) throws(Failure) {
        let made = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if made >= 0 {
            defer { close(made) }
            try hook?(.created(path: path))
            return
        }
        guard errno == EEXIST else { throw .unopenable(path: path, errno: errno) }
        // Read-only, so a folder opens too and is refused below as not a file; `fchmod` needs no write access.
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ELOOP ? .link(path: path) : .unopenable(path: path, errno: errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw .unopenable(path: path, errno: errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notAFile(path: path) }
        if info.st_mode & 0o077 != 0, fchmod(fd, 0o600) != 0 { throw .unopenable(path: path, errno: errno) }
    }

    /// Foreign keys on (abapit's `PRAGMA foreign_keys = ON`: a snapshot's items go with it), then the schema: a new or
    /// older file is brought to `Schema.version` in one transaction; a newer one is left as it is and queried only.
    private static func prepare(_ database: SQLiteDatabase) throws(Failure) -> Access {
        try guarded {
            try database.execute("PRAGMA foreign_keys = ON")
            let found = try database.userVersion()
            guard found <= Schema.version else {
                try database.execute("PRAGMA query_only = ON")
                return .readOnly(version: found)
            }
            if found < Schema.version {
                try database.transaction {
                    // Read again under the write lock: another store may have brought it up to date meanwhile.
                    if try database.userVersion() == 0 { try database.execute(Schema.toVersion1) }
                }
            }
            return .readWrite
        }
    }

    // MARK: rows

    /// A snapshot's row and abapit's `device_count`; a `WHERE` follows.
    private static let summarySQL = "SELECT s.id, s.taken_at, s.org_id, s.org_name, s.org_scope, s.org_client_id, s.abapit_version, "
        + "s.errors, s.notes, (SELECT COUNT(*) FROM items i WHERE i.snapshot_id = s.id AND i.resource = 'devices') AS device_count "
        + "FROM snapshots s "

    private static func summary(_ row: SQLiteDatabase.Row) throws -> Summary {
        Summary(id: row.integer(0), takenAt: row.text(1) ?? "", orgID: row.text(2) ?? "", orgName: row.text(3) ?? "",
                orgScope: row.text(4) ?? "", clientID: row.text(5) ?? "", writtenBy: row.text(6) ?? "",
                errors: try words(row.text(7), "a snapshot's errors"), notes: try words(row.text(8), "a snapshot's notes"),
                deviceCount: Int(row.integer(9)))
    }

    /// An item from `item_id` and `attributes` at `column` and the next.
    private static func item(_ row: SQLiteDatabase.Row, resource: String, from column: Int32) throws -> Resource {
        let id = row.text(column) ?? ""
        guard let attributes = JSONValue.parse(row.text(column + 1) ?? "")?.object else {
            throw Failure.corrupt("the attributes of \(resource) \(id)")
        }
        return Resource(type: resource, id: id, attributes: attributes)
    }

    /// `errors` and `notes` as stored: a JSON object of strings.
    private static func words(_ words: [String: String]) -> String {
        var object = JSONObject()
        for (key, value) in words { object[key] = .string(value) }
        return StoredJSON.text(.object(object))
    }

    /// `errors` or `notes` read back. A value that isn't a string (abapit wrote strings) shows as its JSON.
    private static func words(_ text: String?, _ what: String) throws -> [String: String] {
        guard let object = JSONValue.parse(text ?? "")?.object else { throw Failure.corrupt(what) }
        var found: [String: String] = [:]
        for (key, value) in object { found[key] = value.string ?? value.jsonText }
        return found
    }

    // MARK: helpers

    private func writable() throws(Failure) {
        if case .readOnly(let version) = access { throw .readOnly(version: version) }
    }

    private static func id(of org: OrgProfile) throws(Failure) -> String {
        guard !org.id.isEmpty else { throw .noOrg }
        return org.id
    }

    /// `body`'s errors as `Failure`s: SQLite's as `.database`, a hook's as they were thrown.
    private static func guarded<T>(_ body: () throws -> T) throws(Failure) -> T {
        do {
            return try body()
        } catch let failure as Failure {
            throw failure
        } catch let failure as SQLiteDatabase.Failure {
            throw .database(code: failure.code, message: failure.message)
        } catch {
            throw .database(code: SQLITE_ERROR, message: "\(error)")
        }
    }
}
