import Foundation

/// The cases a closed Swift enum knows of an open, Apple-defined value set.
public protocol KnownValues: RawRepresentable, CaseIterable, Hashable, Sendable where RawValue == String {}

/// A value from a set Apple may extend (invariant 10). Apple's forward-compatibility rule is that a
/// client must accept values it doesn't know, and Apple's own lists are incomplete
/// (`AuditEventCategory`, `AuditEventSubjectType`, plan §3.3): an unknown value survives as
/// `.unknown(raw)`, and the UI shows it raw rather than dropping the row.
public enum OpenEnum<Known: KnownValues>: Hashable, Sendable, CustomStringConvertible {
    case known(Known)
    case unknown(String)

    public init(_ raw: String) {
        // Byte for byte: Apple's values are ASCII, and `String ==` would fold Unicode equivalents.
        if let match = Known.allCases.first(where: { $0.rawValue.utf8.elementsEqual(raw.utf8) }) {
            self = .known(match)
        } else {
            self = .unknown(raw)
        }
    }

    public init(_ known: Known) { self = .known(known) }

    public var rawValue: String {
        switch self {
        case .known(let value): value.rawValue
        case .unknown(let raw): raw
        }
    }

    public var known: Known? {
        if case .known(let value) = self { value } else { nil }
    }

    public var description: String { rawValue }
}

extension JSONValue {
    /// The string as an open enum value; nil when it isn't a string.
    public func open<Known: KnownValues>(_: Known.Type = Known.self) -> OpenEnum<Known>? {
        string.map(OpenEnum.init)
    }
}
