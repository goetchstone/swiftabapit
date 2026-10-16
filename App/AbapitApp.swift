import AppKit
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

    var body: some Scene {
        WindowGroup("abapit") {
            ContentView()
                .task { await Snapshots.runIfRequested() }
        }
        // Every launch opens a fresh window: an admin tool has nothing worth restoring, and a restored
        // "no windows" state once left a SwiftGamGui launch with no window at all.
        .restorationBehavior(.disabled)
        .defaultSize(width: 1200, height: 760)

        Settings {
            Text("Organizations, keys and permissions arrive in Phase 1.")
                .padding()
                .frame(width: 420)
        }
    }
}

/// The sidebar, mirroring abapit's navigation (plan §4). Sections are hidden by provider and scope, and
/// a section a probe found forbidden shows a lock, once the org store exists (Phase 1).
enum Section: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case devices = "Devices"
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
        case .people: "person.2"
        case .content: "square.stack.3d.up"
        case .activity: "list.bullet.clipboard"
        case .reports: "chart.bar.doc.horizontal"
        case .settings: "key"
        }
    }

    /// The phase that brings the section to life (plan §8), said on its placeholder.
    var arrives: String {
        switch self {
        case .overview, .devices, .settings: "Phase 1"
        case .people, .content: "Phase 2"
        case .activity: "Phases 2 and 4"
        case .reports: "Phase 3"
        }
    }

    /// The section a launch opens on: Overview, or in debug builds `ABAPIT_SCREEN` (for snapshots).
    static var initial: Section {
        #if DEBUG
        if let name = ProcessInfo.processInfo.environment["ABAPIT_SCREEN"],
           let section = allCases.first(where: { $0.rawValue.lowercased() == name.lowercased() }) { return section }
        #endif
        return .overview
    }
}

/// The widths the window is built from. On macOS 27 an inspector that can't fit beside a split view
/// loops AppKit's layout until it raises (SwiftGamGui failure-log 2026-10-10, "person-page layout loop"),
/// so every side column is bounded and the smallest window holds them at their widest.
enum ColumnWidths {
    static let sidebar = (min: 150.0, ideal: 180.0, max: 210.0)
    static let inspector = (min: 320.0, ideal: 360.0, max: 400.0)
    static let windowMin = 920.0
    static let windowMinHeight = 520.0
}

struct ContentView: View {
    @State private var section: Section? = Section.initial

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.symbol)
                    .accessibilityIdentifier("sidebar.\(item.rawValue.lowercased())")
            }
            .navigationSplitViewColumnWidth(min: ColumnWidths.sidebar.min, ideal: ColumnWidths.sidebar.ideal,
                                            max: ColumnWidths.sidebar.max)
        } detail: {
            let shown = section ?? .overview
            ContentUnavailableView {
                Label(shown.rawValue, systemImage: shown.symbol)
            } description: {
                Text("This section arrives in \(shown.arrives) of the port.")
            }
            .navigationTitle(shown.rawValue)
        }
        .navigationSubtitle("No organization yet")
        .frame(minWidth: ColumnWidths.windowMin, minHeight: ColumnWidths.windowMinHeight)
    }
}
