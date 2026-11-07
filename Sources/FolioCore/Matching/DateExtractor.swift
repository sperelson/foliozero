import Foundation

/// Finds document dates in text, like the Paperless-ngx regex date parser
/// (`documents/plugins/date_parsing/regex_parser.py`) with `dateparser`
/// settings `PREFER_DAY_OF_MONTH=first`.
public struct DateExtractor: Sendable {
    public var contentOrder: DateOrder
    public var filenameOrder: DateOrder?
    public var languages: [String]
    public var ignoreDates: Set<CalendarDate>
    public var timeZone: TimeZone

    /// Languages used for month names when none are configured.
    public static let defaultLanguages = ["en", "de", "fr", "es", "it", "nl", "pt", "af", "sv", "da", "nb", "fi", "pl", "cs", "tr"]

    public init(contentOrder: DateOrder = .DMY, filenameOrder: DateOrder? = nil, languages: [String] = [], ignoreDates: Set<CalendarDate> = [], timeZone: TimeZone = .current) {
        self.contentOrder = contentOrder
        self.filenameOrder = filenameOrder
        self.languages = languages.isEmpty ? Self.defaultLanguages : languages
        self.ignoreDates = ignoreDates
        self.timeZone = timeZone
    }

    public init(settings: Settings) {
        self.init(
            contentOrder: settings.dateOrder,
            filenameOrder: settings.filenameDateOrder,
            languages: settings.dateParserLanguages,
            ignoreDates: Set(settings.ignoreDates.compactMap { DateExtractor.parseIgnoreDate($0) }),
            timeZone: settings.timeZone
        )
    }

    /// Paperless-ngx `IGNORE_DATES` values are ISO dates.
    static func parseIgnoreDate(_ string: String) -> CalendarDate? {
        CalendarDate(iso: string.trimmingCharacters(in: .whitespaces))
    }

    /// All valid dates, file name first (when a file name order is set), then content.
    public func dates(filename: String, content: String, now: Date = Date()) -> [CalendarDate] {
        var result: [CalendarDate] = []
        if let filenameOrder {
            result += scan(filename, order: filenameOrder, now: now)
        }
        result += scan(content, order: contentOrder, now: now)
        return result
    }

    /// The first valid date, or nil.
    public func firstDate(filename: String, content: String, now: Date = Date()) -> CalendarDate? {
        if let filenameOrder, let date = scan(filename, order: filenameOrder, now: now, limit: 1).first {
            return date
        }
        return scan(content, order: contentOrder, now: now, limit: 1).first
    }

    // MARK: - Scanning

    private static let letters = "a-zéûäëčžúřěáíóńźçşğü"
    private static let pattern: String = {
        let l = letters
        let start = "(\\b|(?!=([_-])))"
        let end = "(\\b|(?=([_-])))"
        return [
            "\(start)(\\d{1,2})[\\./-](\\d{1,2})[\\./-](\\d{4}|\\d{2})\(end)",
            "\(start)(\\d{4}|\\d{2})[\\./-](\\d{1,2})[\\./-](\\d{1,2})\(end)",
            "\(start)(\\d{1,2}[\\. ]+[\(l)]{3,9} \\d{4}|[\(l)]{3,9} \\d{1,2}, \\d{4})\(end)",
            "\(start)([^\\W\\d_]{3,9} \\d{1,2}, (\\d{4}))\(end)",
            "\(start)([^\\W\\d_]{3,9} \\d{4})\(end)",
            "\(start)(\\d{1,2}[^ 0-9]{2}[\\. ]+[^ ]{3,9}[ \\./-]\\d{4})\(end)",
            "\(start)(\\b\\d{1,2}[ \\./-][\(l)]{3}[ \\./-]\\d{4})\(end)",
        ].joined(separator: "|")
    }()

