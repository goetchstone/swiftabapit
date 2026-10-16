import Foundation
import JSONAPI

/// `orgs.json`: the organizations, their non-secret profiles and which is active (plan §3.7). Versioned and
/// tolerant: a profile this version can't use is kept, shown with its problem, and saved back unchanged; a
/// file from a newer version is read but never written over. Written atomically, `0600` from creation,
/// never through a link, in a `0700` folder. The folder is injected, never a global (SwiftGamGui
/// failure-log 2026-09-25: tests touched the real store).
public struct OrgStore: Sendable, Equatable {
    public static let version = 1
    public static let fileName = "orgs.json"

    public private(set) var orgs: [OrgProfile]
    public var activeID: String?
    /// The version the file said; above `version`, `save` refuses.
    public private(set) var fileVersion: Int
    /// Entries of `orgs` this version can't address (no string `id`) and keys of the file it doesn't know: kept and
    /// written back as they were (Phase 1a's review: a load and save deleted them).
    private var unaddressable: [JSONValue] = []
    private var extras = JSONObject()

    public init(orgs: [OrgProfile] = [], activeID: String? = nil) {
        self.orgs = orgs
        self.activeID = activeID
        fileVersion = Self.version
    }

    public var active: OrgProfile? { orgs.first { $0.id == activeID } ?? orgs.first }

    public subscript(id: String) -> OrgProfile? { orgs.first { $0.id == id } }

    public enum Failure: Error, Equatable, Sendable {
        case unreadable(errno: Int32)
        case notAnOrgFile
        case newerVersion(Int)
        case duplicateClientID(String)
        case duplicateID(String)
        case unknownOrg(String)
        case unwritable(errno: Int32)

        public var message: String {
            switch self {
            case .unreadable(let code): "The organizations file couldn't be read (\(String(cString: strerror(code))))."
            case .notAnOrgFile: "The organizations file isn't one this app wrote; it was left as it is."
            case .newerVersion(let version):
                "The organizations file was written by a newer abapit (version \(version)); this one won't change it."
            case .duplicateClientID(let id): "Another organization already uses the client ID \(id)."
            case .duplicateID(let id): "Another organization already has the id \(id)."
            case .unknownOrg(let id): "There's no organization \(id)."
            case .unwritable(let code): "The organizations file couldn't be saved (\(String(cString: strerror(code))))."
            }
        }
    }

    // MARK: editing

