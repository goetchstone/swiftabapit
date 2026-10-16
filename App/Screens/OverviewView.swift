import AppleModels
import Charts
import Reports
import SwiftUI

/// Overview (plan §8 Phase 1: the minimal dashboard): the fleet's counts, devices added per month, the
/// unassigned ones, and services that haven't connected lately. Built from the Devices screen's load.
struct OverviewView: View {
    let model: DevicesModel
    let hasOrg: Bool
    let addOrg: () -> Void

    var body: some View {
        if !hasOrg {
            ContentUnavailableView {
                Label("No organization yet", systemImage: "building.2")
            } description: {
                Text("Add an Apple Business or Apple School Manager API account in Settings.")
            } actions: {
                Button("Open Settings", action: addOrg)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    StatusBanner(state: model.state, shown: model.rows.count, truncated: model.truncated, total: model.total) {
                        model.load(force: true)
                    }
                    let stats = DeviceStats(model.devices.map(\.resource), now: Date())
                    let unassigned = model.rows.filter { $0.service.isEmpty }.count
                    HStack(spacing: 12) {
                        Tile(title: "Devices", value: stats.total)
                        Tile(title: "Added in 30 days", value: stats.added30)
                        Tile(title: "Not assigned to a service", value: unassigned)
                        Tile(title: "Services", value: model.services.count)
                    }
                    GroupBox("By family") {
                        Chart(stats.byFamily, id: \.name) { tally in
                            BarMark(x: .value("Devices", tally.count), y: .value("Family", tally.name))
                        }
                        .frame(height: CGFloat(max(stats.byFamily.count, 1)) * 28 + 20)
                        .accessibilityLabel("Devices by family: " + stats.byFamily.map { "\($0.name) \($0.count)" }.joined(separator: ", "))
                    }
                    GroupBox("Added per month") {
                        Chart(stats.addedByMonth, id: \.name) { tally in
                            BarMark(x: .value("Month", tally.name), y: .value("Devices", tally.count))
                        }
                        .frame(height: 160)
                        .accessibilityLabel("Devices added per month, last 12 months: " + stats.addedByMonth.map { "\($0.name) \($0.count)" }.joined(separator: ", "))
                    }
                    let quiet = model.services.filter { ($0.daysSinceConnected(now: Date()) ?? .max) > ServicesView.staleAfter }
                    GroupBox("Service health") {
                        if quiet.isEmpty {
                            Label("Every service has connected in the last \(ServicesView.staleAfter) days.", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(quiet) { service in
                                    HStack { Text(service.name); Spacer(); LastConnected(service: service) }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .task { model.load() }
        }
    }
}

struct Tile: View {
    let title: String
    let value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value.formatted()).font(.title.bold()).monospacedDigit()
            Text(title).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}
