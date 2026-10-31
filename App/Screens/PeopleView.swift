import AppModels
import SwiftUI
import UniformTypeIdentifiers

/// People (plan §4; Appendix B: `/users`, `/user-groups`, `/org-units`): users, user groups and org units, one list at a
/// time behind a segmented control (an inner sidebar wouldn't fit beside the sidebar and the inspector in the smallest
/// window). Each list is a sortable, searchable table that fills as pages arrive, with its own banner (loading, cut at the
/// page cap, refused, failed, partial) and its own CSV export, off while it loads or is partial; a School org or an org
/// that can't be read gets the sentence instead of an empty table. The inspector shows the selected user's every
/// attribute, or the selected group's or org unit's members. Read-only: Apple's people are read-only at 2.6 (plan §2.4).
struct PeopleView: View {
    @Bindable var model: PeopleModel
    @State private var exporting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Picker("Show", selection: $model.tab) {
                ForEach(PeopleModel.Tab.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Show users, groups or org units")
            .accessibilityIdentifier("people.tab")
            .padding(.horizontal)
            .padding(.top, 8)
            switch model.tab {
            case .users: list(model.users) { users }
            case .groups: list(model.groups) { groups }
            case .units: list(model.units) { units }
            }
        }
        .searchable(text: $model.search, prompt: model.tab.prompt)
        .toolbar {
            ToolbarItem {
                Button("Export CSV…", systemImage: "square.and.arrow.up") { exporting = true }
                    .disabled(model.exportBlocked(model.tab) != nil)
                    .help(model.exportBlocked(model.tab) ?? "Exports the \(model.tab.title.lowercased()) shown, with this list's columns only")
                    .accessibilityIdentifier("people.export")
            }
        }
        // Written only when asked for: a large list's CSV isn't rebuilt on every redraw.
        .fileExporter(isPresented: $exporting, document: exporting ? CSVDocument(text: model.csv(model.tab)) : nil,
                      contentType: .commaSeparatedText, defaultFilename: model.tab.filename) { _ in }
        .inspector(isPresented: Binding(get: { model.hasSelection }, set: { if !$0 { model.clearSelection() } })) {
            PeopleInspectorView(model: model)
                .inspectorColumnWidth(min: ColumnWidths.inspector.min, ideal: ColumnWidths.inspector.ideal, max: ColumnWidths.inspector.max)
        }
        .task { model.load() }
    }

    /// One list: where its read stands and its table, or the sentence that takes the table's place.
    @ViewBuilder private func list<Row: Sendable, Content: View>(_ listing: PeopleModel.Listing<Row>, @ViewBuilder table: () -> Content) -> some View {
        if let why = listing.unavailable {
            ContentUnavailableView {
                Label(model.tab.title, systemImage: "person.2.slash")
            } description: {
                Text(why)
            }
            .accessibilityIdentifier("people.unavailable")
        } else {
            StatusBanner(state: listing.state, shown: listing.rows.count, truncated: listing.truncated, total: listing.total,
                         partial: listing.partialCount) { model.load(force: true) }
                .padding(.horizontal)
                .padding(.vertical, 6)
            table()
        }
    }

    private var users: some View {
        Table(model.shownUsers, selection: $model.selectedUser, sortOrder: $model.userOrder) {
            TableColumn("Name", value: \.name)
                .width(min: 120, ideal: 170)
            TableColumn("Managed Apple Account", value: \.account)
                .width(min: 140, ideal: 220)
            TableColumn("Email", value: \.email)
                .width(min: 120, ideal: 190)
            TableColumn("Status", value: \.status)
                .width(min: 60, ideal: 90)
            TableColumn("External", value: \.external)
                .width(min: 50, ideal: 60)
            TableColumn("Department", value: \.department)
                .width(min: 80, ideal: 120)
            TableColumn("Job title", value: \.jobTitle)
                .width(min: 80, ideal: 140)
            TableColumn("Start date", value: \.startedSort) { Text(ScreenWords.day($0.started)) }
                .width(min: 80, ideal: 100)
        }
        .accessibilityLabel("Users")
        .accessibilityIdentifier("people.users.table")
        .selectsFirstRow($model.selectedUser, first: model.shownUsers.first?.id, ready: !model.users.state.isLoading)
    }

    private var groups: some View {
        Table(model.shownGroups, selection: $model.selectedGroup, sortOrder: $model.groupOrder) {
            TableColumn("Name", value: \.name)
                .width(min: 120, ideal: 200)
            TableColumn("Type", value: \.type)
                .width(min: 60, ideal: 80)
            TableColumn("Status", value: \.status)
                .width(min: 60, ideal: 80)
            // Apple's count, or a dash: never a zero nobody counted.
            TableColumn("Members", value: \.membersSort) { Text($0.membersText) }
                .width(min: 60, ideal: 80)
            TableColumn("Org unit", value: \.unit)
                .width(min: 100, ideal: 160)
        }
        .accessibilityLabel("User groups")
        .accessibilityIdentifier("people.groups.table")
        .selectsFirstRow($model.selectedGroup, first: model.shownGroups.first?.id, ready: !model.groups.state.isLoading)
    }

    private var units: some View {
        Table(model.shownUnits, selection: $model.selectedUnit, sortOrder: $model.unitOrder) {
            TableColumn("Name", value: \.name)
                .width(min: 120, ideal: 200)
            TableColumn("Description", value: \.summary)
                .width(min: 140, ideal: 280)
            TableColumn("Updated", value: \.updatedSort) { Text(ScreenWords.day($0.updated)) }
                .width(min: 80, ideal: 100)
        }
        .accessibilityLabel("Org units")
        .accessibilityIdentifier("people.units.table")
        .selectsFirstRow($model.selectedUnit, first: model.shownUnits.first?.id, ready: !model.units.state.isLoading)
    }
}
