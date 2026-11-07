import Foundation
import GRDB

/// A date without time or time zone, like Python's `datetime.date`.
/// Paperless-ngx stores a document's `created` this way (API v9+).
public struct CalendarDate: Sendable, Hashable, Comparable, Codable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The calendar day of `date` in `timeZone`.
    public init(_ date: Date, in timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year!, month: parts.month!, day: parts.day!)
    }

    /// Parses `yyyy-MM-dd`, or the date part of an ISO 8601 timestamp.
    public init?(iso string: String) {
        let datePart = string.prefix(10)
        let pieces = datePart.split(separator: "-")
        guard pieces.count == 3,
              let y = Int(pieces[0]), let m = Int(pieces[1]), let d = Int(pieces[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        self.init(year: y, month: m, day: d)
        guard isValid else { return nil }
    }

    public static func today(in timeZone: TimeZone = .current) -> CalendarDate {
        CalendarDate(Date(), in: timeZone)
    }

    public var isValid: Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components) else { return false }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        return back.year == year && back.month == month && back.day == day
    }

    /// Midnight at the start of this day in `timeZone`.
    public func startDate(in timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    public func adding(days: Int) -> CalendarDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = calendar.date(byAdding: .day, value: days, to: startDate(in: calendar.timeZone))!
        return CalendarDate(date, in: calendar.timeZone)
    }

    public var iso: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    public var description: String { iso }

    public static func < (lhs: CalendarDate, rhs: CalendarDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let value = CalendarDate(iso: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date \(string)")
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(iso)
    }
}

extension CalendarDate: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { iso.databaseValue }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> CalendarDate? {
        String.fromDatabaseValue(dbValue).flatMap { CalendarDate(iso: $0) }
    }
}
