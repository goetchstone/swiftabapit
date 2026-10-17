import AppleModels
import SwiftUI
import UniformTypeIdentifiers

/// Devices (plan §4): the org's devices as a sortable, searchable table that fills as pages arrive; filters
/// by family and status; CSV export of what's shown; the inspector for the selected device.
struct DevicesView: View {
    @Bindable var model: DevicesModel
    let detail: DeviceDetailModel
    @Binding var selection: DeviceRow.ID?
    @State private var exporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusBanner(state: model.state, shown: model.rows.count, truncated: model.truncated, total: model.total) { model.load(force: true) }
                .padding(.horizontal)
                .padding(.vertical, 6)
            Table(model.shown, selection: $selection, sortOrder: $model.sortOrder) {
                TableColumn("Serial", value: \.serial) { Text($0.serial).monospaced() }
                    .width(min: 110, ideal: 130)
                TableColumn("Model", value: \.model)
                    .width(min: 120, ideal: 200)
                TableColumn("Family", value: \.family)
                    .width(min: 60, ideal: 80)
                TableColumn("Status", value: \.status) { Text($0.status.capitalized) }
                    .width(min: 70, ideal: 90)
                TableColumn("Service", value: \.service)
                    .width(min: 90, ideal: 150)
                TableColumn("Added", value: \.addedSort) { row in Text(row.added?.formatted(date: .abbreviated, time: .omitted) ?? "—") }
                    .width(min: 80, ideal: 100)
            }
            .accessibilityIdentifier("devices.table")
        }
        .searchable(text: $model.search, prompt: "Serial, IMEI, order number, MAC…")
        .toolbar {
            ToolbarItemGroup {
                Picker("Family", selection: $model.family) {
                    Text("All families").tag("")
                    ForEach(model.families, id: \.self) { Text($0).tag($0) }
                }
                .accessibilityIdentifier("devices.family")
                Picker("Status", selection: $model.status) {
                    Text("All statuses").tag("")
                    ForEach(model.statuses, id: \.self) { Text($0.capitalized).tag($0) }
                }
                .accessibilityIdentifier("devices.status")
                Button("Export CSV…", systemImage: "square.and.arrow.up") { exporting = true }
                    .disabled(model.shown.isEmpty)
                    .help("Exports the devices shown, every attribute that may leave the app")
                    .accessibilityIdentifier("devices.export")
            }
        }
        .fileExporter(isPresented: $exporting, document: CSVDocument(text: model.csv()), contentType: .commaSeparatedText,
                      defaultFilename: "devices.csv") { _ in }
        .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            DeviceInspectorView(model: detail)
                .inspectorColumnWidth(min: ColumnWidths.inspector.min, ideal: ColumnWidths.inspector.ideal, max: ColumnWidths.inspector.max)
        }
        .onChange(of: selection, initial: true) { _, serial in detail.show(serial) }
        .task { model.load() }
    }
}

extension DeviceRow {
    /// Sorts undated devices first, as a missing date reads oldest.
    var addedSort: Date { added ?? .distantPast }
}

/// A CSV for `fileExporter`: written once, never read back.
struct CSVDocument: FileDocument {
    static let readableContentTypes: [UTType] = [.commaSeparatedText]
    let text: String

    init(text: String) { self.text = text }

    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
