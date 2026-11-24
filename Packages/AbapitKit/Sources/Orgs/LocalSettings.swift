import Foundation
import JSONAPI

/// `settings.json`: this Mac's own settings, in a file in the app's container (never `UserDefaults` or `@AppStorage`:
/// `scripts/check_app.sh` fails a build that uses either). Not a secret and not per org; the folder is injected, as
/// `OrgStore`'s is.
///
/// Written like `orgs.json`: atomically (a `0600` temporary file made `O_EXCL | O_NOFOLLOW`, synced, renamed over the old
/// one), never through a link. The rule it keeps from `orgs.json`'s history: **a file it could not read is never written
/// over.** `load` doesn't throw; it returns the defaults with `blocked` set to why, and `save` then refuses. So a file the
/// app couldn't parse, couldn't open, found to be a link, or that a newer version wrote (its values are read, never
/// changed) stays exactly as it was until the operator deals with it. A file that isn't there yet is not blocked.
/// Keys this version doesn't know are kept and written back, at the top level and among the thresholds.
///
/// It also holds, per client, which Apple device management service is that client's Mosyle Business org (the operator's
/// Q7: a per-client local setting, none by default; where it lives is the coordinating session's proposal): the service's
/// id and the id of the Mosyle org it was set for (the coordinating session's decision, so a client whose Mosyle org was
/// replaced reads the entry as stale), never a name, which is read from Apple each time.
public struct LocalSettings: Sendable, Equatable {
    public static let version = 1
    public static let fileName = "settings.json"

    /// When "Needs attention" raises a finding, in days. The defaults (30, 90, 14, 30) were the coordinating session's
    /// proposal; the operator kept them on 2026-11-20, answering "Keep these defaults (Recommended)".
    public struct Thresholds: Sendable, Equatable {
        /// A device that hasn't checked in to its MDM server for this long (default 30).
        public var checkInDays = 30
        /// AppleCare coverage that ends within this long (default 90).
        public var appleCareExpiringDays = 90
        /// An MDM migration whose deadline is this near (default 14).
        public var migrationDeadlineDays = 14
        /// A service that hasn't connected for this long (default 30).
        public var quietServiceDays = 30

        public init() {}

        /// The most a threshold can be: ten years. A value outside 1...3650 in a file reads as the default.
        public static let range = 1...3650
    }

    public var thresholds = Thresholds()
    /// The version the file said; above `version`, `save` refuses.
    public private(set) var fileVersion = LocalSettings.version
    /// Why `save` refuses, if it does: the file on disk was left as it was.
    public private(set) var blocked: Failure?
    private var extras = JSONObject()
    private var thresholdExtras = JSONObject()
    /// The `mosyle_services` entries as the file holds them, by client id: written back as they were unless changed here.
    private var services = JSONObject()
    /// `mosyle_services` is there and isn't an object: no entry can be read, and the file is never written over.
    private var servicesUnreadable = false
    /// Whether that is all that stops the file being written: the thresholds were read.
    public var mosyleServicesUnreadable: Bool { servicesUnreadable }

    public init() {}

    /// One client's Mosyle service setting as the file holds it.
    public enum MosyleService: Sendable, Equatable {
        /// None set: the default.
        case none
        /// The Apple service's id, and the id of the Mosyle org it was set for.
        case set(service: String, mosyleOrg: String)
        /// The service's id alone, as an earlier build of this screen saved it: with no Mosyle org, it can't be told whether it is
        /// still this client's, so it is never used, and is said.
        case earlierShape(service: String)
        /// It couldn't be read: the file couldn't be, `mosyle_services` isn't an object, or the entry is another shape. Left as it is.
        case unreadable
    }

    /// The service set as `client`'s Mosyle org, as the file holds it.
    public func mosyleService(for client: String) -> MosyleService {
        if servicesUnreadable { return .unreadable }
        // A file that couldn't be read at all holds nothing this version knows; a newer one's values are read.
        if let blocked, case .newerVersion = blocked {} else if blocked != nil { return .unreadable }
        guard let entry = services[client] else { return .none }
        if let service = entry.string, Self.isServiceID(service) { return .earlierShape(service: service) }
        if let object = entry.object, object.count == 2, let service = object["service"]?.string, let org = object["mosyle_org"]?.string,
           Self.isServiceID(service), Self.isServiceID(org) {
            return .set(service: service, mosyleOrg: org)
        }
        return .unreadable
    }

