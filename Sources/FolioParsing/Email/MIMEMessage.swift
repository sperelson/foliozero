import Foundation

/// A mailbox: optional display name and address.
public struct MailAddress: Sendable, Hashable, CustomStringConvertible {
    public var name: String?
    public var address: String

    public init(name: String?, address: String) {
        self.name = name
        self.address = address
    }

    /// "Name <address>" or just the address.
    public var formatted: String {
        guard let name, !name.isEmpty, name != address else { return address }
        return "\(name) <\(address)>"
    }

    public var description: String { formatted }
}

/// A header field with its decoded value (RFC 2047 encoded words decoded, folding removed).
public struct MIMEHeaderField: Sendable, Hashable {
    public var name: String
    public var value: String
    /// The unfolded value before encoded-word decoding.
    public var rawValue: String
}

/// A non-body part of a message.
public struct MIMEAttachment: Sendable, Hashable {
    public enum Disposition: String, Sendable, Hashable {
        case inline
        case attachment
    }

    /// File name from Content-Disposition `filename` or Content-Type `name` (RFC 2231 and RFC 2047 decoded).
    public var filename: String?
    /// Lower-cased MIME type, for example "application/pdf".
    public var contentType: String
    public var disposition: Disposition
    /// Content-ID without angle brackets, for `cid:` references from HTML.
    public var contentId: String?
    /// Decoded content.
    public var data: Data

    public var size: Int { data.count }
}

public enum MIMEError: Error, Sendable, CustomStringConvertible {
    case empty
    case malformed(String)

    public var description: String {
        switch self {
        case .empty: "The message is empty"
        case .malformed(let why): "Malformed message: \(why)"
        }
    }
}

/// An Internet message (RFC 5322) with MIME parts (RFC 2045-2049).
///
/// Bodies: the first `text/plain` and `text/html` parts that are not
/// attachments, decoded to strings with their charset. Everything else with
/// a file name, a non-text type or `Content-Disposition: attachment` is an
/// attachment; attached messages (`message/rfc822`) are attachments too.
public struct MIMEMessage: Sendable {
    public var headers: [MIMEHeaderField]
    public var from: MailAddress?
    public var sender: MailAddress?
    public var replyTo: [MailAddress]
    public var to: [MailAddress]
    public var cc: [MailAddress]
    public var bcc: [MailAddress]
    public var subject: String?
    public var date: Date?
    /// Message-ID without angle brackets.
    public var messageID: String?
    public var textBody: String?
    public var htmlBody: String?
    public var attachments: [MIMEAttachment]

    /// First decoded value of header `name` (case-insensitive).
    public func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    /// All decoded values of header `name` (case-insensitive).
    public func headers(named name: String) -> [String] {
        headers.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }.map(\.value)
    }

    /// Parses a complete message (CRLF or LF line endings).
    public static func parse(_ data: Data) throws -> MIMEMessage {
        guard !data.isEmpty else { throw MIMEError.empty }
        let entity = MIMEEntity(data: data)
        guard !entity.headers.isEmpty else { throw MIMEError.malformed("no header fields") }

        var collector = BodyCollector()
        collector.walk(entity)

        let fields = entity.headers.map {
            MIMEHeaderField(name: $0.name, value: EncodedWords.decode($0.value), rawValue: $0.value)
        }
        func raw(_ name: String) -> String? {
            entity.headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
        func addresses(_ name: String) -> [MailAddress] {
            entity.headers
                .filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                .flatMap { AddressParser.parseList($0.value) }
        }

        return MIMEMessage(
            headers: fields,
            from: addresses("From").first,
            sender: addresses("Sender").first,
            replyTo: addresses("Reply-To"),
            to: addresses("To"),
            cc: addresses("Cc"),
            bcc: addresses("Bcc"),
            subject: raw("Subject").map { EncodedWords.decode($0).trimmingCharacters(in: .whitespaces) },
            date: raw("Date").flatMap(RFC5322Date.parse),
            messageID: raw("Message-ID").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t")) },
            textBody: collector.text,
            htmlBody: collector.html,
            attachments: collector.attachments
        )
    }
}

