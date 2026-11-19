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
    /// The answer to which customer the org is for; none until the operator picks one.
    @State private var clientChoice: ClientChoice?

    private var draft: MosyleDraft {
        MosyleDraft(name: name, accessToken: accessToken, email: email, password: password, logsToken: logsToken, editing: editing)
    }

    /// An Add's question, asked whenever some client has room for a Mosyle org, or the answer given lost its client (plan
    /// §8.0, "Clients"); never an edit's.
    private var question: ClientQuestion? { editing == nil ? orgs.clientQuestion(adding: .mdm, answer: clientChoice) : nil }

    /// Why Add can't be pressed yet, in words; nil when it can.
    private var blocker: String? { draft.problem ?? question.flatMap { $0.accepts(clientChoice) ? nil : $0.note ?? $0.prompt } }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $name).accessibilityIdentifier("mosyleEditor.name")
            }
            if let question {
                Section(question.title) {
                    Picker(question.prompt, selection: $clientChoice) {
                        ForEach(question.options) { Text($0.label).tag(Optional($0.choice)) }
                    }
                    .pickerStyle(.radioGroup)
                    .accessibilityIdentifier("mosyleEditor.client")
                    if let note = question.note { Label(note, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                }
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
                    .disabled(saving || blocker != nil)
                    .help(blocker ?? "")
            }
        }
        .interactiveDismissDisabled(saving)
        .onAppear { if let editing { name = editing.name } }
        .onDisappear(perform: forget)
    }

    private func save() {
        saving = true
        problem = nil
        let draft = draft
        // The answer as chosen, never another: one whose client was filled or removed since is refused, not taken for none.
        let choice = clientChoice
        Task {
            defer { saving = false }
            do {
                try await orgs.saveMosyle(draft, editing: editing?.id, client: choice)
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
