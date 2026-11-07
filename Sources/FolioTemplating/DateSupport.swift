import Foundation
import xlocale

/// A date or date-time as Python sees it.
struct PyDateTime {
    var date: Date
    var includesTime: Bool
    var timeZone: TimeZone
    /// True for a date-time parsed from a string without a UTC offset (a Python naive datetime).
    var isNaive = false

    init(date: Date, includesTime: Bool, timeZone: TimeZone, isNaive: Bool = false) {
        self.date = date
        self.includesTime = includesTime
        self.timeZone = timeZone
        self.isNaive = isNaive
    }

    init?(_ value: TemplateValue) {
        guard case let .date(date, includesTime, timeZone) = value else { return nil }
        self.init(date: date, includesTime: includesTime, timeZone: timeZone)
    }
}

/// Calendar fields of a date in a time zone, with microsecond precision.
struct DateParts {
    var year: Int
    var month: Int
    var day: Int
    var hour: Int
    var minute: Int
    var second: Int
    var microsecond: Int
    /// Python `weekday()`: Monday is 0.
    var weekday: Int
    /// 1-based day of the year.
    var dayOfYear: Int
    /// UTC offset in seconds.
    var offset: Int
}

enum DateSupport {
    static func gregorian(_ timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    static func parts(_ date: Date, _ timeZone: TimeZone) -> DateParts {
        let totalMicros = (date.timeIntervalSince1970 * 1_000_000).rounded()
        var seconds = (totalMicros / 1_000_000).rounded(.down)
        var micros = Int(totalMicros - seconds * 1_000_000)
        if micros >= 1_000_000 { micros -= 1_000_000; seconds += 1 }
        let whole = Date(timeIntervalSince1970: seconds)
        let calendar = gregorian(timeZone)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: whole)
        let dayOfYear = calendar.ordinality(of: .day, in: .year, for: whole) ?? 1
        return DateParts(
            year: c.year ?? 1, month: c.month ?? 1, day: c.day ?? 1,
            hour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0,
            microsecond: micros,
            weekday: ((c.weekday ?? 1) + 5) % 7,
            dayOfYear: dayOfYear,
            offset: timeZone.secondsFromGMT(for: whole)
        )
    }

    /// A number that orders calendar days, read in `timeZone`.
    static func dayOrdinal(_ date: Date, _ timeZone: TimeZone) -> Int {
        let p = parts(date, timeZone)
        return p.year * 10_000 + p.month * 100 + p.day
    }

    /// The start of the calendar day of `date` in `timeZone`.
    static func startOfDay(_ date: Date, _ timeZone: TimeZone) -> Date {
        gregorian(timeZone).startOfDay(for: date)
    }

    private static func pad(_ value: Int, _ width: Int) -> String {
        let digits = String(abs(value))
        let padded = String(repeating: "0", count: max(0, width - digits.count)) + digits
        return value < 0 ? "-" + padded : padded
    }

    /// Python's UTC offset text: `+HH:MM`, or `+HHMM` without `separator`.
    static func offsetString(_ offset: Int, separator: String = ":") -> String {
        let sign = offset < 0 ? "-" : "+"
        let magnitude = abs(offset)
        var text = sign + pad(magnitude / 3600, 2) + separator + pad(magnitude % 3600 / 60, 2)
        if magnitude % 60 != 0 { text += separator + pad(magnitude % 60, 2) }
        return text
    }

    static func dateString(_ p: DateParts) -> String {
        "\(pad(p.year, 4))-\(pad(p.month, 2))-\(pad(p.day, 2))"
    }

    static func timeString(_ p: DateParts) -> String {
        var text = "\(pad(p.hour, 2)):\(pad(p.minute, 2)):\(pad(p.second, 2))"
        if p.microsecond != 0 { text += "." + pad(p.microsecond, 6) }
        return text
    }

    /// Python `str(date)` / `str(datetime)`.
    static func pythonString(_ date: Date, includesTime: Bool, timeZone: TimeZone) -> String {
        let p = parts(date, timeZone)
        guard includesTime else { return dateString(p) }
        return dateString(p) + " " + timeString(p) + offsetString(p.offset)
    }

