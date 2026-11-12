import AppModels
import Reports
import SwiftUI
import UniformTypeIdentifiers

/// Apple Business against Mosyle Business (plan Phase 7; abapit's `/reports/reconciliation`): the active Apple org's devices
/// joined by serial to its paired Mosyle org's. A summary line, then one bucket at a time, chosen in the toolbar: owned in
/// Apple Business and not enrolled in Mosyle, in both, enrolled in Mosyle and unknown to Apple Business. The report waits for
/// both lists read whole and says why it waits; an Apple org with no Mosyle org paired gets the sentence. Every word is the
/// model's (`ReconciliationModel`).
struct ReconciliationView: View {
    @Bindable var model: ReconciliationModel
    @State private var exporting = false
    @Environment(\.exportClient) private var exportClient
    @SceneStorage("reconciliation.columns") private var columns = TableColumnCustomization<ReconciliationModel.Row>()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.report == nil {
                ContentUnavailableView {
                    Label("Reconciliation", systemImage: model.isNotInScope ? "building.columns" : "arrow.triangle.2.circlepath")
                } description: {
                    Text(model.note ?? "")
                }
                .accessibilityIdentifier("reconciliation.note")
            } else {
                if let readAt = model.readAt {
                    StatusBanner(state: .loaded(at: readAt))
                        .padding(.horizontal)
                        .padding(.top, 6)
                }
                if let summary = model.summary {
                    Text(summary)
                        .font(.callout)
                        .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .accessibilityIdentifier("reconciliation.summary")
                }
                table
            }
        }
        .searchable(text: $model.search, prompt: "Serial, model or user")
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $model.presence) {
                    ForEach(Reconciliation.Presence.allCases, id: \.self) { Text(model.title($0)).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .disabled(model.report == nil)
                .accessibilityLabel("Show devices in Apple only, in both, or in Mosyle only")
                .accessibilityIdentifier("reconciliation.presence")
            }
            ToolbarItem {
                Button("Export CSV…", systemImage: "square.and.arrow.up") { exporting = true }
                    .disabled(model.exportBlocked != nil)
                    .help(model.exportBlocked ?? "Exports every serial, in all three columns, as abapit's reconciliation export did")
                    .accessibilityIdentifier("reconciliation.export")
            }
        }
        .fileExporter(isPresented: $exporting, document: exporting ? CSVDocument(text: model.csv()) : nil,
                      contentType: .commaSeparatedText, defaultFilename: ScreenWords.filename("reconciliation.csv", client: exportClient)) { _ in }
        .task { model.load() }
    }

    /// Five of eight columns show by default, within the Devices table's minimums (530 pt); the rest are a right-click away.
    private var table: some View {
        Table(model.shown, sortOrder: $model.order, columnCustomization: $columns) {
            TableColumn("Serial", value: \.serial).width(min: 100, ideal: 130).customizationID("serial")
            TableColumn("Model", value: \.model).width(min: 100, ideal: 170).customizationID("model")
            TableColumn("Apple status", value: \.appleStatus).width(min: 80, ideal: 100).customizationID("apple-status")
            TableColumn("Mosyle status", value: \.mosyleStatus).width(min: 80, ideal: 100).customizationID("mosyle-status")
            TableColumn("Last check-in", value: \.lastCheckInSort) { Text(ScreenWords.day($0.lastCheckIn)) }
                .width(min: 80, ideal: 100).customizationID("check-in")
            TableColumn("Family", value: \.family).width(min: 60, ideal: 80).customizationID("family").defaultVisibility(.hidden)
            TableColumn("OS", value: \.os).width(min: 50, ideal: 70).customizationID("os").defaultVisibility(.hidden)
            TableColumn("User", value: \.user).width(min: 100, ideal: 180).customizationID("user").defaultVisibility(.hidden)
        }
        .accessibilityLabel("Reconciliation")
        .accessibilityIdentifier("reconciliation.table")
    }
}
