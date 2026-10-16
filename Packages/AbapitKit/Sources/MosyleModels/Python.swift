import Foundation
import JSONAPI

/// The few Python behaviours abapit's `mosyle.py` leans on, made exact so the adapters hold to its goldens:
/// truthiness (`x or y`), `str()` of a parsed value, `int()` of a timestamp, `in` on strings and a set's keys.
/// Unicode properties come from Swift's own tables, which may be a version ahead of the generator's Python (the
/// golden's `unicode`): only a character assigned in between can differ.
enum Python {
    /// `bool(value)`: null, `false`, `0`, `0.0`, `""`, `[]` and `{}` are false; NaN is true.
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

    /// `str(value)` of what `json.loads` made of it: the string itself, `True`, `None`, a number as Python writes
    /// it (Phase 7a review L4: `1e20` is `1e+20`, `1e3` is `1000.0`), and a list or a dict as its `repr()`.
    static func str(_ value: JSONValue?) -> String {
        switch value {
        case nil: "None"
        case .string(let text)?: text
        case let value?: repr(value)
        }
    }

    /// `repr(value)`, which `str()` of a list or a dict uses for each item.
    static func repr(_ value: JSONValue) -> String {
        switch value {
        case .null: "None"
        case .bool(let flag): flag ? "True" : "False"
        case .number(let text): isInteger(text) ? (text == "-0" ? "0" : text) : value.double.map(repr) ?? text
        case .string(let text): repr(text)
        case .array(let items): "[" + items.map(repr).joined(separator: ", ") + "]"
        case .object(let members): "{" + members.map { repr($0.key) + ": " + repr($0.value) }.joined(separator: ", ") + "}"
        }
    }

    /// `json.loads` makes an int of a number with no fraction and no exponent (exact, however long; `-0` is 0) and a
    /// float of any other, `NaN` and `Infinity` included.
    static func isInteger(_ text: String) -> Bool {
        !text.unicodeScalars.contains { $0 == "." || $0 == "e" || $0 == "E" || $0 == "N" || $0 == "I" }
    }

    /// `repr(float)`: the shortest digits that read back as the same double, positional while the decimal exponent
    /// is from -4 to 15, else `1e+16` or `1e-05` (CPython's `format_float_short`, mode `r`). Swift's `description`
    /// finds the same shortest digits, so they are taken from it; its layout differs (it writes `9.5e+15`).
    static func repr(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        let sign = value.sign == .minus ? "-" : ""
        let parts = value.magnitude.description.split(separator: "e", maxSplits: 1)
        let pieces = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        var digits = Array(pieces[0] + (pieces.count > 1 ? pieces[1] : ""))
        // The decimal point sits after `point` of the digits.
        var point = pieces[0].count + (parts.count > 1 ? Int(parts[1]) ?? 0 : 0)
        while digits.count > 1, digits.first == "0" { digits.removeFirst(); point -= 1 }
        while digits.count > 1, digits.last == "0" { digits.removeLast() }
        if digits == ["0"] { return sign + "0.0" }
        if point <= -4 || point > 16 {
            let exponent = point - 1, rest = digits.dropFirst()
            return sign + String(digits[0]) + (rest.isEmpty ? "" : "." + String(rest)) + "e" + (exponent < 0 ? "-" : "+")
                + pad(abs(exponent), 2)
        }
        if point <= 0 { return sign + "0." + String(repeating: "0", count: -point) + String(digits) }
        if point >= digits.count { return sign + String(digits) + String(repeating: "0", count: point - digits.count) + ".0" }
        return sign + String(digits[..<point]) + "." + String(digits[point...])
    }

