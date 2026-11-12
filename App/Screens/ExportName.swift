import AppModels
import SwiftUI

/// The client an export is named for (plan §8.0, "Clients"): `ContentView` sets it from `OrgsModel.exportClient`, nil with
/// one client, and every screen's Export names its file through `ScreenWords.filename`, where the rule is tested.
extension EnvironmentValues {
    @Entry var exportClient: String? = nil
}
