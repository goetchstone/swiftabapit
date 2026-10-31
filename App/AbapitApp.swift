import AppKit
import AppModels
import Reports
import SwiftUI

/// The process's entry point. A debug spike (`ABAPIT_SPIKE`) runs headless and exits before AppKit or
/// SwiftUI starts, so it never puts a window on the operator's screen (CLAUDE.md, rules of engagement;
/// SwiftGamGui RULE-FEEDBACK 2026-10-10). Everything else is the app.
@main
enum Launch {
    static func main() {
        #if DEBUG
        if let spike = ProcessInfo.processInfo.environment["ABAPIT_SPIKE"] {
            exit(Spikes.run(spike))
        }
        #endif
        AbapitApp.main()
    }
}

struct AbapitApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var services = AppServices.make()

    var body: some Scene {
        WindowGroup("abapit") {
            ContentView(services: services)
                .task { await Snapshots.runIfRequested() }
        }
        // Every launch opens a fresh window: an admin tool has nothing worth restoring, and a restored
        // "no windows" state once left a SwiftGamGui launch with no window at all.
        .restorationBehavior(.disabled)
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(after: .toolbar) {
                // The window's section decides what it reads again (`ContentView.refresh`).
                Button("Refresh") { NotificationCenter.default.post(name: .refreshSection, object: nil) }
                    .keyboardShortcut("r")
                Button("Find Device…") { NotificationCenter.default.post(name: .findDevice, object: nil) }
                    .keyboardShortcut("l")
            }
        }

        Settings {
            SettingsView(orgs: services.orgs, isDemo: services.isDemo)
                .frame(minWidth: 760, minHeight: 480)
        }
    }
}

extension Notification.Name {
    static let findDevice = Notification.Name("io.github.goetchstone.swiftabapit.findDevice")
    static let refreshSection = Notification.Name("io.github.goetchstone.swiftabapit.refreshSection")
}

/// What the app adds to the sidebar's sections (`SidebarItem`, in AppModels, where the scope and lock rules are
/// tested): each one's symbol and the section a launch opens on.
extension SidebarItem {
    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .devices: "laptopcomputer.and.iphone"
        case .services: "server.rack"
        case .appleMDM: "ipad.and.iphone"
        case .people: "person.2"
        case .content: "square.stack.3d.up"
        case .activity: "list.bullet.clipboard"
        case .reports: "chart.bar.doc.horizontal"
        case .settings: "key"
        }
    }

    /// The section a launch opens on: Overview, or in debug builds `ABAPIT_SCREEN` (a raw value, for snapshots).
    static var initial: SidebarItem {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["ABAPIT_SCREEN"],
           let section = allCases.first(where: { $0.rawValue == name.lowercased() }) { return section }
        #endif
        return .overview
    }
}

/// The widths the window is built from. On macOS 27 an inspector that can't fit beside a split view loops
/// AppKit's layout until it raises (SwiftGamGui failure-log 2026-10-10, "person-page layout loop"), so every
/// side column is bounded and the smallest window holds them at their widest.
enum ColumnWidths {
    static let sidebar = (min: 150.0, ideal: 180.0, max: 210.0)
    static let inspector = (min: 300.0, ideal: 340.0, max: 380.0)
    static let windowMin = 1_000.0
    static let windowMinHeight = 560.0
}

struct ContentView: View {
    let services: AppServices
    @State private var section: SidebarItem? = SidebarItem.initial
    @State private var selection: DeviceRow.ID?
    @State private var finding = false
    @State private var query = ""

    private var orgs: OrgsModel { services.orgs }

