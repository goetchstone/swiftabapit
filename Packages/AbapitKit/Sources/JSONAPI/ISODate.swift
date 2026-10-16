import Foundation

/// abapit's `reports.parse_iso`: Python 3.12's `datetime.fromisoformat` after every `Z` becomes
/// `+00:00`, with a naive result read as UTC. Held to the `parse_iso` cases in
/// `Tests/Fixtures/parity/reports.json`.
///
/// Python reads more than Apple or Mosyle send; this reads the forms they do: a date (`2024-03-01` or
/// `20240301`), then one separator and a time (`HH`, `HH:MM`, `HH:MM:SS`, or the same without colons, with
/// a `.`- or `,`-separated fraction of any length, kept to microseconds), then an offset (`±HH`, `±HHMM`,
/// `±HH:MM`). Two listed deviations: ISO week dates (`2024-W09`) and a space before the offset are refused.
public struct ISODate: Sendable, Equatable, Comparable {
    /// The instant.
    public let date: Date
    /// The offset it was written in, in seconds east of UTC: abapit reads its calendar fields (a month for
    /// the dashboard's "added per month") in that offset, not in UTC.
    public let offset: Int
    /// Microseconds within the second, as Python keeps them (a `Date` rounds through a `Double`).
    public let microsecond: Int

    public static func < (a: ISODate, b: ISODate) -> Bool { a.date < b.date }

    public static func parse(_ text: String?) -> ISODate? {
        guard let text, !text.isEmpty else { return nil }
        var scalars = Array(text.replacingOccurrences(of: "Z", with: "+00:00").unicodeScalars)
        // The date: extended or basic.
        let dateLength: Int
        let (year, month, day): (Int, Int, Int)
        if scalars.count >= 10, scalars[4] == "-", scalars[7] == "-",
           let y = number(scalars, 0, 4), let m = number(scalars, 5, 2), let d = number(scalars, 8, 2) {
            (year, month, day, dateLength) = (y, m, d, 10)
        } else if scalars.count >= 8, let y = number(scalars, 0, 4), let m = number(scalars, 4, 2), let d = number(scalars, 6, 2),
                  scalars.count == 8 || !isDigit(scalars[8]) {
            (year, month, day, dateLength) = (y, m, d, 8)
        } else {
            return nil
        }
        guard year >= 1, (1...12).contains(month), (1...daysIn(month, year)).contains(day) else { return nil }
        var hour = 0, minute = 0, second = 0, micro = 0, offset = 0
        if scalars.count > dateLength {
            // Any single separator, as Python 3.11+ allows; the time must follow it.
            scalars = Array(scalars[(dateLength + 1)...])
            guard let time = parseTime(scalars) else { return nil }
            (hour, minute, second, micro, offset) = time
        }
        var components = DateComponents()
        (components.year, components.month, components.day) = (year, month, day)
        (components.hour, components.minute, components.second) = (hour, minute, second)
        guard let base = calendar.date(from: components) else { return nil }
        return ISODate(date: base.addingTimeInterval(TimeInterval(micro) / 1_000_000 - TimeInterval(offset)), offset: offset,
                       microsecond: micro)
    }

    /// `datetime.isoformat()` of the parsed value: `YYYY-MM-DDTHH:MM:SS[.ffffff]+HH:MM`, in its own offset.
    public var isoformat: String {
        let local = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                            from: date.addingTimeInterval(TimeInterval(offset) - TimeInterval(microsecond) / 1_000_000))
        func pad(_ value: Int?, _ width: Int) -> String {
            let text = String(value ?? 0)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        var text = "\(pad(local.year, 4))-\(pad(local.month, 2))-\(pad(local.day, 2))T\(pad(local.hour, 2)):\(pad(local.minute, 2)):\(pad(local.second, 2))"
        if microsecond != 0 { text += "." + pad(microsecond, 6) }
        let sign = offset < 0 ? "-" : "+", magnitude = abs(offset)
        return text + "\(sign)\(pad(magnitude / 3600, 2)):\(pad(magnitude / 60 % 60, 2))"
    }

    /// The calendar fields in the offset it was written in (abapit's `strftime` reads these).
    public var localComponents: DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute, .second],
                                from: date.addingTimeInterval(TimeInterval(offset) - TimeInterval(microsecond) / 1_000_000))
    }

    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    private var calendar: Calendar { Self.calendar }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool { ("0"..."9").contains(scalar) }

    private static func number(_ scalars: [Unicode.Scalar], _ start: Int, _ length: Int) -> Int? {
        guard start + length <= scalars.count else { return nil }
        var value = 0
        for scalar in scalars[start..<(start + length)] {
            guard isDigit(scalar) else { return nil }
            value = value * 10 + Int(scalar.value - 48)
        }
        return value
    }

    private static func daysIn(_ month: Int, _ year: Int) -> Int {
        switch month {
        case 2: (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// `HH[:MM[:SS[.f…]]]` or `HH[MM[SS[.f…]]]`, then an optional `±HH[[:]MM]`.
    private static func parseTime(_ scalars: [Unicode.Scalar]) -> (Int, Int, Int, Int, Int)? {
        let signIndex = scalars.firstIndex { $0 == "+" || $0 == "-" } ?? scalars.count
        let clock = Array(scalars[..<signIndex]), zone = Array(scalars[signIndex...])
        // The clock's fields, split off the fraction.
        let fractionIndex = clock.firstIndex { $0 == "." || $0 == "," } ?? clock.count
        let whole = Array(clock[..<fractionIndex])
        let fields: [Int]
        if whole.contains(":") {
            let parts = whole.split(separator: ":", omittingEmptySubsequences: false)
            fields = parts.compactMap { $0.count == 2 ? number(Array($0), 0, 2) : nil }
            guard (1...3).contains(parts.count), fields.count == parts.count else { return nil }
        } else {
            fields = stride(from: 0, to: whole.count, by: 2).compactMap { number(whole, $0, 2) }
            guard [2, 4, 6].contains(whole.count), fields.count == whole.count / 2 else { return nil }
        }
        let hour = fields[0], minute = fields.count > 1 ? fields[1] : 0, second = fields.count > 2 ? fields[2] : 0
        guard hour < 24, minute < 60, second < 60 else { return nil }
        var micro = 0
        if fractionIndex < clock.count {
            // Python allows a fraction only after seconds.
            guard fields.count == 3 else { return nil }
            let digits = Array(clock[(fractionIndex + 1)...])
            guard !digits.isEmpty, digits.allSatisfy(isDigit) else { return nil }
            let kept = Array((digits.prefix(6) + Array(repeating: Unicode.Scalar("0"), count: 6)).prefix(6))
            micro = number(kept, 0, 6) ?? 0
        }
        var offset = 0
        if !zone.isEmpty {
            let sign = zone[0] == "-" ? -1 : 1
            let rest = Array(zone.dropFirst())
            let hh: Int?, mm: Int?
            switch rest.count {
            case 2: (hh, mm) = (number(rest, 0, 2), 0)
            case 4: (hh, mm) = (number(rest, 0, 2), number(rest, 2, 2))
            case 5 where rest[2] == ":": (hh, mm) = (number(rest, 0, 2), number(rest, 3, 2))
            default: return nil
            }
            guard let hh, let mm, hh < 24, mm < 60 else { return nil }
            offset = sign * (hh * 3600 + mm * 60)
        }
        return (hour, minute, second, micro, offset)
    }
}