    private static let regex = try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])

    func scan(_ text: String, order: DateOrder, now: Date, limit: Int = .max) -> [CalendarDate] {
        let nsText = text as NSString
        var found: [CalendarDate] = []
        let reference = CalendarDate(now, in: timeZone)
        let months = MonthNames.table(for: languages)
        // Unlike Paperless-ngx (finditer), a candidate that is not a date, such as
        // "Generated 2024" in "Generated 2024-03-14", only consumes its first word.
        // The scan resumes after that word, so the real date is still found, and
        // "31.02.2024" cannot turn into "1.02.2024".
        var position = 0
        while position < nsText.length, found.count < limit,
              let match = Self.regex.firstMatch(in: text, range: NSRange(location: position, length: nsText.length - position)) {
            let candidate = nsText.substring(with: match.range)
            if let date = Self.parse(candidate, order: order, months: months, reference: reference),
               date.year > 1900, date <= reference, !ignoreDates.contains(date) {
                found.append(date)
                position = max(match.range.upperBound, match.range.location + 1)
            } else {
                position = Self.endOfWord(in: nsText, from: match.range.location)
            }
        }
        return found
    }

    /// Index just past the run of letters and digits starting at `start` (at least start + 1).
    private static func endOfWord(in text: NSString, from start: Int) -> Int {
        var index = start
        while index < text.length,
              let scalar = Unicode.Scalar(text.character(at: index)),
              CharacterSet.alphanumerics.contains(scalar) {
            index += 1
        }
        return max(index, start + 1)
    }

    // MARK: - Parsing one candidate

    static func parse(_ raw: String, order: DateOrder, months: [String: Int], reference: CalendarDate) -> CalendarDate? {
        let string = raw.trimmingCharacters(in: CharacterSet(charactersIn: " _-.,").union(.whitespacesAndNewlines))
        let tokens = tokenize(string)
        guard !tokens.isEmpty else { return nil }

        var numbers: [(value: Int, digits: Int)] = []
        var month: Int?
        for token in tokens {
            if let value = Int(token) {
                numbers.append((value, token.count))
            } else if let leading = Int(token.prefix { $0.isNumber }), token.first?.isNumber == true {
                numbers.append((leading, token.prefix { $0.isNumber }.count)) // "14th"
            } else if let m = months[MonthNames.fold(token)] {
                month = m
            }
        }

        if let month {
            // Textual month: remaining numbers are day and year.
            guard let yearIndex = numbers.firstIndex(where: { $0.digits == 4 }) else { return nil }
            let year = numbers[yearIndex].value
            let day = numbers.enumerated().first { $0.offset != yearIndex }?.element.value ?? 1
            return valid(year: year, month: month, day: day)
        }

        guard numbers.count == 3 else { return nil }
        if numbers[0].digits == 4 {
            return valid(year: numbers[0].value, month: numbers[1].value, day: numbers[2].value)
        }
        let components = Array(order.rawValue)
        var year = 0, monthValue = 0, day = 0
        for (index, component) in components.enumerated() {
            let number = numbers[index]
            switch component {
            case "Y": year = number.digits == 4 ? number.value : expandTwoDigitYear(number.value)
            case "M": monthValue = number.value
            default: day = number.value
            }
        }
        if numbers[2].digits == 4, order.rawValue.first == "Y" {
            // e.g. order YMD but text is 14.03.2024: fall back to day-first.
            return valid(year: numbers[2].value, month: numbers[1].value, day: numbers[0].value)
        }
        return valid(year: year, month: monthValue, day: day)
    }

    /// Python `%y`: 69-99 map to 1900s, 00-68 to 2000s.
    static func expandTwoDigitYear(_ value: Int) -> Int {
        value >= 69 ? 1900 + value : 2000 + value
    }

    private static func valid(year: Int, month: Int, day: Int) -> CalendarDate? {
        let date = CalendarDate(year: year, month: month, day: day)
        return date.isValid ? date : nil
    }

    private static func tokenize(_ string: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        for ch in string {
            if ch.isLetter || ch.isNumber {
                if let last = current.last, last.isNumber != ch.isNumber, !(last.isNumber && ch.isLetter) {
                    tokens.append(current)
                    current = ""
                }
                current.append(ch)
            } else if !current.isEmpty {
                tokens.append(current)
                current = ""
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }
}

/// Month names in many languages, folded to lowercase ASCII-ish keys.
enum MonthNames {
    nonisolated(unsafe) private static var cache: [String: [String: Int]] = [:]
    private static let lock = NSLock()

    static func table(for languages: [String]) -> [String: Int] {
        let key = languages.joined(separator: "+")
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[key] { return cached }
        var table: [String: Int] = [:]
        for language in languages {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: language)
            let lists = [
                formatter.monthSymbols, formatter.shortMonthSymbols,
                formatter.standaloneMonthSymbols, formatter.shortStandaloneMonthSymbols,
            ]
            for list in lists {
                for (index, name) in (list ?? []).enumerated() {
                    let folded = fold(name.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
                    if folded.count >= 3, table[folded] == nil { table[folded] = index + 1 }
                }
            }
        }
        // Common English abbreviations DateFormatter does not list.
        for (name, month) in ["sept": 9, "febr": 2] where table[name] == nil { table[name] = month }
        cache[key] = table
        return table
    }

    static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}
