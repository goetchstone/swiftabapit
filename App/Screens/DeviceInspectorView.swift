import AppleModels
import JSONAPI
import SwiftUI

/// The Device inspector, ABM half (plan §4; Device 360's Mosyle half arrives in Phase 7): the device's
/// attributes, its AppleCare, its Activation Lock and its assigned service, each panel loaded on its own.
struct DeviceInspectorView: View {
    let model: DeviceDetailModel

    var body: some View {
        Form {
            Section("Device") {
                PanelView(model.device) { device in
                    LabeledContent("Serial", value: device.serialNumber).monospaced()
                    LabeledContent("Model", value: device.deviceModel ?? "—")
                    LabeledContent("Family", value: device.productFamily?.rawValue ?? "—")
                    LabeledContent("Status", value: device.status?.rawValue.capitalized ?? "—")
                    LabeledContent("Ordered", value: Self.date(device.orderDate))
                    LabeledContent("Added", value: Self.date(device.addedToOrgDate))
                    if let released = device.releasedFromOrgDate { LabeledContent("Released", value: Self.date(released)) }
                    LabeledContent("Purchased from", value: device.purchaseSourceType?.rawValue.capitalized ?? "—")
                    if device.isMigrationCapable == true || device.migrationStatus != nil {
                        LabeledContent("MDM migration", value: device.migrationStatus?.rawValue.capitalized ?? "Capable")
                        if let deadline = device.migrationDeadline { LabeledContent("Migration deadline", value: Self.date(deadline)) }
                    }
                    DisclosureGroup("Every attribute Apple sent") {
                        ForEach(device.attributes.keys, id: \.self) { key in
                            LabeledContent(key, value: Self.text(device.attributes[key]))
                                .textSelection(.enabled)
                        }
                    }
                    .accessibilityIdentifier("inspector.attributes")
                }
            }
            Section("Device management service") {
                PanelView(model.service) { service in
                    if let service {
                        LabeledContent("Assigned to", value: service.name)
                        LabeledContent("Type", value: service.type?.rawValue ?? "—")
                    } else {
                        Text("Not assigned to a service.")
                    }
                }
            }
            Section("Activation Lock") {
                PanelView(model.lock) { lock in
                    LabeledContent("Locked", value: lock.isLocked == true ? "Yes" : lock.isLocked == false ? "No" : "Unknown")
                    LabeledContent("Held by", value: lock.lockType?.rawValue ?? "—")
                    if lock.blocksRelease {
                        Label("A person's Apple Account holds this lock: the device can't be redeployed or released until they remove it.",
                              systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
            }
            Section("AppleCare") {
                PanelView(model.coverage) { rows in
                    if rows.isEmpty { Text("No coverage.") }
                    ForEach(rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.summary ?? "Coverage").bold()
                            Text([row.status?.rawValue.capitalized, row.end.map { "ends \(Self.date($0))" } ?? "no end date",
                                  row.paymentType?.rawValue, row.isCanceled ? "canceled" : nil].compactMap { $0 }.joined(separator: " · "))
                                .foregroundStyle(.secondary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("device.inspector")
    }

    static func date(_ value: ISODate?) -> String {
        value.map { $0.date.formatted(date: .abbreviated, time: .omitted) } ?? "—"
    }

    static func text(_ value: JSONValue?) -> String {
        switch value {
        case nil, .null?: "—"
        case .string(let text)?: text.isEmpty ? "—" : text
        case .bool(let flag)?: flag ? "Yes" : "No"
        case .number(let text)?: text
        case .array(let items)?: items.map { text($0) }.joined(separator: ", ")
        case .object?: value!.jsonText
        }
    }
}

/// One inspector panel: its content when loaded, else where it stands, in words.
struct PanelView<Value, Content: View>: View {
    let panel: Panel<Value>
    @ViewBuilder let content: (Value) -> Content

    init(_ panel: Panel<Value>, @ViewBuilder content: @escaping (Value) -> Content) {
        self.panel = panel
        self.content = content
    }

    var body: some View {
        switch panel {
        case .loading: ProgressView().controlSize(.small).accessibilityLabel("Loading")
        case .loaded(let value): content(value)
        case .forbidden: Label("Your role can't read this.", systemImage: "lock")
        case .failed(let message): Label(message, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
        }
    }
}
