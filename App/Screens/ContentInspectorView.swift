import AppModels
import SwiftUI

/// The Content inspector (plan Phase 2: app, package, blueprint and configuration detail): the chosen row read alone, as
/// `ContentDetail` words it. Addresses are text with selection on, never links (they aren't on the host allowlist,
/// invariant 4); a blueprint's members by relationship, or why they weren't read; a custom setting's profile masked
/// (invariant 11), with what was masked; every attribute Apple sent, as the device inspector lists them.
struct ContentInspectorView: View {
    let model: ContentDetailModel

    var body: some View {
        Form {
            PanelView(model.item) { detail in
                Section {
                    ForEach(Array(detail.fields.enumerated()), id: \.offset) { _, field in
                        LabeledContent(field.label, value: field.value)
                            .textSelection(.enabled)
                    }
                    ForEach(detail.notes, id: \.self) { note in
                        Label(note, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text(detail.title)
                }
                if let note = detail.membersNote {
                    Section("Members") {
                        Label(note, systemImage: "lock")
                            .accessibilityIdentifier("content.inspector.membersNote")
                    }
                }
                ForEach(detail.members) { group in
                    Section(group.title) {
                        Text(group.summary)
                            .foregroundStyle(group.isTruncated || group.count == nil ? .orange : .secondary)
                        ForEach(Array(group.members.enumerated()), id: \.offset) { _, member in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(member.name ?? member.id)
                                if member.name != nil {
                                    Text(member.id).monospaced().font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .textSelection(.enabled)
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .accessibilityIdentifier("content.inspector.members.\(group.id)")
                }
                if detail.profile != nil || detail.profileNote != nil {
                    Section("Profile") {
                        if let note = detail.profileNote {
                            Label(note, systemImage: "eye.slash")
                                .foregroundStyle(.secondary)
                        }
                        if let profile = detail.profile {
                            Text(profile)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .accessibilityLabel("The profile, its secrets masked")
                                .accessibilityIdentifier("content.inspector.profile")
                        }
                    }
                }
                Section {
                    DisclosureGroup("Every attribute Apple sent") {
                        ForEach(Array(detail.attributes.enumerated()), id: \.offset) { _, field in
                            LabeledContent(field.label, value: field.value)
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityIdentifier("content.inspector.attributes")
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("content.inspector")
    }
}
