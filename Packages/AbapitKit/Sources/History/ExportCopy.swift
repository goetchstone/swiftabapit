import Darwin
import Foundation
import JSONAPI
import SQLite3

/// A copy of the snapshot history for `sqlite3` or Datasette (plan Phase 3, "Export a copy"). One consistent database that
/// doesn't depend on this app's file or its journal, holding **one client's organizations only** when asked for that (the
/// plan's clients rule: no export mixes clients), and owner-only (`0600`).
///
/// It holds that client's snapshots (serials, device models, services, the people's Managed Apple Accounts as the snapshot
/// policy keeps them) and its Needs-attention findings and dismissals. No key, token or secret is ever in the history, so none
/// is in the copy.
extension SnapshotStore {
    /// What the Save panel says the copy holds. `client` is the active client's name when the operator has more than one client,
    /// nil when there is one (then nothing says "client": there is no other to mix with).
    public static func exportCopyWords(client: String?) -> String {
        let tail = " It holds no key or token. Only you can read the file; keep it somewhere only you can reach."
        guard let client else {
            return "The copy holds your organizations' snapshots (serial numbers, device models, services and the people's Managed Apple Accounts "
                + "the snapshot policy keeps) and their Needs-attention choices; no history of an organization you removed." + tail
        }
        return "The copy holds \(client)'s snapshots only (serial numbers, device models, services and the people's Managed Apple Accounts the "
            + "snapshot policy keeps) and its Needs-attention choices; no other client's, and no history of an organization you removed." + tail
    }

