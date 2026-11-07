import AppleModels
import AppModels
import JSONAPI
import SwiftUI

/// The selected audit event: its common attributes, its payload where Apple put it (`AuditEventPayload`) with what was
/// wrong with where it was said (`payloadProblems`, Phase 2a review M1), and every other attribute Apple sent, shown raw
/// (invariant 10). The words come from `AuditEventDetail`; the values are shown as Apple sent them. Nothing here is a
/// link: an id or a name is text to copy, never fetched.
struct ActivityInspectorView: View {
    let row: ActivityRow?

    var body: some View {
        Form {
            if let row {
                let detail = AuditEventDetail(row.event)
                Section("Event") {
                    LabeledContent("When", value: row.time?.formatted(date: .abbreviated, time: .standard) ?? "—")
                    LabeledContent("Type", value: row.type)
                    LabeledContent("Shown in", value: detail.pane)
                    LabeledContent("Outcome", value: row.outcome)
                    LabeledContent("Actor", value: row.actor)
                    LabeledContent("Subject", value: row.subject)
                }
                Section("Payload") {
                    ForEach(detail.notes, id: \.self) { note in
                        Label(note, systemImage: "questionmark.circle")
                            .foregroundStyle(.secondary)
                    }
                    if let key = detail.payloadKey {
                        LabeledContent("Read under", value: key).monospaced()
                        ForEach(detail.payloadFields) { field in
                            LabeledContent(field.label, value: DeviceInspectorView.text(row.event.payload?.object[field.key]))
                                .textSelection(.enabled)
                        }
                    }
                }
                .accessibilityIdentifier("activity.inspector.payload")
                Section("Common attributes") {
                    ForEach(detail.common) { field in
                        LabeledContent(field.label, value: DeviceInspectorView.text(row.event.attributes[field.key]))
                            .textSelection(.enabled)
                    }
                }
                .accessibilityIdentifier("activity.inspector.attributes")
                if !detail.otherAttributes.isEmpty {
                    Section("Other attributes Apple sent") {
                        ForEach(detail.otherAttributes, id: \.self) { key in
                            LabeledContent(key, value: DeviceInspectorView.text(row.event.attributes[key]))
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityIdentifier("activity.inspector.other")
                }
            } else {
                Text("Select an event to see its payload and every attribute Apple sent.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("activity.inspector")
    }
}
