import AppKit
import AppleBusiness
import AppleModels
import AppModels
import Orgs
import SwiftUI
import UniformTypeIdentifiers
import Vault

/// Settings (plan §4): the organizations, each with Test and Permissions; adding, editing and removing one.
/// Secrets go to the Keychain; `orgs.json` keeps the rest (plan §3.7).
struct SettingsView: View {
    let orgs: OrgsModel
    let isDemo: Bool
    @State private var selected: String?
    @State private var editing: OrgEditor.Mode?
    /// The Mosyle org being edited, or `.add`.
    @State private var editingMosyle: OrgEditor.Mode?
    /// The selected org's client's name as typed, renamed on Return.
    @State private var clientName = ""
    @State private var removing: OrgProfile?
    @State private var testResult: [String: String] = [:]
    @State private var working: String?
    @State private var problem: String?
    @State private var acceptance: String?

    private var profile: OrgProfile? { orgs.store[selected ?? orgs.active?.id ?? ""] }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                // By client only when there are two or more (the operator, 2026-11-12): with one, the list is as it was.
                List(selection: $selected) {
                    if orgs.showsClients {
                        ForEach(orgs.clients) { client in
                            Section(client.name) { ForEach(client.orgs.compactMap { orgs.store[$0] }) { row($0) } }
                        }
                    } else {
                        ForEach(orgs.store.orgs) { row($0) }
                    }
                }
                .accessibilityIdentifier("settings.orgs")
                HStack {
                    Menu("Add", systemImage: "plus") {
                        Button("Apple Business or Apple School Manager…") { editing = .add }
                            .accessibilityIdentifier("settings.add")
                        Button("Mosyle Business…") { editingMosyle = .add }
                            .accessibilityIdentifier("settings.addMosyle")
                    }
                    .accessibilityIdentifier("settings.addMenu")
                    Spacer()
                }
                .padding([.horizontal, .bottom], 8)
            }
            .frame(minWidth: 220, idealWidth: 260, maxWidth: 320)

            Form {
                if let message = orgs.problem ?? problem {
                    Label(message, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
                }
                if isDemo {
                    Label("Demo: this organization lives in memory and its \"Apple\" is the test stub. Nothing is saved.", systemImage: "theatermasks")
                }
                // What grouping the organizations into clients changed, said until read (plan §8.0, "Clients").
                if !orgs.migrationNotes.isEmpty {
                    Section("Clients") {
                        ForEach(orgs.migrationNotes, id: \.self) { Label($0, systemImage: "arrow.triangle.branch") }
                        Button("Got It") { orgs.dismissMigrationNotes() }.accessibilityIdentifier("settings.notes.dismiss")
                    }
                }
                if let profile, profile.provider == .known(.mosyle) {
                    mosyle(profile)
                } else if let profile {
                    Section(profile.name) {
                        LabeledContent("Scope", value: profile.scope.known?.displayName ?? profile.scope.rawValue)
                        if profile.scope == .known(.school) {
                            Label(ScreenWords.schoolUnverified, systemImage: "checkmark.seal.trianglebadge.exclamationmark")
                                .foregroundStyle(.secondary)
                        }
                        LabeledContent("Client ID", value: profile.clientID).textSelection(.enabled)
                        LabeledContent("Key ID", value: profile.keyID).textSelection(.enabled)
                        LabeledContent("Team ID", value: profile.teamID.isEmpty ? "— (the client ID is the issuer)" : profile.teamID)
                        LabeledContent("Role", value: profile.role.isEmpty ? "—" : profile.role)
                        if let problem = profile.problem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                        HStack {
                            if profile.id != orgs.active?.id { Button("Make Active") { orgs.select(profile.id) } }
                            Button("Test") { test(profile) }.disabled(working != nil)
                                .help("Mints a token and reads one device: proves the key, the account and the network")
                            Button("Check Permissions") { probe(profile) }.disabled(working != nil)
                                .help("Reads one item from each section; Apple has no permissions endpoint")
                            Spacer()
                            Button("Edit…") { editing = .edit(profile) }
                            Button("Remove…", role: .destructive) { removing = profile }
                        }
                        if working == profile.id { ProgressView().controlSize(.small) }
                        if let result = testResult[profile.id] { Text(result) }
                        #if DEBUG
                        Button("Run Acceptance Pass") { accept(profile) }.disabled(working != nil)
                            .help("Every read this version makes; reports counts and unknown field names, never data (plan §7)")
                        #endif
                    }
                    clientSection(profile)
                    // What the profile holds, never a copy kept here: an edit to another account clears it there, and a
                    // check of the old account is never recorded (verifier round 2: this view kept its own results).
                    let found = Self.stored(profile)
                    if !found.isEmpty {
                        Section("Permissions\(profile.probedAt.isEmpty ? "" : " (checked \(profile.probedAt))")") {
                            ForEach(found, id: \.section) { result in
                                LabeledContent(result.section.displayName) {
                                    switch result.status {
                                    case ProbeResult.ok: Label("Can read", systemImage: "checkmark.circle")
                                    case ProbeResult.forbidden: Label("Your role can't read this", systemImage: "lock")
                                    default: Label(result.status, systemImage: "exclamationmark.triangle")
                                    }
                                }
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("No organization selected", systemImage: "building.2",
                                           description: Text("Add an Apple Business or Apple School Manager API account."))
                }
            }
            .formStyle(.grouped)
            .frame(minWidth: 380)
        }
        .onAppear {
            #if DEBUG
            // The snapshot harness's add sheet (`ABAPIT_SHEET`, scripts/screenshots.sh): CI draws the customer question.
            switch ProcessInfo.processInfo.environment["ABAPIT_SHEET"] {
            case "add-apple": editing = .add
            case "add-mosyle": editingMosyle = .add
            default: break
            }
            #endif
        }
        .sheet(item: $editing) { mode in OrgEditor(mode: mode, orgs: orgs) }
        // A Test's result belongs to the credentials it read: an edit may have changed them.
        .sheet(item: $editingMosyle, onDismiss: { testResult = [:] }) { mode in
            MosyleOrgEditor(editing: { if case .edit(let profile) = mode { profile } else { nil } }(), orgs: orgs)
        }
        .sheet(isPresented: Binding(get: { acceptance != nil }, set: { if !$0 { acceptance = nil } })) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Acceptance pass").font(.headline)
                ScrollView { Text(acceptance ?? "").monospaced().textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(acceptance ?? "", forType: .string) }
                    Spacer()
                    Button("Done") { acceptance = nil }.keyboardShortcut(.defaultAction)
                }
            }
            .padding()
            .frame(minWidth: 560, minHeight: 360)
        }
        .confirmationDialog("Remove \(removing?.name ?? "this organization")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            presenting: removing) { profile in
            Button(profile.provider == .known(.mosyle) ? "Remove and Delete Its Credentials" : "Remove and Delete Its Key", role: .destructive) {
                remove(profile)
            }
            Button("Cancel", role: .cancel) {}
        } message: { profile in
            Text(profile.provider == .known(.mosyle)
                 ? "Its credentials are deleted from this Mac's Keychain, and its settings from abapit. Mosyle keeps the access token: revoke it there if you no longer need it."
                 : "Its key is deleted from this Mac's Keychain, and its settings from abapit. Apple Business keeps the API account: revoke it there if you no longer need it.")
        }
    }

    /// A Mosyle Business org: its name, Test (a login and one page of Macs), its pair, Edit and Remove. Its credentials are
    /// in the Keychain and never shown.
    @ViewBuilder private func mosyle(_ profile: OrgProfile) -> some View {
        Section(profile.name) {
            LabeledContent("Provider", value: "Mosyle Business")
            LabeledContent("Credentials", value: "In this Mac's Keychain")
            HStack {
                if profile.id != orgs.active?.id { Button("Make Active") { orgs.select(profile.id) } }
                Button("Test") { testMosyle(profile) }.disabled(working != nil)
                    .help("Logs in afresh with the stored credentials and reads one page of Macs: proves the token, the admin account and the network")
                Spacer()
                Button("Edit…") { editingMosyle = .edit(profile) }
                Button("Remove…", role: .destructive) { removing = profile }
            }
            if working == profile.id { ProgressView().controlSize(.small) }
            if let result = testResult[profile.id] { Text(result) }
        }
        clientSection(profile)
    }

    /// One org in the list: its name, whether it is active, its kind.
    private func row(_ org: OrgProfile) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(org.name.isEmpty ? org.id : org.name)
                if org.id == orgs.active?.id { Text("Active").font(.caption).foregroundStyle(.secondary) }
            }
            Text([org.provider == .known(.mosyle) ? "Mosyle Business" : org.scope.known?.displayName ?? org.provider.rawValue, org.role]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary)
        }
        .tag(org.id)
        .accessibilityElement(children: .combine)
    }

    /// The org's client. With two or more: which it belongs to (another with room for it, or a new one of its own) and the
    /// client's name; a client has one Apple organization and one MDM organization. With one, no client is named: an org
    /// grouped with another says so, with Separate to make it a different customer's, so a join made in the add sheet can
    /// always be seen and undone (plan §8.0, "Clients").
    @ViewBuilder private func clientSection(_ profile: OrgProfile) -> some View {
        if !orgs.showsClients, let grouping = orgs.grouping(of: profile.id) {
            Section {
                HStack {
                    Text(grouping).accessibilityIdentifier("settings.groupedWith")
                    Spacer()
                    Button("Separate") {
                        do {
                            try orgs.move(profile.id, toClient: nil)
                            problem = nil
                        } catch {
                            problem = OrgsModel.message(error)
                        }
                    }
                    .help("Makes this organization a different customer's: it is no longer read with the other.")
                    .accessibilityIdentifier("settings.separate")
                }
            } header: {
                Text("Customer")
            } footer: {
                Text("Grouped organizations are one customer's: their devices are read together, Apple's against Mosyle's.")
                    .foregroundStyle(.secondary)
            }
        } else if orgs.showsClients, let client = orgs.store.client(of: profile.id) {
            let slot = Client.Slot(profile)
            let room = orgs.clients.filter { $0.id == client.id || !$0.has(slot) }
            Section("Client") {
                Picker("Client", selection: Binding(get: { client.id }, set: { pick in
                    do {
                        try orgs.move(profile.id, toClient: pick.isEmpty ? nil : pick)
                        problem = nil
                    } catch {
                        problem = OrgsModel.message(error)
                    }
                })) {
                    ForEach(room) { Text($0.name).tag($0.id) }
                    if client.orgs.count > 1 { Text("A new client of its own").tag("") }
                }
                .accessibilityIdentifier("settings.client")
                TextField("Client name", text: $clientName)
                    .onSubmit {
                        do {
                            try orgs.renameClient(client.id, to: clientName)
                            problem = nil
                        } catch {
                            problem = OrgsModel.message(error)
                        }
                    }
                    .onAppear { clientName = client.name }
                    .onChange(of: client.name) { clientName = client.name }
                    .onChange(of: client.id) { clientName = client.name }
                    .accessibilityIdentifier("settings.clientName")
            }
        }
    }

    private func testMosyle(_ profile: OrgProfile) {
        guard let client = orgs.mosyleClient(for: profile) else { return }
        working = profile.id
        Task {
            defer { working = nil }
            do {
                try await client.ping()
                testResult[profile.id] = "Connected: the token, the admin account and the network work."
            } catch {
                testResult[profile.id] = OrgsModel.message(error)
            }
        }
    }

    static func stored(_ profile: OrgProfile) -> [ProbeResult] {
        AppleSection.allCases.compactMap { section in profile.capabilities[section.rawValue].map { ProbeResult(section: section, status: $0) } }
    }

    private func test(_ profile: OrgProfile) {
        guard let client = orgs.client(for: profile) else { testResult[profile.id] = profile.problem; return }
        working = profile.id
        Task {
            defer { working = nil }
            do {
                try await client.ping()
                testResult[profile.id] = "Connected: the key, the account and the network work."
            } catch {
                testResult[profile.id] = DevicesModel.message(error)
            }
        }
    }

    private func probe(_ profile: OrgProfile) {
        guard let client = orgs.client(for: profile) else { return }
        working = profile.id
        Task {
            defer { working = nil }
            orgs.record(await client.probeReads(), probed: profile)
        }
    }

    #if DEBUG
    private func accept(_ profile: OrgProfile) {
        guard let client = orgs.client(for: profile) else { return }
        working = profile.id
        Task {
            defer { working = nil }
            acceptance = await client.acceptancePass().text
        }
    }
    #endif

    private func remove(_ profile: OrgProfile) {
        Task {
            do {
                try await orgs.remove(profile.id, deleteSecrets: true)
                selected = nil
            } catch {
                problem = DevicesModel.message(error)
            }
        }
    }
}

extension ProbeResult: @retroactive Identifiable {
    public var id: String { section.rawValue }
}
