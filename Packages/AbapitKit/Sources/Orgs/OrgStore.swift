import Foundation
import JSONAPI

/// `orgs.json`: the organizations, their non-secret profiles, which is active, and the clients they belong to (plan §3.7,
/// §8.0 "Clients"). Versioned and tolerant: a profile this version can't use is kept, shown with its problem, and saved back
/// unchanged; a file from a newer version is read but never written over. A version-1 file, written before clients, is
/// grouped into clients when it is read (`group`), the same way every time, and saved as version 2 by the app; its Keychain
/// items, keyed by org, are never touched. Written atomically, `0600` from creation,
/// never through a link, in a `0700` folder. The folder is injected, never a global (SwiftGamGui
/// failure-log 2026-09-25: tests touched the real store).
public struct OrgStore: Sendable, Equatable {
    public static let version = 2
    public static let fileName = "orgs.json"

    public private(set) var orgs: [OrgProfile]
    public var activeID: String?
    /// Every org in exactly one client, each client with at least one org (`normalize`).
    public private(set) var clients: [Client] = []
    /// What grouping a version-1 file changed that the operator should hear about once: a Mosyle org two Apple orgs were
    /// paired with stays with one of them. Kept, with the old `paired_org` values, until Settings has shown it.
    public private(set) var migrationNotes: [String] = []
    /// Whether this store was grouped into clients from a file (or profiles) that had none: the app saves it at once.
    public private(set) var migrated = false
    /// The version the file said; above `version`, `save` refuses.
    public private(set) var fileVersion: Int
    /// Entries of `orgs` this version can't address (no string `id`) and keys of the file it doesn't know: kept and
    /// written back as they were (Phase 1a's review: a load and save deleted them).
    private var unaddressable: [JSONValue] = []
    private var extras = JSONObject()

