import AppModels
import SwiftUI
import UniformTypeIdentifiers

/// Apple MDM (Appendix B: "Devices › Apple MDM"; plan Phase 2): the devices Apple's own device management enrolls, as a
/// sortable, searchable table with each one's posture from its details, read after the list (`AppleMDMModel`). A row
/// whose details weren't read says why in every posture column. CSV export of what's shown, off while the list or the
/// details are read or the list is partial; the inspector for the selected device, with every detail Apple sent.
/// Read-only: nothing here writes.
struct AppleMDMView: View {
    @Bindable var model: AppleMDMModel
    @State private var exporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            StatusBanner(state: model.state, shown: model.devices.count, truncated: model.truncated, total: model.total,
                         partial: model.partialCount) {
                model.load(force: true)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            if let note = model.detailsNote {
                Label(note, systemImage: "questionmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    // Wraps to the pane rather than asking for its one-line width: the narrow window's tripwire reads
                    // each column's ideal width (Debug/Snapshots.swift, `columnsTooNarrow`).
                    .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                    .accessibilityIdentifier("apple-mdm.detailsNote")
            }
            if let empty = model.emptyTitle {
                // Never an empty table (invariant 8): the banner above says why in full.
                ContentUnavailableView(empty, systemImage: "ipad.and.iphone")
                    .accessibilityIdentifier("apple-mdm.empty")
            } else {
                table
            }
        }
        .searchable(text: $model.search, prompt: "Serial, name or enrolled user")
        .toolbar {
            ToolbarItem {
                Button("Export CSV…", systemImage: "square.and.arrow.up") { exporting = true }
                    .disabled(model.shown.isEmpty || model.exportBlocked != nil)
                    .help(model.exportBlocked ?? "Exports the devices shown with their posture, the Apple MDM columns only")
                    .accessibilityLabel("Export the Apple MDM devices as CSV")
                    .accessibilityIdentifier("apple-mdm.export")
            }
        }
        .fileExporter(isPresented: $exporting, document: exporting ? CSVDocument(text: model.csv()) : nil, contentType: .commaSeparatedText,
                      defaultFilename: "apple-mdm.csv") { _ in }
        .inspector(isPresented: Binding(get: { model.selection != nil }, set: { if !$0 { model.selection = nil } })) {
            AppleMDMInspectorView(row: model.selected)
                .inspectorColumnWidth(min: ColumnWidths.inspector.min, ideal: ColumnWidths.inspector.ideal, max: ColumnWidths.inspector.max)
        }
        .task { model.load() }
    }

    /// Eleven columns, in two groups: a column builder takes ten.
    private var table: some View {
        Table(model.shown, selection: $model.selection, sortOrder: $model.sortOrder) {
            Group {
                TableColumn("Serial", value: \AppleMDMRow.serial, comparator: String.StandardComparator.lexical) { Text($0.serial).monospaced() }
                    .width(min: 110, ideal: 130)
                TableColumn("Name", value: \AppleMDMRow.name)
                    .width(min: 100, ideal: 170)
                TableColumn("Family", value: \AppleMDMRow.family)
                    .width(min: 50, ideal: 70)
                TableColumn("OS", value: \AppleMDMRow.os) { PostureText(row: $0, text: $0.os) }
                    .width(min: 50, ideal: 70)
                TableColumn("Last check-in", value: \AppleMDMRow.checkInSort) { PostureText(row: $0, text: $0.checkIn) }
                    .width(min: 90, ideal: 140)
            }
            Group {
                TableColumn("FileVault", value: \AppleMDMRow.fileVault) { PostureText(row: $0, text: $0.fileVault) }
                    .width(min: 60, ideal: 75)
                TableColumn("Firewall", value: \AppleMDMRow.firewall) { PostureText(row: $0, text: $0.firewall) }
                    .width(min: 60, ideal: 75)
                TableColumn("Lock", value: \AppleMDMRow.lock) { PostureText(row: $0, text: $0.lock) }
                    .width(min: 60, ideal: 80)
                TableColumn("Erase", value: \AppleMDMRow.erase) { PostureText(row: $0, text: $0.erase) }
                    .width(min: 60, ideal: 80)
                TableColumn("Lost mode", value: \AppleMDMRow.lostMode) { PostureText(row: $0, text: $0.lostMode) }
                    .width(min: 60, ideal: 75)
                TableColumn("Storage", value: \AppleMDMRow.storageSort) { PostureText(row: $0, text: $0.storage) }
                    .width(min: 100, ideal: 150)
            }
        }
        .accessibilityLabel("Apple MDM devices")
        .accessibilityIdentifier("apple-mdm.table")
        .selectsFirstRow($model.selection, first: model.shown.first?.id, ready: !model.state.isLoading)
    }
}

/// A posture cell: Apple's value in words, or, dimmed, why there is none ("Reading…", "Not read", "No details", "Role
/// can't read", "Failed"), so an unread FileVault never reads as off.
private struct PostureText: View {
    let row: AppleMDMRow
    let text: String

    var body: some View {
        Text(text).foregroundStyle(row.details.detail == nil ? .secondary : .primary)
    }
}
