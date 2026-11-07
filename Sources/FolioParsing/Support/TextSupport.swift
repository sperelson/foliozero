import Foundation
import NaturalLanguage

/// Text clean-up shared by all parsers.
public enum TextNormalizer {
    /// Mirrors Paperless-ngx `post_process_text`: collapses runs of horizontal
    /// whitespace to one space, removes whitespace at the start and end of each
    /// line, replaces NUL with a space and trims the result. Line breaks are
    /// normalised to `\n`; blank lines are kept.
    public static func postProcess(_ text: String) -> String {
        guard !text.isEmpty else { return "" }
        var lines: [String] = []
        var current = ""
        var pendingSpace = false
        var previousWasCR = false

        for scalar in text.unicodeScalars {
            switch scalar {
            case "\n" where previousWasCR:
                // Second half of "\r\n": the line already ended.
                previousWasCR = false
                continue
            case "\n", "\r", "\u{2028}", "\u{2029}":
                lines.append(current)
                current = ""
                pendingSpace = false
            default:
                if scalar == "\u{0}" || scalar.properties.isWhitespace {
                    if !current.isEmpty { pendingSpace = true }
                } else {
                    if pendingSpace {
                        current.append(" ")
                        pendingSpace = false
                    }
                    current.unicodeScalars.append(scalar)
                }
            }
            previousWasCR = scalar == "\r"
        }
        lines.append(current)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Number of characters that are not whitespace or newlines.
    public static func nonWhitespaceCount(_ text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars where !scalar.properties.isWhitespace {
            count += 1
        }
        return count
    }

    /// Removes NUL characters, which SQLite text columns and FTS do not like.
    public static func removingNULs(_ text: String) -> String {
        text.contains("\u{0}") ? text.replacingOccurrences(of: "\u{0}", with: "") : text
    }
}

/// Decodes text files of unknown encoding.
public enum TextEncodingDetector {
    /// Decodes `data`: byte order mark first, then strict UTF-8, then UTF-16
    /// without a BOM (by the position of zero bytes), then Windows-1252, then
    /// ISO Latin-1 (which never fails). NUL characters are removed.
    public static func decode(_ data: Data) -> (text: String, encoding: String.Encoding) {
        let (text, encoding) = rawDecode(data)
        return (TextNormalizer.removingNULs(text), encoding)
    }

    static func rawDecode(_ data: Data) -> (String, String.Encoding) {
        if let (encoding, bomLength) = byteOrderMark(data) {
            let body = data.dropFirst(bomLength)
            if let text = String(data: Data(body), encoding: encoding) { return (text, encoding) }
        }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }
        if let encoding = utf16WithoutBOM(data), let text = String(data: data, encoding: encoding) {
            return (text, encoding)
        }
        if let text = String(data: data, encoding: .windowsCP1252) { return (text, .windowsCP1252) }
        // Latin-1 maps every byte to a character, so this cannot fail in practice.
        return (String(data: data, encoding: .isoLatin1) ?? String(decoding: data, as: UTF8.self), .isoLatin1)
    }

    /// Encoding and length of a byte order mark at the start of `data`.
    public static func byteOrderMark(_ data: Data) -> (String.Encoding, Int)? {
        let b = [UInt8](data.prefix(4))
        if b.count >= 4, b[0] == 0xFF, b[1] == 0xFE, b[2] == 0, b[3] == 0 { return (.utf32LittleEndian, 4) }
        if b.count >= 4, b[0] == 0, b[1] == 0, b[2] == 0xFE, b[3] == 0xFF { return (.utf32BigEndian, 4) }
        if b.count >= 3, b[0] == 0xEF, b[1] == 0xBB, b[2] == 0xBF { return (.utf8, 3) }
        if b.count >= 2, b[0] == 0xFF, b[1] == 0xFE { return (.utf16LittleEndian, 2) }
        if b.count >= 2, b[0] == 0xFE, b[1] == 0xFF { return (.utf16BigEndian, 2) }
        return nil
    }

    /// Detects BOM-less UTF-16 by the zero high bytes that Latin-script text has.
    static func utf16WithoutBOM(_ data: Data) -> String.Encoding? {
        let sample = [UInt8](data.prefix(4096))
        guard sample.count >= 4 else { return nil }
        let pairs = sample.count / 2
        var zeroEven = 0
        var zeroOdd = 0
        for i in 0..<pairs {
            if sample[2 * i] == 0 { zeroEven += 1 }
            if sample[2 * i + 1] == 0 { zeroOdd += 1 }
        }
        let threshold = Double(pairs) * 0.6
        if Double(zeroOdd) >= threshold, Double(zeroEven) < Double(pairs) * 0.05 { return .utf16LittleEndian }
        if Double(zeroEven) >= threshold, Double(zeroOdd) < Double(pairs) * 0.05 { return .utf16BigEndian }
        return nil
    }

    /// True when `data` (a file prefix) looks like text rather than binary:
    /// a text BOM, or no NUL bytes and almost no control characters.
    public static func looksLikeText(_ data: Data) -> Bool {
        if data.isEmpty { return false }
        if let (encoding, bomLength) = byteOrderMark(data) {
            let body = Data(data.dropFirst(bomLength).prefix(4096))
            guard let text = decodeTruncated(body, encoding: encoding) else { return false }
            return !text.contains("\u{0}") && controlRatio(text.unicodeScalars) < 0.02
        }
        if let encoding = utf16WithoutBOM(data) {
            guard let text = decodeTruncated(Data(data.prefix(4096)), encoding: encoding) else { return false }
            return !text.contains("\u{0}") && controlRatio(text.unicodeScalars) < 0.02
        }
        let sample = data.prefix(8192)
        if sample.contains(0) { return false }
        var control = 0
        for byte in sample where byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0D && byte != 0x0C && byte != 0x1B {
            control += 1
        }
        if Double(control) / Double(sample.count) > 0.02 { return false }
        // Valid UTF-8 (allowing a cut-off sequence at the end) is text. Otherwise
        // accept it as a single-byte encoding such as Windows-1252.
        return true
    }

    private static func decodeTruncated(_ data: Data, encoding: String.Encoding) -> String? {
        var slice = data
        for _ in 0..<4 {
            if let text = String(data: slice, encoding: encoding) { return text }
            guard !slice.isEmpty else { return nil }
            slice = slice.dropLast()
        }
        return nil
    }

    private static func controlRatio(_ scalars: String.UnicodeScalarView) -> Double {
        var total = 0
        var control = 0
        for scalar in scalars {
            total += 1
            if scalar.value < 0x20, scalar != "\t", scalar != "\n", scalar != "\r", scalar != "\u{0C}" { control += 1 }
        }
        return total == 0 ? 0 : Double(control) / Double(total)
    }
}

/// Guesses the language of extracted text.
public enum LanguageDetector {
    /// BCP-47 tag of the dominant language, or nil when the text is too short or unclear.
    public static func detect(_ text: String) -> String? {
        let sample = String(text.prefix(4000))
        guard TextNormalizer.nonWhitespaceCount(sample) >= 20 else { return nil }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        let confidence = recognizer.languageHypotheses(withMaximum: 1)[language] ?? 0
        return confidence >= 0.5 ? language.rawValue : nil
    }
}
