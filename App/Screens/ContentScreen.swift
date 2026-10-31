import AppModels
import SwiftUI

/// Content (plan §4; Appendix B: apps, packages, blueprints and configurations, each with its detail): a placeholder the
/// content unit replaces. Not `ContentView`: that is the window's. `ContentView` routes here with `ContentScreen(model:)`.
struct ContentScreen: View {
    let model: ContentModel

    var body: some View {
        ContentUnavailableView {
            Label("Content", systemImage: "square.stack.3d.up")
        } description: {
            Text("This screen arrives in Phase 2b of the port.")
        }
        .accessibilityIdentifier("content.placeholder")
        .task { model.load() }
    }
}
