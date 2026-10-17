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
    @State private var removing: OrgProfile?
    @State private var results: [String: [ProbeResult]] = [:]
    @State private var testResult: [String: String] = [:]
    @State private var working: String?
    @State private var problem: String?
    @State private var acceptance: String?

    private var profile: OrgProfile? { orgs.store[selected ?? orgs.active?.id ?? ""] }

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                List(orgs.store.orgs, selection: $selected) { org in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(org.name.isEmpty ? org.id : org.name)
                            if org.id == orgs.active?.id { Text("Active").font(.caption).foregroundStyle(.secondary) }
                        }
                        Text([org.scope.known?.displayName ?? org.provider.rawValue, org.role].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(org.id)
                    .accessibilityElement(children: .combine)
                }
                .accessibilityIdentifier("settings.orgs")
                HStack {
                    Button("Add Apple Organization…", systemImage: "plus") { editing = .add }
                        .accessibilityIdentifier("settings.add")
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
                if let profile {
                    Section(profile.name) {
                        LabeledContent("Scope", value: profile.scope.known?.displayName ?? profile.scope.rawValue)
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
                    let found = results[profile.id] ?? Self.stored(profile)
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
        .sheet(item: $editing) { mode in OrgEditor(mode: mode, orgs: orgs) }
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
            Button("Remove and Delete Its Key", role: .destructive) { remove(profile) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Its key is deleted from this Mac's Keychain, and its settings from abapit. Apple Business keeps the API account: revoke it there if you no longer need it.")
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
            let found = await client.probeReads()
            results[profile.id] = found
            orgs.record(found, probed: profile)
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
