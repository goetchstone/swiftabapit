import AppleModels
import AppModels
import SwiftUI

/// Device management services with their health (plan §2.1): how many devices each holds and when it last
/// connected, flagged by the Overview's rule (`DevicesModel.connection(of:now:)`, Reports' `QuietServices`). The services
/// have their own state, apart from the devices' (Phase 1b review M3).
struct ServicesView: View {
    let model: DevicesModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusBanner(state: model.servicesState, shown: model.services.count, truncated: model.servicesTruncated,
                         partial: model.servicesPartialCount) { model.load(force: true) }
                .padding(.horizontal)
                .padding(.vertical, 6)
            Table(model.services) {
                TableColumn("Service") { Text($0.name) }
                    .width(min: 140, ideal: 220)
                TableColumn("Type") { Text($0.type?.rawValue ?? "—") }
                    .width(min: 70, ideal: 110)
                TableColumn("Status") { Text($0.status?.rawValue.capitalized ?? "—") }
                    .width(min: 60, ideal: 80)
                // The count read, else Apple's own attribute, else a dash: never a zero nobody counted.
                TableColumn("Devices") { service in Text((model.deviceCount[service.id] ?? service.deviceCount).map { $0.formatted() } ?? "—") }
                    .width(min: 60, ideal: 70)
                TableColumn("Last connected") { service in LastConnected(service: service) }
                    .width(min: 120, ideal: 180)
                TableColumn("From") { Text($0.lastConnectedIP ?? "—").monospaced() }
                    .width(min: 90, ideal: 120)
            }
            .accessibilityIdentifier("services.table")
        }
        .task { model.load() }
    }
}

/// A service's last connection in the model's words (Phase 2b review L4): a flag is said in words beside its colour.
struct LastConnected: View {
    let service: MDMService

    var body: some View {
        let connection = DevicesModel.connection(of: service, now: Date())
        if connection.isQuiet {
            Label(connection.text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .accessibilityLabel(connection.spoken)
        } else {
            Text(connection.text)
        }
    }
}
