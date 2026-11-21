import AppModels
import SwiftUI
import UniformTypeIdentifiers

/// Activity's two panes: the audit log (`ActivityView`) and Changes (`ChangesView`), chosen in the toolbar so each keeps its own
/// layout. Changes is local history, so it opens whatever the audit log's state is (a School org, a refused role).
struct ActivityScreen: View {
    let activity: ActivityModel
    let changes: ChangesModel

    enum Pane: String, CaseIterable, Identifiable {
        case audit = "Audit Log", changes = "Changes"
        var id: Self { self }
    }

    @State private var pane: Pane = {
        #if DEBUG
        // The snapshot harness's pane (`ABAPIT_PANE=changes`, scripts/screenshots.sh).
        if ProcessInfo.processInfo.environment["ABAPIT_PANE"] == "changes" { return .changes }
        #endif
        return .audit
    }()

    var body: some View {
        Group {
            switch pane {
            case .audit: ActivityView(model: activity)
            case .changes: ChangesView(model: changes)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Show", selection: $pane) {
                    ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("The audit log from Apple, or the changes between two snapshots in this Mac's history")
                .accessibilityLabel("Activity pane")
                .accessibilityIdentifier("activity.show")
            }
        }
    }
}

/// Activity › Changes (plan Phase 3): the snapshots of the active organization, two compared, "Snapshot now", and the
/// comparison as CSV. Everything it says comes from `ChangesModel`; the view lays it out. Reads the local history only, except
/// for Snapshot now, which asks Apple for reads only (nothing here writes to Apple).
struct ChangesView: View {
    let model: ChangesModel
    @State private var exporting = false

