import Foundation
import JSONAPI
import MosyleModels

/// abapit's `reports.device_timeline` (held to `Tests/Fixtures/parity/reports.json`): one device's dates from both sources,
/// newest first, the "what happened" neither Apple Business nor Mosyle gives alone (Device 360).
public enum DeviceTimeline {
    public struct Item: Sendable, Equatable {
        /// The date as its source wrote it: the list sorts on this text, by code points, as abapit did.
        public let when: String
        /// `ordered`, `added`, `audit`, `enrolled`, `checkin`, `push` or `beat`.
        public let kind: String
        public let label: String
        /// `ABM` or `Mosyle`, abapit's words.
        public let source: String
    }

    /// The device's Apple attributes, its Apple audit events and its Mosyle attributes, each optional; an item only for a
    /// date that is truthy. A date that isn't a string is its Python `str()` (abapit sorted it as it came, and raised when
    /// it met a string: a recorded deviation, no golden holds one).
    public static func items(apple: JSONObject?, mosyle: JSONObject?, audit: [Resource]?) -> [Item] {
        var items: [Item] = []
        func add(_ when: JSONValue?, _ kind: String, _ label: String, _ source: String) {
            guard Python.truthy(when) else { return }
            items.append(Item(when: Python.str(when), kind: kind, label: label, source: source))
        }
        let apple = apple ?? [:], mosyle = mosyle ?? [:]
        add(apple["orderDateTime"], "ordered", "Ordered", "ABM")
        add(apple["addedToOrgDateTime"], "added", "Added to Apple Business", "ABM")
        for event in audit ?? [] {
            let a = event.attributes
            add(a["eventDateTime"], "audit", label(type: a["type"], outcome: a["outcome"]), "ABM")
        }
        add(mosyle["enrolledAt"], "enrolled", "Enrolled in Mosyle", "Mosyle")
        add(mosyle["lastMdmCheckIn"], "checkin", "MDM check-in", "Mosyle")
        add(mosyle["lastPush"], "push", "Last MDM push", "Mosyle")
        add(mosyle["lastCheckIn"], "beat", "Last seen (heartbeat)", "Mosyle")
        // Newest first, stably: Python's `sort(reverse=True)` keeps equal dates in the order they were added.
        return items.enumerated().sorted { a, b in
            a.element.when.unicodeScalars.elementsEqual(b.element.when.unicodeScalars) ? a.offset < b.offset
                : Python.precedes(b.element.when, a.element.when)
        }.map(\.element)
    }

    /// `attrs.get("type", "event").replace("_", " ").title()`, then `f"{label} · {outcome}".strip(" ·")` when the outcome is
    /// truthy.
    static func label(type: JSONValue?, outcome: JSONValue?) -> String {
        // By code points: `replacingOccurrences` compares Characters, and `_` + U+0301 is one that isn't `_`.
        var spaced = ""
        spaced.unicodeScalars.append(contentsOf: Python.str(type ?? .string("event")).unicodeScalars.map { $0 == "_" ? " " : $0 })
        let name = Python.title(spaced)
        guard Python.truthy(outcome) else { return name }
        let joined = Array("\(name) \u{B7} \(Python.str(outcome))".unicodeScalars)
        let edge: Set<Unicode.Scalar> = [" ", "\u{B7}"]
        guard let first = joined.firstIndex(where: { !edge.contains($0) }), let last = joined.lastIndex(where: { !edge.contains($0) }) else {
            return ""
        }
        var out = ""
        out.unicodeScalars.append(contentsOf: joined[first...last])
        return out
    }
}