    /// abapit's `slugify` (`[^a-z0-9]+` → `-`, trimmed, `org` when empty), kept to 48 characters, then made
    /// unique with `-2`, `-3`, … (abapit's `_unique_slug`).
    /// `avoiding` adds ids that are taken elsewhere: an org removed from this file whose Keychain items are still
    /// stored keeps its id, so a new org never inherits another's secrets (Phase 1a's review).
    public func uniqueID(for name: String, avoiding taken: Set<String> = []) -> String {
        var slug = "", dash = false
        for scalar in name.lowercased().unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                if dash, !slug.isEmpty { slug += "-" }
                dash = false
                slug.unicodeScalars.append(scalar)
            } else {
                dash = true
            }
        }
        slug = String(slug.prefix(48))
        while slug.hasSuffix("-") { slug.removeLast() }
        if slug.isEmpty { slug = "org" }
        var candidate = slug, counter = 2
        while self[candidate] != nil || taken.contains(candidate) {
            candidate = "\(slug)-\(counter)"
            counter += 1
        }
        return candidate
    }

    /// Adds `profile`; the first org becomes active. An Apple org's client ID must be unique.
    public mutating func add(_ profile: OrgProfile) throws(Failure) {
        guard self[profile.id] == nil else { throw .duplicateID(profile.id) }
        try checkClientID(profile, replacing: nil)
        orgs.append(profile)
        if activeID == nil { activeID = profile.id }
    }

    /// Replaces the profile with the same id.
    public mutating func update(_ profile: OrgProfile) throws(Failure) {
        guard let index = orgs.firstIndex(where: { $0.id == profile.id }) else { throw .unknownOrg(profile.id) }
        try checkClientID(profile, replacing: profile.id)
        orgs[index] = profile
    }

    /// Removes the org. Its Keychain items, history and logs are the caller's to offer to delete (defect 14).
    public mutating func remove(_ id: String) {
        orgs.removeAll { $0.id == id }
        if activeID == id { activeID = orgs.first?.id }
        for index in orgs.indices where orgs[index].pairedOrg == id { orgs[index].pairedOrg = "" }
    }

    /// Client IDs compare trimmed and case-insensitively: `BUSINESSAPI.abc ` is `businessapi.ABC` to a person.
    private func checkClientID(_ profile: OrgProfile, replacing: String?) throws(Failure) {
        func key(_ id: String) -> String { id.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard profile.provider == .known(.apple), !key(profile.clientID).isEmpty else { return }
        if orgs.contains(where: { $0.id != replacing && $0.provider == .known(.apple) && key($0.clientID) == key(profile.clientID) }) {
            throw .duplicateClientID(profile.clientID)
        }
    }

    // MARK: the file

    /// The store in `folder`, or an empty one when there's no file yet.
    public static func load(from folder: URL) throws(Failure) -> OrgStore {
        let file = folder.appending(path: fileName)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        if fd < 0, errno == ENOENT { return OrgStore() }
        guard fd >= 0 else { throw .unreadable(errno: errno) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 4 * 1024 * 1024 else { throw .notAnOrgFile }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var total = 0
        while total < bytes.count {
            let got = bytes.withUnsafeMutableBytes { Foundation.read(fd, $0.baseAddress! + total, $0.count - total) }
            guard got > 0 else { break }
            total += got
        }
        guard let root = JSONValue.parse(String(decoding: bytes[..<total], as: UTF8.self))?.object,
              let version = root["version"]?.int, let list = root["orgs"]?.array else { throw .notAnOrgFile }
        var usable: [OrgProfile] = [], kept: [JSONValue] = [], ids: Set<String> = []
        for entry in list {
            if let object = entry.object, let id = object["id"]?.string, !id.isEmpty, ids.insert(id).inserted {
                usable.append(OrgProfile(raw: object))
            } else {
                kept.append(entry)
            }
        }
        var store = OrgStore(orgs: usable, activeID: root["active"]?.string)
        store.fileVersion = version
        store.unaddressable = kept
        for (key, value) in root where !["version", "active", "orgs"].contains(key) { store.extras[key] = value }
        return store
    }

    /// Writes the store to `folder` atomically: a `0600` temporary file made with `O_EXCL | O_NOFOLLOW`,
    /// synced, then renamed over the old one. Refuses a file from a newer version.
    public func save(to folder: URL) throws(Failure) {
        guard fileVersion <= Self.version else { throw .newerVersion(fileVersion) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw .unwritable(errno: EACCES)
        }
        var root = JSONObject()
        root["version"] = .number(String(Self.version))
        if let activeID { root["active"] = .string(activeID) }
        root["orgs"] = .array(orgs.map { .object($0.raw) } + unaddressable)
        for (key, value) in extras { root[key] = value }
        let bytes = Array((JSONValue.dumps(.object(root)) + "\n").utf8)
        let final = folder.appending(path: Self.fileName)
        let temporary = folder.appending(path: ".\(Self.fileName).\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw .unwritable(errno: errno) }
        var written = 0
        while written < bytes.count {
            let count = bytes.withUnsafeBytes { Foundation.write(fd, $0.baseAddress! + written, $0.count - written) }
            guard count > 0 else {
                let code = errno
                close(fd)
                unlink(temporary.path)
                throw .unwritable(errno: code)
            }
            written += count
        }
        guard fsync(fd) == 0, close(fd) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw .unwritable(errno: code)
        }
        guard rename(temporary.path, final.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw .unwritable(errno: code)
        }
    }
}
