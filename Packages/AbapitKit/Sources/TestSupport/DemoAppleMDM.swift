#if DEBUG
// Test and demo code only: compiled out of a Release build, so the app's Release binary carries no stub
// (scripts/check_app.sh holds that).
import Foundation
import JSONAPI

/// The demo org's Apple MDM devices and their posture (plan §4, demo mode), for the Apple MDM screen and its snapshots:
/// fifteen of the demo fleet's devices (seven Macs, four iPhones, four iPads, with the fleet's `DEMO…` serials, models,
/// Wi-Fi addresses and IMEIs), each with details of varied posture. FileVault is off on two Macs, one Mac never checked in,
/// one iPhone is in lost mode and another locked, and one iPad has no details on record (the stub answers 404). The names
/// are rooms and roles, never people; the dates are fixed to `DemoFleet.reference`, so the pictures don't move.
public enum DemoAppleMDM {
    static let rooms: [(family: String, names: [String])] = [
        ("Mac", ["Design Studio Mac", "Front Desk Mac", "Finance Mac", "Loaner Mac 1", "Loaner Mac 2", "Conference Room Mac", "Lab Mac"]),
        ("iPhone", ["Sales iPhone 1", "Sales iPhone 2", "Field Service iPhone", "Warehouse iPhone"]),
        ("iPad", ["Reception iPad", "Inventory iPad", "Kiosk iPad", "Training iPad"]),
    ]

    /// Adds the demo's data to `stub`; `DemoOrg.make()` calls it.
    public static func load(into stub: AppleStub) {
        let fleet = DemoFleet.make().devices
        var devices: [Resource] = [], number = 0
        for (family, names) in rooms {
            let picked = fleet.filter { $0.attributes["productFamily"]?.string == family }.prefix(names.count)
            for (index, (device, name)) in zip(picked, names).enumerated() {
                number += 1
                let serial = device.id
                devices.append(Resource(type: "mdmDevices", id: serial, attributes: [
                    "serialNumber": .string(serial), "deviceName": .string(name), "productFamily": .string(family), "enrolledUserId": .null,
                ]))
                // The iPad with no details on record.
                if family == "iPad", index == 0 { continue }
                stub.setDetails(serial, details(of: device, name: name, family: family, index: index, number: number))
            }
        }
        stub.add(devices)
    }

    /// One device's details: the fleet's own identifiers, and the posture its place in the list gives it.
    static func details(of device: Resource, name: String, family: String, index: Int, number: Int) -> Resource {
        let model = device.attributes["deviceModel"]?.string ?? family
        let total = capacity(device.attributes["deviceCapacity"]?.string)
        let mac = family == "Mac", desktop = model.contains("mini") || model.contains("iMac")
        let checkIn = DemoFleet.reference - Double(mac && index == 5 ? 9 * 86_400 : number * 37 * 60)
        var attributes: JSONObject = [
            "serialNumber": .string(device.id), "deviceName": .string(name), "deviceModel": .string(model),
            "osVersion": .string(mac ? (index == 6 ? "26.6" : "27.0.1") : (index == 3 ? "26.5.1" : "27.0")),
            "platform": .string(mac ? "macOS" : family == "iPhone" ? "iOS" : "iPadOS"),
            "imei": device.attributes["imei"] ?? .null, "meid": .null,
            "wifiMacAddress": device.attributes["wifiMacAddress"] ?? .null,
            "bluetoothMacAddress": .string(String(format: "02:DE:B7:00:00:%02X", number)),
            "ethernetMacAddress": desktop ? .string(String(format: "02:DE:E7:00:00:%02X", number)) : .null,
            "lastCheckInDateTime": .string(DemoFleet.iso(checkIn)),
            // FileVault and the firewall are macOS's: an iPhone's or an iPad's come as null.
            "isFirewallEnabled": mac ? .bool(index != 4) : .null,
            "isFileVaultEnabled": mac ? .bool(index > 1) : .null,
            "storageFreeCapacity": .number(String(total * Int64(12 + (number * 17) % 60) / 100)),
            "storageTotalCapacity": .number(String(total)),
            "deviceLockStatus": .string(family == "iPhone" && index == 1 ? "LOCKED" : "UNLOCKED"),
            "deviceEraseStatus": .string("NOT_ERASED"),
            "lostModeStatus": .string(family == "iPhone" && index == 0 ? "ENABLED" : "DISABLED"),
        ]
        if mac, index == 2 {
            // Enrolled, never checked in: nothing reported yet.
            for key in ["lastCheckInDateTime", "osVersion", "isFirewallEnabled", "isFileVaultEnabled", "storageFreeCapacity", "storageTotalCapacity"] {
                attributes[key] = .null
            }
        }
        return Resource(type: "mdmDeviceDetails", id: device.id, attributes: attributes)
    }

    /// The fleet's `deviceCapacity` ("256GB", "1TB") in bytes, as Apple's details are read (assumed bytes).
    static func capacity(_ text: String?) -> Int64 {
        guard let text, let amount = Int64(text.prefix { $0.isNumber }) else { return 128_000_000_000 }
        return amount * (text.hasSuffix("TB") ? 1_000_000_000_000 : 1_000_000_000)
    }
}
#endif