    /// Writes a copy of the history at `destination`, owner-only (`0600`). With `orgs`, only those organizations' snapshots, items
    /// and findings are in it (every other org's rows are deleted from a private working copy before anything is written to
    /// the destination); nil copies everything.
    ///
    /// - **Private working copy first.** `VACUUM INTO` a file in a folder only this user can enter (the store's own folder, or a
    ///   new `0700` folder under the temporary folder for an in-memory store), the other orgs' rows deleted and the file
    ///   `VACUUM`ed again, so nothing of them survives in its free pages. Nothing is written to the destination until that
    ///   succeeded, and the working copy is removed afterwards.
    /// - **The destination is created by this call, by descriptor, and nothing else.** `open(O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
    ///   0600)`: never wider than `0600`, never through a link. A path that exists, of any kind and empty or not, is refused ("a copy
    ///   never replaces a file; choose a new name") and left untouched: it is never unlinked, truncated or written into, so a file
    ///   another program filled meanwhile, or a descriptor it opened earlier, can't be reached. A folder's inheritable ACL on the new file refuses the export and removes the file. The bytes are copied in, `fsync`ed, and what the path leads to afterwards is
    ///   checked to be that file: regular, one name, `0600`, no ACL, not empty, the same inode; if not, the file this call made is
    ///   removed (only while the path still leads to it). SQLite never opens the destination.
    /// - A symbolic link anywhere above the file is refused (each name `lstat`ed).
    public func exportCopy(to destination: URL, orgs keep: Set<String>? = nil) throws(Failure) {
        let given = destination.path(percentEncoded: false)
        let components = given.split(separator: "/").map(String.init)
        guard destination.isFileURL, given.hasPrefix("/"), !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw .notCopied("\(given) isn't a file path.")
        }
        let path = "/" + components.joined(separator: "/")
        var prefix = ""
        for name in components.dropLast() {
            prefix += "/" + name
            var info = stat()
            guard lstat(prefix, &info) == 0 else { throw .notCopied("\(prefix) couldn't be opened (\(String(cString: strerror(errno)))).") }
            if info.st_mode & S_IFMT == S_IFLNK { throw .notCopied("\(prefix) is a symbolic link; choose a place that isn't behind one.") }
            if info.st_mode & S_IFMT != S_IFDIR { throw .notCopied("\(prefix) isn't a folder.") }
        }
        // A look before the work, so a refusal costs nothing; `O_EXCL` below is what decides.
        var existing = stat()
        if lstat(path, &existing) == 0 {
            throw .notCopied(Self.exists(path))
        } else if errno != ENOENT {
            throw .notCopied("\(path) couldn't be looked at (\(String(cString: strerror(errno)))).")
        }
        if let home { Self.removeLeftovers(in: home) }
        let (folder, made) = try workFolder()
        let work = folder + "/export-\(UUID().uuidString).tmp"
        defer {
            unlink(work)
            unlink(work + "-journal")
            if made { rmdir(folder) }
        }
        try Self.guarded {
            // A newer file is opened `query_only`, which refuses even this: `VACUUM INTO` writes the new file and nothing in
            // this one, so the pragma is lifted for that one statement and put back.
            if case .readOnly = access { try database.execute("PRAGMA query_only = OFF") }
            defer { if case .readOnly = access { try? database.execute("PRAGMA query_only = ON") } }
            try database.run("VACUUM INTO ?", [.text(work)])
        }
        if let keep { try Self.narrow(work, to: keep) }
        try hook?(.beforeCreate(path: path))
        try Self.copy(work, to: path, hook: hook)
    }

    /// The folder for the working copy: the store's own (`0700`), or a new one only this user can enter.
    private func workFolder() throws(Failure) -> (path: String, made: Bool) {
        if let home { return (home, false) }
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path(percentEncoded: false), nil) else {
            throw .notCopied("the temporary folder couldn't be found.")
        }
        defer { free(resolved) }
        let folder = String(cString: resolved) + "/swiftabapit-export-\(UUID().uuidString)"
        guard mkdir(folder, 0o700) == 0 else { throw .notCopied("a private working folder couldn't be made (\(String(cString: strerror(errno)))).") }
        return (folder, true)
    }

    /// The working copy with only `keep`'s orgs' rows, free pages included.
    private static func narrow(_ file: String, to keep: Set<String>) throws(Failure) {
        try guarded {
            let copy = try SQLiteDatabase(path: file, flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_NOFOLLOW)
            try copy.execute("PRAGMA foreign_keys = ON")
            let list = StoredJSON.text(.array(keep.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { .string($0) }))
            try copy.run("DELETE FROM snapshots WHERE org_id NOT IN (SELECT value FROM json_each(?))", [.text(list)])
            try copy.run("DELETE FROM attention WHERE org_id NOT IN (SELECT value FROM json_each(?))", [.text(list)])
            // AUTOINCREMENT's counter would say how many snapshots the other orgs had: it is set to the highest id kept. The ids
            // that remain keep their numbers (renumbering would break nothing here, but is not needed), so gaps show.
            try copy.execute("UPDATE sqlite_sequence SET seq = (SELECT COALESCE(MAX(id), 0) FROM snapshots) WHERE name = 'snapshots'")
            try copy.execute("VACUUM")
        }
    }

    static func exists(_ path: String) -> String { "\(path) already exists. A copy never replaces a file; choose a new name." }

    /// A working copy a crash left behind (`export-<UUID>.tmp`, and its journal) in the store's own folder: only that pattern, only
    /// regular files, only there.
    static func removeLeftovers(in folder: String) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
        for name in names where isWorkingName(name) {
            var info = stat()
            if lstat(folder + "/" + name, &info) == 0, info.st_mode & S_IFMT == S_IFREG { unlink(folder + "/" + name) }
        }
    }

    /// `export-<UUID>.tmp` or its `-journal`, exactly: what `exportCopy` names its working copy.
    static func isWorkingName(_ name: String) -> Bool {
        var rest = Substring(name)
        guard rest.hasPrefix("export-") else { return false }
        rest = rest.dropFirst("export-".count)
        if rest.hasSuffix("-journal") { rest = rest.dropLast("-journal".count) }
        guard rest.hasSuffix(".tmp") else { return false }
        let uuid = rest.dropLast(".tmp".count)
        return UUID(uuidString: String(uuid)) != nil && uuid.count == 36
    }

    /// Whether `fd` has an access control list (a folder's inheritable `everyone allow read` is one): it is a way for others to read.
    private static func hasACL(_ fd: Int32) -> Bool {
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else { return false }
        acl_free(UnsafeMutableRawPointer(acl))
        return true
    }

    private static func copy(_ work: String, to path: String, hook: Hook?) throws(Failure) {
        let source = open(work, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw .notCopied("the working copy couldn't be read (\(String(cString: strerror(errno)))).") }
        defer { close(source) }
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            throw .notCopied(errno == EEXIST ? exists(path) : "\(path) couldn't be made (\(String(cString: strerror(errno)))).")
        }
        defer { close(fd) }
        var mine = stat()
        // Not removed if it can't be identified: without its inode there is no telling it is still ours, so it is left, and said.
        guard fstat(fd, &mine) == 0 else {
            throw .notCopied("\(path) was made but couldn't be read (\(String(cString: strerror(errno)))); it was left where it is, empty. Remove it and try again.")
        }
        do throws(Failure) {
            // An ACL inherited from the folder is refused, not stripped: until it was stripped, another user it names could have
            // opened the empty file and kept that descriptor. The file is ours, so it is removed (below).
            if hasACL(fd) {
                throw Failure.notCopied("this folder gives others access to new files (an access control list it passes on); choose another folder.")
            }
            var buffer = [UInt8](repeating: 0, count: 1 << 20)
            while true {
                let count = read(source, &buffer, buffer.count)
                guard count >= 0 else { throw Failure.notCopied("the working copy couldn't be read (\(String(cString: strerror(errno)))).") }
                if count == 0 { break }
                var done = 0
                while done < count {
                    let wrote = buffer.withUnsafeBytes { write(fd, $0.baseAddress! + done, count - done) }
                    guard wrote > 0 else { throw Failure.notCopied("\(path) couldn't be written (\(String(cString: strerror(errno)))).") }
                    done += wrote
                }
            }
            guard fsync(fd) == 0 else { throw Failure.notCopied("\(path) couldn't be saved (\(String(cString: strerror(errno)))).") }
            try hook?(.copied(path: path))
            var after = stat(), linked = stat()
            guard fstat(fd, &after) == 0, lstat(path, &linked) == 0, linked.st_mode & S_IFMT == S_IFREG, linked.st_dev == mine.st_dev, linked.st_ino == mine.st_ino,
                  after.st_nlink == 1, after.st_mode & 0o077 == 0, after.st_size > 0, !hasACL(fd) else {
                throw Failure.notCopied("\(path) isn't the private file the copy was written to. Nothing there can be trusted; remove it and try again.")
            }
        } catch {
            // Whole or absent: this call made the file, so it is removed, but only while the path still leads to it.
            var linked = stat()
            if lstat(path, &linked) == 0, linked.st_ino == mine.st_ino, linked.st_dev == mine.st_dev { unlink(path) }
            throw error
        }
    }
}
