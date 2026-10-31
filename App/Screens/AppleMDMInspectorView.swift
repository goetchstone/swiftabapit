import AppleModels
import AppModels
import JSONAPI
import SwiftUI

/// The Apple MDM inspector: the selected device as the list has it, its posture in words, and every attribute of its
/// details as Apple sent it (a details record holds no secret, so the every-attribute list is safe here). A device whose
/// details weren't read says why; selecting it asks for them (`AppleMDMModel.selection`).
struct AppleMDMInspectorView: View {
    let row: AppleMDMRow?

    var body: some View {
        Form {
            if let row {
                Section("Device") {
                    LabeledContent("Serial", value: row.serial).monospaced()
                    LabeledContent("Name", value: Self.dash(row.name))
                    LabeledContent("Family", value: Self.dash(row.family))
                    LabeledContent("Enrolled user", value: Self.dash(row.user))
                    DisclosureGroup("Every attribute in the list") { Self.attributes(row.device.attributes) }
                        .accessibilityIdentifier("apple-mdm.inspector.list")
                }
                Section("Posture") { posture(row) }
                if let detail = row.details.detail {
                    Section("Every detail Apple sent") { Self.attributes(detail.attributes) }
                        .accessibilityIdentifier("apple-mdm.inspector.details")
                }
            } else {
                Text("Select a device to see its details.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("apple-mdm.inspector")
    }

    @ViewBuilder private func posture(_ row: AppleMDMRow) -> some View {
        switch row.details {
        case .read(let detail):
            LabeledContent("OS", value: row.os)
            LabeledContent("Platform", value: Self.dash(detail.platform ?? ""))
            LabeledContent("Model", value: Self.dash(detail.deviceModel ?? ""))
            LabeledContent("Last check-in", value: row.checkIn)
            LabeledContent("FileVault", value: row.fileVault)
            LabeledContent("Firewall", value: row.firewall)
            LabeledContent("Lock", value: row.lock)
            LabeledContent("Erase", value: row.erase)
            LabeledContent("Lost mode", value: row.lostMode)
            LabeledContent("Storage", value: row.storage)
        case .reading:
            HStack {
                ProgressView().controlSize(.small).accessibilityLabel("Loading")
                Text("Reading the device's details…")
            }
        case .none:
            Label("Apple has no details on record for this device.", systemImage: "questionmark.circle")
        case .forbidden:
            Label("Your role can't read this.", systemImage: "lock")
        case .failed(let why):
            Label(why, systemImage: "exclamationmark.octagon").foregroundStyle(.red)
        case .notRead:
            Label("Not read.", systemImage: "questionmark.circle")
        }
    }

    /// Every attribute in Apple's order, each value as the device inspector shows one. By position: two keys Apple sent
    /// that differ only in normalization are two rows, not one identity.
    private static func attributes(_ attributes: JSONObject) -> some View {
        ForEach(Array(attributes.keys.enumerated()), id: \.offset) { _, key in
            LabeledContent(key, value: DeviceInspectorView.text(attributes[key]))
                .textSelection(.enabled)
        }
    }

    private static func dash(_ text: String) -> String { text.isEmpty ? "—" : text }
}
