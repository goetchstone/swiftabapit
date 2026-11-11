import AppModels
import Orgs
import SwiftUI

/// Adding or editing a Mosyle Business org (plan §4): its name, and its credentials, which go to the Keychain as one set
/// (`OrgsModel.saveMosyle`, tested in the package) and are never shown again. An edit keeps the stored credentials unless all
/// of them are entered again; the typed values are dropped when the sheet closes.
struct MosyleOrgEditor: View {
    /// The org edited; nil to add one.
    let editing: OrgProfile?
    let orgs: OrgsModel
    @Environment(\.dismiss) private var dismiss
    @State private var draft = MosyleDraft()
    @State private var problem: String?
    @State private var saving = false

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name).accessibilityIdentifier("mosyleEditor.name")
            }
            Section {
                SecureField("Access token", text: $draft.accessToken).accessibilityIdentifier("mosyleEditor.token")
                TextField("Admin email", text: $draft.email).accessibilityIdentifier("mosyleEditor.email")
                SecureField("Admin password", text: $draft.password).accessibilityIdentifier("mosyleEditor.password")
                SecureField("Logs Stream token (optional)", text: $draft.logsToken).accessibilityIdentifier("mosyleEditor.logsToken")
            } header: {
                Text("Credentials")
            } footer: {
                Text(editing == nil ? "From Mosyle Business's API integration: stored in this Mac's Keychain, never shown again."
                     : "The stored credentials are kept unless you enter them all again; an empty Logs Stream token then removes the stored one.")
                    .foregroundStyle(.secondary)
            }
            if let problem { Label(problem, systemImage: "exclamationmark.octagon").foregroundStyle(.red) }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460, minHeight: 360)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { draft = MosyleDraft(); dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button(editing == nil ? "Add" : "Save") { save() }
                    .disabled(saving || draft.problem != nil)
                    .help(draft.problem ?? "")
            }
        }
        .onAppear { if let editing { draft = MosyleDraft(editing) } }
        .onDisappear { draft = MosyleDraft() }
    }

    private func save() {
        saving = true
        problem = nil
        Task {
            defer { saving = false }
            do {
                try await orgs.saveMosyle(draft, editing: editing?.id)
            } catch {
                problem = OrgsModel.message(error)
                return
            }
            draft = MosyleDraft()
            dismiss()
        }
    }
}