    /// The most items of one kind shown under a resource; the rest are in the CSV, and the screen says so.
    private static let shownLimit = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusBanner(state: model.state) { model.refresh() }
                .padding(.horizontal)
                .padding(.vertical, 6)
            // The comparison first: it is what the screen is for. A grouped form, as Settings is, so long lines wrap.
            Form {
                compareSection
                if let comparison = model.comparison { comparisonSections(comparison) }
                SnapshotNowSection(model: model)
                historySection
            }
            .formStyle(.grouped)
            .accessibilityIdentifier("changes.list")
        }
        .toolbar {
            ToolbarItem {
                Button("Export CSV…", systemImage: "square.and.arrow.up") { exporting = true }
                    .disabled(model.exportBlocked != nil)
                    .help(model.exportBlocked ?? "Saves the differences between the two snapshots compared")
                    .accessibilityIdentifier("changes.export")
            }
        }
        .fileExporter(isPresented: $exporting, document: exporting ? CSVDocument(text: model.csv()) : nil, contentType: .commaSeparatedText,
                      defaultFilename: model.exportFileName) { _ in }
        .fileDialogMessage(model.exportWords)
        .task { await model.load() }
    }

    // MARK: compare

    @ViewBuilder private var compareSection: some View {
        Section("Compare") {
            if model.rows.count >= 2 {
                Picker("Older", selection: Binding(get: { model.olderID }, set: { pick in Task { await model.choose(older: pick, newer: model.newerID) } })) {
                    ForEach(model.rows) { Text(Self.when($0)).tag(Optional($0.id)) }
                }
                .accessibilityIdentifier("changes.older")
                Picker("Newer", selection: Binding(get: { model.newerID }, set: { pick in Task { await model.choose(older: model.olderID, newer: pick) } })) {
                    ForEach(model.rows) { Text(Self.when($0)).tag(Optional($0.id)) }
                }
                .accessibilityIdentifier("changes.newer")
            }
            if let note = model.listNote { Label(note, systemImage: "list.number").accessibilityIdentifier("changes.listnote") }
            if model.rows.isEmpty, case .loaded = model.state {
                Label("No snapshots yet. Snapshot Now below reads this organization and records it; the second snapshot gives something to compare.",
                      systemImage: "tray")
                    .accessibilityIdentifier("changes.empty")
            } else if let why = model.comparisonProblem, model.comparison == nil, !model.rows.isEmpty {
                Label(why, systemImage: "info.circle").accessibilityIdentifier("changes.problem")
            }
        }
    }

    @ViewBuilder private func comparisonSections(_ comparison: ChangesModel.Comparison) -> some View {
        Section("Changes") {
            Text("From \(Self.when(comparison.older)) to \(Self.when(comparison.newer)).")
                .accessibilityIdentifier("changes.range")
            if comparison.changes.isEmpty && comparison.unchanged.isEmpty {
                Label("Nothing was read in full in both snapshots, so nothing is compared.", systemImage: "eye.slash")
                    .accessibilityIdentifier("changes.nothingcompared")
            } else if comparison.changes.isEmpty {
                Label("No difference in what both snapshots read in full.", systemImage: "equal.circle")
                    .accessibilityIdentifier("changes.nodiff")
            }
        }
        ForEach(comparison.changes) { change in
            Section {
                if change.isEmpty {
                    Text("No change among the items read in both snapshots.").foregroundStyle(.secondary)
                }
                entries("Added", change.added)
                entries("Removed", change.removed)
                if !change.changed.isEmpty {
                    ForEach(change.changed.prefix(Self.shownLimit)) { item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Changed: \(item.label) (\(item.id))").fontWeight(.medium)
                            ForEach(item.fields, id: \.field) { field in
                                Text("\(field.field): \(field.old) → \(field.new)").font(.callout).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityElement(children: .combine)
                    }
                    more(change.changed.count)
                }
                ForEach(change.withheld, id: \.self) { words in
                    Label(words, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            } header: {
                HStack {
                    Text(change.title)
                    if change.partial { Text("partial").font(.caption).padding(.horizontal, 6).background(.orange.opacity(0.25), in: Capsule()) }
                    Text(change.counts).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("changes.resource.\(change.resource)")
            }
        }
        if !comparison.skipped.isEmpty || !comparison.unchanged.isEmpty {
            Section("Not shown") {
                ForEach(comparison.skipped) { Label("\($0.title): \($0.why)", systemImage: "eye.slash").accessibilityIdentifier("changes.skipped.\($0.resource)") }
                if !comparison.unchanged.isEmpty {
                    Label("No change: \(comparison.unchanged.joined(separator: ", ")).", systemImage: "equal.circle")
                        .accessibilityIdentifier("changes.unchanged")
                }
            }
        }
    }

    @ViewBuilder private func entries(_ word: String, _ items: [ChangesModel.Entry]) -> some View {
        ForEach(items.prefix(Self.shownLimit)) { Text("\(word): \($0.label) (\($0.id))") }
        more(items.count)
    }

    @ViewBuilder private func more(_ count: Int) -> some View {
        if count > Self.shownLimit {
            Text("Showing \(Self.shownLimit) of \(count.formatted()): the rest are in the CSV export.").font(.callout).foregroundStyle(.secondary)
        }
    }

    // MARK: history

    @ViewBuilder private var historySection: some View {
        if !model.rows.isEmpty {
            Section("Snapshots, newest first") {
                ForEach(model.rows) { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.when(row)).fontWeight(.medium)
                        Text("\(row.devices.formatted()) device\(row.devices == 1 ? "" : "s") · \(row.writtenBy)").font(.callout).foregroundStyle(.secondary)
                        ForEach(row.marks, id: \.self) { Label($0, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.callout) }
                        ForEach(row.notes, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("changes.snapshot.\(row.id)")
                }
            }
        }
    }

    static func when(_ row: ChangesModel.SnapshotRow) -> String {
        row.date.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? row.takenAt
    }
}

/// "Snapshot now": the sweeps chosen for this one run with the collector's estimate each, the button, and while a run goes its
/// progress and Cancel. A Mosyle org says it has no collector yet. Nothing of another org's run shows.
private struct SnapshotNowSection: View {
    let model: ChangesModel

    var body: some View {
        Section("Snapshot now") {
            if model.isMosyle {
                Label(ChangesModel.mosyleWords, systemImage: "info.circle").accessibilityIdentifier("changes.mosyle")
            } else {
                Text("Reads this organization from Apple now and records it in this Mac's history. The lists are read first; each sweep below is one more read for every device, so it takes longer.")
                    .foregroundStyle(.secondary)
                ForEach(model.availableSweeps, id: \.self) { sweep in
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(sweep.title, isOn: Binding(get: { model.sweeps.contains(sweep) }, set: { model.set(sweep, on: $0) }))
                            .disabled(model.isRunning)
                            .accessibilityIdentifier("changes.sweep.\(sweep.rawValue)")
                        Text(model.estimateLine(sweep)).font(.callout).foregroundStyle(.secondary)
                            .accessibilityIdentifier("changes.estimate.\(sweep.rawValue)")
                    }
                }
                if let basis = model.estimateBasis { Text(basis).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    Button("Snapshot Now") { Task { await model.snapshotNow() } }
                        .disabled(model.startBlocked != nil)
                        .help(model.startBlocked ?? "Reads this organization from Apple and records a snapshot")
                        .accessibilityIdentifier("changes.snapshot")
                    if model.isRunning {
                        ProgressView().controlSize(.small)
                        Button("Cancel") { model.cancel() }
                            .help("Stops reading. A snapshot not yet written is not saved")
                            .accessibilityIdentifier("changes.cancel")
                    }
                    Spacer()
                }
                if let blocked = model.startBlocked, !model.isRunning {
                    Label(blocked, systemImage: "hourglass").accessibilityIdentifier("changes.blocked")
                }
                if let reading = model.reading { Text("Reading \(reading.lowercased())…").accessibilityIdentifier("changes.reading") }
                if let progress = model.progress { Text(progress).accessibilityIdentifier("changes.progress") }
                if let estimate = model.runEstimate { Text(estimate).font(.callout).foregroundStyle(.secondary).accessibilityIdentifier("changes.runEstimate") }
                if let refusal = model.refusal { Label(refusal, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).accessibilityIdentifier("changes.refusal") }
            }
            if let result = model.result { Label(result, systemImage: "checkmark.circle").accessibilityIdentifier("changes.result") }
        }
    }
}
