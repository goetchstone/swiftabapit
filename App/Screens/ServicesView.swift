import AppleModels
import SwiftUI

/// Device management services with their health (plan §2.1): how many devices each holds and when it last
/// connected, flagged when that was more than `staleAfter` days ago.
struct ServicesView: View {
    let model: DevicesModel
    static let staleAfter = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusBanner(state: model.state) { model.load(force: true) }
                .padding(.horizontal)
                .padding(.vertical, 6)
            Table(model.services) {
                TableColumn("Service") { Text($0.name) }
                    .width(min: 140, ideal: 220)
                TableColumn("Type") { Text($0.type?.rawValue ?? "—") }
                    .width(min: 70, ideal: 110)
                TableColumn("Status") { Text($0.status?.rawValue.capitalized ?? "—") }
                    .width(min: 60, ideal: 80)
                TableColumn("Devices") { service in Text((model.deviceCount[service.id] ?? service.deviceCount ?? 0).formatted()) }
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

struct LastConnected: View {
    let service: MDMService

    var body: some View {
        if let days = service.daysSinceConnected(now: Date()) {
            if days > ServicesView.staleAfter {
                Label("\(days) days ago", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityLabel("Not connected for \(days) days")
            } else {
                Text(days == 0 ? "Today" : "\(days) day\(days == 1 ? "" : "s") ago")
            }
        } else {
            Text("Never").foregroundStyle(.secondary)
        }
    }
}
