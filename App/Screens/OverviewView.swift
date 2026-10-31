import AppModels
import SwiftUI

/// Overview › Dashboard (plan §8 Phase 2; Appendix B): the fleet's counts, by family, by status and added per month;
/// devices per service and the unassigned ones; services not connected in N days; the last seven days' audit events.
/// Thin over `DashboardModel`, which decides what each card may count and says why when it can't (invariant 8): a dash
/// or words, never a zero nobody counted. An org that can't be read says why instead of showing zeros (Phase 1b review,
/// LOW). The cards are in Screens/DashboardCards.swift.
struct OverviewView: View {
    let dashboard: DashboardModel
    let hasOrg: Bool
    let addOrg: () -> Void

    private var model: DevicesModel { dashboard.devices }

    init(model: DashboardModel, hasOrg: Bool, addOrg: @escaping () -> Void) {
        dashboard = model
        self.hasOrg = hasOrg
        self.addOrg = addOrg
    }

    var body: some View {
        if !hasOrg {
            ContentUnavailableView {
                Label("No organization yet", systemImage: "building.2")
            } description: {
                Text("Add an Apple Business or Apple School Manager API account in Settings.")
            } actions: {
                Button("Open Settings", action: addOrg)
                    .accessibilityIdentifier("overview.open-settings")
            }
        } else if case .unusable(let why) = model.state {
            ContentUnavailableView {
                Label("This organization can't be read", systemImage: "exclamationmark.triangle")
            } description: {
                Text(why)
            } actions: {
                Button("Open Settings", action: addOrg)
                    .accessibilityIdentifier("overview.unusable.open-settings")
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StatusBanner(state: model.state, shown: model.rows.count, truncated: model.truncated, total: model.total,
                                 partial: model.partialCount) {
                        dashboard.load(force: true)
                    }
                    if let note = model.serviceNote {
                        Label(note, systemImage: "questionmark.circle").font(.callout).foregroundStyle(.secondary)
                    }
                    // One `now` and one count per drawing, so every card counts the same list at the same moment.
                    let now = Date()
                    let stats = dashboard.stats(now: now)
                    HStack(spacing: 12) {
                        // A dash until the list it counts is read whole; the cards and the banner say why.
                        Tile(title: "Devices", id: "devices", value: stats?.total)
                        Tile(title: "Added in 30 days", id: "added-30", value: stats?.added30)
                        Tile(title: "Added in 90 days", id: "added-90", value: stats?.added90)
                        Tile(title: "Not assigned to a service", id: "unassigned", value: model.unassignedCount)
                        Tile(title: "Services", id: "services", value: model.serviceCount)
                    }
                    MonthsCard(dashboard: dashboard, stats: stats)
                    // Two columns in the smallest window (its pane is about 790 pt wide), more in a wider one.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                        FamilyCard(dashboard: dashboard, stats: stats)
                        StatusCard(dashboard: dashboard, stats: stats)
                        ServiceCountCard(dashboard: dashboard)
                        UnassignedCard(dashboard: dashboard)
                        QuietServicesCard(dashboard: dashboard, now: now)
                    }
                    RecentEventsCard(dashboard: dashboard)
                }
                .padding()
            }
            .task { dashboard.load() }
        }
    }
}

/// A count, or a dash when nobody could count it (never a zero; the reason is said beside it).
struct Tile: View {
    let title: String
    let id: String
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
        .accessibilityIdentifier("overview.tile.\(id)")
    }
}
