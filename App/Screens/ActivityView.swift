import AppleModels
import AppModels
import SwiftUI
import UniformTypeIdentifiers

/// Activity (Appendix B: "Activity › Audit, Subscriptions, Lifecycle, Access & Security"): the audit log over the range and
/// Apple's filters (set in the toolbar's popover), Reports' views over the same read with their counts by type, a sortable,
/// searchable table, CSV of what's shown (common attributes only), and the inspector for the selected event. Everything
/// it says comes from `ActivityModel`; the view lays it out. Read-only: nothing here writes.
struct ActivityView: View {
    @Bindable var model: ActivityModel
    @State private var exporting = false
    @Environment(\.exportClient) private var exportClient
    @State private var filtering = false
    /// Which columns show, and their order and widths: the operator's, kept with the window.
    @SceneStorage("activity.columns") private var columns = TableColumnCustomization<ActivityRow>()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusBanner(state: model.state, shown: model.rows.count, truncated: model.truncated, total: model.total, partial: model.partialCount) {
                model.load(force: true)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            ActivityHeader(model: model)
                .padding(.horizontal)
                .padding(.bottom, 8)
            if let why = model.emptyText {
                ContentUnavailableView {
                    Label(model.pane.title, systemImage: symbol)
                } description: {
                    Text(why)
                }
                .accessibilityIdentifier("activity.empty")
            } else {
                // Five of the six columns show by default, within the Devices table's minimum width (all six need 590 pt
                // at their narrowest); Category is a right-click on the header away, and the panes already group by it.
                Table(model.shown, selection: $model.selection, sortOrder: $model.sortOrder, columnCustomization: $columns) {
                    TableColumn("When", value: \.timeSort) { row in
                        Text(row.time?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    }
                    .width(min: 120, ideal: 150)
                    .customizationID("when")
                    TableColumn("Type", value: \.type)
                        .width(min: 140, ideal: 220)
                        .customizationID("type")
                    TableColumn("Category", value: \.category)
                        .width(min: 80, ideal: 120)
                        .customizationID("category")
                        .defaultVisibility(.hidden)
                    TableColumn("Outcome", value: \.outcome) { row in
                        if row.failed {
                            Label(row.outcome, systemImage: "xmark.octagon").foregroundStyle(.red)
                        } else {
                            Text(row.outcome)
                        }
                    }
                    .width(min: 70, ideal: 80)
                    .customizationID("outcome")
                    TableColumn("Actor", value: \.actor)
                        .width(min: 90, ideal: 150)
                        .customizationID("actor")
                    TableColumn("Subject", value: \.subject)
                        .width(min: 90, ideal: 150)
                        .customizationID("subject")
                }
                .accessibilityIdentifier("activity.table")
                .selectsFirstRow($model.selection, first: model.shown.first?.id, ready: !model.state.isLoading)
            }
        }
        .searchable(text: $model.search, prompt: "Type, actor, subject…")
        .toolbar {
            ToolbarItemGroup {
                Picker("View", selection: $model.pane) {
                    ForEach(ActivityPane.allCases) { Text($0.title).tag($0) }
                }
                .help("Which events the table shows: every one, or one of Reports' views over the same read")
                .accessibilityIdentifier("activity.pane")
                Button("Range and Filters…", systemImage: "line.3.horizontal.decrease.circle") { filtering = true }
                    .help("The range read and Apple's filters: type, actor and subject")
                    .accessibilityIdentifier("activity.filters")
                    .popover(isPresented: $filtering, arrowEdge: .bottom) {
                        ActivityFilterForm(model: model) { filtering = false }
                    }
                Button("Export CSV…", systemImage: "square.and.arrow.up") { exporting = true }
                    .disabled(model.exportBlocked != nil)
                    .help(model.exportBlocked ?? "Exports the events shown, with their common attributes only (no payloads)")
                    .accessibilityIdentifier("activity.export")
            }
        }
        .fileExporter(isPresented: $exporting, document: exporting ? CSVDocument(text: model.csv()) : nil, contentType: .commaSeparatedText,
                      defaultFilename: ScreenWords.filename(model.exportName, client: exportClient)) { _ in }
        .inspector(isPresented: Binding(get: { model.selection != nil }, set: { if !$0 { model.selection = nil } })) {
            ActivityInspectorView(row: model.selected)
                .inspectorColumnWidth(min: ColumnWidths.inspector.min, ideal: ColumnWidths.inspector.ideal, max: ColumnWidths.inspector.max)
        }
        .task { model.load() }
    }