    /// Sets the service that is `client`'s Mosyle org, for the Mosyle org `mosyleOrg`, or, with nil, clears it. Refuses an id
    /// that isn't one (`notAServiceID`), and an entry it couldn't read (`serviceUnreadable`): that is left as it is, never
    /// written over. Nothing is written until `save`.
    public mutating func setMosyleService(_ service: String?, mosyleOrg: String, for client: String) throws(Failure) {
        if mosyleService(for: client) == .unreadable { throw .serviceUnreadable }
        guard let service else {
            services[client] = nil
            return
        }
        guard !client.isEmpty, Self.isServiceID(service), Self.isServiceID(mosyleOrg) else { throw .notAServiceID }
        services[client] = .object(["service": .string(service), "mosyle_org": .string(mosyleOrg)])
    }

    /// Removes `client`'s entry, when it has one this version can read (one it can't is left as it is). Whether anything changed.
    @discardableResult
    public mutating func dropMosyleService(for client: String) -> Bool {
        switch mosyleService(for: client) {
        case .none, .unreadable: return false
        case .set, .earlierShape:
            services[client] = nil
            return true
        }
    }

    /// Whether `text` can be stored as a service's id: 1 to 256 UTF-8 bytes, none of them whitespace, a control or a format
    /// character. Apple's ids are opaque text; this keeps a name or a line of words out of the file, never judges the id.
    public static func isServiceID(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 256 && text.unicodeScalars.allSatisfy { scalar in
            !(scalar.properties.isWhitespace || scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format)
        }
    }

    public enum Failure: Error, Equatable, Sendable {
        /// The file couldn't be opened or read.
        case unreadable(errno: Int32)
        /// A symbolic link where the file should be.
        case link
        /// Not a settings file: not a regular file, too large, or not a JSON object.
        case notASettingsFile
        case newerVersion(Int)
        case unwritable(errno: Int32)
        /// A threshold outside `Thresholds.range`: nothing is written.
        case thresholdOutOfRange(String)
        /// A Mosyle service setting whose client or id isn't one (`isServiceID`): nothing is written.
        case notAServiceID
        /// The client's Mosyle service setting couldn't be read: it is left as it is, never written over.
        case serviceUnreadable

        public var message: String {
            switch self {
            case .unreadable(let code): "The settings file couldn't be read (\(String(cString: strerror(code)))). It was left as it is."
            case .link: "The settings file is a symbolic link. It was left as it is."
            case .notASettingsFile: "The settings file isn't one this app wrote. It was left as it is."
            case .newerVersion(let version): "The settings file was written by a newer abapit (version \(version)); this one won't change it."
            case .unwritable(let code): "The settings file couldn't be saved (\(String(cString: strerror(code))))."
            case .thresholdOutOfRange(let key): "The setting \(key) must be between 1 and 3650 days; nothing was saved."
            case .notAServiceID: "That isn't a device management service's id; nothing was saved."
            case .serviceUnreadable:
                "This client's Mosyle service setting in the settings file couldn't be read. It was left as it is: fix or remove it there, then choose again."
            }
        }
    }

    /// The top-level key of the per-client Mosyle service setting: an object, client id to `{"service": …, "mosyle_org": …}`.
    static let servicesKey = "mosyle_services"

    private static var thresholdKeys: [(key: String, path: WritableKeyPath<Thresholds, Int>)] { [
        ("check_in_days", \.checkInDays), ("applecare_expiring_days", \.appleCareExpiringDays),
        ("migration_deadline_days", \.migrationDeadlineDays), ("quiet_service_days", \.quietServiceDays),
    ] }

    // MARK: the file