// MARK: - Entity parsing

/// One MIME entity: headers plus raw body bytes, with nested parts for multipart types.
struct MIMEEntity {
    struct Header {
        var name: String
        var value: String
    }

    var headers: [Header]
    var body: Data
    var contentType: String
    var parameters: [String: String]
    var parts: [MIMEEntity]

    init(data: Data, defaultType: String = "text/plain", depth: Int = 0) {
        let (headerData, body) = Self.split(data)
        headers = Self.parseHeaders(headerData)
        self.body = body
        let typeHeader = headers.first { $0.name.lowercased() == "content-type" }?.value
        if let typeHeader {
            let parsed = HeaderParameters.parse(typeHeader)
            contentType = parsed.value.isEmpty ? defaultType : parsed.value.lowercased()
            parameters = parsed.parameters
        } else {
            contentType = defaultType
            parameters = [:]
        }
        parts = []
        if contentType.hasPrefix("multipart/"), let boundary = parameters["boundary"], !boundary.isEmpty, depth < 30 {
            let childDefault = contentType == "multipart/digest" ? "message/rfc822" : "text/plain"
            parts = Self.splitMultipart(body, boundary: boundary).map {
                MIMEEntity(data: $0, defaultType: childDefault, depth: depth + 1)
            }
        }
    }

