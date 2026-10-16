import AppKit
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
                Button("Refresh") { services.devices.load(force: true) }
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
}

/// The sidebar, mirroring abapit's navigation (plan §4). A section a probe found forbidden shows a lock.
enum SidebarItem: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case devices = "Devices"
    case services = "Services"
    case people = "People"
    case content = "Content"
    case activity = "Activity"
    case reports = "Reports"
    case settings = "Settings"

    var id: Self { self }

    var symbol: String {
        switch self {
        case .overview: "gauge.with.dots.needle.33percent"
        case .devices: "laptopcomputer.and.iphone"
        case .services: "server.rack"
        case .people: "person.2"
        case .content: "square.stack.3d.up"
        case .activity: "list.bullet.clipboard"
        case .reports: "chart.bar.doc.horizontal"
        case .settings: "key"
        }
    }

    /// The probe section whose "forbidden" locks this one.
    var probed: String? {
        switch self {
        case .devices: "devices"
        case .services: "mdm_servers"
        case .people: "users"
        case .content: "apps"
        case .activity: "audit_events"
        default: nil
        }
    }

    /// The phase that brings a placeholder section to life (plan §8).
    var arrives: String? {
        switch self {
        case .people, .content: "Phase 2"
        case .activity: "Phases 2 and 4"
        case .reports: "Phase 3"
        default: nil
        }
    }

    /// The section a launch opens on: Overview, or in debug builds `ABAPIT_SCREEN` (for snapshots).
    static var initial: SidebarItem {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["ABAPIT_SCREEN"],
           let section = allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) { return section }
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

    var body: some View {
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $section) { item in
                let locked = item.probed.map { orgs.active?.deniedSections.contains($0) == true } ?? false
                Label(item.rawValue, systemImage: locked ? "lock" : item.symbol)
                    .accessibilityLabel(locked ? "\(item.rawValue), your role can't read this" : item.rawValue)
                    .accessibilityIdentifier("sidebar.\(item.rawValue.lowercased())")
            }
            .navigationSplitViewColumnWidth(min: ColumnWidths.sidebar.min, ideal: ColumnWidths.sidebar.ideal, max: ColumnWidths.sidebar.max)
        } detail: {
            detail(section ?? .overview)
                .navigationTitle((section ?? .overview).rawValue)
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
                Button("Refresh", systemImage: "arrow.clockwise") { services.devices.load(force: true) }
                    .help("Read again from Apple (⌘R)")
                    .disabled(orgs.active == nil)
            }
        }
        .onChange(of: orgs.generation) { selection = nil }
        .onReceive(NotificationCenter.default.publisher(for: .findDevice)) { _ in finding = true }
        .sheet(isPresented: $finding) { findSheet }
        .frame(minWidth: ColumnWidths.windowMin, minHeight: ColumnWidths.windowMinHeight)
        #if DEBUG
        .task { await selectForSnapshot() }
        #endif
    }

    @ViewBuilder private func detail(_ section: SidebarItem) -> some View {
        if let probed = section.probed, orgs.active?.deniedSections.contains(probed) == true {
            ContentUnavailableView {
                Label("Your role can't read this", systemImage: "lock")
            } description: {
                Text("The last permissions check found this API account's role can't read \(section.rawValue.lowercased()).")
            } actions: {
                Button("Re-check in Settings") { self.section = .settings }
            }
        } else {
            switch section {
            case .overview: OverviewView(model: services.devices, hasOrg: orgs.active != nil) { self.section = .settings }
            case .devices: DevicesView(model: services.devices, detail: services.detail, selection: $selection)
            case .services: ServicesView(model: services.devices)
            case .settings: SettingsView(orgs: orgs, isDemo: services.isDemo)
            default:
                ContentUnavailableView {
                    Label(section.rawValue, systemImage: section.symbol)
                } description: {
                    Text("This section arrives in \(section.arrives ?? "a later phase") of the port.")
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

    #if DEBUG
    /// `ABAPIT_SELECT=first` for snapshots: selects the first device once the table has loaded, so the inspector
    /// shows (demo serials come from a seed, so the picture is stable).
    private func selectForSnapshot() async {
        guard ProcessInfo.processInfo.environment["ABAPIT_SELECT"] == "first" else { return }
        for _ in 0..<40 {
            if let first = services.devices.shown.first, !services.devices.state.isLoading {
                selection = first.id
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
    #endif
}