    /// The settings in `folder`: the defaults when there is no file, the file's values (a missing or out-of-range one as
    /// its default) when there is, and the defaults with `blocked` set when the file can't be trusted.
    public static func load(from folder: URL) -> LocalSettings {
        var settings = LocalSettings()
        let fd = open(folder.appending(path: fileName).path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return settings }
            settings.blocked = errno == ELOOP ? .link : .unreadable(errno: errno)
            return settings
        }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 1024 * 1024 else {
            settings.blocked = .notASettingsFile
            return settings
        }
        var bytes = [UInt8](repeating: 0, count: Int(info.st_size))
        var total = 0
        while total < bytes.count {
            let got = bytes.withUnsafeMutableBytes { Foundation.read(fd, $0.baseAddress! + total, $0.count - total) }
            guard got > 0 else {
                settings.blocked = got < 0 ? .unreadable(errno: errno) : .notASettingsFile
                return settings
            }
            total += got
        }
        guard let root = JSONValue.parse(String(decoding: bytes[..<total], as: UTF8.self))?.object, let version = root["version"]?.int
        else {
            settings.blocked = .notASettingsFile
            return settings
        }
        settings.fileVersion = version
        if version > Self.version { settings.blocked = .newerVersion(version) }
        // Present but not an object: the file isn't one this version can keep whole, so it is never replaced.
        if let value = root["attention"], value.object == nil {
            settings.blocked = .notASettingsFile
            return settings
        }
        // The Mosyle services the same way, but the thresholds are still read: one bad value never costs the others.
        if let value = root[servicesKey], value.object == nil {
            settings.blocked = .notASettingsFile
            settings.servicesUnreadable = true
        }
        let attention = root["attention"]?.object ?? JSONObject()
        for (key, path) in thresholdKeys {
            if let days = attention[key]?.int, Thresholds.range.contains(days) { settings.thresholds[keyPath: path] = days }
        }
        for (key, value) in attention where !thresholdKeys.contains(where: { $0.key == key }) { settings.thresholdExtras[key] = value }
        settings.services = root[servicesKey]?.object ?? JSONObject()
        for (key, value) in root where !["version", "attention", servicesKey].contains(key) { settings.extras[key] = value }
        return settings
    }

    /// Writes the settings to `folder` atomically. Refuses, writing nothing, when `blocked`; when the file on disk is
    /// unreadable, not JSON, not a regular file, a link or from a newer version *now* (it is read again here, so a file that
    /// became one of those since `load` is never written over); or when a threshold is outside `Thresholds.range` (`load` reads
    /// such a stored value as its default; `save` never writes one). Otherwise it writes this value whole: a value loaded before
    /// the file changed would write over the change, so a caller changing one setting loads the file again, makes the change
    /// and saves that (`OrgsModel.changeSettings`).
    public func save(to folder: URL) throws(Failure) {
        try save(to: folder, beforeRename: nil)
    }

    /// What `save` checks of the values themselves, writing nothing: every threshold within `Thresholds.range`. The demo and the
    /// tests, which keep the settings in memory, check a change by it.
    public func check() throws(Failure) {
        if let blocked { throw blocked }
        for (key, path) in Self.thresholdKeys where !Thresholds.range.contains(thresholds[keyPath: path]) {
            throw .thresholdOutOfRange(key)
        }
    }

    /// `beforeRename` runs with the temporary file written and synced, the old file untouched: a test stops there, as a
    /// crash would. Never set outside the tests.
    func save(to folder: URL, beforeRename: (() throws(Failure) -> Void)?) throws(Failure) {
        if let blocked { throw blocked }
        try check()
        // The file as it is now (a missing one is fine). Not atomic with the rename below: another program writing in
        // that window is out of scope, as for `orgs.json`.
        if let onDisk = Self.load(from: folder).blocked { throw onDisk }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            throw .unwritable(errno: EACCES)
        }
        let final = folder.appending(path: Self.fileName)
        var existing = stat()
        // A link would be replaced by the rename, not followed; refusing says so rather than changing what it was.
        if lstat(final.path, &existing) == 0, existing.st_mode & S_IFMT == S_IFLNK { throw .link }
        var attention = thresholdExtras
        for (key, path) in Self.thresholdKeys {
            let days = thresholds[keyPath: path]
            attention[key] = .number(String(days))
        }
        var root = extras
        root["version"] = .number(String(Self.version))
        root["attention"] = .object(attention)
        if !services.isEmpty { root[Self.servicesKey] = .object(services) }
        let bytes = Array((JSONValue.dumps(.object(root)) + "\n").utf8)
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
        try beforeRename?()
        guard rename(temporary.path, final.path) == 0 else {
            let code = errno
            unlink(temporary.path)
            throw .unwritable(errno: code)
        }
    }
}
