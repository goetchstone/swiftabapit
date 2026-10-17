import AppleBusiness
import Orgs
import SwiftUI
import UniformTypeIdentifiers
import Vault

/// Adding or editing an Apple Business / Apple School Manager org (plan §3.4.1): the account's IDs, and its
/// key picked from a file, read once, normalized, stored in the Keychain; then the offer to move the original
/// file to the Trash. Every field can be changed and cleared (defect 14).
struct OrgEditor: View {
    enum Mode: Identifiable {
        case add
        case edit(OrgProfile)

        var id: String {
            switch self {
            case .add: "add"
            case .edit(let profile): profile.id
            }
        }
    }

    let mode: Mode
    let orgs: OrgsModel
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var scope = Scope.business
    @State private var clientID = ""
    @State private var keyID = ""
    @State private var teamID = ""
    @State private var role = ""
    @State private var key: ImportedKey?
    @State private var keyFile: URL?
    @State private var importing = false
    @State private var problem: String?
    @State private var saving = false
    @State private var offerTrash: URL?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name).accessibilityIdentifier("editor.name")
                Picker("Scope", selection: $scope) {
                    ForEach(Scope.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("Client ID", text: $clientID, prompt: Text("BUSINESSAPI.… or SCHOOLAPI.…")).accessibilityIdentifier("editor.clientID")
                TextField("Key ID", text: $keyID).accessibilityIdentifier("editor.keyID")
                TextField("Team ID (optional)", text: $teamID, prompt: Text("Leave empty to use the client ID"))
                TextField("Role (for your notes)", text: $role, prompt: Text("Administrator, Device Enrollment Manager…"))
            }
            Section("Private key") {
                HStack {
                    if let key {
                        Label("Key \(key.fingerprint.prefix(16))… read", systemImage: "key")
                            .accessibilityLabel("A key was read; fingerprint \(key.fingerprint.prefix(16))")
                    } else if case .edit = mode {
                        Text("The stored key is kept unless you choose another.").foregroundStyle(.secondary)
                    } else {
                        Text("The .pem Apple Business or Apple School Manager gave you for this API account.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Choose Key File…") { importing = true }.accessibilityIdentifier("editor.chooseKey")
                }
            }
            if let problem { Label(problem, systemImage: "exclamationmark.octagon").foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(isAdding ? "Add" : "Save") { save() }.disabled(saving || !canSave)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [UTType(filenameExtension: "pem") ?? .data, .data, .text]) { result in
            read(result)
        }
        .alert("Move the original key file to the Trash?", isPresented: Binding(get: { offerTrash != nil }, set: { if !$0 { offerTrash = nil; dismiss() } })) {
            Button("Move to Trash", role: .destructive) { trash() }
            Button("Keep It") { offerTrash = nil; dismiss() }
        } message: {
            Text("The key is in this Mac's Keychain now. The file is still at \(offerTrash?.path(percentEncoded: false) ?? "its place"); anyone who can read it can use the API account.")
        }
        .onAppear(perform: fill)
    }

    private var isAdding: Bool { if case .add = mode { true } else { false } }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !clientID.trimmingCharacters(in: .whitespaces).isEmpty
            && !keyID.trimmingCharacters(in: .whitespaces).isEmpty && (key != nil || !isAdding)
    }

    private func fill() {
        guard case .edit(let profile) = mode else { return }
        (name, clientID, keyID, teamID, role) = (profile.name, profile.clientID, profile.keyID, profile.teamID, profile.role)
        scope = profile.scope.known ?? .business
    }

    /// Reads the picked file once, by descriptor, inside its security scope, then parses it. Nothing is stored
    /// until Save.
    private func read(_ result: Result<URL, any Error>) {
        problem = nil
        guard case .success(let url) = result else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            key = try KeyImport.parse(KeyImport.read(url))
            keyFile = url
        } catch {
            key = nil
            problem = error.message
        }
    }

    private func save() {
        saving = true
        problem = nil
        Task {
            defer { saving = false }
            do {
                var profile: OrgProfile
                switch mode {
                case .add: profile = try await OrgProfile(id: orgs.newID(for: name), name: name, provider: .apple)
                case .edit(let existing): profile = existing
                }
                profile.name = name
                profile.scope = .known(scope)
                profile.clientID = clientID
                profile.keyID = keyID
                profile.teamID = teamID
                profile.role = role
                guard let item = VaultItem(org: profile.id, kind: .appleKey) else { problem = "That name can't be used."; return }
                if let key { try await orgs.vault.storeKey(key, as: item) }
                do {
                    if isAdding { try orgs.add(profile) } else { try orgs.update(profile) }
                } catch {
                    // Whole or absent: a new org that couldn't be saved leaves no key behind.
                    if isAdding { try? await orgs.vault.remove(org: profile.id) }
                    problem = (error as? OrgStore.Failure)?.message ?? error.localizedDescription
                    return
                }
                if let keyFile, key != nil { offerTrash = keyFile } else { dismiss() }
            } catch let error as VaultError {
                problem = error.guidance
            } catch {
                problem = error.localizedDescription
            }
        }
    }

    private func trash() {
        guard let url = offerTrash else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            problem = "The file couldn't be moved to the Trash (\(error.localizedDescription)). Delete it yourself."
        }
        offerTrash = nil
        dismiss()
    }
}
