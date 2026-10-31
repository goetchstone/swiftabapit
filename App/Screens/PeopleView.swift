import AppModels
import SwiftUI

/// People (plan §4; Appendix B: users with their detail, user groups and org units with their members): a placeholder the
/// people unit replaces. It owns this file; `ContentView` routes here with `PeopleView(model:)`.
struct PeopleView: View {
    let model: PeopleModel

    var body: some View {
        ContentUnavailableView {
            Label("People", systemImage: "person.2")
        } description: {
            Text("This screen arrives in Phase 2b of the port.")
        }
        .accessibilityIdentifier("people.placeholder")
        .task { model.load() }
    }
}
