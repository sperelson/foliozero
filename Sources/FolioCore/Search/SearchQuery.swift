import Foundation

/// Parsed form of the Paperless-ngx advanced search syntax
/// (docs: usage.md "Document searches").
public indirect enum SearchQuery: Sendable, Equatable {
    /// A word, possibly with wildcards (`*`, `?`, `[...]`), in the given text field(s).
    case term(String, field: TextField)
    /// Words that must appear in this order.
    case phrase([String], field: TextField)
    case and([SearchQuery])
    case or([SearchQuery])
    case not(SearchQuery)
    /// Inclusive numeric range. Equal bounds mean an exact value.
    case number(NumberField, lower: Int?, upper: Int?)
    /// Half-open date range `[from, to)`.
    case date(DateField, from: Date?, to: Date?)
    /// Document has a tag whose name equals (case-insensitive) or matches the wildcard pattern.
    case tag(String)
    /// Checksum equality, or prefix when the value ends with `*`.
    case checksum(String, prefix: Bool)
    /// Matches every document (empty query).
    case all

    public enum TextField: String, Sendable, Equatable, CaseIterable {
        /// title, content, correspondent, document type, tags
        case `default`
        case title, content, correspondent, documentType = "document_type", storagePath = "storage_path"
        case originalFilename = "original_filename"
        case notes, notesUser = "notes_user"
        case customFieldNames = "custom_field_names", customFieldValues = "custom_field_values"
        case barcodeValues = "barcode_values", barcodeFormats = "barcode_formats"

        /// FTS5 columns this field searches.
        var columns: [String] {
            self == .default ? SearchSchema.defaultColumns : [rawValue]
        }
    }

    public enum NumberField: String, Sendable, Equatable {
        case asn, pageCount = "page_count", numNotes = "num_notes"
    }

    public enum DateField: String, Sendable, Equatable {
        case created, added, modified
    }
}

public struct SearchQueryError: Error, Sendable, CustomStringConvertible, Equatable {
    public var message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}

/// Parses the Paperless-ngx query language.
public struct SearchQueryParser: Sendable {
    public var timeZone: TimeZone
    public var now: Date

    public init(timeZone: TimeZone = .current, now: Date = Date()) {
        self.timeZone = timeZone
        self.now = now
    }

    public func parse(_ input: String) throws -> SearchQuery {
        var lexer = Lexer(input)
        let tokens = try lexer.tokenize()
        var parser = Parser(tokens: tokens, dates: DateExpressions(timeZone: timeZone, now: now))
        let query = try parser.parseExpression()
        if parser.index < tokens.count {
            throw SearchQueryError("Unexpected \"\(tokens[parser.index].text)\"")
        }
        return query
    }

    // MARK: - Lexer

    enum TokenKind: Equatable {
        case word          // bare word, may contain wildcards
        case quoted        // "..."
        case lparen, rparen
        case and, or, not
        case field(String, FieldValue)
    }

    enum FieldValue: Equatable {
        case word(String)
        case quoted(String)
        case range(String, String)
    }

    struct Token: Equatable {
        var kind: TokenKind
        var text: String
    }

    struct Lexer {
        let chars: [Character]
        var i = 0

        init(_ input: String) { chars = Array(input) }

