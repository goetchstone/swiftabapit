import Foundation
import Observation

/// Content (plan §8 Phase 2; Appendix B: `/apps`, `/packages`, `/blueprints`, `/configurations`): each list and its
/// detail; a blueprint's members (a refused include is said, with no count); a configuration's profile only as
/// `customSettings?.profileText`, masked (invariant 11). Business only. A placeholder the content unit fills.
@MainActor
@Observable
public final class ContentModel {
    private let orgs: OrgsModel

    public init(orgs: OrgsModel) {
        self.orgs = orgs
    }

    /// Loads unless the active org's data is already here; `force` reads again (Refresh, ⌘R).
    public func load(force: Bool = false) {}
}
