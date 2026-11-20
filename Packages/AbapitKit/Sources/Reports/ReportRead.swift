import Foundation
import JSONAPI

/// How much of a list a report was given (invariant 8). A report says it in its own words and never reads a list it
/// didn't get whole as the whole fleet: the screens that load the lists (the page cap, a refused role) build one.
public enum ListRead: Sendable, Equatable {
    /// Every page was read.
    case whole
    /// Some of it: the page cap, or a failure part-way. The text says how much ("showing 500 of at least 800").
    case partly(String)
    /// None of it: the text says why ("your role can't read this").
    case notRead(String)

    /// Short words for a CSV's leading `listRead` column.
    public var csvWords: String {
        switch self {
        case .whole: "read in full"
        case .partly(let how): "read in part: \(how)"
        case .notRead(let why): "not read: \(why)"
        }
    }

    public var isNotRead: Bool { if case .notRead = self { true } else { false } }

    public var words: String {
        switch self {
        case .whole: "Read in full."
        case .partly(let how): "Read in part: \(how). The counts below cover only what was read."
        case .notRead(let why): "Not read: \(why). Nothing below can be judged."
        }
    }
}

/// What one device's own read gave (its Activation Lock status, its AppleCare coverage). `notRead` carries the reason, in
/// words; it is never an answer about the device.
public enum DeviceRead<Value: Sendable>: Sendable {
    case read(Value)
    case notRead(String)
}

extension DeviceRead: Equatable where Value: Equatable {}

/// Reports sort and compare by bytes, as the rest of this module does: `String <` folds canonical equivalents.
func byBytes(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

/// "yes" and "no" for a CSV cell, and nothing for a value Apple didn't send.
func yesNo(_ flag: Bool?) -> String { flag.map { $0 ? "yes" : "no" } ?? "" }

/// What Apple sent for `key`, in words: nil when it is absent or null; a string as it is; any other value as its JSON text.
/// A value that was sent is never shown as "not sent" (review, item 8).
func sent(_ object: JSONObject, _ key: String) -> String? {
    switch object[key] {
    case nil, .null?: nil
    case .string(let text)?: text
    case let value?: value.jsonText
    }
}

/// A value Apple sent where a number or a flag is expected, as JSON text (a string keeps its quotes); nil when absent or null.
func sentRaw(_ object: JSONObject, _ key: String) -> String? {
    switch object[key] {
    case nil, .null?: nil
    case let value?: value.jsonText
    }
}

/// A value that isn't a date `ISODate` reads, as the Services screen shows it: its JSON text.
func unreadableDate(_ value: JSONValue) -> String { value.jsonText }
