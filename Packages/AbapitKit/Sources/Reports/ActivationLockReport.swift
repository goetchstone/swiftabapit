import AppleModels
import Foundation
import JSONAPI

/// The Activation Lock report (plan Phase 3): devices by who holds the lock. A `USER` lock, a person's Apple Account,
/// "blocks redeploy and release" (`ActivationLockStatus.blocksRelease`); an `MDM` lock doesn't. No abapit counterpart.
///
/// The input is the device list plus a map of reads by device id: a device with no entry (a sweep cut short) is
/// `notRead`, counted apart and said, never as unlocked (invariant 8). A lock type this version doesn't know is its own
/// group, shown raw (invariant 10); a value Apple sent in another shape is shown as its JSON text. Nothing here touches
/// a bypass code: only `isLocked` and `lockType` are read. The `blocksRelease` cell is yes or no only where the lock was
/// read and Apple sent an answer it can be judged by.
public struct ActivationLockReport: Sendable {
    public enum Kind: Sendable, Equatable {
        /// `isLocked` and `lockType` `USER`: `blocksRelease`.
        case userLock
        case mdmLock
        /// Locked, by a type this version doesn't know, or `NONE`, or none sent: the raw words.
        case otherLock(String)
        case unlocked
        /// Read, but no `isLocked` Apple sent reads as a yes or no; what it sent, if anything, as text.
        case unclear(String?)
        case notRead(String)
    }

    public struct Row: Sendable, Identifiable {
        public let device: OrgDevice
        public let kind: Kind
        public var id: String { device.id }

        /// The display group: `lock:USER`, `lock:MDM`, `lock:<raw type>`, `unlocked`, `unclear`, `not-read`.
        public var group: String {
            switch kind {
            case .userLock: "lock:USER"
            case .mdmLock: "lock:MDM"
            case .otherLock(let raw): "lock:\(raw)"
            case .unlocked: "unlocked"
            case .unclear: "unclear"
            case .notRead: "not-read"
            }
        }

        /// The filter token the catalog lists: a type this version doesn't know is `lock:other`.
        public var token: String {
            if case .otherLock(let raw) = kind { return raw == "NONE" ? "lock:NONE" : "lock:other" }
            return group
        }

        /// A person's Apple Account holds the lock: the device can't be redeployed or released until it's removed.
        public var blocksRelease: Bool { if case .userLock = kind { true } else { false } }

        /// For the CSV and the words: yes or no only when the lock was read and Apple's answer can be judged; "unknown" for a
        /// lock this version can't place; "not read" for a device whose status wasn't read.
        public var blocksReleaseWords: String {
            switch kind {
            case .userLock: "yes"
            case .mdmLock, .unlocked: "no"
            case .otherLock, .unclear: "unknown"
            case .notRead: "not read"
            }
        }
    }

    public struct Group: Sendable {
        public let key: String
        public let title: String
        public let rows: [Row]
        public var count: Int { rows.count }
    }

    public static let fixedGroups = ["lock:USER", "lock:MDM", "lock:NONE", "lock:other", "unlocked", "unclear", "not-read"]

    public let list: ListRead
    /// In group order (USER, MDM, other types by raw name, unlocked, unclear, not read), then by serial.
    public let rows: [Row]

    /// `reads` is keyed by device id; a device with no entry wasn't reached.
    public init(_ devices: [OrgDevice], reads: [String: DeviceRead<ActivationLockStatus>], list: ListRead = .whole) {
        self.list = list
        rows = devices.map { device in
            switch reads[device.id] {
            case nil: Row(device: device, kind: .notRead("the sweep didn't reach this device"))
            case .notRead(let why)?: Row(device: device, kind: .notRead(why))
            case .read(let status)?: Row(device: device, kind: Self.kind(status))
            }
        }.sorted { a, b in
            let (x, y) = (Self.rank(a.kind), Self.rank(b.kind))
            if x != y { return x < y }
            if a.group != b.group { return byBytes(a.group, b.group) }
            return byBytes(a.device.serialNumber, b.device.serialNumber)
        }
    }

    static func kind(_ status: ActivationLockStatus) -> Kind {
        switch status.isLocked {
        case nil: return .unclear(sent(status.attributes, "isLocked"))
        case false?: return .unlocked
        case true?: break
        }
        if status.blocksRelease { return .userLock }
        if status.lockType == .known(.mdm) { return .mdmLock }
        return .otherLock(sent(status.attributes, "lockType") ?? "not sent")
    }

    static func rank(_ kind: Kind) -> Int {
        switch kind {
        case .userLock: 0
        case .mdmLock: 1
        case .otherLock: 2
        case .unlocked: 3
        case .unclear: 4
        case .notRead: 5
        }
    }

    /// The rows of a catalog token (`lock:other` is every type this version doesn't know) or of a display group.
    public func rows(group: String) -> [Row] { rows.filter { $0.token == group || $0.group == group } }

    /// The groups that have devices, in order.
    public var groups: [Group] {
        var order: [String] = []
        for row in rows where !order.contains(row.group) { order.append(row.group) }
        return order.map { key in Group(key: key, title: Self.title(key), rows: rows.filter { $0.group == key }) }
    }

    static func title(_ key: String) -> String {
        switch key {
        case "lock:USER": "Locked by a person's Apple Account (USER): blocks redeploy and release"
        case "lock:MDM": "Locked by the device management service (MDM)"
        case "unlocked": "Not locked"
        case "unclear": "Read, but Apple sent no readable isLocked: can't say whether it blocks release"
        case "not-read": "Not read: not counted as unlocked"
        default: "Locked, lock type \(key.dropFirst("lock:".count)): can't say whether it blocks release"
        }
    }

    public var blockingRelease: Int { rows.filter(\.blocksRelease).count }
    public var notRead: Int { rows.filter { $0.group == "not-read" }.count }

    /// What the report says, line by line: the list's read, then each group, then what couldn't be judged. A list that wasn't
    /// read says only that.
    public var words: [String] {
        if case .notRead = list { return [list.words] }
        var lines = [list.words]
        lines += groups.map { "\($0.title): \($0.count)" }
        if notRead > 0 { lines.append("\(notRead) devices' Activation Lock status wasn't read; they are not counted as unlocked.") }
        return lines
    }
}
