import AppModels
import Orgs
import SwiftUI
import UniformTypeIdentifiers
import Vault

/// Adding or editing an Apple Business / Apple School Manager org (plan §3.4.1): the account's IDs, and its
/// key picked from a file, read once, normalized, stored in the Keychain; then the offer to move the original
/// file to the Trash. Every field can be changed and cleared (defect 14). The save itself is `OrgsModel.save`,
/// tested in the package (Phase 1b review M4); the parsed key is dropped as soon as it is stored, and on Cancel.
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
    @State private var draft = OrgDraft()
    @State private var key: ImportedKey?
    @State private var keyFile: URL?
    @State private var importing = false
    @State private var problem: String?
    @State private var saving = false
    @State private var offerTrash: URL?

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name).accessibilityIdentifier("editor.name")
                Picker("Scope", selection: $draft.scope) {
                    ForEach(Scope.allCases, id: \.self) { Text($0.displayName).tag($0) }
                }
                TextField("Client ID", text: $draft.clientID, prompt: Text("BUSINESSAPI.… or SCHOOLAPI.…")).accessibilityIdentifier("editor.clientID")
                TextField("Key ID", text: $draft.keyID).accessibilityIdentifier("editor.keyID")
                TextField("Team ID (optional)", text: $draft.teamID, prompt: Text("Leave empty to use the client ID"))
                TextField("Role (for your notes)", text: $draft.role, prompt: Text("Administrator, Device Enrollment Manager…"))
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
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { key = nil; dismiss() } }
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
        .onDisappear { key = nil }
    }

    private var isAdding: Bool { if case .add = mode { true } else { false } }

    private var canSave: Bool { draft.isComplete && (key != nil || !isAdding) }

    private func fill() {
        guard case .edit(let profile) = mode else { return }
        draft = OrgDraft(profile)
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

    /// Only the edited fields and the key go to the model; it merges them onto the profile as it is at that moment,
    /// never onto the copy this sheet opened with.
    private func save() {
        saving = true
        problem = nil
        var editing: String?
        if case .edit(let profile) = mode { editing = profile.id }
        Task {
            defer { saving = false }
            let picked = key != nil
            do {
                try await orgs.save(draft, key: key, editing: editing)
            } catch {
                // A key that stayed in the Keychain needs no copy here; any other failure keeps it for the retry.
                if (error as? OrgsModel.SaveFailure)?.keyIsStored == true { key = nil }
                problem = OrgsModel.message(error)
                return
            }
            key = nil
            if let keyFile, picked { offerTrash = keyFile } else { dismiss() }
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