    func header(_ name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var transferEncoding: String {
        (header("Content-Transfer-Encoding") ?? "7bit").trimmingCharacters(in: .whitespaces).lowercased()
    }

    var disposition: (value: String, parameters: [String: String])? {
        header("Content-Disposition").map {
            let parsed = HeaderParameters.parse($0)
            return (parsed.value.lowercased(), parsed.parameters)
        }
    }

    /// Body with the transfer encoding removed.
    var decodedBody: Data {
        switch transferEncoding {
        case "base64": TransferDecoding.base64(body)
        case "quoted-printable": TransferDecoding.quotedPrintable(body)
        default: body
        }
    }

    /// Body decoded to a string with the declared charset (UTF-8, then Latin-1 when undeclared or wrong).
    var decodedText: String {
        Charsets.decode(decodedBody, charset: parameters["charset"])
    }

    var filename: String? {
        let name = disposition?.parameters["filename"] ?? parameters["name"]
        guard let name, !name.isEmpty else { return nil }
        let decoded = EncodedWords.decode(name).trimmingCharacters(in: .whitespacesAndNewlines)
        return (decoded as NSString).lastPathComponent
    }

    /// Splits at the first empty line. Returns (header bytes, body bytes).
    static func split(_ data: Data) -> (Data, Data) {
        let bytes = [UInt8](data)
        var index = 0
        // A message that starts with an empty line has no headers.
        while index < bytes.count {
            var lineEnd = index
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            let lineLength = lineEnd - index - ((lineEnd > index && bytes[lineEnd - 1] == 0x0D) ? 1 : 0)
            if lineLength == 0 {
                let bodyStart = min(lineEnd + 1, bytes.count)
                return (Data(bytes[0..<index]), Data(bytes[bodyStart...]))
            }
            index = lineEnd + 1
        }
        return (data, Data())
    }

    static func parseHeaders(_ data: Data) -> [Header] {
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        var headers: [Header] = []
        for line in text.split(omittingEmptySubsequences: true, whereSeparator: { $0 == "\n" || $0 == "\r\n" }) {
            let line = line.hasSuffix("\r") ? line.dropLast() : line
            if let first = line.first, first == " " || first == "\t" {
                // Folded continuation of the previous field.
                if !headers.isEmpty {
                    headers[headers.count - 1].value += " " + line.trimmingCharacters(in: .whitespaces)
                }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(" ") else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers.append(Header(name: name, value: value))
        }
        return headers
    }

    /// Body parts between `--boundary` delimiter lines; the preamble and epilogue are dropped.
    static func splitMultipart(_ body: Data, boundary: String) -> [Data] {
        let bytes = [UInt8](body)
        let delimiter = Array("--\(boundary)".utf8)
        var parts: [Data] = []
        var partStart: Int?
        var index = 0
        while index <= bytes.count {
            var lineEnd = index
            while lineEnd < bytes.count, bytes[lineEnd] != 0x0A { lineEnd += 1 }
            var contentEnd = lineEnd
            if contentEnd > index, bytes[contentEnd - 1] == 0x0D { contentEnd -= 1 }
            let line = bytes[index..<contentEnd]
            if line.count >= delimiter.count, line.starts(with: delimiter) {
                let rest = line.dropFirst(delimiter.count)
                let isClose = rest.starts(with: [0x2D, 0x2D])
                let trailing = isClose ? rest.dropFirst(2) : rest
                if trailing.allSatisfy({ $0 == 0x20 || $0 == 0x09 }) {
                    if let start = partStart {
                        // The line break before the delimiter belongs to the delimiter.
                        var end = index
                        if end > start, bytes[end - 1] == 0x0A { end -= 1 }
                        if end > start, bytes[end - 1] == 0x0D { end -= 1 }
                        parts.append(Data(bytes[start..<max(start, end)]))
                    }
                    if isClose { return parts }
                    partStart = min(lineEnd + 1, bytes.count)
                }
            }
            if lineEnd >= bytes.count { break }
            index = lineEnd + 1
        }
        // Missing close delimiter: keep the last part.
        if let start = partStart, start < bytes.count {
            parts.append(Data(bytes[start...]))
        }
        return parts
    }
}

/// Picks the bodies and attachments while walking the entity tree.
struct BodyCollector {
    var text: String?
    var html: String?
    var attachments: [MIMEAttachment] = []

    mutating func walk(_ entity: MIMEEntity) {
        if entity.contentType.hasPrefix("multipart/") {
            for part in entity.parts { walk(part) }
            return
        }
        let disposition = entity.disposition
        let isAttachment = disposition?.value == "attachment"
        let filename = entity.filename
        if !isAttachment, filename == nil {
            if entity.contentType == "text/plain", text == nil {
                text = entity.decodedText
                return
            }
            if entity.contentType == "text/html", html == nil {
                html = entity.decodedText
                return
            }
        }
        // Empty multipart preambles and the like.
        if entity.body.isEmpty, filename == nil, entity.headers.isEmpty { return }
        let contentId = entity.header("Content-ID")?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
        attachments.append(MIMEAttachment(
            filename: filename ?? (entity.contentType == "message/rfc822" ? Self.messageFileName(entity) : nil),
            contentType: entity.contentType,
            disposition: isAttachment ? .attachment : (disposition?.value == "inline" || contentId != nil ? .inline : .attachment),
            contentId: (contentId?.isEmpty ?? true) ? nil : contentId,
            data: entity.decodedBody
        ))
    }

    static func messageFileName(_ entity: MIMEEntity) -> String {
        let inner = MIMEEntity(data: entity.decodedBody)
        let subject = inner.header("Subject").map(EncodedWords.decode)?
            .components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined(separator: "-")
            .trimmingCharacters(in: .whitespaces)
        return "\((subject?.isEmpty ?? true) ? "message" : subject!).eml"
    }
}

// MARK: - Header values

/// `value; key=value; key*=charset'lang'pct; key*0*=...` (RFC 2045 and RFC 2231).
enum HeaderParameters {
    static func parse(_ header: String) -> (value: String, parameters: [String: String]) {
        let segments = splitOutsideQuotes(header, separator: ";")
        let value = segments.first?.trimmingCharacters(in: .whitespaces) ?? ""
        var plain: [String: String] = [:]
        // RFC 2231 continuations: name -> [(index, encoded?, text)]
        var continued: [String: [(Int, Bool, String)]] = [:]

        for segment in segments.dropFirst() {
            guard let equals = segment.firstIndex(of: "=") else { continue }
            var key = segment[..<equals].trimmingCharacters(in: .whitespaces).lowercased()
            var raw = segment[segment.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if raw.hasPrefix("\""), raw.hasSuffix("\""), raw.count >= 2 {
                raw = unquote(String(raw.dropFirst().dropLast()))
            }
            let extended = key.hasSuffix("*")
            if extended { key.removeLast() }
            if let star = key.lastIndex(of: "*"), let index = Int(key[key.index(after: star)...]) {
                let base = String(key[..<star])
                continued[base, default: []].append((index, extended, raw))
            } else if extended {
                plain[key] = decodeExtended(raw, charset: nil).value
            } else if plain[key] == nil {
                plain[key] = raw
            }
        }
        for (base, pieces) in continued {
            var charset: String?
            var result = ""
            for (position, piece) in pieces.sorted(by: { $0.0 < $1.0 }).enumerated() {
                if piece.1 {
                    let decoded = decodeExtended(piece.2, charset: position == 0 ? nil : charset)
                    if position == 0 { charset = decoded.charset }
                    result += decoded.value
                } else {
                    result += piece.2
                }
            }
            plain[base] = result
        }
        return (value, plain)
    }

    /// `charset'language'percent-encoded` (the charset part only on the first segment).
    static func decodeExtended(_ raw: String, charset knownCharset: String?) -> (value: String, charset: String?) {
        var charset = knownCharset
        var encoded = Substring(raw)
        if knownCharset == nil {
            let pieces = raw.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            if pieces.count == 3 {
                charset = String(pieces[0])
                encoded = pieces[2]
            }
        }
        var bytes: [UInt8] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let character = encoded[index]
            if character == "%", let next = encoded.index(index, offsetBy: 3, limitedBy: encoded.endIndex),
               let byte = UInt8(encoded[encoded.index(after: index)..<next], radix: 16) {
                bytes.append(byte)
                index = next
            } else {
                bytes.append(contentsOf: Array(String(character).utf8))
                index = encoded.index(after: index)
            }
        }
        return (Charsets.decode(Data(bytes), charset: charset), charset)
    }

    static func unquote(_ text: String) -> String {
        guard text.contains("\\") else { return text }
        var out = ""
        var escaping = false
        for character in text {
            if escaping {
                out.append(character)
                escaping = false
            } else if character == "\\" {
                escaping = true
            } else {
                out.append(character)
            }
        }
        return out
    }

    static func splitOutsideQuotes(_ text: String, separator: Character) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var escaping = false
        for character in text {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            if character == "\\", inQuotes {
                current.append(character)
                escaping = true
                continue
            }
            if character == "\"" { inQuotes.toggle() }
            if character == separator, !inQuotes {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }
}

/// RFC 2047 encoded words: `=?charset?B?...?=` and `=?charset?Q?...?=`.
public enum EncodedWords {
    /// Decodes every encoded word in `text`. Whitespace between two adjacent
    /// encoded words is dropped, as RFC 2047 requires.
    public static func decode(_ text: String) -> String {
        guard text.contains("=?") else { return text }
        guard let regex = try? NSRegularExpression(pattern: "=\\?([^?\\s]+)\\?([bBqQ])\\?([^?\\s]*)\\?=") else { return text }
        let ns = text as NSString
        var out = ""
        var cursor = 0
        var previousWasWord = false
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let between = ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            if !(previousWasWord && between.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
                out += between
            }
            var charset = ns.substring(with: match.range(at: 1))
            if let star = charset.firstIndex(of: "*") { charset = String(charset[..<star]) } // RFC 2231 language suffix
            let encoding = ns.substring(with: match.range(at: 2)).uppercased()
            let payload = ns.substring(with: match.range(at: 3))
            let bytes: Data = encoding == "B"
                ? TransferDecoding.base64(Data(payload.utf8))
                : TransferDecoding.qEncoding(payload)
            out += Charsets.decode(bytes, charset: charset)
            cursor = match.range.location + match.range.length
            previousWasWord = true
        }
        out += ns.substring(from: cursor)
        return out
    }
}

/// Address lists: `Name <a@b>, "Last, First" <c@d>, e@f, Group: g@h;`.
enum AddressParser {
    static func parseList(_ raw: String) -> [MailAddress] {
        var results: [MailAddress] = []
        for item in splitAddresses(raw) {
            var entry = item.trimmingCharacters(in: .whitespaces)
            // Group syntax "Group: a, b;" was split already; drop the group label.
            if let colon = entry.firstIndex(of: ":"), !entry[..<colon].contains("<"), !entry[..<colon].contains("\"") {
                entry = String(entry[entry.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            }
            entry = entry.trimmingCharacters(in: CharacterSet(charactersIn: "; "))
            guard !entry.isEmpty else { continue }
            if let open = entry.lastIndex(of: "<"), let close = entry.lastIndex(of: ">"), open < close {
                let address = String(entry[entry.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
                var name = String(entry[..<open]).trimmingCharacters(in: .whitespaces)
                if name.hasPrefix("\""), name.hasSuffix("\""), name.count >= 2 {
                    name = HeaderParameters.unquote(String(name.dropFirst().dropLast()))
                }
                name = EncodedWords.decode(name).trimmingCharacters(in: .whitespaces)
                guard !address.isEmpty else { continue }
                results.append(MailAddress(name: name.isEmpty ? nil : name, address: address))
            } else {
                // "a@b (Name)" comment form.
                var address = entry
                var name: String?
                if let open = entry.firstIndex(of: "("), let close = entry.lastIndex(of: ")"), open < close {
                    name = EncodedWords.decode(String(entry[entry.index(after: open)..<close]))
                    address = String(entry[..<open]).trimmingCharacters(in: .whitespaces)
                }
                guard address.contains("@") else { continue }
                results.append(MailAddress(name: name, address: address))
            }
        }
        return results
    }

    /// Splits at commas (and group-ending semicolons) outside quotes, angle brackets and comments.
    static func splitAddresses(_ raw: String) -> [String] {
        var parts: [String] = []
        var current = ""
        var inQuotes = false
        var angle = 0
        var comment = 0
        var escaping = false
        for character in raw {
            if escaping {
                current.append(character)
                escaping = false
                continue
            }
            switch character {
            case "\\" where inQuotes: escaping = true
            case "\"" where comment == 0: inQuotes.toggle()
            case "<" where !inQuotes: angle += 1
            case ">" where !inQuotes: angle = max(0, angle - 1)
            case "(" where !inQuotes: comment += 1
            case ")" where !inQuotes: comment = max(0, comment - 1)
            default: break
            }
            if (character == "," || character == ";"), !inQuotes, angle == 0, comment == 0 {
                parts.append(current)
                current = ""
            } else {
                current.append(character)
            }
        }
        parts.append(current)
        return parts
    }
}

// MARK: - Decoding

enum TransferDecoding {
    static func base64(_ data: Data) -> Data {
        var clean = data.filter { byte in
            (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || (byte >= 0x30 && byte <= 0x39)
                || byte == 0x2B || byte == 0x2F
        }
        // Re-pad; stray "=" in the middle (concatenated parts) are dropped above.
        while clean.count % 4 != 0 { clean.append(0x3D) }
        if let decoded = Data(base64Encoded: clean) { return decoded }
        // A truncated final quantum: drop it.
        return Data(base64Encoded: clean.prefix(clean.count - 4)) ?? Data()
    }

    static func quotedPrintable(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x3D { // "="
                if index + 1 < bytes.count, bytes[index + 1] == 0x0A { index += 2; continue }
                if index + 2 < bytes.count, bytes[index + 1] == 0x0D, bytes[index + 2] == 0x0A { index += 3; continue }
                if index + 2 < bytes.count, let high = hex(bytes[index + 1]), let low = hex(bytes[index + 2]) {
                    out.append(high << 4 | low)
                    index += 3
                    continue
                }
                // Soft break followed by trailing whitespace, or a malformed escape: keep literally.
                var lookahead = index + 1
                while lookahead < bytes.count, bytes[lookahead] == 0x20 || bytes[lookahead] == 0x09 { lookahead += 1 }
                if lookahead < bytes.count, bytes[lookahead] == 0x0A || bytes[lookahead] == 0x0D {
                    index = lookahead + (bytes[lookahead] == 0x0D && lookahead + 1 < bytes.count && bytes[lookahead + 1] == 0x0A ? 2 : 1)
                    continue
                }
            }
            out.append(byte)
            index += 1
        }
        return Data(out)
    }

    /// RFC 2047 "Q": like quoted-printable, with "_" for space.
    static func qEncoding(_ text: String) -> Data {
        let bytes = Array(text.utf8).map { $0 == 0x5F ? 0x20 : $0 }
        return quotedPrintable(Data(bytes))
    }

    static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}

/// Charset names to `String.Encoding`.
public enum Charsets {
    /// Decodes `data` with the IANA `charset`. Falls back to UTF-8, then Windows-1252.
    /// "us-ascii" and "iso-8859-1" are read as Windows-1252, as mail clients do.
    public static func decode(_ data: Data, charset: String?) -> String {
        if let encoding = encoding(for: charset), let text = String(data: data, encoding: encoding) {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        return String(data: data, encoding: .windowsCP1252)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
    }

    public static func encoding(for charset: String?) -> String.Encoding? {
        guard var name = charset?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased(), !name.isEmpty else {
            return nil
        }
        switch name {
        case "utf8", "utf-8": return .utf8
        case "us-ascii", "ascii", "iso-8859-1", "latin1", "latin-1", "iso8859-1": return .windowsCP1252
        case "cp1252": name = "windows-1252"
        case "utf-7", "unicode-1-1-utf-7": return nil
        default: break
        }
        let cf = CFStringConvertIANACharSetNameToEncoding(name as CFString)
        guard cf != kCFStringEncodingInvalidId else { return nil }
        return String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
    }
}

/// RFC 5322 dates, including obsolete zone names and missing seconds or weekday.
public enum RFC5322Date {
    static let zones: [String: Int] = [
        "UT": 0, "UTC": 0, "GMT": 0, "Z": 0,
        "EST": -5, "EDT": -4, "CST": -6, "CDT": -5, "MST": -7, "MDT": -6, "PST": -8, "PDT": -7,
        "CET": 1, "CEST": 2, "SAST": 2, "BST": 1, "IST": 1, "EET": 2, "EEST": 3, "JST": 9,
    ]
    static let months = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]

    /// "Mon, 2 Nov 2026 10:00:00 +0200", "2 Nov 26 10:00 GMT", "Mon, 02 Nov 2026 10:00:00 +0200 (SAST)".
    public static func parse(_ raw: String) -> Date? {
        var text = raw.replacingOccurrences(of: "\\([^)]*\\)", with: " ", options: .regularExpression)
        if let comma = text.firstIndex(of: ",") { text = String(text[text.index(after: comma)...]) }
        let tokens = text.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard tokens.count >= 4, let day = Int(tokens[0]),
              let month = months.firstIndex(of: String(tokens[1].lowercased().prefix(3))),
              var year = Int(tokens[2]) else { return nil }
        if year < 50 { year += 2000 } else if year < 100 { year += 1900 }
        let time = tokens[3].split(separator: ":").compactMap { Int($0) }
        guard time.count >= 2 else { return nil }
        var offset = 0
        if tokens.count >= 5 {
            let zone = tokens[4]
            if let sign = zone.first, sign == "+" || sign == "-", zone.count == 5, let value = Int(zone.dropFirst()) {
                offset = (value / 100 * 3600 + value % 100 * 60) * (sign == "-" ? -1 : 1)
            } else if let hours = zones[zone.uppercased()] {
                offset = hours * 3600
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offset) ?? TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: year, month: month + 1, day: day,
            hour: time[0], minute: time[1], second: time.count > 2 ? time[2] : 0
        ))
    }
}
