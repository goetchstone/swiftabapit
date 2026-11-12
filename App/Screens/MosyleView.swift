import AppModels
import JSONAPI
import Mosyle
import Reports
import SwiftUI
import UniformTypeIdentifiers

/// Mosyle Business (plan Phase 7; Appendix B): the Mosyle org in view, the active one or the one the active Apple org is
/// paired with. One list at a time, chosen in the toolbar (a menu: eight lists wouldn't fit a segmented control beside the
/// sidebar in the smallest window): devices, users, user groups, device groups with their members and compliance, custom
/// device attributes, the admin log, and abapit's two Mosyle reports over the devices. Each list has its banner, its notes
/// and its own CSV; an Apple org with no Mosyle org paired gets the sentence instead of a table. Every word is the model's
/// (`MosyleModel`). Read-only: Mosyle's writes are Phase 8's.
struct MosyleView: View {
    @Bindable var model: MosyleModel
    @State private var exporting = false
    @Environment(\.exportClient) private var exportClient
    @SceneStorage("mosyle.devices.columns") private var deviceColumns = TableColumnCustomization<MosyleModel.DeviceRow>()
    @SceneStorage("mosyle.log.columns") private var logColumns = TableColumnCustomization<MosyleModel.RecordRow>()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch model.tab {
            case .devices: list(model.devices) { devices }
            case .users: list(model.users) { people(model.users, label: "Users", detail: "Email", kind: "Type") }
            case .userGroups: list(model.userGroups) { people(model.userGroups, label: "User groups", detail: "Members", kind: "Platform") }
            case .deviceGroups: list(model.deviceGroups) { deviceGroups }
            case .attributes: list(model.attributes) { attributes }
            case .adminLog: list(model.adminLog) { adminLog }
            case .osVersions: list(model.devices) { report { versions } }
            case .stale: list(model.devices) { report { stale } }
            }
        }
        .searchable(text: $model.search, prompt: model.tab.prompt)
        .toolbar {
            ToolbarItem {
                Picker("Show", selection: $model.tab) {
                    ForEach(MosyleModel.Tab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Show which Mosyle list")
                .accessibilityIdentifier("mosyle.tab")
            }
            if model.tab == .adminLog {
                ToolbarItem {
                    Picker("Days", selection: $model.adminDays) {
                        ForEach([1, 7, 30, 90, 365], id: \.self) { Text("Last \($0) day\($0 == 1 ? "" : "s")").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("How far back the admin log reads")
                    .accessibilityIdentifier("mosyle.adminDays")
                }
            }
            if model.tab == .stale {
                ToolbarItem {
                    Picker("Silent for", selection: $model.staleDays) {
                        ForEach([7, 14, 30, 60, 90], id: \.self) { Text("\($0) days or more").tag($0) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("How long without a check-in counts")
                    .accessibilityIdentifier("mosyle.staleDays")
                }
            }
            ToolbarItem {
                Button("Export CSV…", systemImage: "square.and.arrow.up") { exporting = true }
                    .disabled(model.exportBlocked(model.tab) != nil)
                    .help(model.exportBlocked(model.tab) ?? "Exports the \(model.tab.title.lowercased()) shown, with this list's columns only")
                    .accessibilityIdentifier("mosyle.export")
            }
        }
        .fileExporter(isPresented: $exporting, document: exporting ? CSVDocument(text: model.csv(model.tab)) : nil,
                      contentType: .commaSeparatedText, defaultFilename: ScreenWords.filename(model.tab.filename, client: exportClient)) { _ in }
        .inspector(isPresented: Binding(get: { model.hasSelection }, set: { if !$0 { model.clearSelection() } })) {
            MosyleInspectorView(model: model)
                .inspectorColumnWidth(min: ColumnWidths.inspector.min, ideal: ColumnWidths.inspector.ideal, max: ColumnWidths.inspector.max)
        }
        .task { model.load() }
    }

    /// One list: its banner and notes, then its table; or the sentence that takes the table's place.
    @ViewBuilder private func list<Row: Sendable, Content: View>(_ listing: MosyleModel.Listing<Row>, @ViewBuilder table: () -> Content) -> some View {
        if let why = listing.unavailable {
            ContentUnavailableView {
                Label(model.tab.title, systemImage: "iphone.slash")
            } description: {
                Text(why)
            }
            .accessibilityIdentifier("mosyle.unavailable")
        } else {
            StatusBanner(state: listing.state, shown: listing.rows.count, truncated: listing.truncated, partial: listing.partialCount) {
                model.load(force: true)
            }
            .padding(.horizontal)
            .padding(.top, 6)
            if let note = model.note(model.tab) {
                // Wrapping text takes an ideal width of 0, so its longest line never sets the pane's width (PR 12's Activity crash).
                Label(note, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 0, idealWidth: 0, maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .accessibilityIdentifier("mosyle.note")
            }
            Spacer().frame(height: 6)
            table()
        }
    }

    /// A report over the devices: its table once the devices are read whole, else what it waits for.
    @ViewBuilder private func report<Content: View>(@ViewBuilder _ table: () -> Content) -> some View {
        if model.devices.isWhole {
            table()
        } else {
            ContentUnavailableView(model.tab.title, systemImage: "chart.bar.xaxis", description: Text(model.reportNote ?? ""))
        }
    }

    /// Five of seven columns show by default, within the Devices table's minimums (530 pt); the rest are a right-click away,
    /// and the inspector and the CSV hold every one.
    private var devices: some View {
        Table(model.shownDevices, selection: $model.selectedDevice, sortOrder: $model.deviceOrder, columnCustomization: $deviceColumns) {
            TableColumn("Serial", value: \.serial).width(min: 100, ideal: 130).customizationID("serial")
            TableColumn("Name", value: \.name).width(min: 110, ideal: 180).customizationID("name")
            TableColumn("Model", value: \.model).width(min: 100, ideal: 150).customizationID("model")
            TableColumn("OS", value: \.os).width(min: 50, ideal: 70).customizationID("os")
            TableColumn("Last check-in", value: \.lastCheckInSort) { Text(ScreenWords.day($0.lastCheckIn)) }
                .width(min: 80, ideal: 100).customizationID("check-in")
            TableColumn("Family", value: \.family).width(min: 60, ideal: 80).customizationID("family").defaultVisibility(.hidden)
            TableColumn("User", value: \.user).width(min: 100, ideal: 180).customizationID("user").defaultVisibility(.hidden)
        }
        .accessibilityLabel("Mosyle devices")
        .accessibilityIdentifier("mosyle.devices.table")
        .selectsFirstRow($model.selectedDevice, first: model.shownDevices.first?.id, ready: !model.devices.state.isLoading)
    }

    private func people(_ listing: MosyleModel.Listing<MosyleModel.PersonRow>, label: String, detail: String, kind: String) -> some View {
        Table(model.shown(listing), sortOrder: $model.personOrder) {
            TableColumn("Name", value: \.name).width(min: 120, ideal: 200)
            TableColumn(detail, value: \.detail).width(min: 80, ideal: 200)
            TableColumn("Identifier", value: \.identifier).width(min: 90, ideal: 140)
            TableColumn(kind, value: \.kind).width(min: 60, ideal: 100)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier("mosyle.people.table")
    }

    private var deviceGroups: some View {
        Table(model.shown(model.deviceGroups), selection: $model.selectedGroup, sortOrder: $model.personOrder) {
            TableColumn("Name", value: \.name).width(min: 120, ideal: 200)
            TableColumn("Devices", value: \.detail).width(min: 60, ideal: 80)
            TableColumn("Platform", value: \.kind).width(min: 70, ideal: 100)
            TableColumn("Identifier", value: \.identifier).width(min: 80, ideal: 120)
        }
        .accessibilityLabel("Device groups")
        .accessibilityIdentifier("mosyle.groups.table")
    }

    private var attributes: some View {
        Table(model.shown(model.attributes), sortOrder: $model.recordOrder) {
            TableColumn("Attribute", value: \.title).width(min: 120, ideal: 180)
            TableColumn("Value", value: \.detail).width(min: 80, ideal: 160)
            TableColumn("Platform", value: \.extra).width(min: 70, ideal: 100)
            TableColumn("Source", value: \.note).width(min: 60, ideal: 90)
        }
        .accessibilityLabel("Custom device attributes")
        .accessibilityIdentifier("mosyle.attributes.table")
    }

    private var adminLog: some View {
        Table(model.shown(model.adminLog), sortOrder: $model.recordOrder, columnCustomization: $logColumns) {
            TableColumn("When", value: \.whenSort) { Text($0.when.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? $0.note) }
                .width(min: 110, ideal: 150).customizationID("when")
            TableColumn("Admin", value: \.detail).width(min: 120, ideal: 200).customizationID("admin")
            TableColumn("Action", value: \.title).width(min: 140, ideal: 260).customizationID("action")
            TableColumn("Address", value: \.extra).width(min: 80, ideal: 110).customizationID("ip").defaultVisibility(.hidden)
        }
        .accessibilityLabel("Admin log")
        .accessibilityIdentifier("mosyle.adminLog.table")
    }

    private var versions: some View {
        Table(model.shownVersions) {
            TableColumn("OS version", value: \.version).width(min: 100, ideal: 160)
            TableColumn("Devices") { Text($0.count.formatted()) }.width(min: 60, ideal: 80)
            TableColumn("Share") { Text("\($0.percent.formatted())%") }.width(min: 60, ideal: 80)
        }
        .accessibilityLabel("Mosyle OS versions")
        .accessibilityIdentifier("mosyle.versions.table")
    }

    private var stale: some View {
        Table(model.shownStale()) {
            TableColumn("Serial") { Text($0.serial) }.width(min: 100, ideal: 130)
            TableColumn("Model") { Text(MosyleView.text($0.deviceModel)) }.width(min: 100, ideal: 150)
            TableColumn("Last check-in") { Text(MosyleView.text($0.lastCheckIn)) }.width(min: 90, ideal: 160)
            TableColumn("Days") { Text($0.daysStale.map { $0.formatted() } ?? "Never") }.width(min: 50, ideal: 60)
            TableColumn("User") { Text(MosyleView.text($0.currentUser)) }.width(min: 100, ideal: 160)
        }
        .accessibilityLabel("Mosyle devices not checking in")
        .accessibilityIdentifier("mosyle.stale.table")
    }

    static func text(_ value: JSONValue) -> String {
        switch value {
        case .string(let text): text.isEmpty ? "—" : text
        case .number(let text): text
        default: "—"
        }
    }
}

/// The Mosyle inspector: a device's fields and its Mosyle dates, or a device group's members, all of them or only the
/// compliant or the non-compliant ones, each named by the device the device list holds, else by its UDID.
struct MosyleInspectorView: View {
    @Bindable var model: MosyleModel

    var body: some View {
        Form {
            switch model.tab {
            case .deviceGroups: if let row = model.group { group(row) } else { missing }
            default: if let row = model.device { device(row) } else { missing }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("mosyle.inspector")
    }

    @ViewBuilder private var missing: some View {
        if let note = model.selectionNote {
            Section { Label(note, systemImage: "questionmark.circle") }
        }
    }

    @ViewBuilder private func device(_ row: MosyleModel.DeviceRow) -> some View {
        Section("Device") {
            ForEach(MosyleModel.fields(of: row), id: \.label) { field in
                LabeledContent(field.label, value: field.value).textSelection(.enabled)
            }
        }
        Section("Dates") {
            let items = MosyleModel.timeline(of: row)
            if items.isEmpty { Text("Mosyle sent no dates for this device.").foregroundStyle(.secondary) }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                LabeledContent(item.label, value: item.when)
            }
        }
    }

    @ViewBuilder private func group(_ row: MosyleModel.PersonRow) -> some View {
        Section("Device group") {
            LabeledContent("Name", value: row.name)
            LabeledContent("Platform", value: row.kind)
            LabeledContent("Devices, Mosyle's count", value: row.detail)
        }
        Section("Members") {
            Picker("Show", selection: $model.memberFilter) {
                Text("All").tag(MosyleRead.Compliance?.none)
                Text("Compliant").tag(MosyleRead.Compliance?.some(.compliant))
                Text("Not compliant").tag(MosyleRead.Compliance?.some(.noncompliant))
            }
            .accessibilityIdentifier("mosyle.memberFilter")
            PanelView(model.members.panel) { _ in
                let rows = model.memberRows
                if rows.isEmpty { Text("No members.").foregroundStyle(.secondary) }
                ForEach(rows) { member in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(member.name)
                        Text(member.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                }
                if let note = model.memberNote { Label(note, systemImage: "questionmark.circle").foregroundStyle(.secondary) }
            }
        }
    }
}
