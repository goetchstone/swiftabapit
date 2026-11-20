import AppleModels
import Foundation

/// What the app has already read, to name a blueprint's members. Apple's blueprint reads give each member as an ID and
/// nothing else (`include` is refused live, and no related-resource endpoint exists), so a name can only come from a list
/// the app loaded for its own screen: Content's apps, packages and configurations, People's users and groups, the Devices
/// screen's devices. No read is made to name a member, and a list nobody opened is never loaded for it: its members stay
/// IDs, and the detail says so (`ContentWords.naming`, invariant 8).
///
/// Each list is the active org's: an org switch empties every model's list at once (`orgChanged`), so a lookup made after
/// it can't see the old org's rows, and a list still loading for the new org is "not read" until it ends.
package struct MemberNames: Sendable, Equatable {
    /// One relationship's list as far as the app has read it.
    package enum Source: Sendable, Equatable {
        /// Read to its end or cut at the page cap (`whole` is false then): a member missing from a cut list may be past the cut.
        case read([String: String], whole: Bool)
        /// Idle or still loading: nothing to name from yet.
        case notRead
        /// Refused, failed, not in this org's scope or the org unusable: the screen shows why.
        case unreadable
    }

    package var sources: [Blueprint.Relationship: Source]

    package init(_ sources: [Blueprint.Relationship: Source] = [:]) { self.sources = sources }

    /// A list that nothing has been read for.
    package subscript(relationship: Blueprint.Relationship) -> Source { sources[relationship] ?? .notRead }

    /// A list's names as a source, by its load state: only a list that ended is named from, and a failed or refused walk's
    /// partial rows aren't (the screen shows them as partial; a name from them could be taken for a whole list's).
    package static func source(_ state: LoadState, truncated: Bool, names: () -> [String: String]) -> Source {
        switch state {
        case .idle, .loading: .notRead
        case .loaded: .read(names(), whole: !truncated)
        case .forbidden, .failed, .unusable, .notInScope: .unreadable
        }
    }

    /// `pairs` by id, the first of a repeated id kept.
    package static func byID(_ pairs: [(id: String, name: String)]) -> [String: String] {
        Dictionary(pairs.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}

extension MemberNames {
    /// The lists the Devices and People screens have read, each as its own row shows a member: a device by its serial and
    /// model, a user by the Users table's name, a group by the Groups table's.
    @MainActor
    package static func sources(devices: DevicesModel, people: PeopleModel) -> [Blueprint.Relationship: Source] {
        [
            .orgDevices: source(devices.state, truncated: devices.truncated) {
                byID(devices.rows.map { ($0.id, $0.model.isEmpty ? $0.serial : "\($0.serial) · \($0.model)") })
            },
            .users: source(people.users.state, truncated: people.users.truncated) {
                byID(people.users.rows.map { ($0.id, $0.name) })
            },
            .userGroups: source(people.groups.state, truncated: people.groups.truncated) {
                byID(people.groups.rows.map { ($0.id, PeopleModel.text($0.name)) })
            },
        ]
    }
}