    /// A store of `orgs`, grouped into clients as a version-1 file is (`group`): the demo's and the tests' stores are made so.
    public init(orgs: [OrgProfile] = [], activeID: String? = nil) {
        self.orgs = orgs
        self.activeID = activeID
        fileVersion = Self.version
        (clients, migrationNotes) = Self.group(orgs, active: activeID)
        migrated = !orgs.isEmpty
        // No active org recorded: the default client's lead, so the app opens on the client grouping made first (the
        // review of PR 18: `active` fell back to the first org, which could be another client's Mosyle org).
        if activeID == nil { self.activeID = clients.first.flatMap { $0.apple ?? $0.mdm } }
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
        case unknownClient(String)
        /// The client already has an org in the place this one takes (one Apple org, one MDM org).
        case clientFull(String)
        case clientNameTaken(String)
        case clientNameEmpty

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
            // In a customer's words, not "client": with one client the app shows none, and an add sheet can still meet these
            // when another sheet's save got there first (the operator, 2026-11-12: "lets make it friendly").
            case .unknownClient: "That customer isn't set up any more: choose again."
            case .clientFull(let name): "\(name) already has an organization of that kind: a customer has one Apple organization and one MDM organization."
            case .clientNameTaken(let name): "Another client is already called \(name)."
            case .clientNameEmpty: "A client needs a name."
            }
        }
    }

    // MARK: editing

    /// abapit's `slugify` (`[^a-z0-9]+` → `-`, trimmed, `org` when empty), kept to 48 characters, then made
    /// unique with `-2`, `-3`, … (abapit's `_unique_slug`).
    /// `avoiding` adds ids that are taken elsewhere: an org removed from this file whose Keychain items are still
    /// stored keeps its id, so a new org never inherits another's secrets (Phase 1a's review).
    public func uniqueID(for name: String, avoiding taken: Set<String> = []) -> String {
        let slug = Self.slug(name)
        var candidate = slug, counter = 2
        while self[candidate] != nil || taken.contains(candidate) {
            candidate = "\(slug)-\(counter)"
            counter += 1
        }
        return candidate
    }

    static func slug(_ name: String) -> String {
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
        return slug
    }

    /// Adds `profile` to the client `target`, which must have no org of its kind (one Apple org, one MDM org), or, with nil,
    /// as a client of its own named after it; the first org becomes active. An Apple org's client ID must be unique. Whole or
    /// not at all: a refusal leaves the store as it was.
    ///
    /// A new org never joins a client by itself: `target` is the operator's answer to the add sheet's question, which
    /// customer the org is for (plan §8.0, "Clients"; the review of PR 18: an Add that joined the active client paired two
    /// customers' orgs with nothing on screen to show it; defect 17).
    public mutating func add(_ profile: OrgProfile, to target: String? = nil) throws(Failure) {
        guard self[profile.id] == nil else { throw .duplicateID(profile.id) }
        try checkClientID(profile, replacing: nil)
        let slot = Client.Slot(profile)
        var joined: Int?
        if let target {
            guard let index = clients.firstIndex(where: { $0.id == target }) else { throw .unknownClient(target) }
            guard !clients[index].has(slot) else { throw .clientFull(clients[index].name) }
            joined = index
        }
        orgs.append(profile)
        if activeID == nil { activeID = profile.id }
        if let joined {
            clients[joined].set(slot, profile.id)
        } else {
            clients.append(newClient(for: profile))
        }
    }

    /// The clients a new org of `slot`'s kind could join: those with no org in that place, in the store's order.
    public func clients(withRoomFor slot: Client.Slot) -> [Client] { clients.filter { !$0.has(slot) } }

    /// Replaces the profile with the same id.
    public mutating func update(_ profile: OrgProfile) throws(Failure) {
        guard let index = orgs.firstIndex(where: { $0.id == profile.id }) else { throw .unknownOrg(profile.id) }
        try checkClientID(profile, replacing: profile.id)
        orgs[index] = profile
    }

    /// Removes the org, and its client when it was the client's last. Its Keychain items, history and logs are the caller's
    /// to offer to delete (defect 14). The org that becomes active is the client's other one when there is one.
    public mutating func remove(_ id: String) {
        let sibling = client(of: id)?.orgs.first { $0 != id }
        let (leaving, left) = (self[id], client(of: id)?.id)
        orgs.removeAll { $0.id == id }
        if activeID == id { activeID = sibling ?? orgs.first?.id }
        for index in orgs.indices where orgs[index].pairedOrg == id { orgs[index].pairedOrg = "" }
        for index in clients.indices {
            if clients[index].apple == id { clients[index].apple = nil }
            if clients[index].mdm == id { clients[index].mdm = nil }
        }
        clients.removeAll { $0.orgs.isEmpty }
        if let leaving, let left { renameClient(left, leftBy: leaving) }
        // A note about how clients were made means nothing once there is one client left, and none shows with one.
        if clients.count < 2, !migrationNotes.isEmpty { dismissMigrationNotes() }
    }

    // MARK: clients

    public func client(of org: String) -> Client? { clients.first { $0.holds(org) } }

    public subscript(client id: String) -> Client? { clients.first { $0.id == id } }

    /// The active org's client.
    public var activeClient: Client? { active.flatMap { client(of: $0.id) } }

    /// Moves `org` to the client `target` (nil: a new client of its own, named after it), which must have no org of its
    /// kind. The client it leaves is removed when it is left with none. Settings undoes a join with it.
    public mutating func move(_ org: String, to target: String?) throws(Failure) {
        guard let profile = self[org] else { throw .unknownOrg(org) }
        let slot = Client.Slot(profile)
        if let target {
            guard let index = clients.firstIndex(where: { $0.id == target }) else { throw .unknownClient(target) }
            guard !clients[index].holds(org) else { return }
            guard !clients[index].has(slot) else { throw .clientFull(clients[index].name) }
        } else if client(of: org)?.orgs == [org] {
            return
        }
        let left = client(of: org)?.id
        for index in clients.indices where clients[index].holds(org) { clients[index].set(slot, nil) }
        clients.removeAll { $0.orgs.isEmpty }
        if let left { renameClient(left, leftBy: profile) }
        if let target, let index = clients.firstIndex(where: { $0.id == target }) {
            clients[index].set(slot, org)
        } else {
            clients.append(newClient(for: profile))
        }
        clients.removeAll { $0.orgs.isEmpty }
    }

    /// Renames a client. Names are unique, compared trimmed and without case.
    public mutating func renameClient(_ id: String, to name: String) throws(Failure) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw .clientNameEmpty }
        guard let index = clients.firstIndex(where: { $0.id == id }) else { throw .unknownClient(id) }
        if let taken = clients.first(where: { $0.id != id && Self.nameKey($0.name) == Self.nameKey(trimmed) }) { throw .clientNameTaken(taken.name) }
        clients[index].name = trimmed
    }

    /// The migration's notes have been shown: they go, and with them the `paired_org` values they spoke of.
    public mutating func dismissMigrationNotes() {
        migrationNotes = []
        for index in orgs.indices where !orgs[index].pairedOrg.isEmpty { orgs[index].pairedOrg = "" }
    }

    /// A client name as uniqueness compares it: trimmed, without case, and with `/` and `:` as `-`, the form an export's file
    /// name takes (`ScreenWords.filename`), so two clients' files can never share a name, on a volume that ignores case too.
    static func nameKey(_ name: String) -> String {
        String(String.UnicodeScalarView(name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().unicodeScalars.map {
            $0 == "/" || $0 == ":" ? "-" : $0
        }))
    }

    /// A client named after `profile` (its name, else its id), the name made unique with " (2)", " (3)"….
    private func newClient(for profile: OrgProfile) -> Client {
        Self.client(for: profile, slot: Client.Slot(profile), other: nil, among: clients)
    }

    /// The name a client made for `profile` starts from: its name, trimmed, else its id.
    static func baseName(_ profile: OrgProfile) -> String {
        let trimmed = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? profile.id : trimmed
    }

    /// `base`, or `base (2)`, `base (3)`… : the first no client in `clients` has, as uniqueness compares names.
    static func uniqueName(_ base: String, among clients: [Client]) -> String {
        var name = base, counter = 2
        while clients.contains(where: { nameKey($0.name) == nameKey(name) }) {
            name = "\(base) (\(counter))"
            counter += 1
        }
        return name
    }

    /// Whether `name` is one a client made for an org called `base` gets: `base`, or `base` made unique (" (2)"…).
    static func isNamed(_ name: String, after base: String) -> Bool {
        let key = nameKey(name), stem = nameKey(base)
        guard key != stem else { return true }
        guard key.hasPrefix(stem + " ("), key.hasSuffix(")") else { return false }
        let digits = key.dropFirst(stem.count + 2).dropLast()
        return !digits.isEmpty && digits.allSatisfy { ("0"..."9").contains($0) }
    }

    /// After `profile` left the client `id`, by a move or a removal: when that client is still named after it and holds
    /// another org, it takes that org's name, so no client is named after an org it doesn't hold (the review of PR 19: after
    /// Separate, the Mosyle org's client kept the Apple org's name, on its exports and in the switcher). A name the operator
    /// gave is kept. Called before the leaving org's new client is made, so that one gets its own name back cleanly.
    private mutating func renameClient(_ id: String, leftBy profile: OrgProfile) {
        guard let index = clients.firstIndex(where: { $0.id == id }), Self.isNamed(clients[index].name, after: Self.baseName(profile)),
              let staying = clients[index].orgs.first.flatMap({ self[$0] }) else { return }
        let others = clients.enumerated().filter { $0.offset != index }.map(\.element)
        clients[index].name = Self.uniqueName(Self.baseName(staying), among: others)
    }

    static func client(for profile: OrgProfile, slot: Client.Slot, other: String?, among clients: [Client]) -> Client {
        let base = baseName(profile)
        let name = uniqueName(base, among: clients)
        let slug = slug(base)
        var id = slug, number = 2
        while clients.contains(where: { $0.id == id }) {
            id = "\(slug)-\(number)"
            number += 1
        }
        var client = Client(id: id, name: name, apple: nil, mdm: nil)
        client.set(slot, profile.id)
        if let other { client.set(slot == .apple ? .mdm : .apple, other) }
        return client
    }

    /// Version 1's orgs grouped into clients, the same way every time (the operator's decision, 2026-11-12, and the details
    /// the parent session added):
    /// - The default client takes the active org if one is set, else the first Apple org in the store's order (never a
    ///   dictionary's), with the Mosyle org its `paired_org` names; when the active org is a Mosyle org, the first Apple org
    ///   paired with it joins it.
    /// - Every other Apple org, in the store's order, is a client of its own, with its paired Mosyle org unless a client
    ///   before it took that one: then a note says where the pairing went.
    /// - Every Mosyle org left, and any org of a provider this version doesn't know, is a client of its own with no Apple
    ///   org.
    /// - Names come from the client's first org, made unique with " (2)", " (3)"….
    public static func group(_ orgs: [OrgProfile], active: String?) -> (clients: [Client], notes: [String]) {
        var clients: [Client] = [], notes: [String] = [], placed: Set<String> = []
        func profile(_ id: String) -> OrgProfile? { orgs.first { $0.id == id } }
        func mosylePair(of apple: OrgProfile) -> OrgProfile? {
            profile(apple.pairedOrg).flatMap { $0.provider == .known(.mosyle) ? $0 : nil }
        }
        func title(_ org: OrgProfile) -> String { org.name.isEmpty ? org.id : org.name }
        func take(_ org: OrgProfile, with other: OrgProfile?) {
            let client = client(for: org, slot: Client.Slot(org), other: other?.id, among: clients)
            clients.append(client)
            placed.insert(org.id)
            if let other { placed.insert(other.id) }
        }
        let apples = orgs.filter { $0.provider == .known(.apple) }
        let lead = active.flatMap(profile) ?? apples.first
        if let lead {
            if lead.provider == .known(.apple) {
                take(lead, with: mosylePair(of: lead))
            } else if lead.provider == .known(.mosyle), let apple = apples.first(where: { mosylePair(of: $0)?.id == lead.id }) {
                take(apple, with: lead)
            } else {
                take(lead, with: nil)
            }
        }
        for apple in apples where !placed.contains(apple.id) {
            let pair = mosylePair(of: apple)
            if let pair, placed.contains(pair.id) {
                let holder = clients.first { $0.holds(pair.id) }?.name ?? ""
                notes.append("\(title(apple)) was paired with \(title(pair)), which stays with the client \(holder); \(title(apple)) is a client of its own.")
                take(apple, with: nil)
            } else {
                take(apple, with: pair)
            }
        }
        for org in orgs where !placed.contains(org.id) { take(org, with: nil) }
        return (clients, notes)
    }

    /// Every org in exactly one client, each client with at least one org, a client's places holding orgs of their kind:
    /// a version-2 file is read through this, so a hand edit or a newer version's store can't leave an org in no client or
    /// in two. What it can't keep (a client naming an org that isn't there, a second claim) is dropped; an org left out
    /// becomes a client of its own.
    mutating func normalize() {
        var seen: Set<String> = [], ids: Set<String> = [], kept: [Client] = []
        for var client in clients {
            // A client with no id, or one already used, claims nothing: its orgs are left for the clients that hold them.
            guard !client.id.isEmpty, ids.insert(client.id).inserted else { continue }
            // A name empty, or one another client before it has (as uniqueness compares names), is made unique as a new one is.
            let trimmed = client.name.trimmingCharacters(in: .whitespacesAndNewlines)
            client.name = Self.uniqueName(trimmed.isEmpty ? client.id : trimmed, among: kept)
            for slot in [Client.Slot.apple, .mdm] {
                guard let org = slot == .apple ? client.apple : client.mdm else { continue }
                if let profile = self[org], Client.Slot(profile) == slot, seen.insert(org).inserted { continue }
                client.set(slot, nil)
            }
            if !client.orgs.isEmpty { kept.append(client) }
        }
        clients = kept
        for profile in orgs where !seen.contains(profile.id) { clients.append(newClient(for: profile)) }
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
        if version >= 2, let list = root["clients"]?.array {
            // Clients written by version 2 or later: read, then held to the rules; nothing is grouped again. A newer
            // version's file keeps its version, so `save` still refuses it.
            store.clients = list.compactMap(\.object).map(Client.init(raw:))
            store.migrationNotes = (root["migration_notes"]?.array ?? []).compactMap(\.string)
            store.migrated = false
            store.normalize()
        } else if version < 2 {
            // Version 1: grouped once (`group`, done by `init` above); the app saves the store as version 2.
            store.fileVersion = Self.version
        }
        // A version-2 or newer file with no clients is grouped as version 1 is (`init` above), its pairs kept together.
        for (key, value) in root where !["version", "active", "orgs", "clients", "migration_notes"].contains(key) { store.extras[key] = value }
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
        root["clients"] = .array(clients.map { .object($0.raw) })
        if !migrationNotes.isEmpty { root["migration_notes"] = .array(migrationNotes.map(JSONValue.string)) }
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