        mutating func tokenize() throws -> [Token] {
            var tokens: [Token] = []
            while true {
                skipWhitespace()
                guard i < chars.count else { break }
                let c = chars[i]
                if c == "(" { tokens.append(Token(kind: .lparen, text: "(")); i += 1; continue }
                if c == ")" { tokens.append(Token(kind: .rparen, text: ")")); i += 1; continue }
                if c == "\"" {
                    let text = try readQuoted()
                    tokens.append(Token(kind: .quoted, text: text))
                    continue
                }
                let word = readWord()
                if word == "AND" { tokens.append(Token(kind: .and, text: word)); continue }
                if word == "OR" { tokens.append(Token(kind: .or, text: word)); continue }
                if word == "NOT" { tokens.append(Token(kind: .not, text: word)); continue }
                // field:value
                if let colon = word.firstIndex(of: ":"), colon != word.startIndex {
                    let name = String(word[..<colon]).lowercased()
                    let rest = String(word[word.index(after: colon)...])
                    if rest.isEmpty, i < chars.count, chars[i] == "\"" {
                        let text = try readQuoted()
                        tokens.append(Token(kind: .field(name, .quoted(text)), text: "\(name):\"\(text)\""))
                        continue
                    }
                    if rest.isEmpty, i < chars.count, chars[i] == "[" {
                        let (lower, upper) = try readRange()
                        tokens.append(Token(kind: .field(name, .range(lower, upper)), text: "\(name):[\(lower) to \(upper)]"))
                        continue
                    }
                    if !rest.isEmpty {
                        tokens.append(Token(kind: .field(name, .word(rest)), text: word))
                        continue
                    }
                }
                tokens.append(Token(kind: .word, text: word))
            }
            return tokens
        }

        mutating func skipWhitespace() {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
        }

        mutating func readQuoted() throws -> String {
            i += 1 // opening quote
            var text = ""
            while i < chars.count, chars[i] != "\"" {
                text.append(chars[i])
                i += 1
            }
            guard i < chars.count else { throw SearchQueryError("Missing closing quote") }
            i += 1
            return text
        }

        /// Reads up to whitespace or a parenthesis. A `:` followed by `"` or `[` ends the word.
        mutating func readWord() -> String {
            var text = ""
            while i < chars.count {
                let c = chars[i]
                if c.isWhitespace || c == "(" || c == ")" { break }
                if c == "\"" { break }
                if c == "[", text.last == ":" { break }
                // Wildcard brackets inside a word are part of it.
                if c == "[" {
                    while i < chars.count, chars[i] != "]", !chars[i].isWhitespace {
                        text.append(chars[i]); i += 1
                    }
                    if i < chars.count, chars[i] == "]" { text.append("]"); i += 1 }
                    continue
                }
                text.append(c)
                i += 1
            }
            return text
        }

