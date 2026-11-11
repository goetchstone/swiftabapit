import Foundation
import JSONAPI

/// Mosyle's records as JSON:API-shaped resources with abapit's attribute names, so reports, reconciliation
/// and Device 360 read Mosyle and Apple alike. Held to `Tests/Fixtures/parity/mosyle.json`.
public enum MosyleAdapter {
    /// abapit's `_FIELD_MAP`, in its order (a later source wins when two map to one name, as in abapit).
    static let fields: [(source: String, name: String)] = [
        ("serial_number", "serialNumber"), ("deviceudid", "deviceUdid"), ("device_name", "deviceName"),
        ("device_model", "deviceModelId"), ("device_model_name", "deviceModel"), ("model_name", "modelName"),
        ("osversion", "osVersion"), ("status", "status"), ("enrollment_type", "enrollmentType"),
        ("ManagementStatus", "managementStatus"), ("userid", "userId"), ("useremail", "userEmail"), ("username", "userName"),
        ("CurrentConsoleManagedUser", "currentUser"), ("currentconsolemanageduser", "currentUser"), ("battery", "batteryLevel"),
        ("total_disk", "totalDiskGB"), ("available_disk", "availableDiskGB"), ("is_supervised", "isSupervised"),
        ("lostmode_status", "lostModeStatus"), ("asset_tag", "assetTag"), ("imei", "imei"), ("meid", "meid"),
        ("wifi_mac_address", "wifiMacAddress"), ("bluetooth_mac_address", "bluetoothMacAddress"),
        ("ethernet_mac_address", "ethernetMacAddress"),
    ]

    /// abapit's `_DATE_MAP`: epoch seconds (or a date string) to ISO.
    static let dates: [(source: String, name: String)] = [
        ("date_last_beat", "lastCheckIn"), ("date_last_push", "lastPush"), ("date_enroll", "enrolledAt"),
        ("date_checkin", "lastMdmCheckIn"), ("date_app_info", "appInfoUpdated"),
    ]

    /// Every attribute a device can carry here. Anything else Mosyle sends is dropped at the door, the
    /// Activation Lock bypass codes first among them (plan §2.3 defect 1: abapit passed every raw key through
    /// to pages and CSV). The list request asks for these sources only (`specific_columns`).
    public static let deviceAttributes: Set<String> = Set(fields.map(\.name) + dates.map(\.name) + ["deviceModel", "productFamily", "managedBy"])

    /// The raw columns to request: the sources above, plus the two that pick the family. The golden's `device_columns`
    /// case pins the list (verifier round 1), so a column can't join the request unseen.
    public static let deviceColumns: [String] = fields.map(\.source) + dates.map(\.source) + ["os", "device_type"]

    /// Phase 7a review L1 (invariant 11): users and groups pass an allowlist too. abapit's `adapt_user` and
    /// `adapt_group` kept every raw field (its tables and its CSV showed them all), so a password, a token or a
    /// bypass code sent on a user reached the page and the export. Kept: abapit's own names, then the raw fields
    /// those are read from, the only Mosyle user and group fields with a source here (`Contracts/mosyle/` has none
    /// yet). A field to show joins with its source; the golden's `allowlists` case pins these.
    public static let userAttributes = ["name", "email", "identifier", "userType", "iduser", "id", "managedappleid", "type", "usertype"]
    public static let groupAttributes = ["name", "identifier", "memberCount", "os", "idusergroup", "iddevicegroup", "id",
                                         "device_numbers", "idusers_primary", "members"]

    /// What abapit deduplicated devices by, `raw.get("serial_number") or raw.get("deviceudid")`, compared as its
    /// `set` compared them (Phase 7a review L4): a numeric serial by value (`123` and `123.0` are one key, `true`
    /// and `1` another; `"123"` is a third), a string by its code points.
    public struct DeviceKey: Hashable, Sendable {
        let bytes: [UInt8]
    }

    /// The device's dedupe key; nil when it has none, so it is always kept. A list or an object is no key here:
    /// abapit raised `TypeError` (unhashable) and lost the whole device list.
    public static func deviceKey(_ raw: JSONObject) -> DeviceKey? {
        [raw["serial_number"], raw["deviceudid"]].lazy.compactMap { $0 }.first(where: Python.truthy).flatMap(Python.key).map(DeviceKey.init)
    }

    static let osFamily = ["mac": "Mac", "macos": "Mac", "osx": "Mac", "tvos": "AppleTV", "atv": "AppleTV", "watchos": "Watch", "visionos": "Vision"]

    /// abapit's `adapt_device`, as an allowlist: the same names and values for what it maps, nothing else.
    public static func device(_ raw: JSONObject) -> Resource {
        var attributes = JSONObject()
        for (source, name) in fields where raw[source] != nil { attributes[name] = raw[source] }
        for (source, name) in dates where raw[source] != nil { attributes[name] = MosyleTime.iso(raw[source]).map(JSONValue.string) ?? .null }
        if !Python.truthy(attributes["deviceModel"]) {
            attributes["deviceModel"] = Python.truthy(raw["device_model"]) ? raw["device_model"]! : (raw["model_name"] ?? .string(""))
        }
        attributes["productFamily"] = .string(family(raw))
        attributes["managedBy"] = .string("Mosyle")
        return Resource(type: "orgDevices", id: firstTruthy(raw, "serial_number", "deviceudid"), attributes: attributes)
    }

