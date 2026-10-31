import AppleModels
import AppModels
import Charts
import Reports
import SwiftUI

/// The Dashboard's cards (`OverviewView`). Each shows its model's words first, why it counts nothing or what is worth
/// saying of what it counts, then what it counts, so a card never shows an empty chart or a zero for a list nobody read.
/// Each chart has an accessibility label and a summary of every bar (`DashboardModel.summary`) a screen reader reads, and
/// each mark its own label and value, so the chart's audio graph names them too.
struct DashboardCard<Content: View>: View {
    let title: String
    let id: String
    let words: String?
    @ViewBuilder let content: () -> Content

    init(_ title: String, id: String, words: String?, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.id = id
        self.words = words
        self.content = content
    }

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                if let words {
                    Label(words, systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("overview.\(id).words")
                }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Text(title).font(.headline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier("overview.\(id)")
    }
}

/// Devices added per month, the last 12 calendar months (abapit's `added_by_month`).
struct MonthsCard: View {
    let dashboard: DashboardModel
    let stats: DeviceStats?

    var body: some View {
        DashboardCard("Added per month", id: "added", words: dashboard.fleetWords) {
            if let stats, stats.total > 0 {
                Chart(stats.addedByMonth, id: \.name) { tally in
                    BarMark(x: .value("Month", tally.name), y: .value("Devices", tally.count))
                        .accessibilityLabel(tally.name)
                        .accessibilityValue("\(tally.count.formatted()) added")
                }
                .frame(height: 160)
                .accessibilityLabel("Devices added per month, the last 12 months")
                .accessibilityValue(DashboardModel.summary(stats.addedByMonth))
                .accessibilityIdentifier("overview.added.chart")
            }
        }
    }
}

/// Devices by product family, most first.
struct FamilyCard: View {
    let dashboard: DashboardModel
    let stats: DeviceStats?

    var body: some View {
        DashboardCard("By family", id: "family", words: dashboard.fleetWords) {
            if let stats, !stats.byFamily.isEmpty {
                TallyBars(tallies: stats.byFamily, axis: "Family", label: "Devices by family", id: "family")
            }
        }
    }
}

/// Devices by status, as a ring: each status named in the legend, not by colour alone.
struct StatusCard: View {
    let dashboard: DashboardModel
    let stats: DeviceStats?

    var body: some View {
        DashboardCard("By status", id: "status", words: dashboard.fleetWords) {
            if let stats, !stats.byStatus.isEmpty {
                Chart(stats.byStatus, id: \.name) { tally in
                    SectorMark(angle: .value("Devices", tally.count), innerRadius: .ratio(0.6), angularInset: 1.5)
                        .foregroundStyle(by: .value("Status", tally.name))
                        .accessibilityLabel(tally.name)
                        .accessibilityValue("\(tally.count.formatted()) devices")
                }
                .chartLegend(position: .trailing, alignment: .center, spacing: 12)
                .frame(height: 170)
                .accessibilityLabel("Devices by status")
                .accessibilityValue(DashboardModel.summary(stats.byStatus))
                .accessibilityIdentifier("overview.status.chart")
            }
        }
    }
}

/// Horizontal bars of named counts, each count written beside its bar.
struct TallyBars: View {
    let tallies: [Tally]
    let axis: String
    let label: String
    let id: String

    var body: some View {
        Chart(tallies, id: \.name) { tally in
            BarMark(x: .value("Devices", tally.count), y: .value(axis, tally.name))
                .annotation(position: .trailing) {
                    Text(tally.count.formatted()).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityLabel(tally.name)
                .accessibilityValue("\(tally.count.formatted()) devices")
        }
        .chartXAxis(.hidden)
        .frame(height: CGFloat(tallies.count) * 26 + 12)
        .accessibilityLabel(label)
        .accessibilityValue(DashboardModel.summary(tallies))
        .accessibilityIdentifier("overview.\(id).chart")
    }
}

/// Devices per device management service: each service whose device list was read whole; the card's words name the
/// others, which have no bar rather than a bar of 0.
struct ServiceCountCard: View {
    let dashboard: DashboardModel

