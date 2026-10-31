import Foundation
import Observation

/// Activity (Appendix B: "Activity › Audit, Subscriptions, Lifecycle, Access & Security"): the audit log over a
/// checked range (`AuditQuery`), Apple's own filters and cursor paging, and Reports' `AuditView`s over it. Business
/// only. A placeholder the activity unit fills.
@MainActor
@Observable
public final class ActivityModel {
    private let orgs: OrgsModel

    public init(orgs: OrgsModel) {
        self.orgs = orgs
    }

    /// Loads unless the active org's data is already here; `force` reads again (Refresh, ⌘R).
    public func load(force: Bool = false) {}
}
