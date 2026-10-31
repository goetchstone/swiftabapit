import AppModels
import SwiftUI

/// Activity (Appendix B: the audit log and its Subscriptions, Device Lifecycle and Access & Security views): a placeholder
/// the activity unit replaces. `ContentView` routes here with `ActivityView(model:)`.
struct ActivityView: View {
    let model: ActivityModel

    var body: some View {
        ContentUnavailableView {
            Label("Activity", systemImage: "list.bullet.clipboard")
        } description: {
            Text("This screen arrives in Phase 2b of the port.")
        }
        .accessibilityIdentifier("activity.placeholder")
        .task { model.load() }
    }
}
