import Foundation

/// Plain-text helpers for HTML that work without WebKit (any thread, no main actor).
public enum HTMLText {
    /// Text of an HTML document: scripts, styles and comments removed, block
    /// elements turned into line breaks, entities decoded, whitespace cleaned.
    public static func plainText(_ html: String) -> String {
        var text = html
        for pattern in [
            "<!--[\\s\\S]*?-->",
            "<(script|style|head|template|noscript)\\b[^>]*>[\\s\\S]*?</\\1\\s*>",
        ] {
            text = text.replacingOccurrences(of: pattern, with: " ", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(
            of: "<(br|/p|/div|/h[1-6]|/li|/tr|/table|/blockquote|/pre|/section|/article|/header|/footer|hr)\\b[^>]*>",
            with: "\n",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: "<(td|th)\\b[^>]*>", with: "\t", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<li\\b[^>]*>", with: "\n• ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return TextNormalizer.postProcess(decodeEntities(text))
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
    }

    /// Content of the first `<title>` element.
    public static func title(_ html: String) -> String? {
        guard let range = html.range(of: "<title\\b[^>]*>[\\s\\S]*?</title\\s*>", options: [.regularExpression, .caseInsensitive]) else {
            return nil
        }
        let inner = html[range]
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let title = TextNormalizer.postProcess(decodeEntities(inner)).replacingOccurrences(of: "\n", with: " ")
        return title.isEmpty ? nil : title
    }

    /// `content` of `<meta>` tags keyed by lower-cased name, property or itemprop.
    public static func metaTags(_ html: String) -> [String: String] {
        guard let regex = try? NSRegularExpression(pattern: "<meta\\b[^>]*>", options: .caseInsensitive) else { return [:] }
        let attribute = try? NSRegularExpression(
            pattern: "([a-zA-Z:-]+)\\s*=\\s*(\"([^\"]*)\"|'([^']*)'|([^\\s>]+))",
            options: []
        )
        var result: [String: String] = [:]
        let ns = html as NSString
        for match in regex.matches(in: html, range: NSRange(location: 0, length: ns.length)).prefix(500) {
            let tag = ns.substring(with: match.range)
            var attributes: [String: String] = [:]
            let tagNS = tag as NSString
            for a in attribute?.matches(in: tag, range: NSRange(location: 0, length: tagNS.length)) ?? [] {
                let name = tagNS.substring(with: a.range(at: 1)).lowercased()
                let value = [3, 4, 5].compactMap { index -> String? in
                    let r = a.range(at: index)
                    return r.location == NSNotFound ? nil : tagNS.substring(with: r)
                }.first ?? ""
                attributes[name] = decodeEntities(value)
            }
            let key = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"] ?? "").lowercased()
            if !key.isEmpty, let content = attributes["content"], result[key] == nil {
                result[key] = content
            }
        }
        return result
    }

    /// Escapes text for use inside HTML.
    public static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(character)
            }
        }
        return out
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "copy": "©", "reg": "®", "trade": "™", "euro": "€", "pound": "£", "yen": "¥", "cent": "¢",
        "sect": "§", "deg": "°", "plusmn": "±", "times": "×", "divide": "÷", "middot": "·",
        "hellip": "…", "mdash": "—", "ndash": "–", "lsquo": "‘", "rsquo": "’", "ldquo": "“",
        "rdquo": "”", "laquo": "«", "raquo": "»", "bull": "•", "shy": "\u{00AD}",
        "auml": "ä", "ouml": "ö", "uuml": "ü", "Auml": "Ä", "Ouml": "Ö", "Uuml": "Ü", "szlig": "ß",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "euml": "ë", "aacute": "á", "agrave": "à",
        "acirc": "â", "iacute": "í", "icirc": "î", "iuml": "ï", "oacute": "ó", "ocirc": "ô",
        "uacute": "ú", "ucirc": "û", "ccedil": "ç", "ntilde": "ñ", "Eacute": "É", "aring": "å",
        "Aring": "Å", "oslash": "ø", "Oslash": "Ø", "aelig": "æ", "AElig": "Æ",
    ]

    /// Decodes named (common subset), decimal and hexadecimal character references.
    public static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&",
                  let semicolon = text[index...].prefix(12).firstIndex(of: ";") else {
                out.append(character)
                index = text.index(after: index)
                continue
            }
            let name = text[text.index(after: index)..<semicolon]
            var replacement: String?
            if name.hasPrefix("#x") || name.hasPrefix("#X") {
                replacement = UInt32(name.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if name.hasPrefix("#") {
                replacement = UInt32(name.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                replacement = namedEntities[String(name)]
            }
            if let replacement {
                out += replacement
                index = text.index(after: semicolon)
            } else {
                out.append(character)
                index = text.index(after: index)
            }
        }
        return out
    }
}

/// Dates from web page metadata and other loosely formatted sources.
public enum FlexibleDate {
    /// `<meta>` keys checked for a publication date, in order of preference.
    public static let metaDateKeys = [
        "article:published_time", "og:published_time", "datepublished", "date", "dc.date.issued",
        "dc.date", "dcterms.date", "dcterms.created", "pubdate", "publishdate", "publish_date",
        "sailthru.date", "parsely-pub-date", "citation_publication_date", "citation_date",
    ]

    /// Publication date from meta tags, then from `<time datetime>` values.
    public static func publicationDate(meta: [String: String], times: [String] = []) -> Date? {
        for key in metaDateKeys {
            if let value = meta[key], let date = parse(value) { return date }
        }
        for value in times {
            if let date = parse(value) { return date }
        }
        return nil
    }

    /// Parses ISO 8601 (with or without time, fractional seconds or zone), RFC 822
    /// and a few common numeric forms. Dates without a zone use the local time zone.
    public static func parse(_ raw: String) -> Date? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.count >= 8 else { return nil }
        let iso = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [
            [.withInternetDateTime, .withFractionalSeconds],
            [.withInternetDateTime],
        ] {
            iso.formatOptions = options
            if let date = iso.date(from: value) { return date }
        }
        if let date = RFC5322Date.parse(value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in [
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ", "yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd'T'HH:mmZ", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd", "yyyy/MM/dd", "yyyyMMdd",
        ] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}
