import Darwin
import Foundation
import JSONAPI
import SQLite3
import Synchronization

/// abapit's `history.sqlite`, opened to be copied from (plan Phase 3, "Import abapit history"): read-only, never changed.
///
/// - **Read-only, three ways.** SQLite opens it with `SQLITE_OPEN_READONLY` and the URI `mode=ro&immutable=1`: `immutable`
///   means no lock file, no journal and no WAL is ever made beside it, and `PRAGMA query_only` is on. Because `immutable` also
///   ignores a hot journal (rolling it back would write), a non-empty `-journal` or `-wal` beside the file is **refused**
///   first: reading around it would import the pages of a transaction abapit never committed. The connection reports itself read-only
///   (`isReadOnly`), which the tests hold it to. Nothing in this type has a statement that changes data.
/// - **No link.** The file is opened `O_NOFOLLOW` first and held to a regular file, and SQLite opens it with
///   `SQLITE_OPEN_NOFOLLOW`, which refuses a link anywhere on the path.
/// - **abapit's file or nothing.** abapit's `SCHEMA` (`PRAGMA user_version` 0, a `snapshots` and an `items` table with
///   exactly abapit's columns). A file this app wrote (version 1 or more, with the columns it added), another program's
///   database, a file that isn't SQLite and a file changed since abapit made it are refused with words.
/// - **No text from the file travels but data.** abapit's `errors` hold Python's exception text, which can carry URLs: only
///   the keys are read (`Snapshot.errorKeys`), never a value. A row that doesn't read is `corrupt`, in words that quote nothing.
///
/// An actor, so the reads run off the main thread, one at a time, a snapshot per call: the whole file is never in memory.
public actor AbapitHistory {
    public enum Failure: Error, Equatable, Sendable {
        /// A symbolic link as the file or anywhere on its path.
        case link(path: String)
        case notAFile(path: String)
        case unopenable(path: String, errno: Int32)
        /// Not abapit's history; `why` says what it is instead, in words.
        case notAbapits(why: String)
        /// The file at the path isn't the one that was checked and opened (replaced while it was being opened).
        case changed(path: String)
        /// A non-empty `-journal` or `-wal` beside the file: abapit stopped part way through a write. Reading it as it stands would
        /// import pages of a transaction that never committed (a snapshot of 13 of 2000 devices, with `integrity_check` saying ok).
        case unfinishedWrite(path: String)
        /// The files beside it couldn't be looked at (the sandbox, or the system's error), so whether a write was left unfinished
        /// isn't known.
        case unchecked(path: String, errno: Int32)
        /// SQLite's result code (its message can quote the file's own text, so it isn't carried).
        case database(code: Int32)
        /// A row that doesn't read, in words that quote nothing from it.
        case corrupt(String)

        public var message: String {
            switch self {
            case .link(let path): "\(path) is or passes through a symbolic link, so it wasn't opened."
            case .notAFile(let path): "\(path) isn't a file."
            case .unopenable(let path, let code): "\(path) couldn't be opened (\(String(cString: strerror(code))))."
            case .notAbapits(let why): "That isn't abapit's history: \(why) Nothing was read from it and it was not changed."
            case .changed(let path): "\((path as NSString).lastPathComponent) was replaced while it was being opened, so it wasn't imported."
            case .unfinishedWrite(let path):
                "abapit stopped part way through writing \((path as NSString).lastPathComponent): an unfinished write was left beside it. Open the file once "
                    + "in sqlite3 (for example: sqlite3 <the file> \"select 1\") so SQLite finishes the rollback, then import again. Nothing was read from it and it was not changed."
            case .unchecked(let path, let code):
                "Whether abapit left an unfinished write beside \((path as NSString).lastPathComponent) couldn't be checked (\(String(cString: strerror(code)))), so it wasn't imported."
            case .database(let code): "abapit's history couldn't be read (SQLite error \(code)). It was not changed."
            case .corrupt(let what): "abapit's history holds a row this app can't read (\(what))."
            }
        }
    }

    /// One snapshot's row, before its items are read.
    public struct Header: Sendable, Equatable {
        /// abapit's own id for it (not kept: the store gives its own).
        public let id: Int64
        /// As abapit wrote it (`2026-09-01T08:00:00Z`).
        public let takenAt: String
        /// The Apple API account's client ID the snapshot was taken for.
        public let clientID: String
        public let scope: String
        let version: String

        /// `abapit <version>` for a version that looks like one (digits, letters, `.`, `_`, `+`, `-`, at most 32 bytes), else
        /// `abapit`: what the store writes as the row's `abapit_version`, never text read from the file as it stands.
        public var writtenBy: String {
            let plain = !version.isEmpty && version.utf8.count <= 32 && version.utf8.allSatisfy {
                ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2B || $0 == 0x2D
            }
            return plain ? "abapit \(version)" : "abapit"
        }
    }

    /// One snapshot with its items.
    public struct Snapshot: Sendable, Equatable {
        public let header: Header
        /// Each resource's items as abapit stored them (`items.resource`), attributes parsed.
        public let resources: [String: [Resource]]
        /// The resources abapit's `errors` names, sorted by bytes; never the error text.
        public let errorKeys: [String]
    }

    /// abapit's columns at the pin, in order, with their declared types.
    static let snapshotColumns = ["id INTEGER", "taken_at TEXT", "org_client_id TEXT", "org_name TEXT", "org_scope TEXT", "abapit_version TEXT", "errors TEXT"]
    static let itemColumns = ["snapshot_id INTEGER", "resource TEXT", "item_id TEXT", "attributes TEXT"]

    let database: SQLiteDatabase
    /// The file as checked, held open so SQLite reads that file (`/dev/fd/N`) and not whatever the path leads to later (a FIFO swapped in
    /// would hang the open). Closed with the actor.
    private let descriptor: Int32
    /// Whether SQLite reads the checked descriptor (`/dev/fd/N`) rather than the path (the fallback where the system won't open that name).
    nonisolated let readsByDescriptor: Bool
    private let inode: UInt64

    /// The inodes of the files whose descriptors this type has closed, one entry per close: what the tests count to hold a
    /// descriptor to exactly one close (a refused file's was once closed twice, the second time possibly another owner's).
    static let closed = Mutex<[UInt64]>([])

    private static func release(_ fd: Int32, inode: UInt64) {
        close(fd)
        closed.withLock { $0.append(inode) }
    }

    /// Opens `file` read-only and checks it is abapit's.
    public init(file: URL) throws(Failure) {
        try self.init(file: file, viaDescriptor: true, beforeOpen: nil)
    }

    /// `viaDescriptor: false` goes straight to the path and `beforeOpen` runs once the file is checked and held, before SQLite opens
    /// it: where a test changes the disk under the open, as another program could. Never set outside the tests.
    init(file: URL, viaDescriptor: Bool, beforeOpen: (() -> Void)?) throws(Failure) {
        let given = file.path(percentEncoded: false)
        guard file.isFileURL, given.hasPrefix("/") else { throw .notAFile(path: given) }
        // No link on the way: `O_NOFOLLOW` looks at the last name only, and SQLite, handed the descriptor, looks at no path.
        var prefix = ""
        for name in given.split(separator: "/").dropLast() {
            prefix += "/" + name
            var above = stat()
            if lstat(prefix, &above) == 0, above.st_mode & S_IFMT == S_IFLNK { throw .link(path: given) }
        }
        let fd = open(given, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ELOOP ? .link(path: given) : .unopenable(path: given, errno: errno) }
        var keep = false
        var info = stat()
        defer { if !keep { Self.release(fd, inode: UInt64(info.st_ino)) } }
        guard fstat(fd, &info) == 0 else { throw .unopenable(path: given, errno: errno) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw .notAFile(path: given) }
        // A journal or WAL beside it holds a write abapit didn't finish; `immutable` would read the file without it applied.
        for suffix in ["-journal", "-wal"] {
            var side = stat()
            if lstat(given + suffix, &side) == 0 {
                if side.st_size != 0 || side.st_mode & S_IFMT != S_IFREG { throw .unfinishedWrite(path: given) }
            } else if errno != ENOENT {
                throw .unchecked(path: given, errno: errno)
            }
        }
        // `?` and `#` and `%` in a name are escaped, so the name can't carry a parameter of its own.
        let name = given.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? given
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOFOLLOW
        beforeOpen?()
        let opened: SQLiteDatabase
        var byDescriptor = false
        do throws(SQLiteDatabase.Failure) {
            // The descriptor first. SQLite opens lazily: the first read tells whether the descriptor's name works here. Only a
            // "can't open" or a permission refusal falls back to the checked path; any other answer (not a database, say) is the
            // file's, and is refused.
            do {
                guard viaDescriptor else { throw SQLiteDatabase.Failure(code: SQLITE_CANTOPEN, message: "not tried") }
                let direct = try SQLiteDatabase(path: "file:/dev/fd/\(fd)?mode=ro&immutable=1", flags: flags)
                _ = try direct.userVersion()
                opened = direct
                byDescriptor = true
            } catch let failure as SQLiteDatabase.Failure where Self.mayFallBack(failure.code) {
                opened = try SQLiteDatabase(path: "file:\(name)?mode=ro&immutable=1", flags: flags)
            } catch let failure as SQLiteDatabase.Failure {
                throw failure
            } catch {
                throw SQLiteDatabase.Failure(code: SQLITE_ERROR, message: "\(error)")
            }
        } catch {
            if error.code == SQLiteDatabase.cantOpenSymlink { throw .link(path: given) }
            throw Self.refusal(error.code)
        }
        if !byDescriptor {
            // The path is read again: it must lead to the file that was checked and held.
            var there = stat()
            guard stat(given, &there) == 0, there.st_dev == info.st_dev, there.st_ino == info.st_ino else { throw .changed(path: given) }
        }
        database = opened
        readsByDescriptor = byDescriptor
        descriptor = fd
        inode = UInt64(info.st_ino)
        // From here `deinit` owns the descriptor, also when a check below refuses the file: closing it here too closed it twice.
        keep = true
        try Self.guarded {
            try opened.execute("PRAGMA query_only = ON")
            guard opened.isReadOnly else { throw Failure.notAbapits(why: "it couldn't be opened read-only.") }
            try Self.verify(opened)
        }
    }

    deinit {
        Self.release(descriptor, inode: inode)
    }

    /// SQLite's "can't open" and permission refusals: the descriptor's name isn't available here, the path may be.
    static func mayFallBack(_ code: Int32) -> Bool {
        [SQLITE_CANTOPEN, SQLITE_PERM, SQLITE_AUTH].contains(code & 0xFF)
    }

    /// Whether the connection reports itself read-only and a write through it fails: what the tests hold the open to. (On a
    /// connection that could write, the probe would make a table: it is only ever run on a test's own copy.)
    func refusesWrites() -> Bool {
        database.isReadOnly && (try? database.execute("CREATE TABLE abapit_import_probe (a)")) == nil
            && (try? database.execute("DELETE FROM items")) == nil
    }

    /// The snapshots, oldest first by abapit's id (the order they were taken), their items not yet read.
    public func headers() throws(Failure) -> [Header] {
        try Self.guarded {
            try database.rows("SELECT id, taken_at, org_client_id, org_scope, abapit_version FROM snapshots ORDER BY id ASC") { row in
                Header(id: row.integer(0), takenAt: try row.text(1) ?? "", clientID: try row.text(2) ?? "", scope: try row.text(3) ?? "",
                       version: try row.text(4) ?? "")
            }
        }
    }

    /// The items of one snapshot and the names of the resources abapit recorded an error for.
    public func load(_ header: Header) throws(Failure) -> Snapshot {
        try Self.guarded {
            try database.reading {
                var resources: [String: [Resource]] = [:]
                let rows = try database.rows("SELECT resource, item_id, attributes FROM items WHERE snapshot_id = ? ORDER BY resource, item_id",
                                             [.integer(header.id)]) { row -> Resource in
                    let resource = try row.text(0) ?? "", id = try row.text(1) ?? ""
                    let text = try row.text(2) ?? ""
                    guard !SnapshotStore.hasLoneSurrogate(text) else { throw Failure.corrupt("an item holds an escape of half a character") }
                    guard let attributes = JSONValue.parse(text)?.object else { throw Failure.corrupt("an item's attributes aren't a JSON object") }
                    return Resource(type: resource, id: id, attributes: attributes)
                }
                for item in rows { resources[item.type, default: []].append(item) }
                let errors = try database.rows("SELECT errors FROM snapshots WHERE id = ?", [.integer(header.id)]) { try $0.text(0) ?? "" }.first ?? "{}"
                guard !SnapshotStore.hasLoneSurrogate(errors), let object = JSONValue.parse(errors)?.object else {
                    throw Failure.corrupt("a snapshot's errors aren't a JSON object")
                }
                return Snapshot(header: header, resources: resources, errorKeys: object.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) })
            }
        }
    }

    // MARK: checking

    private static func verify(_ database: SQLiteDatabase) throws {
        let version = try database.userVersion()
        guard version == 0 else {
            throw Failure.notAbapits(why: version > 0
                ? "its schema version is \(version): it was written by this app or a newer one, not by abapit."
                : "it isn't a version abapit wrote.")
        }
        for (table, expected) in [("snapshots", snapshotColumns), ("items", itemColumns)] {
            let found = try database.rows("PRAGMA table_info(\(table))") { row -> String in
                "\(try row.text(1) ?? "") \((try row.text(2) ?? "").uppercased())"
            }
            guard !found.isEmpty else { throw Failure.notAbapits(why: "it has no \(table) table.") }
            guard found == expected else {
                throw Failure.notAbapits(why: "its \(table) table doesn't have the columns abapit's has (another program's database, or one that was changed).")
            }
        }
    }

    /// `body`'s SQLite errors as `Failure`s (the code only), text that isn't UTF-8 as `corrupt`.
    private static func guarded<T>(_ body: () throws -> T) throws(Failure) -> T {
        do {
            return try body()
        } catch let failure as Failure {
            throw failure
        } catch let failure as SQLiteDatabase.Failure {
            throw refusal(failure.code)
        } catch let invalid as SQLiteDatabase.InvalidText {
            throw .corrupt("the column \(invalid.column) isn't UTF-8")
        } catch {
            throw .database(code: SQLITE_ERROR)
        }
    }

    /// A file SQLite says isn't a database (or is encrypted) isn't abapit's; any other code is SQLite's.
    private static func refusal(_ code: Int32) -> Failure {
        let primary = code & 0xFF
        if primary == SQLITE_NOTADB || primary == SQLITE_CORRUPT {
            return .notAbapits(why: "it isn't a SQLite database, or it is damaged.")
        }
        return .database(code: code)
    }
}
