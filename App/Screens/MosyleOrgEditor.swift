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
    /// What is typed, kept only while the sheet is open: the draft made of it holds the credentials as `Secret`s.
    @State private var name = ""
    @State private var accessToken = ""
    @State private var email = ""
    @State private var password = ""
    @State private var logsToken = ""
    @State private var problem: String?
    @State private var saving = false

    private var draft: MosyleDraft {
        MosyleDraft(name: name, accessToken: accessToken, email: email, password: password, logsToken: logsToken, editing: editing)
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name).accessibilityIdentifier("mosyleEditor.name")
            }
            Section {
                SecureField("Access token", text: $accessToken).accessibilityIdentifier("mosyleEditor.token")
                TextField("Admin email", text: $email).accessibilityIdentifier("mosyleEditor.email")
                SecureField("Admin password", text: $password).accessibilityIdentifier("mosyleEditor.password")
                SecureField("Logs Stream token (optional)", text: $logsToken).accessibilityIdentifier("mosyleEditor.logsToken")
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
            // Not while a save runs: its outcome, a failure included, is said here, never after the sheet is gone.
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { forget(); dismiss() }.disabled(saving) }
            ToolbarItem(placement: .confirmationAction) {
                Button(editing == nil ? "Add" : "Save") { save() }
                    .disabled(saving || draft.problem != nil)
                    .help(draft.problem ?? "")
            }
        }
        .onAppear { if let editing { name = editing.name } }
        .onDisappear(perform: forget)
    }

    private func save() {
        saving = true
        problem = nil
        let draft = draft
        Task {
            defer { saving = false }
            do {
                try await orgs.saveMosyle(draft, editing: editing?.id)
            } catch {
                problem = OrgsModel.message(error)
                return
            }
            forget()
            dismiss()
        }
    }

    /// Drops what was typed: the sheet's copy of the credentials lives no longer than the sheet.
    private func forget() {
        (accessToken, email, password, logsToken) = ("", "", "", "")
    }
}