    /// `repr(str)`: single quotes unless the text holds one and no double quote; `\\`, that quote, `\t`, `\n` and
    /// `\r` escaped; any other character Python won't print (an ASCII control, or Unicode's C and Z categories past
    /// ASCII) as `\xhh`, `\uhhhh` or `\Uhhhhhhhh`.
    static func repr(_ text: String) -> String {
        let scalars = text.unicodeScalars
        let quote: Unicode.Scalar = scalars.contains("'") && !scalars.contains("\"") ? "\"" : "'"
        var out = String(quote)
        for scalar in scalars {
            switch scalar {
            case quote, "\\": out += "\\" + String(scalar)
            case "\t": out += "\\t"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F || (scalar.value > 0x7F && !isPrintable(scalar)) {
                    let (prefix, width) = scalar.value <= 0xFF ? ("\\x", 2) : scalar.value <= 0xFFFF ? ("\\u", 4) : ("\\U", 8)
                    let hex = String(scalar.value, radix: 16)
                    out += prefix + String(repeating: "0", count: width - hex.count) + hex
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        return out + String(quote)
    }

    /// `str.isprintable()` for one character past ASCII: not Other (Cc, Cf, Cs, Co, Cn) and not a Separator.
    static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned, .spaceSeparator, .lineSeparator, .paragraphSeparator: false
        default: true
        }
    }

    /// `int(value)` for what Mosyle sends a timestamp as: an integer string, a number (a float truncated toward
    /// zero), a boolean (1 or 0). Nil where Python raises.
    ///
    /// A string is read as CPython's `PyLong_FromUnicodeObject` reads it (Phase 7a review L4): past ASCII, each
    /// decimal digit of any script becomes its ASCII digit (`١٢` is 12) and each space a space; then only ASCII's
    /// own whitespace is stripped around a sign and digits with single `_` between them. So U+001C to U+001F, which
    /// `str.isspace()` counts, are refused here, as there.
    static func int(_ value: JSONValue?) -> Int? {
        switch value {
        case .bool(let flag)?: return flag ? 1 : 0
        case .number(let text)?:
            if let whole = Int(text) { return whole }
            guard let double = value?.double, double.isFinite, abs(double) < 9.2e18 else { return nil }
            return Int(double.rounded(.towardZero))
        case .string(let text)?:
            var scalars: [Unicode.Scalar] = []
            for scalar in text.unicodeScalars {
                if scalar.value < 0x7F {
                    scalars.append(scalar)
                } else if isSpace(scalar) {
                    scalars.append(" ")
                } else if let digit = decimal(scalar) {
                    scalars.append(Unicode.Scalar(UInt8(0x30 + digit)))
                } else {
                    return nil
                }
            }
            let asciiSpace: Set<Unicode.Scalar> = [" ", "\t", "\n", "\u{0B}", "\u{0C}", "\r"]
            while let first = scalars.first, asciiSpace.contains(first) { scalars.removeFirst() }
            while let last = scalars.last, asciiSpace.contains(last) { scalars.removeLast() }
            var sign = 1
            if let first = scalars.first, first == "+" || first == "-" {
                sign = first == "-" ? -1 : 1
                scalars.removeFirst()
            }
            guard let first = scalars.first, let last = scalars.last, isASCIIDigit(first), isASCIIDigit(last) else { return nil }
            var digits = "", previousUnderscore = false
            for scalar in scalars {
                if scalar == "_" {
                    guard !previousUnderscore else { return nil }
                    previousUnderscore = true
                } else if isASCIIDigit(scalar) {
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

    static func isASCIIDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }

    /// A decimal digit's value (Unicode's Nd, `Numeric_Type=Decimal`): the set `int()` reads.
    static func decimal(_ scalar: Unicode.Scalar) -> Int? {
        guard scalar.properties.numericType == .decimal, let value = scalar.properties.numericValue else { return nil }
        return Int(value)
    }

    /// `str.isdigit()` for one character: a decimal digit, or a digit such as `²` or `①` (`Numeric_Type` Decimal or
    /// Digit).
    static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.numericType == .decimal || scalar.properties.numericType == .digit
    }

    /// Python's `str.isspace()`, the same set the serial parser uses.
    static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        [0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x1F, 0x20, 0x85, 0xA0, 0x1680, 0x2000, 0x2001, 0x2002, 0x2003,
         0x2004, 0x2005, 0x2006, 0x2007, 0x2008, 0x2009, 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000].contains(scalar.value)
    }

    /// `part in text`, by code points as Python compares. Swift's `contains` compares Characters, so "ipad" + U+0301
    /// didn't hold "ipad" (Phase 7a review L4).
    static func contains(_ text: String, _ part: String) -> Bool {
        let whole = Array(text.unicodeScalars), piece = Array(part.unicodeScalars)
        guard piece.count <= whole.count else { return false }
        return (0...(whole.count - piece.count)).contains { whole[$0..<($0 + piece.count)].elementsEqual(piece) }
    }

    /// What a Python `set` tells apart, for a string, a number or a boolean: a string by its code points (Swift's
    /// `==` would merge "é" and "e" + U+0301); a number by its value, as `1 == 1.0 == True` (an int exactly, a float
    /// with an integral value as that integer, any other float as its shortest digits). Every NaN `json.loads`
    /// makes is one object, so NaN finds NaN. Nil for null, a list or an object: no key, or not hashable.
    static func key(_ value: JSONValue) -> [UInt8]? {
        switch value {
        case .string(let text): return Array("s".utf8) + Array(text.utf8)
        case .bool(let flag): return Array((flag ? "i1" : "i0").utf8)
        case .number(let text) where isInteger(text): return Array(("i" + (text == "-0" ? "0" : text)).utf8)
        case .number:
            guard let double = value.double else { return nil }
            guard double.isFinite, double == double.rounded(.towardZero) else { return Array(("f" + repr(double)).utf8) }
            // printf writes every digit of an integral double; an Int holds only up to 2^63.
            return Array(("i" + (double == 0 ? "0" : String(format: "%.0f", double))).utf8)
        case .null, .array, .object: return nil
        }
    }

    static func pad(_ number: Int, _ width: Int) -> String {
        let text = String(number)
        return String(repeating: "0", count: max(0, width - text.count)) + text
    }
}

/// Mosyle's timestamps.
public enum MosyleTime {
    /// `datetime.fromtimestamp`'s range: years 1 to 9999.
    static let earliest = -62_135_596_800, latest = 253_402_300_799

    /// abapit's `_to_iso`: a string whose first four characters are digits (by `str.isdigit()`, so `١٩٧٠` and `²²²²`
    /// count) and that holds a `-` is already a date and is kept; otherwise epoch seconds become
    /// `YYYY-MM-DDTHH:MM:SSZ`; anything else is nil (held to the `to_iso` cases of `Tests/Fixtures/parity/mosyle.json`).
    public static func iso(_ value: JSONValue?) -> String? {
        switch value {
        case nil, .null?: return nil
        case .string(let text)? where text.isEmpty: return nil
        case .string(let text)? where text.unicodeScalars.prefix(4).count == 4
            && text.unicodeScalars.prefix(4).allSatisfy(Python.isDigit) && text.unicodeScalars.contains("-"):
            return text
        default:
            guard let seconds = Python.int(value), (earliest...latest).contains(seconds) else { return nil }
            let days = seconds >= 0 ? seconds / 86_400 : -((-seconds + 86_399) / 86_400)
            let second = seconds - days * 86_400
            let (year, month, day) = civil(days)
            return "\(Python.pad(year, 4))-\(Python.pad(month, 2))-\(Python.pad(day, 2))T\(Python.pad(second / 3600, 2)):"
                + "\(Python.pad(second % 3600 / 60, 2)):\(Python.pad(second % 60, 2))Z"
        }
    }

    /// The proleptic Gregorian date `days` after 1970-01-01, the calendar Python's datetime keeps (Phase 7a review
    /// L4: Foundation's Gregorian calendar turns Julian before 1582-10-15, so year 1 began two days late). Howard
    /// Hinnant's `civil_from_days`.
    static func civil(_ days: Int) -> (year: Int, month: Int, day: Int) {
        let shifted = days + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, dayOfYear - (153 * shiftedMonth + 2) / 5 + 1)
    }

    /// The days in `month` of `year`, proleptic Gregorian: 1500 is no leap year, 1600 is.
    static func days(inMonth month: Int, of year: Int) -> Int {
        let leap = year % 4 == 0 && (year % 100 != 0 || year % 400 == 0)
        return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month - 1]
    }

