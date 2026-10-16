import Foundation
import JSONAPI

/// The few Python behaviours abapit's `mosyle.py` leans on, made exact so the adapters hold to its goldens:
/// truthiness (`x or y`), `str()` of a scalar, and `int()` of a timestamp.
enum Python {
    /// `bool(value)`: null, `false`, `0`, `""`, `[]` and `{}` are false.
    static func truthy(_ value: JSONValue?) -> Bool {
        switch value {
        case nil, .null?: false
        case .bool(let flag)?: flag
        case .number(let text)?: (Double(text) ?? 1) != 0
        case .string(let text)?: !text.isEmpty
        case .array(let items)?: !items.isEmpty
        case .object(let members)?: !members.isEmpty
        }
    }

    /// `str(value)` for a scalar (`True`, `5`, `0.81`, the string itself); `None` for null.
    static func str(_ value: JSONValue?) -> String {
        switch value {
        case nil, .null?: "None"
        case .bool(let flag)?: flag ? "True" : "False"
        case .number(let text)?: text
        case .string(let text)?: text
        case .array?, .object?: JSONValue.dumps(value!)
        }
    }

    /// `int(value)` for what Mosyle sends a timestamp as: an integer string (whitespace around it, a sign, `_`
    /// between digits allowed, as Python allows), a number (a float truncated toward zero), a boolean (1 or 0).
    /// Nil where Python raises.
    static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .bool(let flag)?: return flag ? 1 : 0
        case .number(let text)?:
            if let whole = Int(text) { return whole }
            guard let double = Double(text), double.isFinite, abs(double) < 9.2e18 else { return nil }
            return Int(double.rounded(.towardZero))
        case .string(let text)?:
            var scalars = Array(text.unicodeScalars)
            while let first = scalars.first, isSpace(first) { scalars.removeFirst() }
            while let last = scalars.last, isSpace(last) { scalars.removeLast() }
            var sign = 1
            if let first = scalars.first, first == "+" || first == "-" {
                sign = first == "-" ? -1 : 1
                scalars.removeFirst()
            }
            guard let first = scalars.first, let last = scalars.last, isDigit(first), isDigit(last) else { return nil }
            var digits = "", previousUnderscore = false
            for scalar in scalars {
                if scalar == "_" {
                    guard !previousUnderscore else { return nil }
                    previousUnderscore = true
                } else if isDigit(scalar) {
                    digits.unicodeScalars.append(scalar)
                    previousUnderscore = false
                } else {
                    return nil
                }
            }
            return Int(digits).map { $0 * sign }
        default:
            return nil
        }
    }

    static func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }

    /// Python's `str.isspace()`, the same set the serial parser uses.
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003,
         0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000].contains(scalar.value)
    }
}

/// Mosyle's timestamps.
public enum MosyleTime {
    /// `datetime.fromtimestamp`'s range: years 1 to 9999.
    static let earliest = -62_135_596_800, latest = 253_402_300_799

    /// abapit's `_to_iso`: a string that starts with four digits and holds a `-` is already a date and is kept;
    /// otherwise epoch seconds become `YYYY-MM-DDTHH:MM:SSZ`; anything else is nil (held to the `to_iso` cases
    /// of `Tests/Fixtures/parity/mosyle.json`).
    public static func iso(_ value: JSONValue?) -> String? {
        switch value {
        case nil, .null?: return nil
        case .string(let text)? where text.isEmpty: return nil
        case .string(let text)? where text.unicodeScalars.prefix(4).count == 4
            && text.unicodeScalars.prefix(4).allSatisfy(Python.isDigit) && text.contains("-"):
            return text
        default:
            guard let seconds = Python.int(value), (earliest...latest).contains(seconds) else { return nil }
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                                from: Date(timeIntervalSince1970: TimeInterval(seconds)))
            return String(format: "%04d-%02d-%02dT%02d:%02d:%02dZ", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
                          parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
        }
    }

    /// The Logs Stream's compliance timestamp, `01:00 PM - 03/12/2024`: no zone is given, so it is read as the
    /// Mac's local time and written without one (`2024-03-12T13:00:00`). abapit left it unparsed (plan §2.3
    /// defect 5). Nil when it isn't that shape or isn't a real date.
    public static func compliance(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        let pattern = /^(\d{1,2}):(\d{2}) (AM|PM) - (\d{2})\/(\d{2})\/(\d{4})$/
        guard let match = text.wholeMatch(of: pattern), let hour = Int(match.1), let minute = Int(match.2),
              let month = Int(match.4), let day = Int(match.5), let year = Int(match.6) else { return nil }
        let hours = hour % 12 + (match.3 == "PM" ? 12 : 0)
        guard hours < 24, minute < 60, (1...12).contains(month), year >= 1 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day)),
              calendar.component(.day, from: date) == day else { return nil }
        return String(format: "%04d-%02d-%02dT%02d:%02d:00", year, month, day, hours, minute)
    }
}