    /// abapit's `_family`: the `os` first, then the model and device type's words (by code points, as Python's
    /// `in`), then iOS means iPhone.
    static func family(_ raw: JSONObject) -> String {
        let os = Python.truthy(raw["os"]) ? Python.str(raw["os"]).lowercased() : ""
        if let mapped = osFamily[os] { return mapped }
        let model = firstTruthy(raw, "device_model", "model_name", "device_model_name").lowercased()
        let type = Python.truthy(raw["device_type"]) ? Python.str(raw["device_type"]).lowercased() : ""
        if Python.contains(model, "ipad") || Python.contains(type, "ipad") { return "iPad" }
        if Python.contains(model, "iphone") || Python.contains(type, "iphone") { return "iPhone" }
        return os == "ios" ? "iPhone" : ""
    }

    /// Python's `str(raw.get(a) or raw.get(b) or … or "")`.
    static func firstTruthy(_ raw: JSONObject, _ keys: String...) -> String {
        keys.lazy.compactMap { raw[$0] }.first(where: Python.truthy).map(Python.str) ?? ""
    }

    /// abapit's `adapt_user`: the four names it reads, then the raw fields on `userAttributes` as Mosyle sent them.
    public static func user(_ raw: JSONObject) -> Resource {
        var attributes: JSONObject = [
            "name": raw["name"] ?? .string(""),
            "email": Python.truthy(raw["email"]) ? raw["email"]! : (raw["managedappleid"] ?? .string("")),
            "identifier": raw["identifier"] ?? .string(""),
            "userType": Python.truthy(raw["type"]) ? raw["type"]! : (raw["usertype"] ?? .string("")),
        ]
        for (key, value) in raw where attributes[key] == nil && userAttributes.contains(key) { attributes[key] = value }
        return Resource(type: "mosyleUsers", id: firstTruthy(raw, "iduser", "id", "identifier"), attributes: attributes)
    }

    /// One field this app reads from a record no source shows (a custom device attribute, an admin-log entry): the name it
    /// is shown under and the raw names it may come under, the first truthy one taken. Each raw name is a guess, listed in
    /// docs/domains/mosyle.md to check live; every other field is dropped at the door (invariant 11) and only its name is
    /// kept, so a screen can say what it didn't show.
    public typealias Guessed = (name: String, sources: [String])

    /// A custom device attribute's fields. The capitalised names are those a third-party client of Mosyle Manager reads
    /// (`Name`, `UniqueID`, `Value`, `Source`, `LastUpdate`, `IsDeleted`); the lower-case ones are Mosyle Business's usual
    /// spelling.
    public static let attributeFields: [Guessed] = [
        ("name", ["name", "Name", "attribute_name"]), ("identifier", ["UniqueID", "uniqueid", "idattribute", "id"]),
        ("value", ["Value", "value", "default_value"]), ("source", ["Source", "source"]), ("updated", ["LastUpdate", "last_update"]),
        ("deleted", ["IsDeleted", "is_deleted"]),
    ]

    /// An admin-log entry's fields: who did what, and when.
    public static let adminLogFields: [Guessed] = [
        ("when", ["date", "timestamp", "Timestamp", "created_at", "date_created"]),
        ("admin", ["user", "username", "UserName", "user_name", "email", "useremail", "E-mail", "admin"]),
        ("action", ["action", "Action", "event", "description", "activity"]),
        ("ip", ["ip", "ip_address", "IP"]),
    ]

    /// `raw` cut to `fields`, and the names of the raw fields it held that no field reads (sorted, by code points).
    public static func guessed(_ raw: JSONObject, _ fields: [Guessed]) -> (attributes: JSONObject, unread: [String]) {
        var attributes = JSONObject()
        for (name, sources) in fields {
            if let value = sources.lazy.compactMap({ raw[$0] }).first(where: Python.truthy) { attributes[name] = value }
        }
        let read = Set(fields.flatMap(\.sources).map { Array($0.utf8) })
        let unread = raw.keys.filter { !read.contains(Array($0.utf8)) }.sorted(by: Python.precedes)
        return (attributes, unread)
    }

    /// A custom device attribute of the platform `os` (the one it was asked for, which its row may not repeat).
    public static func customAttribute(_ raw: JSONObject, os: String) -> (Resource, unread: [String]) {
        var (attributes, unread) = guessed(raw, attributeFields)
        attributes["os"] = .string(os)
        let found: JSONValue? = attributes["identifier"] ?? attributes["name"]
        let key: String = found.map { Python.str($0) } ?? ""
        return (Resource(type: "customDeviceAttributes", id: key.isEmpty ? "" : os + "/" + key, attributes: attributes), unread)
    }

    /// An admin-log entry, its date as ISO when it is an epoch or a date string Mosyle's device dates use.
    public static func adminLog(_ raw: JSONObject) -> (Resource, unread: [String]) {
        var (attributes, unread) = guessed(raw, adminLogFields)
        if let when = attributes["when"], let iso = MosyleTime.iso(when) { attributes["when"] = .string(iso) }
        return (Resource(type: "adminLogs", id: "", attributes: attributes), unread)
    }

    /// abapit's `adapt_group`, for user groups (`userGroups`) and device groups (`deviceGroups`), cut to
    /// `groupAttributes`.
    public static func group(_ raw: JSONObject, kind: String) -> Resource {
        var members = raw["device_numbers"]
        if members == nil || members == .null {
            if case .array(let primary)? = raw["idusers_primary"] { members = .number(String(primary.count)) } else { members = raw["members"] }
        }
        var attributes: JSONObject = ["name": raw["name"] ?? .string(""), "identifier": raw["identifier"] ?? .string(""),
                                      "memberCount": members ?? .null, "os": raw["os"] ?? .string("")]
        for (key, value) in raw where attributes[key] == nil && groupAttributes.contains(key) { attributes[key] = value }
        return Resource(type: kind, id: firstTruthy(raw, "idusergroup", "iddevicegroup", "id"), attributes: attributes)
    }
}
