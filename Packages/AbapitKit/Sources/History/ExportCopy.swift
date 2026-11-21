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
    /// What the Save panel says the copy holds. `client` is the active client's name when the operator has more than one.
    public static func exportCopyWords(client: String?) -> String {
        "The copy holds \(client.map { "\($0)'s" } ?? "this client's") snapshots only (serial numbers, device models, services and the people's "
            + "Managed Apple Accounts the snapshot policy keeps) and its Needs-attention choices; no other client's, and no history of an "
            + "organization you removed. It holds no key or token. Only you can read the file; keep it somewhere only you can reach."
    }

    /// Writes a copy of the history at `destination`, owner-only (`0600`). With `orgs`, only those organizations' snapshots, items
    /// and findings are in it (every other org's rows are deleted from a private working copy before anything is written to
    /// the destination); nil copies everything.
    ///
    /// - **Private working copy first.** `VACUUM INTO` a file in a folder only this user can enter (the store's own folder, or a
    ///   new `0700` folder under the temporary folder for an in-memory store), the other orgs' rows deleted and the file
    ///   `VACUUM`ed again, so nothing of them survives in its free pages. Nothing is written to the destination until that
    ///   succeeded, and the working copy is removed afterwards.
    /// - **The destination is made by this call, by descriptor.** `open(O_CREAT | O_EXCL | O_NOFOLLOW, 0600)`: never wider than
    ///   `0600`, never through a link, and a destination that exists and isn't empty is refused, never replaced. An existing
    ///   *empty* regular file (a Save panel's placeholder) with one name is written into through its descriptor, not replaced
    ///   or unlinked, and narrowed to `0600` before a byte is written. The bytes are copied in, `fsync`ed, and what the path
    ///   leads to afterwards is checked to be that file: regular, one name, `0600`, not empty. SQLite never opens the destination.
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
        // A look before the work, so a refusal costs nothing; the descriptor below is what decides.
        var existing = stat()
        if lstat(path, &existing) == 0 { try Self.refuseUnlessEmptyFile(existing, path) } else if errno != ENOENT {
            throw .notCopied("\(path) couldn't be looked at (\(String(cString: strerror(errno)))).")
        }
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
            try copy.execute("VACUUM")
        }
    }

    private static func refuseUnlessEmptyFile(_ info: stat, _ path: String) throws(Failure) {
        switch info.st_mode & S_IFMT {
        case S_IFLNK: throw .notCopied("\(path) is a symbolic link; choose a name that isn't used.")
        case S_IFREG: break
        default: throw .notCopied("\(path) already exists and isn't a file. Choose a name that isn't used.")
        }
        guard info.st_size == 0 else {
            throw .notCopied("\(path) already exists and isn't empty. Choose a name that isn't used: a copy never replaces a file.")
        }
        guard info.st_nlink == 1 else { throw .notCopied("\(path) has a second name on disk (a hard link).") }
    }

    private static func copy(_ work: String, to path: String, hook: Hook?) throws(Failure) {
        let source = open(work, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard source >= 0 else { throw .notCopied("the working copy couldn't be read (\(String(cString: strerror(errno)))).") }
        defer { close(source) }
        var created = true
        var fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        if fd < 0, errno == EEXIST {
            created = false
            fd = open(path, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else {
                throw .notCopied(errno == ELOOP ? "\(path) is a symbolic link; choose a name that isn't used."
                                 : "\(path) couldn't be opened (\(String(cString: strerror(errno)))).")
            }
        } else if fd < 0 {
            throw .notCopied("\(path) couldn't be made (\(String(cString: strerror(errno)))).")
        }
        defer { close(fd) }
        var mine = stat()
        guard fstat(fd, &mine) == 0 else { throw .notCopied("\(path) couldn't be read (\(String(cString: strerror(errno)))).") }
        do throws(Failure) {
            if !created {
                // The descriptor decides, not the look above: a file swapped in since is refused here.
                try refuseUnlessEmptyFile(mine, path)
                guard fchmod(fd, 0o600) == 0 else { throw Failure.notCopied("\(path) couldn't be made private (\(String(cString: strerror(errno)))).") }
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
                  after.st_nlink == 1, after.st_mode & 0o077 == 0, after.st_size > 0 else {
                throw Failure.notCopied("\(path) isn't the private file the copy was written to. Nothing there can be trusted; remove it and try again.")
            }
        } catch {
            // Whole or absent: a file this call made is removed (only while the path still leads to it), a placeholder emptied.
            var linked = stat()
            if created, lstat(path, &linked) == 0, linked.st_ino == mine.st_ino, linked.st_dev == mine.st_dev { unlink(path) } else if !created { _ = ftruncate(fd, 0) }
            throw error
        }
    }
}