    private var symbol: String {
        switch model.state {
        case .forbidden: "lock"
        case .notInScope: "building.columns"
        case .failed, .unusable: "exclamationmark.triangle"
        default: "list.bullet.clipboard"
        }
    }
}

/// Above the table: the range read, Apple's filters, what this version couldn't place, and the pane's purpose, count and
/// counts by type. Every line wraps, so the narrowest window holds it.
private struct ActivityHeader: View {
    let model: ActivityModel

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let query = model.query {
                Text("\(model.applied.rangeName): \(query.start.formatted(date: .abbreviated, time: .shortened)) to \(query.end.formatted(date: .abbreviated, time: .shortened)).")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("activity.range.read")
            }
            if let summary = model.applied.summary {
                Label(summary, systemImage: "line.3.horizontal.decrease.circle")
                    .accessibilityIdentifier("activity.filters.read")
            }
            if let note = model.unplacedNote {
                Label(note, systemImage: "questionmark.circle")
                    .accessibilityIdentifier("activity.unplaced")
            }
            Text(model.pane.title).font(.headline).padding(.top, 2)
            Text(model.pane.blurb).foregroundStyle(.secondary)
            if let summary = model.summary(for: model.pane) {
                Text(summary).accessibilityIdentifier("activity.summary")
            }
            if let counts = model.countsText(model.pane) {
                Text(counts)
                    .accessibilityLabel("Counts by type: \(counts)")
                    .accessibilityIdentifier("activity.counts")
            }
        }
        .font(.callout)
        // Wraps to the pane rather than asking for its longest line's width, as Apple MDM's note does. With
        // `.fixedSize(horizontal: false, vertical: true)` the counts line set the column's ideal width, the wrap set the
        // height, and AppKit's constraint passes never settled: the app crashed on every Activity snapshot (PR 12).
        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

/// The range and Apple's filters, edited in a popover and read with Read: a range or an id the model refuses says why
/// here, and Read stays off until it can be read.
private struct ActivityFilterForm: View {
    @Bindable var model: ActivityModel
    let done: () -> Void

    var body: some View {
        Form {
            Picker("Range", selection: $model.draft.days) {
                ForEach(AuditFilter.presets, id: \.self) { days in Text(days == 1 ? "Last day" : "Last \(days) days").tag(Optional(days)) }
                Text("Custom range").tag(Int?.none)
            }
            .accessibilityIdentifier("activity.range")
            if model.draft.days == nil {
                DatePicker("From", selection: $model.draft.start)
                    .accessibilityIdentifier("activity.start")
                DatePicker("To", selection: $model.draft.end)
                    .accessibilityIdentifier("activity.end")
            }
            Picker("Type", selection: $model.draft.type) {
                Text("Every type").tag(AuditEventType?.none)
                ForEach(ActivityModel.typeChoices, id: \.pane) { group in
                    Section(group.pane.title) {
                        ForEach(group.types, id: \.self) { type in Text(ActivityModel.title(of: type)).tag(Optional(type)) }
                    }
                }
            }
            .accessibilityIdentifier("activity.type")
            TextField("Actor ID", text: $model.draft.actorID, prompt: Text("Any actor"))
                .accessibilityIdentifier("activity.actor")
            TextField("Subject ID", text: $model.draft.subjectID, prompt: Text("Any subject, such as a serial"))
                .accessibilityIdentifier("activity.subject")
            if let why = model.draftProblem ?? model.problem {
                Label(why, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("activity.problem")
            }
            HStack {
                Button("Reset") { model.draft = AuditFilter() }
                    .accessibilityIdentifier("activity.reset")
                Spacer()
                Button("Read") { if model.apply() { done() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.draftProblem != nil)
                    .accessibilityIdentifier("activity.read")
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
    }
}
