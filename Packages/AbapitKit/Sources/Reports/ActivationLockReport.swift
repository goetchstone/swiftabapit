import AppleModels
import Foundation
import JSONAPI

/// The Activation Lock report (plan Phase 3): devices by who holds the lock. A `USER` lock, a person's Apple Account,
/// "blocks redeploy and release" (`ActivationLockStatus.blocksRelease`); an `MDM` lock doesn't. No abapit counterpart.
///
/// A device whose status wasn't read (the sweep was cut, the role can't read it, the read failed) is `notRead`, counted
/// apart and said, never as unlocked (invariant 8). A lock type this version doesn't know is its own group, shown raw
/// (invariant 10). Nothing here touches a bypass code: only `isLocked` and `lockType` are read.
public struct ActivationLockReport: Sendable {
    public struct Entry: Sendable {
        public let device: OrgDevice
        public let lock: DeviceRead<ActivationLockStatus>

        public init(device: OrgDevice, lock: DeviceRead<ActivationLockStatus>) {
            self.device = device
            self.lock = lock
        }
    }

    public enum Kind: Sendable, Equatable {
        /// `isLocked` and `lockType` `USER`: `blocksRelease`.
        case userLock
        case mdmLock
        /// Locked, by a type this version doesn't know, or `NONE`, or none sent: the raw words.
        case otherLock(String)
        case unlocked
        /// Read, but Apple sent no `isLocked`.
        case unclear
        case notRead(String)
    }

    public struct Row: Sendable, Identifiable {
        public let device: OrgDevice
        public let kind: Kind
        public var id: String { device.id }

        /// The filter token: `lock:USER`, `lock:MDM`, `lock:<raw type>`, `unlocked`, `unclear`, `not-read`.
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

        /// A person's Apple Account holds the lock: the device can't be redeployed or released until it's removed.
        public var blocksRelease: Bool { if case .userLock = kind { true } else { false } }
    }

    public struct Group: Sendable {
        public let key: String
        public let title: String
        public let rows: [Row]
        public var count: Int { rows.count }
    }

    public static let fixedGroups = ["lock:USER", "lock:MDM", "unlocked", "unclear", "not-read"]

    public let list: ListRead
    /// In group order (USER, MDM, other types by raw name, unlocked, unclear, not read), then by serial.
    public let rows: [Row]

    public init(_ entries: [Entry], list: ListRead = .whole) {
        self.list = list
        rows = entries.map { entry in
            switch entry.lock {
            case .notRead(let why): Row(device: entry.device, kind: .notRead(why))
            case .read(let status): Row(device: entry.device, kind: Self.kind(status))
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
        case nil: return .unclear
        case false?: return .unlocked
        case true?: break
        }
        if status.blocksRelease { return .userLock }
        switch status.lockType {
        case .known(.mdm)?: return .mdmLock
        case let type?: return .otherLock(type.rawValue)
        case nil: return .otherLock("not sent")
        }
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

    public func rows(group: String) -> [Row] { rows.filter { $0.group == group } }

    /// The groups that have devices, in order.
    public var groups: [Group] {
        var order: [String] = []
        for row in rows where !order.contains(row.group) { order.append(row.group) }
        return order.map { key in
            let members = rows(group: key)
            return Group(key: key, title: Self.title(key), rows: members)
        }
    }

    static func title(_ key: String) -> String {
        switch key {
        case "lock:USER": "Locked by a person's Apple Account (USER): blocks redeploy and release"
        case "lock:MDM": "Locked by the device management service (MDM)"
        case "unlocked": "Not locked"
        case "unclear": "Read, but Apple sent no lock answer"
        case "not-read": "Not read: not counted as unlocked"
        default: "Locked, lock type \(key.dropFirst("lock:".count))"
        }
    }

    public var blockingRelease: Int { rows.filter(\.blocksRelease).count }
    public var notRead: Int { rows(group: "not-read").count }

    /// What the report says, line by line: the list's read, then each group, then what couldn't be judged.
    public var words: [String] {
        var lines = [list.words]
        lines += groups.map { "\($0.title): \($0.count)" }
        if notRead > 0 { lines.append("\(notRead) devices' Activation Lock status wasn't read; they are not counted as unlocked.") }
        return lines
    }
}
