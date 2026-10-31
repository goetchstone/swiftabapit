import AppModels
import SwiftUI

/// Apple MDM (Appendix B: "Devices › Apple MDM", the devices Apple's MDM enrolls and their posture): a placeholder the
/// Apple MDM unit replaces. `ContentView` routes here with `AppleMDMView(model:)`.
struct AppleMDMView: View {
    let model: AppleMDMModel

    var body: some View {
        ContentUnavailableView {
            Label("Apple MDM", systemImage: "ipad.and.iphone")
        } description: {
            Text("This screen arrives in Phase 2b of the port.")
        }
        .accessibilityIdentifier("apple-mdm.placeholder")
        .task { model.load() }
    }
}