    var body: some View {
        DashboardCard("Devices per service", id: "services", words: dashboard.servicesWords) {
            if let counts = dashboard.perService, counts.contains(where: { $0.count != nil }) {
                Chart(counts) { service in
                    if let count = service.count {
                        BarMark(x: .value("Devices", count), y: .value("Service", service.name))
                            .annotation(position: .trailing) {
                                Text(count.formatted()).font(.caption).foregroundStyle(.secondary)
                            }
                            .accessibilityLabel(service.name)
                            .accessibilityValue("\(count.formatted()) devices")
                    }
                }
                .chartXAxis(.hidden)
                .frame(height: CGFloat(counts.filter { $0.count != nil }.count) * 26 + 12)
                .accessibilityLabel("Devices per device management service")
                .accessibilityValue(DashboardModel.summary(counts))
                .accessibilityIdentifier("overview.services.chart")
            }
        }
    }
}

/// The devices no service holds, once every list is read whole: how many, and the first serials by code point.
struct UnassignedCard: View {
    let dashboard: DashboardModel

    var body: some View {
        DashboardCard("Not assigned to a service", id: "unassigned", words: dashboard.unassignedWords) {
            if let serials = dashboard.unassigned, !serials.isEmpty {
                Text(serials.count.formatted()).font(.title2.bold()).monospacedDigit()
                    .accessibilityLabel("\(serials.count.formatted()) devices not assigned")
                Text(serials.prefix(DashboardModel.unassignedListed).joined(separator: "  "))
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("overview.unassigned.serials")
            }
        }
    }
}

/// Services not connected in the chosen number of days (Reports' `QuietServices`): never connected and unreadable dates
/// first, said as such, then the longest silent.
struct QuietServicesCard: View {
    @Bindable var dashboard: DashboardModel
    let now: Date

    var body: some View {
        DashboardCard("Services not connected lately", id: "quiet", words: dashboard.quietWords(now: now)) {
            Picker("Not connected in", selection: $dashboard.quietDays) {
                ForEach(DashboardModel.quietDayChoices, id: \.self) { days in
                    Text("\(days.formatted()) day\(days == 1 ? "" : "s")").tag(days)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel("Not connected in how many days")
            .accessibilityIdentifier("overview.quiet.days")
            if let rows = dashboard.quiet(now: now), !rows.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(rows, id: \.service.id) { row in
                        HStack {
                            Text(row.service.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 8)
                            Label(DashboardModel.lastConnected(row, now: now), systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .lineLimit(1)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                .accessibilityIdentifier("overview.quiet.list")
            }
        }
    }
}

/// The newest ten audit events of the last seven days, newest first (Reports' `AuditDigest.recent`). Refused, failed or
/// not in the org's scope is said here only.
struct RecentEventsCard: View {
    let dashboard: DashboardModel

    var body: some View {
        DashboardCard("Recent audit events", id: "audit", words: dashboard.auditWords) {
            if !dashboard.recentEvents.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    EventRow(when: Text("When"), type: "Event", actor: "Actor", subject: "Subject", outcome: "Outcome")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    Divider()
                    ForEach(dashboard.recentEvents) { event in
                        EventRow(when: Self.when(event), type: event.type?.rawValue ?? "—", actor: event.actorName ?? "—",
                                 subject: event.subjectName ?? "—", outcome: event.outcome?.rawValue ?? "—")
                    }
                }
                .accessibilityIdentifier("overview.audit.list")
            }
        }
    }

    /// The event's instant in the operator's time zone; a date this app can't read is shown as Apple sent it.
    static func when(_ event: AuditEvent) -> Text {
        if let date = event.eventDate?.date { return Text(date, format: .dateTime.month(.abbreviated).day().hour().minute()) }
        return Text(event.attributes["eventDateTime"]?.string ?? "—")
    }
}

/// One line of the recent events: fixed columns for the time and the outcome, the rest sharing what is left, each cut
/// to one line, so the smallest window fits them.
private struct EventRow: View {
    let when: Text
    let type: String
    let actor: String
    let subject: String
    let outcome: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            when.frame(width: 120, alignment: .leading)
            Text(type).font(.callout.monospaced()).frame(maxWidth: .infinity, alignment: .leading)
            Text(actor).frame(maxWidth: .infinity, alignment: .leading)
            Text(subject).frame(maxWidth: .infinity, alignment: .leading)
            Text(outcome).frame(width: 80, alignment: .leading)
        }
        .lineLimit(1)
        .truncationMode(.middle)
        .accessibilityElement(children: .combine)
    }
}