    /// The Logs Stream's compliance timestamp, `01:00 PM - 03/12/2024`: no zone is given, so it is read as the
    /// Mac's local time and written without one (`2024-03-12T13:00:00`). abapit left it unparsed (plan §2.3
    /// defect 5). Nil unless it is exactly that shape, in ASCII digits, with an hour of 1 to 12 (Phase 7a review L4:
    /// `13:00 PM` and `00:30 PM` read as times, the `hours < 24` check could never fail) and a real proleptic
    /// Gregorian date (`02/29/1500` is not one).
    public static func compliance(_ value: JSONValue?) -> String? {
        guard case .string(let text)? = value else { return nil }
        let scalars = Array(text.unicodeScalars)
        let width = scalars.count > 1 && scalars[1] == ":" ? 1 : 2
        guard scalars.count == width + 19 else { return nil }
        func number(_ start: Int, _ count: Int) -> Int? {
            let digits = scalars[start..<(start + count)]
            guard digits.allSatisfy(Python.isASCIIDigit) else { return nil }
            return digits.reduce(0) { $0 * 10 + Int($1.value - 0x30) }
        }
        func literal(_ start: Int, _ expected: String) -> Bool {
            scalars[start..<(start + expected.unicodeScalars.count)].elementsEqual(expected.unicodeScalars)
        }
        let afternoon = literal(width + 3, " PM - ")
        guard let hour = number(0, width), literal(width, ":"), let minute = number(width + 1, 2),
              afternoon || literal(width + 3, " AM - "), let month = number(width + 9, 2), literal(width + 11, "/"),
              let day = number(width + 12, 2), literal(width + 14, "/"), let year = number(width + 15, 4),
              (1...12).contains(hour), minute < 60, (1...12).contains(month), year >= 1,
              (1...days(inMonth: month, of: year)).contains(day) else { return nil }
        return "\(Python.pad(year, 4))-\(Python.pad(month, 2))-\(Python.pad(day, 2))T"
            + "\(Python.pad(hour % 12 + (afternoon ? 12 : 0), 2)):\(Python.pad(minute, 2)):00"
    }
}
