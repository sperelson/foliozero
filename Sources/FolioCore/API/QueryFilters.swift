import Foundation
import GRDB

/// A filter parameter that could not be used, reported as a DRF field error.
/// `path` nests the message like Django REST framework does for nested serializers.
public struct FilterError: Error, Sendable, Equatable, CustomStringConvertible {
    public var field: String
    public var path: [String]
    public var message: String

    public init(field: String, path: [String] = [], message: String) {
        self.field = field
        self.path = path
        self.message = message
    }

    public var description: String { "\(([field] + path).joined(separator: ".")): \(message)" }
}

/// SQL building blocks for django-filter style lookups (`name__icontains=...`).
public enum QueryFilters {
    /// `istartswith`, `iendswith`, `icontains`, `iexact` on a text column. nil for other lookups.
    public static func charLookup(_ column: String, lookup: String, value: String) -> SQL? {
        let escaped = escapeLike(value)
        switch lookup {
        case "icontains": return "\(sql: column) LIKE \("%" + escaped + "%") ESCAPE '\\'"
        case "istartswith": return "\(sql: column) LIKE \(escaped + "%") ESCAPE '\\'"
        case "iendswith": return "\(sql: column) LIKE \("%" + escaped) ESCAPE '\\'"
        case "iexact": return "\(sql: column) = \(value) COLLATE NOCASE"
        case "exact": return "\(sql: column) = \(value)"
        case "contains": return "instr(\(sql: column), \(value)) > 0"
        default: return nil
        }
    }

    public static let charLookups = ["istartswith", "iendswith", "icontains", "iexact"]

    public static func escapeLike(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
    }

    /// `1,2,3` as integers; nil when any part is not an integer.
    public static func intList(_ value: String) -> [Int]? {
        let parts = value.split(separator: ",", omittingEmptySubsequences: true).map { $0.trimmingCharacters(in: .whitespaces) }
        let ints = parts.compactMap { Int($0) }
        return ints.count == parts.count ? ints : nil
    }

    /// django-filter `BooleanFilter` values; nil means "ignore the filter".
    public static func bool(_ value: String) -> Bool? {
        switch value.lowercased() {
        case "true", "1", "yes", "on": true
        case "false", "0", "no", "off": false
        default: nil
        }
    }

    public static func and(_ parts: [SQL]) -> SQL {
        parts.isEmpty ? "1" : "(" + parts.joined(separator: " AND ") + ")"
    }

    public static func or(_ parts: [SQL]) -> SQL {
        parts.isEmpty ? "0" : "(" + parts.joined(separator: " OR ") + ")"
    }

    /// DRF `OrderingFilter`: comma-separated fields, `-` for descending; unknown fields are dropped.
    /// Returns the SQL terms, or nil when no valid field remains.
    public static func ordering(_ param: String?, allowed: [String: String]) -> [String]? {
        guard let param, !param.isEmpty else { return nil }
        var terms: [String] = []
        for raw in param.split(separator: ",") {
            let field = raw.trimmingCharacters(in: .whitespaces)
            let descending = field.hasPrefix("-")
            let name = descending ? String(field.dropFirst()) : field
            guard let expression = allowed[name] else { continue }
            terms.append(expression + (descending ? " DESC" : " ASC"))
        }
        return terms.isEmpty ? nil : terms
    }

    /// The UTC database timestamp text for a date.
    public static func timestamp(_ date: Date) -> String {
        FolioDateFormat.database.string(from: date)
    }

    /// Parses `2024-03-14`, `2024-03-14 10:00`, ISO 8601 with or without zone.
    /// Naive times are in `timeZone`. Returns nil for unparsable text.
    public static func parseDateTime(_ text: String, timeZone: TimeZone) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 10, let date = CalendarDate(iso: trimmed) {
            return date.startDate(in: timeZone)
        }
        let normalized = trimmed.replacingOccurrences(of: " ", with: "T")
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
        ] {
            iso.formatOptions = options
            if let date = iso.date(from: normalized) { return date }
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        for format in ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss.SSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: normalized) { return date }
        }
        // Offsets without a colon (+0200).
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.date(from: normalized)
    }
}