        /// Reads `[lower to upper]`. Bounds may be quoted with single quotes.
        mutating func readRange() throws -> (String, String) {
            i += 1 // [
            var body = ""
            var inQuote = false
            while i < chars.count {
                let c = chars[i]
                if c == "'" { inQuote.toggle(); body.append(c); i += 1; continue }
                if c == "\"" { throw SearchQueryError("Use single quotes inside ranges") }
                if c == "]" && !inQuote { break }
                body.append(c)
                i += 1
            }
            guard i < chars.count else { throw SearchQueryError("Missing ] in range") }
            i += 1
            guard let separator = body.range(of: " to ", options: .caseInsensitive) else {
                throw SearchQueryError("A range needs the form [from to to]")
            }
            func clean(_ s: Substring) -> String {
                s.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "'"))
            }
            return (clean(body[..<separator.lowerBound]), clean(body[separator.upperBound...]))
        }
    }

    // MARK: - Parser

    struct Parser {
        let tokens: [Token]
        var index = 0
        let dates: DateExpressions

        init(tokens: [Token], dates: DateExpressions) {
            self.tokens = tokens
            self.dates = dates
        }

        mutating func parseExpression() throws -> SearchQuery {
            if tokens.isEmpty { return .all }
            return try parseOr()
        }

        mutating func parseOr() throws -> SearchQuery {
            var parts = [try parseAnd()]
            while index < tokens.count, tokens[index].kind == .or {
                index += 1
                parts.append(try parseAnd())
            }
            return parts.count == 1 ? parts[0] : .or(parts)
        }

        mutating func parseAnd() throws -> SearchQuery {
            var parts = [try parseUnary()]
            while index < tokens.count {
                let kind = tokens[index].kind
                if kind == .or || kind == .rparen { break }
                if kind == .and { index += 1 }
                parts.append(try parseUnary())
            }
            return parts.count == 1 ? parts[0] : .and(parts)
        }

        mutating func parseUnary() throws -> SearchQuery {
            guard index < tokens.count else { throw SearchQueryError("Unexpected end of query") }
            if tokens[index].kind == .not {
                index += 1
                return .not(try parseUnary())
            }
            return try parsePrimary()
        }

        mutating func parsePrimary() throws -> SearchQuery {
            let token = tokens[index]
            index += 1
            switch token.kind {
            case .lparen:
                let inner = try parseOr()
                guard index < tokens.count, tokens[index].kind == .rparen else {
                    throw SearchQueryError("Missing closing parenthesis")
                }
                index += 1
                return inner
            case .rparen:
                throw SearchQueryError("Unexpected )")
            case .and, .or, .not:
                throw SearchQueryError("Unexpected \(token.text)")
            case .quoted:
                return textQuery(token.text, field: .default, quoted: true)
            case .word:
                return textQuery(token.text, field: .default, quoted: false)
            case let .field(name, value):
                return try fieldQuery(name: name, value: value, raw: token.text)
            }
        }

        func textQuery(_ text: String, field: SearchQuery.TextField, quoted: Bool) -> SearchQuery {
            if !quoted, SearchQueryParser.isWildcard(text) {
                // Brackets only act as wildcards together with * or ?.
                return .term(text.lowercased(), field: field)
            }
            let words = SearchQueryParser.words(in: text)
            if words.isEmpty { return .all }
            if words.count == 1 { return .term(words[0], field: field) }
            // Unquoted punctuation-joined parts (A-1312/B) and quoted text are phrases.
            return .phrase(words, field: field)
        }

        func fieldQuery(name: String, value: FieldValue, raw: String) throws -> SearchQuery {
            func text(_ field: SearchQuery.TextField) -> SearchQuery {
                switch value {
                case .word(let w): textQuery(w, field: field, quoted: false)
                case .quoted(let q): textQuery(q, field: field, quoted: true)
                case .range(let a, let b): textQuery("\(a) \(b)", field: field, quoted: false)
                }
            }

            switch name {
            case "title": return text(.title)
            case "content": return text(.content)
            case "correspondent": return text(.correspondent)
            case "document_type", "type": return text(.documentType)
            case "storage_path", "path": return text(.storagePath)
            case "original_filename": return text(.originalFilename)
            case "notes", "notes.note": return text(.notes)
            case "notes.user": return text(.notesUser)
            case "custom_fields", "custom_fields.value": return text(.customFieldValues)
            case "custom_fields.name": return text(.customFieldNames)
            case "barcodes", "barcodes.value": return text(.barcodeValues)
            case "barcodes.format": return text(.barcodeFormats)
            case "tag", "tags":
                switch value {
                case .word(let w):
                    let names = w.split(separator: ",").map(String.init).filter { !$0.isEmpty }
                    return names.count == 1 ? .tag(names[0]) : .and(names.map { .tag($0) })
                case .quoted(let q): return .tag(q)
                case .range: throw SearchQueryError("tag does not accept a range")
                }
            case "asn": return try number(.asn, value)
            case "page_count": return try number(.pageCount, value)
            case "num_notes": return try number(.numNotes, value)
            case "checksum":
                switch value {
                case .word(let w), .quoted(let w):
                    let lower = w.lowercased()
                    return lower.hasSuffix("*") ? .checksum(String(lower.dropLast()), prefix: true) : .checksum(lower, prefix: false)
                case .range: throw SearchQueryError("checksum does not accept a range")
                }
            case "created": return try date(.created, value)
            case "added": return try date(.added, value)
            case "modified": return try date(.modified, value)
            default:
                // Unknown fields are searched as ordinary text.
                return textQuery(raw, field: .default, quoted: false)
            }
        }

        func number(_ field: SearchQuery.NumberField, _ value: FieldValue) throws -> SearchQuery {
            func parse(_ s: String) throws -> Int? {
                if s == "*" || s.isEmpty { return nil }
                guard let n = Int(s) else { throw SearchQueryError("\(field.rawValue) needs a number, not \"\(s)\"") }
                return n
            }
            switch value {
            case .word(let w), .quoted(let w):
                if SearchQueryParser.isWildcard(w) { throw SearchQueryError("\(field.rawValue) does not accept wildcards") }
                let n = try parse(w)
                return .number(field, lower: n, upper: n)
            case let .range(a, b):
                return .number(field, lower: try parse(a), upper: try parse(b))
            }
        }

        func date(_ field: SearchQuery.DateField, _ value: FieldValue) throws -> SearchQuery {
            switch value {
            case .word(let w):
                let period = try dates.period(w, quoted: false)
                return .date(field, from: period.start, to: period.end)
            case .quoted(let q):
                let period = try dates.period(q, quoted: true)
                return .date(field, from: period.start, to: period.end)
            case let .range(a, b):
                let from = try dates.bound(a, upper: false)
                let to = try dates.bound(b, upper: true)
                return .date(field, from: from, to: to)
            }
        }
    }

    // MARK: - Helpers

    static func isWildcard(_ text: String) -> Bool {
        text.contains("*") || text.contains("?")
    }

    /// Splits text into index words: letters and digits, lowercased, like the FTS tokenizer.
    static func words(in text: String) -> [String] {
        var words: [String] = []
        var current = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        return words
    }
}