    /// The section on screen: the one chosen, unless the active org's scope hides it (a School org has no people,
    /// content, Apple MDM or audit to read: plan §2.4, §4), then the Overview.
    private var shown: SidebarItem { SidebarItem.showing(section, for: orgs.active) }

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.shown(for: orgs.active), selection: $section) { item in
                let locked = item.isLocked(for: orgs.active)
                Label(item.title, systemImage: locked ? "lock" : item.symbol)
                    .accessibilityLabel(locked ? "\(item.title), your role can't read this" : item.title)
                    .accessibilityIdentifier("sidebar.\(item.rawValue)")
            }
            .navigationSplitViewColumnWidth(min: ColumnWidths.sidebar.min, ideal: ColumnWidths.sidebar.ideal, max: ColumnWidths.sidebar.max)
        } detail: {
            detail(shown)
                .navigationTitle(shown.title)
        }
        .navigationSubtitle(orgs.active.map { "\($0.name)\($0.role.isEmpty ? "" : " · \($0.role)")" } ?? "No organization yet")
        .toolbar {
            if orgs.store.orgs.count > 1 {
                ToolbarItem(placement: .navigation) {
                    Picker("Organization", selection: Binding(get: { orgs.active?.id ?? "" }, set: { orgs.select($0) })) {
                        ForEach(orgs.store.orgs) { Text($0.name).tag($0.id) }
                    }
                    .accessibilityIdentifier("toolbar.org")
                }
            }
            ToolbarItem {
                Button("Refresh", systemImage: "arrow.clockwise", action: refresh)
                    .help("Read this section again from Apple (⌘R)")
                    .disabled(orgs.active == nil)
                    .accessibilityIdentifier("toolbar.refresh")
            }
        }
        .onChange(of: orgs.generation) { selection = nil }
        // A section the org's scope hides isn't left selected: an org switch, or a launch on one, moves to the Overview.
        .onChange(of: shown, initial: true) { _, now in if section != now { section = now } }
        .onReceive(NotificationCenter.default.publisher(for: .findDevice)) { _ in finding = true }
        .onReceive(NotificationCenter.default.publisher(for: .refreshSection)) { _ in refresh() }
        .sheet(isPresented: $finding) { findSheet }
        .frame(minWidth: ColumnWidths.windowMin, minHeight: ColumnWidths.windowMinHeight)
        #if DEBUG
        // The snapshot harness's row selection (`ABAPIT_SELECT=first`): each screen with an inspector reads it
        // through `selectsFirstRow` (Screens/FirstRowSelection.swift).
        .environment(\.selectsFirstRow, ProcessInfo.processInfo.environment["ABAPIT_SELECT"] == "first")
        #endif
    }

    /// Refresh (⌘R, the toolbar): the section on screen reads again from Apple, by `ScreenModels.refresh`'s routing, which
    /// the package's tests hold.
    private func refresh() { services.screens.refresh(shown) }

    @ViewBuilder private func detail(_ section: SidebarItem) -> some View {
        if section.isLocked(for: orgs.active) {
            ContentUnavailableView {
                Label("Your role can't read this", systemImage: "lock")
            } description: {
                Text("The last permissions check found this API account's role can't read \(section.phrase).")
            } actions: {
                Button("Re-check in Settings") { self.section = .settings }
            }
        } else {
            switch section {
            case .overview: OverviewView(model: services.dashboard, hasOrg: orgs.active != nil) { self.section = .settings }
            case .devices: DevicesView(model: services.devices, detail: services.detail, selection: $selection)
            case .services: ServicesView(model: services.devices)
            case .appleMDM: AppleMDMView(model: services.appleMDM)
            case .people: PeopleView(model: services.people)
            case .content: ContentScreen(model: services.content)
            case .activity: ActivityView(model: services.activity)
            case .settings: SettingsView(orgs: orgs, isDemo: services.isDemo)
            case .reports:
                ContentUnavailableView {
                    Label(section.title, systemImage: section.symbol)
                } description: {
                    Text("This section arrives in Phase 3 of the port.")
                }
            }
        }
    }

    /// Find (⌘L): an exact identifier opens that device; several matches filter the table (abapit's `/find`).
    private var findSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Find a device").font(.headline)
            TextField("Serial, IMEI, MEID, EID, order number or MAC address", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 380)
                .onSubmit(find)
                .accessibilityIdentifier("find.field")
            HStack {
                Spacer()
                Button("Cancel") { finding = false }.keyboardShortcut(.cancelAction)
                Button("Find", action: find).keyboardShortcut(.defaultAction).disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
    }

    private func find() {
        let hits = Find.matches(query, in: services.devices.devices)
        section = .devices
        if hits.count == 1 {
            services.devices.search = ""
            selection = hits[0].id
        } else {
            services.devices.search = query
        }
        finding = false
        query = ""
    }
}