    /// Python `date.isoformat()` / `datetime.isoformat()`.
    static func isoFormat(_ value: PyDateTime) -> String {
        let p = parts(value.date, value.timeZone)
        guard value.includesTime else { return dateString(p) }
        return dateString(p) + "T" + timeString(p) + (value.isNaive ? "" : offsetString(p.offset))
    }

    /// Python `repr()` of a date or datetime.
    static func pythonRepr(_ date: Date, includesTime: Bool, timeZone: TimeZone) -> String {
        let p = parts(date, timeZone)
        guard includesTime else { return "datetime.date(\(p.year), \(p.month), \(p.day))" }
        var fields = [p.year, p.month, p.day, p.hour, p.minute]
        if p.second != 0 || p.microsecond != 0 { fields.append(p.second) }
        if p.microsecond != 0 { fields.append(p.microsecond) }
        let zone: String
        if p.offset == 0 {
            zone = "datetime.timezone.utc"
        } else {
            let days = p.offset < 0 ? -1 : 0
            let seconds = p.offset - days * 86_400
            let delta = days == 0 ? "seconds=\(seconds)" : "days=\(days), seconds=\(seconds)"
            zone = "datetime.timezone(datetime.timedelta(\(delta)))"
        }
        return "datetime.datetime(" + fields.map(String.init).joined(separator: ", ") + ", tzinfo=\(zone))"
    }

    /// Python `tzname()`: "UTC" for UTC, "UTC+02:00" for fixed offsets, else the zone abbreviation.
    static func zoneName(_ timeZone: TimeZone, at date: Date) -> String {
        let identifier = timeZone.identifier
        let offset = timeZone.secondsFromGMT(for: date)
        if identifier == "UTC" || identifier == "GMT" || identifier == "Etc/UTC" { return "UTC" }
        if identifier.hasPrefix("GMT") {
            return offset == 0 ? "UTC" : "UTC" + offsetString(offset)
        }
        return timeZone.abbreviation(for: date) ?? "UTC" + offsetString(offset)
    }

    // MARK: strftime

    /// The POSIX locale, so `strftime` prints English names whatever the process locale is.
    nonisolated(unsafe) private static let posixLocale: locale_t? = newlocale(LC_TIME_MASK, "POSIX", nil)