/// Date keywords and relative times for `created:`, `added:`, `modified:`.
struct DateExpressions: Sendable {
    let timeZone: TimeZone
    let now: Date

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.firstWeekday = 2 // Monday
        return calendar
    }

    struct Period {
        var start: Date
        var end: Date
    }

    /// A whole period such as "today", "2005-03", "previous month", "12 december 2019".
    func period(_ raw: String, quoted: Bool) throws -> Period {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let cal = calendar
        let today = cal.startOfDay(for: now)

        func span(_ start: Date, _ component: Calendar.Component, _ count: Int = 1) -> Period {
            Period(start: start, end: cal.date(byAdding: component, value: count, to: start)!)
        }
        func startOf(_ component: Calendar.Component, _ date: Date) -> Date {
            cal.dateInterval(of: component, for: date)!.start
        }

        switch text {
        case "today": return span(today, .day)
        case "yesterday": return span(cal.date(byAdding: .day, value: -1, to: today)!, .day)
        case "tomorrow": return span(cal.date(byAdding: .day, value: 1, to: today)!, .day)
        case "this week": throw SearchQueryError("\"this week\" is not supported; use previous week or a range")
        case "previous week", "last week":
            return span(cal.date(byAdding: .weekOfYear, value: -1, to: startOf(.weekOfYear, today))!, .weekOfYear)
        case "this month": return span(startOf(.month, today), .month)
        case "previous month", "last month":
            return span(cal.date(byAdding: .month, value: -1, to: startOf(.month, today))!, .month)
        case "this quarter":
            return span(quarterStart(today), .month, 3)
        case "previous quarter", "last quarter":
            return span(cal.date(byAdding: .month, value: -3, to: quarterStart(today))!, .month, 3)
        case "this year": return span(startOf(.year, today), .year)
        case "previous year", "last year":
            return span(cal.date(byAdding: .year, value: -1, to: startOf(.year, today))!, .year)
        default: break
        }

        // 2005, 2005-01, 2005-03-04
        let parts = text.split(separator: "-")
        if (1...3).contains(parts.count), parts.allSatisfy({ Int($0) != nil }), parts[0].count == 4 {
            let numbers = parts.compactMap { Int($0) }
            var components = DateComponents(year: numbers[0], month: numbers.count > 1 ? numbers[1] : 1, day: numbers.count > 2 ? numbers[2] : 1)
            components.timeZone = timeZone
            guard let start = cal.date(from: components) else { throw SearchQueryError("Invalid date \(raw)") }
            return span(start, numbers.count == 1 ? .year : numbers.count == 2 ? .month : .day)
        }

        // Exact ISO timestamp.
        if text.contains("t"), let instant = ISO8601DateFormatter.flexible(raw) {
            return Period(start: instant, end: instant.addingTimeInterval(1))
        }

        // Month name: that month this year.
        let months = MonthNames.table(for: ["en"])
        if let month = months[MonthNames.fold(text)] {
            let year = cal.component(.year, from: today)
            let start = cal.date(from: DateComponents(year: year, month: month, day: 1))!
            return span(start, .month)
        }

        // "next monday", "last monday"
        let words = text.split(separator: " ").map(String.init)
        if words.count == 2, words[0] == "next" || words[0] == "last",
           let weekday = Self.weekdays[words[1]] {
            guard quoted else { throw SearchQueryError("Quote \"\(raw)\"") }
            let direction: Calendar.SearchDirection = words[0] == "next" ? .forward : .backward
            let day = cal.nextDate(after: today, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime, direction: direction)!
            return span(cal.startOfDay(for: day), .day)
        }

        // "12 december 2019"
        if words.count == 3, let day = Int(words[0]), let month = months[MonthNames.fold(words[1])], let year = Int(words[2]),
           let start = cal.date(from: DateComponents(year: year, month: month, day: day)) {
            return span(start, .day)
        }

        if Self.weekdays[text] != nil {
            throw SearchQueryError("A bare weekday is not supported; use \"next \(text)\" or \"last \(text)\"")
        }
        if relative(text) != nil || ["now", "noon", "midnight"].contains(text) {
            throw SearchQueryError("\"\(raw)\" only works as a range bound, e.g. [\(raw) to now]")
        }
        throw SearchQueryError("Unknown date \"\(raw)\"")
    }

    /// A range bound. Periods give their start (lower bound) or end (upper bound).
    func bound(_ raw: String, upper: Bool) throws -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if text.isEmpty || text == "*" { return nil }
        let cal = calendar
        switch text {
        case "now": return now
        case "noon": return cal.date(bySettingHour: 12, minute: 0, second: 0, of: now)
        case "midnight": return cal.startOfDay(for: now)
        default: break
        }
        if let date = relative(raw.trimmingCharacters(in: .whitespaces)) { return date }
        let period = try period(raw, quoted: true)
        return upper ? period.end : period.start
    }

    /// `-1 week`, `+2 days`, `now-7d`, `now+1M`. In the compact form `M` is
    /// month and `m` is minute; spelled-out units ignore case.
    func relative(_ text: String) -> Date? {
        var rest = text.replacingOccurrences(of: " ", with: "")
        if rest.lowercased().hasPrefix("now") { rest.removeFirst(3) }
        guard let sign = rest.first, sign == "-" || sign == "+" else { return nil }
        rest.removeFirst()
        let digits = rest.prefix { $0.isNumber }
        guard let amount = Int(digits) else { return nil }
        let unitText = String(rest.dropFirst(digits.count))
        let units: [String: Calendar.Component] = [
            "s": .second, "sec": .second, "second": .second, "seconds": .second,
            "min": .minute, "minute": .minute, "minutes": .minute,
            "h": .hour, "hour": .hour, "hours": .hour,
            "d": .day, "day": .day, "days": .day,
            "w": .weekOfYear, "week": .weekOfYear, "weeks": .weekOfYear,
            "month": .month, "months": .month,
            "y": .year, "year": .year, "years": .year,
        ]
        let component: Calendar.Component?
        switch unitText {
        case "M": component = .month
        case "m": component = .minute
        default: component = units[unitText.lowercased()]
        }
        guard let component else { return nil }
        return calendar.date(byAdding: component, value: sign == "-" ? -amount : amount, to: now)
    }

    func quarterStart(_ date: Date) -> Date {
        let cal = calendar
        let month = cal.component(.month, from: date)
        let quarterMonth = ((month - 1) / 3) * 3 + 1
        return cal.date(from: DateComponents(year: cal.component(.year, from: date), month: quarterMonth, day: 1))!
    }

    static let weekdays: [String: Int] = [
        "sunday": 1, "monday": 2, "tuesday": 3, "wednesday": 4, "thursday": 5, "friday": 6, "saturday": 7,
    ]
}

extension ISO8601DateFormatter {
    /// Parses ISO 8601 timestamps with or without fractional seconds and zone.
    static func flexible(_ string: String) -> Date? {
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds], [.withInternetDateTime],
            [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate],
        ] {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let date = formatter.date(from: string) { return date }
        }
        return nil
    }
}
