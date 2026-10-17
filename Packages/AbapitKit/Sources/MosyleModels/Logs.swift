import Foundation
import JSONAPI

/// abapit's `normalize_logs`: the Logs Stream's per-type shapes flattened into one newest-first list of
/// `{kind, when, label, status, device, serial, user}`. One correction (defect 5): a compliance timestamp
/// (`01:00 PM - 03/12/2024`) is parsed as local time. Held to `Tests/Fixtures/parity/mosyle.json`.
public enum MosyleLogs {
    public static func normalize(_ response: JSONValue?) -> [JSONObject] {
        guard let response = response?.object else { return [] }
        var events: [JSONObject] = []
        func add(_ kind: String, _ when: JSONValue?, _ label: JSONValue?, _ status: JSONValue? = nil, _ device: JSONValue? = nil,
                 _ serial: JSONValue? = nil, _ user: JSONValue? = nil) {
            var stamp = MosyleTime.iso(when) ?? (Python.truthy(when) ? Python.str(when) : "")
            if kind == "compliance", let local = MosyleTime.compliance(.string(stamp)) { stamp = local }
            func orEmpty(_ value: JSONValue?) -> JSONValue { Python.truthy(value) ? value! : .string("") }
            events.append(["kind": .string(kind), "when": .string(stamp), "label": orEmpty(label), "status": orEmpty(status),
                           "device": orEmpty(device), "serial": orEmpty(serial), "user": orEmpty(user)])
        }
        func logs(_ value: JSONValue?) -> [JSONObject] {
            switch value {
            case .object(let object)?: object["Logs"]?.array?.compactMap(\.object) ?? []
            default: []
            }
        }
        if case .object(let compliance)? = response["compliance"] {
            for (_, sub) in compliance {
                for log in logs(sub) {
                    add("compliance", log["Timestamp"], log["RuleName"], log["Status"], log["DeviceName"], log["SerialNumber"], log["E-mail"])
                }
            }
        }
        if case .object(let zeroTrust)? = response["zero_trust"] {
            var entries = logs(zeroTrust["Events"])
            if entries.isEmpty { entries = zeroTrust["Logs"]?.array?.compactMap(\.object) ?? [] }
            for log in entries {
                add("zero_trust", log["Timestamp"], Python.truthy(log["Application"]) ? log["Application"] : log["FileName"], log["Action"],
                    log["Device"], nil, log["Source"])
            }
        }
        for log in logs(response["action_logs"]) {
            add("action", log["ActionDate"], log["Action"], nil, nil, nil, Python.truthy(log["UserName"]) ? log["UserName"] : log["E-mail"])
        }
        for key in ["dns", "av"] {
            let entries: [JSONObject] = switch response[key] {
            case .object?: logs(response[key])
            case .array(let items)?: items.compactMap(\.object)
            default: []
            }
            for log in entries {
                let label = [log["Domain"], log["FileName"], log["RuleName"]].first(where: Python.truthy) ?? log["RuleName"]
                add(key, log["Timestamp"], label, Python.truthy(log["Action"]) ? log["Action"] : log["Status"],
                    Python.truthy(log["Device"]) ? log["Device"] : log["DeviceName"], log["SerialNumber"])
            }
        }
        // Newest first, stably, as Python's sort(reverse=True) keeps equal entries in order. The stamps compare by
        // code points, a tie included (verifier round 2): Swift's `==` on String is canonical equivalence, so
        // "2024-e" + U+0301 and "2024-" + U+00E9 tied and kept their order, where Python puts U+00E9's first.
        let keyed = events.enumerated().map { offset, event in
            (offset: offset, when: Array((event["when"]?.string ?? "").unicodeScalars), event: event)
        }
        return keyed.sorted { a, b in
            a.when == b.when ? a.offset < b.offset : b.when.lexicographicallyPrecedes(a.when)
        }.map(\.event)
    }
}
