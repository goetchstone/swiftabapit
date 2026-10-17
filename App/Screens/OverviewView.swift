import AppleModels
import AppModels
import Charts
import Reports
import SwiftUI

/// Overview (plan §8 Phase 1: the minimal dashboard): the fleet's counts, devices added per month, the
/// unassigned ones, and services that haven't connected lately. Built from the Devices screen's load. An org that
/// can't be read says why instead of showing zeros (Phase 1b review, LOW); so do the service tiles and the health box
/// while the services are read, refused or failed (verifier round 1), and the device tiles while the devices are
/// (verifier round 2).
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
        } else if case .unusable(let why) = model.state {
            ContentUnavailableView {
                Label("This organization can't be read", systemImage: "exclamationmark.triangle")
            } description: {
                Text(why)
            } actions: {
                Button("Open Settings", action: addOrg)
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    StatusBanner(state: model.state, shown: model.rows.count, truncated: model.truncated, total: model.total,
                                 partial: model.partialCount) {
                        model.load(force: true)
                    }
                    if let note = model.serviceNote {
                        Label(note, systemImage: "questionmark.circle").font(.callout).foregroundStyle(.secondary)
                    }
                    let stats = DeviceStats(model.devices.map(\.resource), now: Date())
                    HStack(spacing: 12) {
                        // A dash until the list is read whole; the banner says how far it got and why.
                        Tile(title: "Devices", value: model.devicesReadWhole ? stats.total : nil)
                        Tile(title: "Added in 30 days", value: model.devicesReadWhole ? stats.added30 : nil)
                        // A dash until every service's device list is read whole: unknown is never counted as none.
                        Tile(title: "Not assigned to a service", value: model.unassignedCount)
                        Tile(title: "Services", value: model.serviceCount)
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
                    GroupBox("Service health") {
                        if let why = model.servicesUnread {
                            Label(why, systemImage: "questionmark.circle")
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } else if let quiet = model.quietServices(after: ServicesView.staleAfter), !quiet.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(quiet) { service in
                                    HStack { Text(service.name); Spacer(); LastConnected(service: service) }
                                }
                            }
                        } else {
                            Label("Every service has connected in the last \(ServicesView.staleAfter) days.", systemImage: "checkmark.circle")
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
            }
            .task { model.load() }
        }
    }
}

/// A count, or a dash when nobody could count it (never a zero; the reason is said beside it).
struct Tile: View {
    let title: String
    let value: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value?.formatted() ?? "—").font(.title.bold()).monospacedDigit()
                .accessibilityLabel(value?.formatted() ?? "Not known")
            Text(title).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }
}