    /// Python `strftime`: handles `%f`, `%z`, `%:z` and `%Z` like CPython, then defers to C `strftime`
    /// in the POSIX locale.
    static func strftime(_ format: String, _ value: PyDateTime, limits: ValueLimits) throws -> String {
        let p = parts(value.date, value.timeZone)
        let hasZone = value.includesTime && !value.isNaive
        let source = Array(format.unicodeScalars)
        var prepared = ""
        var index = 0
        while index < source.count {
            let scalar = source[index]
            guard scalar == "%", index + 1 < source.count else {
                prepared.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            let directive = source[index + 1]
            switch directive {
            case "f":
                prepared += pad(p.microsecond, 6)
            case "z":
                if hasZone { prepared += offsetString(p.offset, separator: "") }
            case "Z":
                if hasZone {
                    prepared += zoneName(value.timeZone, at: value.date).replacingOccurrences(of: "%", with: "%%")
                }
            case ":" where index + 2 < source.count && source[index + 2] == "z":
                if hasZone { prepared += offsetString(p.offset) }
                index += 1
            default:
                prepared.unicodeScalars.append("%")
                prepared.unicodeScalars.append(directive)
            }
            index += 2
        }
        if prepared.isEmpty { return "" }

        var time = tm()
        time.tm_year = Int32(p.year - 1900)
        time.tm_mon = Int32(p.month - 1)
        time.tm_mday = Int32(p.day)
        time.tm_hour = Int32(value.includesTime ? p.hour : 0)
        time.tm_min = Int32(value.includesTime ? p.minute : 0)
        time.tm_sec = Int32(value.includesTime ? p.second : 0)
        time.tm_wday = Int32((p.weekday + 1) % 7)
        time.tm_yday = Int32(p.dayOfYear - 1)
        time.tm_isdst = -1
        time.tm_gmtoff = p.offset

        var capacity = max(256, prepared.utf8.count * 4)
        let maximum = max(capacity, min(limits.maxStringLength * 2, prepared.utf8.count * 256))
        while true {
            var buffer = [CChar](repeating: 0, count: capacity)
            let previous = uselocale(posixLocale)
            let written = Foundation.strftime(&buffer, capacity, prepared, &time)
            uselocale(previous)
            if written > 0 {
                let bytes = buffer[..<written].map { UInt8(bitPattern: $0) }
                return try limits.check(String(decoding: bytes, as: UTF8.self))
            }
            if capacity >= maximum { return "" }
            capacity = min(capacity * 4, maximum)
        }
    }

    // MARK: Parsing ISO strings (Django parse_datetime / parse_date)

    /// Parses `YYYY-MM-DD` with an optional time `[T ]HH:MM[:SS[.ffffff]]` and offset (`Z`, `±HH`,
    /// `±HHMM`, `±HH:MM`). Strings without an offset are naive and read in `defaultTimeZone`.
    /// Date-only strings become midnight date-times, as Django's `parse_datetime` does.
    static func parseISO(_ text: String, defaultTimeZone: TimeZone) -> PyDateTime? {
        let s = Array(text.trimmingCharacters(in: .whitespaces).unicodeScalars)
        var index = 0

        func digits(_ minCount: Int, _ maxCount: Int) -> Int? {
            var value = 0
            var count = 0
            while count < maxCount, index < s.count, ("0"..."9").contains(s[index]) {
                value = value * 10 + Int(s[index].value - 48)
                index += 1
                count += 1
            }
            return count >= minCount ? value : nil
        }
        func consume(_ scalar: Unicode.Scalar) -> Bool {
            guard index < s.count, s[index] == scalar else { return false }
            index += 1
            return true
        }

        guard let year = digits(4, 4), consume("-"), let month = digits(1, 2), consume("-"),
              let dayOfMonth = digits(1, 2) else { return nil }
        var hour = 0, minute = 0, second = 0, nanos = 0
        var offset: Int?

        if index < s.count {
            guard consume("T") || consume(" ") else { return nil }
            guard let h = digits(1, 2), consume(":"), let m = digits(1, 2) else { return nil }
            hour = h
            minute = m
            if consume(":") {
                guard let sec = digits(1, 2) else { return nil }
                second = sec
                if consume(".") || consume(",") {
                    let start = index
                    guard let fraction = digits(1, 9) else { return nil }
                    let length = index - start
                    nanos = fraction * Int(pow(10, Double(9 - length)))
                }
            }
            while index < s.count, s[index] == " " { index += 1 }
            if consume("Z") {
                offset = 0
            } else if index < s.count, s[index] == "+" || s[index] == "-" {
                let negative = s[index] == "-"
                index += 1
                guard let oh = digits(2, 2) else { return nil }
                var om = 0
                if index < s.count {
                    _ = consume(":")
                    guard let parsed = digits(2, 2) else { return nil }
                    om = parsed
                }
                offset = (negative ? -1 : 1) * (oh * 3600 + om * 60)
            }
            guard index == s.count else { return nil }
        }

        guard (1...12).contains(month), hour < 24, minute < 60, second < 60 else { return nil }
        let zone = offset.flatMap { TimeZone(secondsFromGMT: $0) } ?? defaultTimeZone
        let calendar = gregorian(zone)
        let components = DateComponents(
            year: year, month: month, day: dayOfMonth, hour: hour, minute: minute, second: second, nanosecond: nanos
        )
        guard let firstOfMonth = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let days = calendar.range(of: .day, in: .month, for: firstOfMonth), days.contains(dayOfMonth),
              let date = calendar.date(from: components) else { return nil }
        return PyDateTime(date: date, includesTime: true, timeZone: zone, isNaive: offset == nil)
    }
}
