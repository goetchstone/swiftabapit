import Darwin
import Foundation
import JSONAPI
import Orgs
import Reports
import SQLite3

/// Snapshot history: point-in-time copies of what an org's reads returned, in one SQLite file on abapit's schema (plan
/// L7, §3.7, Phase 3). A `snapshots` row per run and an `items` row per resource item, its attributes as JSON; every row
/// carries the org's id, and every query asks for one org's rows only.
///
/// The file is an inventory of the org (serials, people, services), so it is the owner's alone: the folder `0700`, the
/// database `0600` from the moment it exists (never made and then narrowed), and its journal takes the database's mode
/// (SQLite gives a journal the mode of its database). The folder and the database are reached from `/` one name at a
/// time, each opened without following a link relative to the folder above, and made there, so a link swapped in
/// anywhere on the way can't receive them. SQLite then opens the database by its path with `SQLITE_OPEN_NOFOLLOW`, which
/// refuses a link anywhere in that path.
///
/// Only a file this app made is opened: an existing file with a second name on disk (a hard link), or a database at
/// version 0 that already holds tables (abapit's history, say), is refused and left as it is. abapit's history is
/// imported, never changed in place.
///
/// The same file keeps the small `attention` table "Needs attention" reads (`AttentionStore.swift`, version 2).
///
/// What it never holds: a secret, and a custom setting's profile (operator, 2026-10-31: what can be read again from Apple
/// isn't kept; a collector stores `Configuration.resource`, the profile withheld). As a backstop to the collectors, an
/// attribute whose name looks like a secret's (`ExportPolicy.isSensitive`), at any depth, is left out of what is stored,
/// and the snapshot's `notes` say how many were left out of each resource (never their names).
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
        /// The file is this app's, at `version` (before the current one), but this process can't write it (its mode, a read-only
        /// volume), so it wasn't migrated: read at the version it has, never written.
        case notWritable(version: Int32)
    }

    public enum Failure: Error, Equatable, Sendable {
        /// A symbolic link where the store's folder or file, or a folder above them, should be.
        case link(path: String)
        /// The database file has a second name on disk (a hard link): refused, left as it is.
        case hardLinked(path: String)
        case notAFolder(path: String)
        case notAFile(path: String)
        /// A database at version 0 that already holds tables: abapit's history, or another program's. Left as it is.
        case notThisAppsFile(path: String)
        case unopenable(path: String, errno: Int32)
        /// SQLite's extended result code and message.
        case database(code: Int32, message: String)
        /// Written by a newer version: this one doesn't change it.
        case readOnly(version: Int32)
        /// The file can't be written by this process (its mode, a read-only volume): read, never changed.
        case notWritable(version: Int32)
        /// The org has no id, so its rows couldn't be told from another's.
        case noOrg
        /// No snapshot with that id for that org (there may be one for another org: it isn't said).
        case noSnapshot(Int64)
        /// The finding isn't in the store: it is recorded by `seen` before it can be dismissed or snoozed.
        case noFinding(rule: String, subject: String)
        /// A rule or subject that isn't an identifier (`isIdentifier`): empty, too long, or holding a space or a quote.
        case notAnIdentifier
        /// A row that doesn't read (JSON that isn't, text that isn't UTF-8, an escape of half a character): the file was
        /// changed outside this app.
        case corrupt(String)
        /// `exportCopy` refused or couldn't make the copy; the words say why (the destination exists and isn't empty, a link on
        /// its path, the system's error).
        case notCopied(String)

        public var message: String {
            switch self {
            case .link(let path): "The snapshot history wasn't opened: \(path) is or passes through a symbolic link."
            case .hardLinked(let path): "The snapshot history wasn't opened: \(path) has a second name on disk (a hard link). It was left as it is."
            case .notAFolder(let path): "The snapshot history wasn't opened: \(path) isn't a folder."
            case .notAFile(let path): "The snapshot history wasn't opened: \(path) isn't a file."
            case .notThisAppsFile(let path):
                "\(path) is abapit's history or another program's database, not this app's. It was left as it is: import abapit's history instead."
            case .unopenable(let path, let code): "The snapshot history at \(path) couldn't be opened (\(String(cString: strerror(code))))."
            case .database(_, let message): "The snapshot history couldn't be read or written (\(message))."
            case .readOnly(let version):
                "The snapshot history was written by a newer abapit (schema version \(version)); this one reads it and won't change it."
            case .notWritable:
                "The snapshot history can't be written; it is read and never changed. Check the file's permissions or the volume."
            case .noOrg: "The organization has no id, so its snapshots can't be kept apart from another's."
            case .noSnapshot(let id): "There's no snapshot \(id) for this organization."
            case .noFinding: "That finding isn't in the list any more, so it can't be changed."
            case .notAnIdentifier: "A finding's rule and subject must be identifiers, not names."
            case .corrupt(let what): "The snapshot history holds a row this app can't read (\(what)); it was changed outside abapit."
            case .notCopied(let why): "The copy wasn't made: \(why)"
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
        /// Per resource read, the items recorded, zero included; a resource not read is absent (`Schema.additions`).
        public let counts: [String: Int]
        /// Items recorded as `devices`, as abapit's list counts them.
        public let deviceCount: Int
        /// Per per-device sweep that ran, the ids of the devices in the list it covers that it did not read, sorted by bytes (`Schema.unread`).
        /// A sweep with no key was not run, or the snapshot doesn't record it (a row from before version 3, one imported from abapit):
        /// never "every device was read". An empty list is a sweep that ran and missed none.
        public let unread: [String: [String]]

        public var date: Date? { ISODate.parse(takenAt)?.date }
    }

    public struct Snapshot: Sendable, Equatable {
        public let summary: Summary
        /// Each resource's items, ordered by id (by bytes, as SQLite and Python compare them); an item's attributes in
        /// abapit's stored order (keys sorted). A resource recorded with no items isn't here: `summary.counts` says it was
        /// read and found none.
        public let resources: [String: [Resource]]
    }

    /// One snapshot's copy of one resource.
    public struct Copy: Sendable, Equatable {
        public let summary: Summary
        /// The items, ordered by id. None is an answer: the org had none when the snapshot was taken.
        public let items: [Resource]
    }

    /// What the history knows of a resource now (invariant 8: its age always shows, through the snapshot's `takenAt`).
    public enum Latest: Sendable, Equatable {
        /// The newest snapshot that tried to read the resource read it: what it found, possibly nothing.
        case read(Copy)
        /// The newest snapshot that tried failed, with this error; `newest` is the last good copy: the newest snapshot that
        /// read the resource without an error, what it found possibly nothing (plan §2.3 defect 13). A snapshot that read
        /// part of it and then failed is never a good copy.
        case failed(Summary, error: String, newest: Copy?)
    }

    public static let fileName = "history.sqlite"
    /// The resource name `activation_lock_view` reads: one item per device, keyed by serial number, attributes as Apple's
    /// `ActivationLockStatus` has them.
    public static let activationLockResource = "activation_lock"

    public nonisolated let access: Access
    let database: SQLiteDatabase
    private let writer: String
    /// Whether `snapshots` has the `unread` column (version 3): a file that couldn't be migrated lacks it, and reads as "not recorded".
    private let hasUnread: Bool
    /// Whether the file has the `attention` table (version 2): one that couldn't be migrated from version 1 hasn't, and holds no finding.
    let hasAttention: Bool
    let hook: Hook?
    /// The store's own folder, which only this user can enter: where an export's working copy is made. Nil in memory.
    let home: String?

    /// Where a test can stop the store, as a crash or a failing disk would, or change the disk under it, as another
    /// program could (`hook`). Never set outside the tests.
    enum Step: Sendable, Equatable {
        /// A folder on the way to the store's has been opened (or made and opened); the next name is opened from it.
        case walked(path: String)
        /// The database file has just been made: nothing written to it yet.
        case created(path: String)
        /// The folder and file are open and checked; SQLite opens the path next.
        case opening(path: String)
        /// A file at version 0 was found empty; the write lock is taken next, and the file looked at again under it.
        case foundEmpty(path: String)
        /// Inside `record`'s transaction: the snapshot row and `items` items are written.
        case recording(items: Int)
        /// A file at version 1 was found and checked as this app's; the write lock is taken next and the version read again.
        case foundVersion1(path: String)
        /// A file at version 2 was found and checked as this app's; the write lock is taken next and the version read again.
        case foundVersion2(path: String)
        /// Inside the migration's transaction, the version confirmed as still the one found: the next version's script runs next.
        case migrating(path: String)
        /// An export's bytes are written and synced; the path is checked next.
        case copied(path: String)
        /// An export has checked that its destination doesn't exist and made its working copy; the destination is created next.
        case beforeCreate(path: String)
    }

    typealias Hook = @Sendable (Step) throws(Failure) -> Void

    /// Opens (and makes, the first time) the store. `appVersion` is this app's version, written on each snapshot as
    /// `swiftabapit <appVersion>` where abapit wrote its own.
    public init(storage: Storage, appVersion: String) throws(Failure) {
        try self.init(storage: storage, appVersion: appVersion, hook: nil)
    }

    init(storage: Storage, appVersion: String, hook: Hook?) throws(Failure) {
        let opened: (database: SQLiteDatabase, access: Access)
        var home: String?
        switch storage {
        case .memory:
            let database = try Self.guarded { try SQLiteDatabase(path: ":memory:", flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) }
            opened = (database, try Self.prepare(database, path: ":memory:", hook: hook))
        case .folder(let folder):
            opened = try Self.openFile(in: folder, hook: hook)
            home = "/" + folder.path(percentEncoded: false).split(separator: "/").joined(separator: "/")
        }
        self.home = home
        database = opened.database
        access = opened.access
        writer = "swiftabapit \(appVersion)"
        self.hook = hook
        hasUnread = try Self.guarded { try opened.database.rows("PRAGMA table_info(snapshots)") { try $0.text(1) ?? "" } }.contains("unread")
        hasAttention = try Self.guarded { try opened.database.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'attention'") { try $0.text(0) ?? "" } }.count == 1
    }

    // MARK: writing

    /// Records one snapshot of `org`: a row taken at `takenAt` (an import passes the original time), and an item per
    /// resource item, its attributes as abapit stores them (`StoredJSON`; its relationships aren't kept, as abapit kept
    /// none). Every resource in `resources` is counted as read (`counts`), an empty list included; one that failed goes in
    /// `errors`. Whole or not at all: a failure part way leaves no row. Two items of a resource with one id keep the last
    /// (abapit's `INSERT OR REPLACE`). An attribute whose name looks like a secret's, at any depth, is left out, and the
    /// resource's note says how many were (`Self.leftOut`). `unread` is, per per-device sweep that ran, the ids of the devices it
    /// did not read (`Summary.unread`); kept sorted by bytes, each id once; a sweep not in it is "not recorded". Returns the snapshot's id.
    @discardableResult
    public func record(org: OrgProfile, takenAt: Date, resources: [String: [Resource]], errors: [String: String] = [:],
                       notes: [String: String] = [:], unread: [String: [String]] = [:]) throws(Failure) -> Int64 {
        // Never nil: only an import skips a duplicate.
        guard let id = try insert(org: org, takenAt: takenAt, writtenBy: writer, resources: resources, errors: errors, notes: notes,
                                  unread: unread, skippingDuplicate: false) else { throw .noSnapshot(0) }
        return id
    }

    /// Records a snapshot imported from abapit's history (`AbapitHistory`), under `writtenBy` (`abapit <version>`, never
    /// `swiftabapit …`, so the row is told from one this app took). A snapshot of `org` already recorded at `takenAt` by
    /// `writtenBy` is the same one imported before: nothing is written and nil is returned (the duplicate check and the
    /// write are one transaction; a caller that has itself written a snapshot at that time in this run passes `skippingDuplicate:
    /// false`, since the earlier row is its own, not an earlier import). Otherwise as `record`.
    @discardableResult
    public func recordImported(org: OrgProfile, takenAt: Date, writtenBy: String, resources: [String: [Resource]], errors: [String: String] = [:],
                               notes: [String: String] = [:], skippingDuplicate: Bool = true) throws(Failure) -> Int64? {
        // abapit never recorded which devices a sweep missed: `{}`, "not recorded".
        try insert(org: org, takenAt: takenAt, writtenBy: writtenBy, resources: resources, errors: errors, notes: notes, unread: [:],
                   skippingDuplicate: skippingDuplicate)
    }

    private func insert(org: OrgProfile, takenAt: Date, writtenBy: String, resources: [String: [Resource]], errors: [String: String],
                        notes: [String: String], unread: [String: [String]], skippingDuplicate: Bool) throws(Failure) -> Int64? {
        try writable()
        let orgID = try Self.id(of: org)
        let names = resources.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var counts = JSONObject(), kept: [String: [(id: String, attributes: JSONObject)]] = [:], notes = notes
        for name in names {
            let items = resources[name] ?? []
            var dropped = 0
            kept[name] = items.map { item in
                let (attributes, count) = Self.withoutSecrets(item.attributes)
                dropped += count
                return (item.id, attributes)
            }
            if dropped > 0 { notes[name] = [notes[name], Self.leftOut(dropped)].compactMap { $0 }.joined(separator: "; ") }
            // Distinct ids by bytes: what the primary key keeps after `INSERT OR REPLACE`.
            counts[name] = .number(String(Set(items.map { Array($0.id.utf8) }).count))
        }
        let scope = org.provider == .known(.apple) ? org.scope.rawValue : org.provider.rawValue
        let taken = Schema.takenAt(takenAt)
        let unreadText = Self.unreadText(unread)
        return try Self.guarded {
            try database.transaction {
                if skippingDuplicate, try database.rows("SELECT 1 FROM snapshots WHERE org_id = ? AND taken_at = ? AND abapit_version = ? LIMIT 1",
                                                        [.text(orgID), .text(taken), .text(writtenBy)], { $0.integer(0) }).first != nil {
                    return nil
                }
                try database.run("""
                    INSERT INTO snapshots (taken_at, org_client_id, org_name, org_scope, abapit_version, errors, org_id, notes, counts, unread) \
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [.text(taken), .text(org.clientID), .text(org.name), .text(scope), .text(writtenBy),
                          .text(Self.words(errors)), .text(orgID), .text(Self.words(notes)), .text(StoredJSON.text(.object(counts))),
                          .text(unreadText)])
                let snapshot = database.lastInsertRowID
                var written = 0
                try hook?(.recording(items: written))
                let insert = try database.prepare("INSERT OR REPLACE INTO items VALUES (?, ?, ?, ?)")
                for name in names {
                    for item in kept[name] ?? [] {
                        try insert.run([.integer(snapshot), .text(name), .text(item.id), .text(StoredJSON.text(.object(item.attributes)))])
                        written += 1
                        try hook?(.recording(items: written))
                    }
                }
                return snapshot
            }
        }
    }

    /// Keeps the newest `keep` snapshots of `org`, by `takenAt` (an import records old snapshots after new ones; `Schema.takenAt` is fixed-width UTC, so text order is time order; the id breaks a tie), and
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
                    SELECT id FROM snapshots WHERE org_id = ? ORDER BY taken_at DESC, id DESC LIMIT ?)
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
                let removed = database.changes
                // The org's findings are its history too: a new org with this id must not inherit a dismissal.
                try database.run("DELETE FROM attention WHERE org_id = ?", [.text(orgID)])
                return removed
            }
        }
    }

    // MARK: reading

    /// Every org id with at least one snapshot or one finding, by bytes. Org ids are slugs of names and can come round again: a new org
    /// must not be given one of these, or it would inherit a removed org's history (`OrgStore.uniqueID(avoiding:)`).
    public func orgIDs() throws(Failure) -> [String] {
        try Self.guarded {
            // Findings count too: an org with dismissals and no snapshots must not be reused either.
            // A file that couldn't be migrated has no attention table: it never held a finding.
            try database.rows("SELECT org_id FROM snapshots" + (hasAttention ? " UNION SELECT org_id FROM attention" : "") + " ORDER BY 1") { try $0.text(0) ?? "" }
        }
    }

    /// `org`'s snapshots, newest first (by `takenAt`, then id), at most `limit` (abapit's list).
    public func snapshots(org: OrgProfile, limit: Int = 100) throws(Failure) -> [Summary] {
        let orgID = try Self.id(of: org)
        return try Self.guarded {
            try database.rows(summarySQL + "WHERE s.org_id = ? ORDER BY s.taken_at DESC, s.id DESC LIMIT ?",
                              [.text(orgID), .integer(Int64(max(limit, 0)))], Self.summary)
        }
    }

    /// How many snapshots `org` has, without reading them (the question Settings asks when an org is removed).
    public func count(org: OrgProfile) throws(Failure) -> Int {
        let orgID = try Self.id(of: org)
        return try Self.guarded {
            try database.rows("SELECT COUNT(*) FROM snapshots WHERE org_id = ?", [.text(orgID)]) { Int($0.integer(0)) }.first ?? 0
        }
    }

    /// One of `org`'s snapshots with every item. Another org's snapshot is refused as one that isn't there.
    public func load(_ id: Int64, org: OrgProfile) throws(Failure) -> Snapshot {
        let orgID = try Self.id(of: org)
        return try Self.guarded {
            try database.reading {
                guard let summary = try database.rows(summarySQL + "WHERE s.id = ? AND s.org_id = ?", [.integer(id), .text(orgID)],
                                                      Self.summary).first else { throw Failure.noSnapshot(id) }
                var resources: [String: [Resource]] = [:]
                let rows = try database.rows("SELECT resource, item_id, attributes FROM items WHERE snapshot_id = ? ORDER BY resource, item_id",
                                             [.integer(id)]) { row in try Self.item(row, resource: row.text(0) ?? "", from: 1) }
                for item in rows { resources[item.type, default: []].append(item) }
                return Snapshot(summary: summary, resources: resources)
            }
        }
    }

    /// What the newest of `org`'s snapshots that tried to read `resource` found: its items (possibly none), or its error
    /// with the last good copy, the newest snapshot that read it without an error (possibly empty). A snapshot that didn't
    /// try is passed over. Nil when none tried.
    public func latest(_ resource: String, org: OrgProfile) throws(Failure) -> Latest? {
        let orgID = try Self.id(of: org)
        return try Self.guarded {
            try database.reading {
                guard let attempt = try database.rows(summarySQL + """
                    WHERE s.org_id = ? AND (EXISTS (SELECT 1 FROM json_each(s.counts) c WHERE c.key = ?) \
                    OR EXISTS (SELECT 1 FROM json_each(s.errors) e WHERE e.key = ?)) ORDER BY s.taken_at DESC, s.id DESC LIMIT 1
                    """, [.text(orgID), .text(resource), .text(resource)], Self.summary).first else { return nil }
                // The error by the key's bytes, as SQLite compares them, not by a Swift dictionary's equivalence.
                let error = try database.rows("SELECT e.value AS errors FROM snapshots s, json_each(s.errors) e WHERE s.id = ? AND e.key = ?",
                                              [.integer(attempt.id), .text(resource)]) { try $0.text(0) ?? "" }.first
                guard let error else { return .read(Copy(summary: attempt, items: try items(resource, in: attempt.id))) }
                guard let id = try database.rows("""
                    SELECT s.id FROM snapshots s WHERE s.org_id = ? \
                    AND EXISTS (SELECT 1 FROM json_each(s.counts) c WHERE c.key = ?) \
                    AND NOT EXISTS (SELECT 1 FROM json_each(s.errors) e WHERE e.key = ?) ORDER BY s.taken_at DESC, s.id DESC LIMIT 1
                    """, [.text(orgID), .text(resource), .text(resource)], { $0.integer(0) }).first,
                      let summary = try database.rows(summarySQL + "WHERE s.id = ?", [.integer(id)], Self.summary).first
                else { return .failed(attempt, error: error, newest: nil) }
                return .failed(attempt, error: error, newest: Copy(summary: summary, items: try items(resource, in: id)))
            }
        }
    }

    /// The newest of `org`'s snapshots that read any of `resource`: in its `counts`, whether or not it also has an error for it (a part
    /// read, which `latest` reports as a failure). `summary.errors[resource]` says which it is. Its items, possibly none. Nil when no
    /// snapshot read any of it. `latest`'s second query without its `NOT EXISTS errors` clause.
    public func newestRead(_ resource: String, org: OrgProfile) throws(Failure) -> Copy? {
        let orgID = try Self.id(of: org)
        return try Self.guarded {
            try database.reading {
                guard let summary = try database.rows(summarySQL + """
                    WHERE s.org_id = ? AND EXISTS (SELECT 1 FROM json_each(s.counts) c WHERE c.key = ?) ORDER BY s.taken_at DESC, s.id DESC LIMIT 1
                    """, [.text(orgID), .text(resource)], Self.summary).first else { return nil }
                return Copy(summary: summary, items: try items(resource, in: summary.id))
            }
        }
    }

    private func items(_ resource: String, in snapshot: Int64) throws -> [Resource] {
        try database.rows("SELECT item_id, attributes FROM items WHERE snapshot_id = ? AND resource = ? ORDER BY item_id",
                          [.integer(snapshot), .text(resource)]) { row in try Self.item(row, resource: resource, from: 0) }
    }

    // MARK: opening

    /// Opens the folder and the file, made where missing, then the file with SQLite, then accepts it or refuses it. A
    /// refused file is left as it was: its mode is narrowed only once it is accepted.
    private static func openFile(in folder: URL, hook: Hook?) throws(Failure) -> (database: SQLiteDatabase, access: Access) {
        // The path as given, never `standardizedFileURL`: Foundation drops `/private` from `/private/var/…` there, which
        // puts a link (`/var`) back into the path. A `.` or `..` is refused rather than resolved.
        let given = folder.path(percentEncoded: false)
        let components = given.split(separator: "/").map(String.init)
        guard folder.isFileURL, given.hasPrefix("/"), !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw .notAFolder(path: given)
        }
        let path = "/" + components.joined(separator: "/")
        let file = (path == "/" ? "" : path) + "/" + fileName
        let folderFD = try openFolder(components, hook: hook)
        defer { close(folderFD) }
        let (fileFD, made) = try openDatabaseFile(in: folderFD, path: file, hook: hook)
        defer { close(fileFD) }
        try hook?(.opening(path: file))
        let database: SQLiteDatabase
        do throws(SQLiteDatabase.Failure) {
            // No SQLITE_OPEN_CREATE: the file exists, made above with its mode.
            database = try SQLiteDatabase(path: file, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW)
        } catch {
            if error.code == SQLiteDatabase.cantOpenSymlink { throw .link(path: file) }
            throw .database(code: error.code, message: error.message)
        }
        let access = try prepare(database, path: file, hook: hook)
        if !made {
            var info = stat()
            guard fstat(fileFD, &info) == 0 else { throw .unopenable(path: file, errno: errno) }
            if info.st_mode & 0o077 != 0, fchmod(fileFD, 0o600) != 0 { throw .unopenable(path: file, errno: errno) }
        }
        return (database, access)
    }

    /// The store's folder as a descriptor, reached from `/` one name at a time: each opened `O_DIRECTORY | O_NOFOLLOW`
    /// relative to the folder above's descriptor, and made `0700` there (`mkdirat`) where missing, so a link put in place
    /// of a folder already passed leads nowhere. A link or a file on the way is refused. The store's own folder is
    /// narrowed to `0700` if it was wider.
    private static func openFolder(_ components: [String], hook: Hook?) throws(Failure) -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw .unopenable(path: "/", errno: errno) }
        var path = ""
        for name in components {
            path += "/" + name
            var next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                if mkdirat(fd, name, 0o700) != 0, errno != EEXIST {
                    let code = errno
                    close(fd)
                    throw .unopenable(path: path, errno: code)
                }
                next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            if next < 0 {
                let failure = refusal(of: name, in: fd, path: path, errno: errno)
                close(fd)
                throw failure
            }
            close(fd)
            fd = next
            do throws(Failure) {
                try hook?(.walked(path: path))
            } catch {
                close(fd)
                throw error
            }
        }
        var info = stat()
        if fstat(fd, &info) != 0 || (info.st_mode & 0o077 != 0 && fchmod(fd, 0o700) != 0) {
            let code = errno
            close(fd)
            throw .unopenable(path: path.isEmpty ? "/" : path, errno: code)
        }
        return fd
    }

    /// Why `name` in the folder `fd` didn't open as a folder: a link, not a folder, or the system's error.
    private static func refusal(of name: String, in fd: Int32, path: String, errno code: Int32) -> Failure {
        var info = stat()
        guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return .unopenable(path: path, errno: code) }
        if info.st_mode & S_IFMT == S_IFLNK { return .link(path: path) }
        if info.st_mode & S_IFMT != S_IFDIR { return .notAFolder(path: path) }
        return .unopenable(path: path, errno: code)
    }

    /// The database file in the folder `fd`: made `0600` by `openat` itself when it isn't there (`O_EXCL`, so never
    /// through a link), else opened without following a link and held to a regular file with one name. Returns it open,
    /// and whether it was made.
    private static func openDatabaseFile(in folder: Int32, path: String, hook: Hook?) throws(Failure) -> (fd: Int32, made: Bool) {
        let made = openat(folder, fileName, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if made >= 0 {
            do throws(Failure) {
                try hook?(.created(path: path))
            } catch {
                close(made)
                throw error
            }
            return (made, true)
        }
        guard errno == EEXIST else { throw .unopenable(path: path, errno: errno) }
        // Read-only, so a folder opens too and is refused below as not a file; `fchmod` needs no write access.
        let fd = openat(folder, fileName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ELOOP ? .link(path: path) : .unopenable(path: path, errno: errno) }
        var info = stat()
        let failure: Failure? = if fstat(fd, &info) != 0 {
            .unopenable(path: path, errno: errno)
        } else if info.st_mode & S_IFMT != S_IFREG {
            .notAFile(path: path)
        } else if info.st_nlink != 1 {
            .hardLinked(path: path)
        } else {
            nil
        }
        if let failure {
            close(fd)
            throw failure
        }
        return (fd, false)
    }

    /// Foreign keys on (abapit's `PRAGMA foreign_keys = ON`: a snapshot's items go with it), then the schema. A file at
    /// this version opens; a newer one is queried only; one at version 0 is made version 1 only when it holds nothing:
    /// one that holds tables (abapit's history, another program's database) is refused and left as it is.
    private static func prepare(_ database: SQLiteDatabase, path: String, hook: Hook?) throws(Failure) -> Access {
        try guarded {
            try database.execute("PRAGMA foreign_keys = ON")
            let found = try database.userVersion()
            guard found <= Schema.version else {
                try database.execute("PRAGMA query_only = ON")
                return .readOnly(version: found)
            }
            guard found < Schema.version else { return .readWrite }
            if found >= 1 {
                // This app's own file at version 1 or 2 (a foreign file can carry `user_version` 1 or 2 too: its `snapshots` must have
                // the columns this app added, and at version 2 the `attention` table), then each later version's script is run, in one
                // transaction: version 2 adds the attention table and version 3 the `unread` column; the snapshots' rows are not touched.
                // Read again under the write lock, so two stores opening at once migrate it once.
                func isThisApps(_ version: Int32) throws -> Bool {
                    let columns = try database.rows("PRAGMA table_info(snapshots)") { try $0.text(1) ?? "" }
                    guard columns.contains("org_id"), columns.contains("counts") else { return false }
                    if version == 2 {
                        let tables = try database.rows("SELECT name FROM sqlite_master WHERE type = 'table'") { try $0.text(0) ?? "" }
                        return tables.contains("attention") && !columns.contains("unread")
                    }
                    return true
                }
                guard try isThisApps(found) else { throw Failure.notThisAppsFile(path: path) }
                try hook?(found == 1 ? .foundVersion1(path: path) : .foundVersion2(path: path))
                // Decided on the version read under the lock: a newer one (another build migrated it past this one) is read-only, this
                // one is left as it is, an older one is migrated from where it stands.
                var newer: Int32?
                do {
                    try database.transaction {
                        let now = try database.userVersion()
                        if now > Schema.version {
                            newer = now
                            return
                        }
                        guard now < Schema.version else { return }
                        guard now >= 1, try isThisApps(now) else { throw Failure.notThisAppsFile(path: path) }
                        try hook?(.migrating(path: path))
                        if now == 1 { try database.execute(Schema.toVersion2) }
                        try database.execute(Schema.toVersion3)
                    }
                } catch let failure as SQLiteDatabase.Failure where failure.code & 0xFF == SQLITE_READONLY {
                    // A file this process can't write (mode 0400, a read-only volume) can't be migrated: it is read at the version it has,
                    // and never written (the version-1 and version-2 columns this build reads are there; `unread` reads as `{}`).
                    try database.execute("PRAGMA query_only = ON")
                    return .notWritable(version: found)
                }
                if let newer {
                    try database.execute("PRAGMA query_only = ON")
                    return .readOnly(version: newer)
                }
                return .readWrite
            }
            func isEmpty() throws -> Bool { try database.rows("SELECT COUNT(*) FROM sqlite_master") { $0.integer(0) }.first == 0 }
            // Looked at before any write lock is taken on a file that may not be this app's.
            guard try isEmpty() else { throw Failure.notThisAppsFile(path: path) }
            try hook?(.foundEmpty(path: path))
            var changed = false
            try database.transaction {
                // Read again under the write lock: another store may have made it meanwhile.
                guard try database.userVersion() == 0 else {
                    changed = true
                    return
                }
                guard try isEmpty() else { throw Failure.notThisAppsFile(path: path) }
                try database.execute(Schema.newDatabase)
            }
            // Another store took the file past version 0 between the look and the lock: decided afresh on the version now there (a newer
            // one is read-only, a current one is as it is, an older one is migrated from where it stands), never assumed writable.
            return changed ? try prepare(database, path: path, hook: hook) : .readWrite
        }
    }

    // MARK: rows

    /// A snapshot's row and abapit's `device_count`; a `WHERE` follows.
    /// A file at a version before 3 that couldn't be migrated (it can't be written) has no `unread` column: its rows read `{}`, "not recorded".
    private static func summarySQL(hasUnread: Bool) -> String {
        "SELECT s.id, s.taken_at, s.org_id, s.org_name, s.org_scope, s.org_client_id, s.abapit_version, "
            + "s.errors, s.notes, s.counts, " + (hasUnread ? "s.unread" : "'{}'") + ", "
            + "(SELECT COUNT(*) FROM items i WHERE i.snapshot_id = s.id AND i.resource = 'devices') AS device_count "
            + "FROM snapshots s "
    }
    private var summarySQL: String { Self.summarySQL(hasUnread: hasUnread) }

    private static func summary(_ row: SQLiteDatabase.Row) throws -> Summary {
        Summary(id: row.integer(0), takenAt: try row.text(1) ?? "", orgID: try row.text(2) ?? "", orgName: try row.text(3) ?? "",
                orgScope: try row.text(4) ?? "", clientID: try row.text(5) ?? "", writtenBy: try row.text(6) ?? "",
                errors: try words(row.text(7), "a snapshot's errors", column: "errors"),
                notes: try words(row.text(8), "a snapshot's notes", column: "notes"),
                counts: try counts(row.text(9)), deviceCount: Int(row.integer(11)), unread: try unread(row.text(10)))
    }

    /// An item from `item_id` and `attributes` at `column` and the next.
    private static func item(_ row: SQLiteDatabase.Row, resource: String, from column: Int32) throws -> Resource {
        let id = try row.text(column) ?? ""
        guard let attributes = try json(row.text(column + 1), column: "attributes")?.object else {
            throw Failure.corrupt("the attributes of \(resource) \(id)")
        }
        return Resource(type: resource, id: id, attributes: attributes)
    }

    /// A JSON column's text parsed, or nil when it isn't JSON. An escape of half a character (a lone surrogate, `\uD800`
    /// to `\uDFFF` without its other half) throws, naming the column: `JSONValue.parse` reads one as U+FFFD (a Swift
    /// string can't hold it), which would change an id or merge two keys silently. This app never writes one
    /// (`StoredJSON` writes a pair). `JSONValue.parse` itself is left as it is for its other callers.
    private static func json(_ text: String?, column: String) throws -> JSONValue? {
        let text = text ?? ""
        if hasLoneSurrogate(text) { throw Failure.corrupt("the column \(column) holds an escape of half a character") }
        return JSONValue.parse(text)
    }

    /// Whether JSON text holds a `\u` escape of a surrogate that isn't half of a pair.
    static func hasLoneSurrogate(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        var index = 0, high = false
        func unit(at start: Int) -> UInt32? {
            guard start + 6 <= scalars.count, scalars[start] == "\\", scalars[start + 1] == "u" else { return nil }
            return UInt32(String(String.UnicodeScalarView(scalars[(start + 2)..<(start + 6)])), radix: 16)
        }
        while index < scalars.count {
            if let value = unit(at: index) {
                switch value {
                case 0xD800...0xDBFF:
                    if high { return true }
                    high = true
                case 0xDC00...0xDFFF:
                    if !high { return true }
                    high = false
                default:
                    if high { return true }
                }
                index += 6
                continue
            }
            if high { return true }
            // Any other escape is two scalars (`\\` included, so a backslash it escapes never starts one).
            index += scalars[index] == "\\" ? 2 : 1
        }
        return high
    }

    /// `errors` and `notes` as stored: a JSON object of strings.
    private static func words(_ words: [String: String]) -> String {
        var object = JSONObject()
        for (key, value) in words { object[key] = .string(value) }
        return StoredJSON.text(.object(object))
    }

    /// `errors` or `notes` read back. A value that isn't a string (abapit wrote strings) shows as its JSON.
    private static func words(_ text: String?, _ what: String, column: String) throws -> [String: String] {
        guard let object = try json(text, column: column)?.object else { throw Failure.corrupt(what) }
        var found: [String: String] = [:]
        for (key, value) in object { found[key] = value.string ?? value.jsonText }
        return found
    }

    /// `unread` as it is stored: per sweep the ids, sorted by bytes, each once; keys sorted like the other JSON columns.
    static func unreadText(_ unread: [String: [String]]) -> String {
        var object = JSONObject()
        for (name, ids) in unread {
            var seen: Set<[UInt8]> = []
            let sorted = ids.filter { seen.insert(Array($0.utf8)).inserted }.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            object[name] = .array(sorted.map { .string($0) })
        }
        return StoredJSON.text(.object(object))
    }

    /// `unread` read back: a JSON object of lists of ids. Anything else was changed outside the app.
    private static func unread(_ text: String?) throws -> [String: [String]] {
        guard let object = try json(text, column: "unread")?.object else { throw Failure.corrupt("a snapshot's unread devices") }
        var found: [String: [String]] = [:]
        for (key, value) in object {
            guard case .array(let items) = value else { throw Failure.corrupt("a snapshot's unread devices") }
            found[key] = try items.map { item in
                guard let id = item.string else { throw Failure.corrupt("a snapshot's unread devices") }
                return id
            }
        }
        return found
    }

    /// `counts` read back: a JSON object of whole numbers, none negative.
    private static func counts(_ text: String?) throws -> [String: Int] {
        guard let object = try json(text, column: "counts")?.object else { throw Failure.corrupt("a snapshot's counts") }
        var found: [String: Int] = [:]
        for (key, value) in object {
            guard let count = value.int, count >= 0 else { throw Failure.corrupt("a snapshot's counts") }
            found[key] = count
        }
        return found
    }

    /// `attributes` without every member, at any depth, whose name looks like a secret's (`ExportPolicy.isSensitive`), and
    /// how many were left out (a member left out isn't looked into).
    static func withoutSecrets(_ attributes: JSONObject) -> (JSONObject, Int) {
        var dropped = 0
        func clean(_ value: JSONValue) -> JSONValue {
            switch value {
            case .object(let object):
                var kept = JSONObject()
                for (key, member) in object {
                    if ExportPolicy.isSensitive(key) {
                        dropped += 1
                    } else {
                        kept[key] = clean(member)
                    }
                }
                return .object(kept)
            case .array(let items):
                return .array(items.map(clean))
            case .null, .bool, .number, .string:
                return value
            }
        }
        guard case .object(let kept) = clean(.object(attributes)) else { return (attributes, 0) }
        return (kept, dropped)
    }

    /// The note for a resource that had `count` attributes left out: the count only, never the names (a key can be data,
    /// such as a device's name in an object keyed by device).
    static func leftOut(_ count: Int) -> String {
        count == 1 ? "1 attribute left out: its name looks like a secret's" : "\(count) attributes left out: their names look like a secret's"
    }

    // MARK: helpers

    func writable() throws(Failure) {
        switch access {
        case .readWrite: return
        case .readOnly(let version): throw .readOnly(version: version)
        case .notWritable(let version): throw .notWritable(version: version)
        }
    }

    static func id(of org: OrgProfile) throws(Failure) -> String {
        guard !org.id.isEmpty else { throw .noOrg }
        return org.id
    }

    /// `body`'s errors as `Failure`s: SQLite's as `.database`, text that isn't UTF-8 as `.corrupt`, a hook's as thrown.
    static func guarded<T>(_ body: () throws -> T) throws(Failure) -> T {
        do {
            return try body()
        } catch let failure as Failure {
            throw failure
        } catch let failure as SQLiteDatabase.Failure {
            throw .database(code: failure.code, message: failure.message)
        } catch let invalid as SQLiteDatabase.InvalidText {
            throw .corrupt("the column \(invalid.column) isn't UTF-8")
        } catch {
            throw .database(code: SQLITE_ERROR, message: "\(error)")
        }
    }
}
