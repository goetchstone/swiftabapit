import Darwin
import Foundation

/// A copy of the snapshot history for `sqlite3` or Datasette (plan Phase 3, "Export a copy"): `VACUUM INTO` a file the
/// operator chose, so the copy is one consistent database that doesn't depend on this app's file or its journal.
///
/// The copy holds everything the history holds: every organization's snapshots (serials, device models, services, people's
/// Managed Apple Accounts as the snapshot policy keeps them) and the Needs-attention findings and the operator's dismissals.
/// No key, token or secret is ever in the history, so none is in the copy. It is the owner's alone (`0600`) from the moment
/// it exists.
extension SnapshotStore {
    /// What the Save panel says the file will hold (the operator asked for this wording's content, 2026-11-20: "what the file
    /// holds"); the app shows it as the panel's message.
    public static let exportCopyWords = "The copy holds every organization's snapshots: serial numbers, device models, services and the people's "
        + "Managed Apple Accounts the snapshot policy keeps, and your Needs-attention choices. It holds no key or token. Only you can read the file; "
        + "keep it somewhere only you can reach."

    /// Writes a copy of the history at `destination`, owner-only (`0600`).
    ///
    /// - A destination that exists and isn't empty is refused, never replaced. An existing empty file (a Save panel's
    ///   placeholder) is replaced by the copy: SQLite refuses to write into any file that exists, so the empty one is removed
    ///   first (a regular file with one name only). A symbolic link anywhere on the path, or as the file, is refused, and a file
    ///   with a second name (a hard link) is refused.
    /// - SQLite makes the file itself (`VACUUM INTO` needs a name), so the call runs with the process's `umask` at `077`: the
    ///   file is `0600` from the instant it exists, never made wider and narrowed. A narrower `umask` is only ever safer for
    ///   what another thread makes meanwhile. The path is opened by a connection that doesn't follow links when the store is
    ///   a file (`SQLITE_OPEN_NOFOLLOW`), and what the path leads to afterwards is checked: a regular file, one name,
    ///   `0600`, not empty.
    public func exportCopy(to destination: URL) throws(Failure) {
        let given = destination.path(percentEncoded: false)
        let components = given.split(separator: "/").map(String.init)
        guard destination.isFileURL, given.hasPrefix("/"), !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }) else {
            throw .notCopied("\(given) isn't a file path.")
        }
        let path = "/" + components.joined(separator: "/")
        // No link on the way: each name above the file is looked at without following it.
        var prefix = ""
        for name in components.dropLast() {
            prefix += "/" + name
            var info = stat()
            guard lstat(prefix, &info) == 0 else { throw .notCopied("\(prefix) couldn't be opened (\(String(cString: strerror(errno)))).") }
            if info.st_mode & S_IFMT == S_IFLNK { throw .notCopied("\(prefix) is a symbolic link; choose a place that isn't behind one.") }
            if info.st_mode & S_IFMT != S_IFDIR { throw .notCopied("\(prefix) isn't a folder.") }
        }
        var existing = stat()
        if lstat(path, &existing) == 0 {
            switch existing.st_mode & S_IFMT {
            case S_IFLNK: throw .notCopied("\(path) is a symbolic link; choose a name that isn't used.")
            case S_IFREG: break
            default: throw .notCopied("\(path) already exists and isn't a file. Choose a name that isn't used.")
            }
            guard existing.st_size == 0 else {
                throw .notCopied("\(path) already exists and isn't empty. Choose a name that isn't used: a copy never replaces a file.")
            }
            guard existing.st_nlink == 1 else { throw .notCopied("\(path) has a second name on disk (a hard link).") }
            guard unlink(path) == 0 else { throw .notCopied("\(path) couldn't be replaced (\(String(cString: strerror(errno)))).") }
        } else if errno != ENOENT {
            throw .notCopied("\(path) couldn't be looked at (\(String(cString: strerror(errno)))).")
        }
        let before = umask(0o077)
        defer { umask(before) }
        do throws(Failure) {
            try Self.guarded {
                // A newer file is opened `query_only`, which refuses even this: `VACUUM INTO` writes the new file and nothing in
                // this one, so the pragma is lifted for that one statement and put back.
                if case .readOnly = access { try database.execute("PRAGMA query_only = OFF") }
                defer { if case .readOnly = access { try? database.execute("PRAGMA query_only = ON") } }
                try database.run("VACUUM INTO ?", [.text(path)])
            }
            var after = stat()
            guard lstat(path, &after) == 0, after.st_mode & S_IFMT == S_IFREG, after.st_nlink == 1, after.st_mode & 0o077 == 0, after.st_size > 0 else {
                throw Failure.notCopied("\(path) isn't the file the copy was written to. Nothing there can be trusted; remove it and try again.")
            }
        } catch {
            // What SQLite left of a copy that failed is not kept: a regular file with one name and nothing else is removed.
            var left = stat()
            if lstat(path, &left) == 0, left.st_mode & S_IFMT == S_IFREG, left.st_nlink == 1 { unlink(path) }
            throw error
        }
    }
}
