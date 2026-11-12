import AppModels
import SwiftUI
import UniformTypeIdentifiers

/// Content (plan §4; Appendix B: apps, packages, blueprints and configurations, each with its detail): one list at a
/// time, chosen in the toolbar, as a sortable, searchable table that fills as pages arrive; the chosen row's detail in
/// the inspector; CSV export of what's shown with the list's own columns, off while the list loads or is partial. Not
/// `ContentView`: that is the window's. Read-only: nothing here writes (Phase 5 adds blueprint and configuration writes).
struct ContentScreen: View {
    @Bindable var model: ContentModel

    var body: some View {
        Group {
            switch model.kind {
            case .apps:
                ContentTable(list: model.apps, model: model) {
                    TableColumn("Name", value: \.name)
                        .width(min: 140, ideal: 220)
                    TableColumn("Bundle ID", value: \.bundleID)
                        .width(min: 120, ideal: 200)
                    TableColumn("Version", value: \.version)
                        .width(min: 50, ideal: 70)
                    TableColumn("Platforms", value: \.platforms)
                        .width(min: 80, ideal: 170)
                    TableColumn("Source", value: \.source)
                        .width(min: 60, ideal: 80)
                }
            case .packages:
                ContentTable(list: model.packages, model: model) {
                    TableColumn("Name", value: \.name)
                        .width(min: 140, ideal: 220)
                    TableColumn("Version", value: \.version)
                        .width(min: 50, ideal: 70)
                    TableColumn("Bundle IDs", value: \.bundleIDs)
                        .width(min: 120, ideal: 240)
                    TableColumn("Updated", value: \.updated) { Text(ScreenWords.day($0.updated)) }
                        .width(min: 80, ideal: 100)
                }
            case .blueprints:
                ContentTable(list: model.blueprints, model: model) {
                    TableColumn("Name", value: \.name)
                        .width(min: 140, ideal: 240)
                    TableColumn("Status", value: \.status)
                        .width(min: 70, ideal: 100)
                    TableColumn("Licences", value: \.licences)
                        .width(min: 60, ideal: 80)
                    TableColumn("Updated", value: \.updated) { Text(ScreenWords.day($0.updated)) }
                        .width(min: 80, ideal: 100)
                }
            case .configurations:
                ContentTable(list: model.configurations, model: model) {
                    TableColumn("Name", value: \.name)
                        .width(min: 140, ideal: 240)
                    TableColumn("Type", value: \.type)
                        .width(min: 90, ideal: 160)
                    TableColumn("Platforms", value: \.platforms)
                        .width(min: 80, ideal: 160)
                    TableColumn("Updated", value: \.updated) { Text(ScreenWords.day($0.updated)) }
                        .width(min: 80, ideal: 100)
                }
            }
        }
        .searchable(text: $model.search, prompt: "Name, bundle ID or identifier")
        .toolbar {
            ToolbarItem {
                Picker("List", selection: $model.kind) {
                    ForEach(ContentKind.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Which content list to show")
                .accessibilityLabel("Content list")
                .accessibilityIdentifier("content.kind")
            }
        }
        .inspector(isPresented: Binding(get: { model.selection != nil }, set: { if !$0 { model.selection = nil } })) {
            ContentInspectorView(model: model.detail)
                .inspectorColumnWidth(min: ColumnWidths.inspector.min, ideal: ColumnWidths.inspector.ideal, max: ColumnWidths.inspector.max)
        }
        .task { model.load() }
    }
}

/// One Content list: where its read stands, its table (or, with no row to show, why in words: never an empty table), and
/// its Export button. The snapshot harness's first-row hook sits on the table, which owns the selection.
private struct ContentTable<Row: ContentRow, Columns: TableColumnContent>: View
where Columns.TableRowValue == Row, Columns.TableColumnSortComparator == KeyPathComparator<Row> {
    @Bindable var list: ContentList<Row>
    @Bindable var model: ContentModel
    let columns: Columns
    @State private var exporting = false
    @Environment(\.exportClient) private var exportClient

    init(list: ContentList<Row>, model: ContentModel, @TableColumnBuilder<Row, KeyPathComparator<Row>> columns: () -> Columns) {
        self.list = list
        self.model = model
        self.columns = columns()
    }

    private var name: String { Row.kind.rawValue }

    var body: some View {
        let shown = list.shown(matching: model.search)
        VStack(alignment: .leading, spacing: 0) {
            if let words = list.emptyWords {
                ContentUnavailableView {
                    Label(Row.kind.title, systemImage: Self.symbol(list.state))
                } description: {
                    Text(words)
                } actions: {
                    if case .failed = list.state {
                        Button("Try Again") { model.load(force: true) }
                            .accessibilityIdentifier("content.\(name).retry")
                    }
                }
                .accessibilityIdentifier("content.\(name).empty")
            } else {
                StatusBanner(state: list.state, shown: list.rows.count, truncated: list.truncated, total: list.total, partial: list.partialCount) {
                    model.load(force: true)
                }
                .padding(.horizontal)
                .padding(.vertical, 6)
                Table(shown, selection: $model.selection, sortOrder: $list.sortOrder) { columns }
                    .accessibilityLabel(Row.kind.title)
                    .accessibilityIdentifier("content.\(name).table")
                    .selectsFirstRow($model.selection, first: shown.first?.id, ready: !list.state.isLoading)
            }
        }
        .toolbar {
            ToolbarItem {
                Button("Export CSV…", systemImage: "square.and.arrow.up") { exporting = true }
                    .disabled(model.exportBlocked(for: Row.kind) != nil)
                    .help(model.exportBlocked(for: Row.kind) ?? "Exports the \(Row.kind.noun) shown, with the \(Row.kind.title) columns only")
                    .accessibilityLabel("Export \(Row.kind.noun) as CSV")
                    .accessibilityIdentifier("content.\(name).export")
            }
        }
        // Written when asked for, not on every redraw of the table.
        .fileExporter(isPresented: $exporting, document: exporting ? CSVDocument(text: model.csv(for: Row.kind)) : nil,
                      contentType: .commaSeparatedText, defaultFilename: ScreenWords.filename("\(name).csv", client: exportClient)) { _ in }
    }

    /// The placeholder's symbol for why there's no row; its words say the same (a status is never colour or symbol alone).
    static func symbol(_ state: LoadState) -> String {
        switch state {
        case .forbidden: "lock"
        case .notInScope: "building.columns"
        case .failed: "exclamationmark.octagon"
        case .unusable: "exclamationmark.triangle"
        case .idle, .loading, .loaded: "tray"
        }
    }
}
