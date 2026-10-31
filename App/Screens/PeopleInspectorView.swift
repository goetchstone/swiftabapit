import AppleModels
import AppModels
import JSONAPI
import SwiftUI

/// The People inspector, for the tab on screen: a user's detail (their typed attributes, phone numbers with their types,
/// roles with the org unit each is held in, then every attribute Apple sent), or a group's or an org unit's detail and
/// members. A member the users read doesn't hold shows as its id, and the note says why; a member list's line says how
/// far it was read beside Apple's own count (invariant 8). Every word here is the model's (`PeopleModel`).
struct PeopleInspectorView: View {
    let model: PeopleModel

    var body: some View {
        Form {
            switch model.tab {
            case .users: if let row = model.user { user(row) } else { missing }
            case .groups: if let row = model.group { group(row) } else { missing }
            case .units: if let row = model.unit { unit(row) } else { missing }
            }
        }
        .formStyle(.grouped)
        // On the form and on single elements only: an identifier on a container can reach every row in it, and two rows
        // would share it.
        .accessibilityIdentifier("people.inspector")
    }

    /// A selection the list doesn't hold, or not yet: why, never a blank pane.
    @ViewBuilder private var missing: some View {
        if let note = model.selectionNote {
            Section {
                Label(note, systemImage: "questionmark.circle")
                    .accessibilityIdentifier("people.selection.note")
            }
        }
    }

    @ViewBuilder private func user(_ row: PeopleModel.UserRow) -> some View {
        Section("Person") { fields(PeopleModel.fields(of: row)) }
        Section("Phone numbers") {
            fields(PeopleModel.phones(of: row.user))
            note(PeopleModel.listNote(row.user, .phoneNumbers))
        }
        Section("Roles") {
            fields(model.roles(of: row.user))
            note(PeopleModel.listNote(row.user, .roleOuList))
            note(model.unitNote(for: row.user.roleOuList?.map(\.ouID) ?? []), symbol: "questionmark.circle")
        }
        everyAttribute(row.user.attributes)
    }

    @ViewBuilder private func group(_ row: PeopleModel.GroupRow) -> some View {
        Section("Group") {
            fields(PeopleModel.fields(of: row))
            note(model.unitNote(for: [row.group.ouID]), symbol: "questionmark.circle")
        }
        members(model.groupMembers, appleCount: row.members)
        everyAttribute(row.group.attributes)
    }

    @ViewBuilder private func unit(_ row: PeopleModel.UnitRow) -> some View {
        Section("Org unit") { fields(PeopleModel.fields(of: row)) }
        members(model.unitMembers, appleCount: nil)
        everyAttribute(row.unit.attributes)
    }

    private func members(_ list: PeopleModel.Members, appleCount: Int?) -> some View {
        Section("Members") {
            if let line = list.line(appleCount: appleCount) {
                HStack(spacing: 6) {
                    if list.state.isLoading { ProgressView().controlSize(.small) }
                    Text(line)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("people.members.line")
            }
            if let note = model.memberNote(list) {
                Label(note, systemImage: "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("people.members.note")
            }
            // By position: Apple may list one id twice, and a row's id must be unique.
            ForEach(Array(model.members(list).enumerated()), id: \.offset) { _, member in
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.name).monospaced(!member.isUser)
                    Text(member.detail).font(.caption).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func fields(_ fields: [PeopleModel.Field]) -> some View {
        ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
            LabeledContent(field.label, value: field.value)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder private func note(_ text: String?, symbol: String? = nil) -> some View {
        if let text {
            if let symbol { Label(text, systemImage: symbol).foregroundStyle(.secondary) } else { Text(text).foregroundStyle(.secondary) }
        }
    }

    /// Every attribute the view's resource holds, raw (invariant 10). A user's, a group's and an org unit's hold no secret.
    private func everyAttribute(_ attributes: JSONObject) -> some View {
        Section {
            DisclosureGroup("Every attribute Apple sent") {
                ForEach(attributes.keys, id: \.self) { key in
                    LabeledContent(key, value: DeviceInspectorView.text(attributes[key]))
                        .textSelection(.enabled)
                }
            }
            .accessibilityIdentifier("people.attributes")
        }
    }
}
