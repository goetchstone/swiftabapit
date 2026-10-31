import Foundation
import Observation

/// People (plan §8 Phase 2; Appendix B: `/users`, `/user-groups`, `/org-units`): users with every attribute and a
/// user's detail, user groups and their members, org units and their members. Business only: a School org's reads
/// throw `.notInScope`, said as `LoadState.notInScope`, never an empty table. A placeholder the people unit fills.
@MainActor
@Observable
public final class PeopleModel {
    private let orgs: OrgsModel

    public init(orgs: OrgsModel) {
        self.orgs = orgs
    }

    /// Loads unless the active org's data is already here; `force` reads again (Refresh, ⌘R).
    public func load(force: Bool = false) {}
}
