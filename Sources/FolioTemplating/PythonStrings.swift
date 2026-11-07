import Foundation

/// Python `str` methods, working on code points as Python does.
enum PyString {
    static func strip(_ s: String, chars: String?, leading: Bool = true, trailing: Bool = true) -> String {
        let set = chars.map { Set($0.unicodeScalars) }
        func remove(_ scalar: Unicode.Scalar) -> Bool {
            set.map { $0.contains(scalar) } ?? Py.isWhitespace(scalar)
        }
        var scalars = Substring(s).unicodeScalars[...]
        if leading { while let first = scalars.first, remove(first) { scalars.removeFirst() } }
        if trailing { while let last = scalars.last, remove(last) { scalars.removeLast() } }
        return Py.string(scalars)
    }

    static func split(_ s: String, separator: String?, maxSplit: Int) throws -> [String] {
        let scalars = Py.scalars(s)
        var parts: [String] = []
        guard let separator else {
            var index = 0
            while index < scalars.count {
                while index < scalars.count, Py.isWhitespace(scalars[index]) { index += 1 }
                guard index < scalars.count else { break }
                if maxSplit >= 0 && parts.count == maxSplit {
                    var end = scalars.count
                    while end > index, Py.isWhitespace(scalars[end - 1]) { end -= 1 }
                    parts.append(Py.string(scalars[index..<end]))
                    return parts
                }
                let start = index
                while index < scalars.count, !Py.isWhitespace(scalars[index]) { index += 1 }
                parts.append(Py.string(scalars[start..<index]))
            }
            return parts
        }
        let needle = Py.scalars(separator)
        guard !needle.isEmpty else { throw RuntimeFailure("empty separator") }
        var start = 0
        while maxSplit < 0 || parts.count < maxSplit, let found = Py.find(needle, in: scalars, from: start) {
            parts.append(Py.string(scalars[start..<found]))
            start = found + needle.count
        }
        parts.append(Py.string(scalars[start...]))
        return parts
    }

    static func replace(_ s: String, old: String, new: String, count: Int, limits: ValueLimits) throws -> String {
        let scalars = Py.scalars(s)
        let needle = Py.scalars(old)
        let replacement = Py.scalars(new)
        var result: [Unicode.Scalar] = []
        var replaced = 0
        if needle.isEmpty {
            // Python inserts the replacement before every character and at the end.
            for scalar in scalars {
                if count < 0 || replaced < count {
                    result.append(contentsOf: replacement)
                    replaced += 1
                }
                result.append(scalar)
                try limits.checkStringLength(result.count)
            }
            if count < 0 || replaced < count { result.append(contentsOf: replacement) }
            return try limits.check(Py.string(result))
        }
        var index = 0
        while index < scalars.count {
            if count < 0 || replaced < count, let found = Py.find(needle, in: scalars, from: index) {
                result.append(contentsOf: scalars[index..<found])
                result.append(contentsOf: replacement)
                index = found + needle.count
                replaced += 1
                try limits.checkStringLength(result.count)
            } else {
                result.append(contentsOf: scalars[index...])
                break
            }
        }
        return try limits.check(Py.string(result))
    }

    /// Python `str.title()`: a letter after a cased letter is lowercased; otherwise title-cased.
    static func title(_ s: String) -> String {
        var result = ""
        var previousCased = false
        for scalar in s.unicodeScalars {
            result += previousCased ? scalar.properties.lowercaseMapping : scalar.properties.titlecaseMapping
            previousCased = scalar.properties.isCased
        }
        return result
    }

    /// Python `str.capitalize()`.
    static func capitalize(_ s: String) -> String {
        guard let first = s.unicodeScalars.first else { return s }
        return first.properties.titlecaseMapping + Py.string(s.unicodeScalars.dropFirst()).lowercased()
    }

    /// Python `str.center(width)`.
    static func center(_ s: String, width: Int, limits: ValueLimits) throws -> String {
        let length = Py.length(of: s)
        guard width > length else { return s }
        try limits.checkStringLength(width)
        let margin = width - length
        let left = margin / 2 + (margin & width & 1)
        return String(repeating: " ", count: left) + s + String(repeating: " ", count: margin - left)
    }

    /// Python `str.splitlines()`.
    static func splitLines(_ s: String) -> [String] {
        var lines: [String] = []
        var current: [Unicode.Scalar] = []
        let scalars = Py.scalars(s)
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            switch scalar.value {
            case 0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029:
                lines.append(Py.string(current))
                current = []
                if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
            default:
                current.append(scalar)
            }
            index += 1
        }
        if !current.isEmpty { lines.append(Py.string(current)) }
        return lines
    }

    /// Python `str.islower()` / `str.isupper()`.
    static func hasOnlyCase(_ s: String, lower: Bool) -> Bool {
        var sawCased = false
        for scalar in s.unicodeScalars where scalar.properties.isCased {
            sawCased = true
            if lower ? scalar.properties.isUppercase : scalar.properties.isLowercase { return false }
            if scalar.properties.generalCategory == .titlecaseLetter { return false }
        }
        return sawCased
    }

    /// Python `int(text, base)`, or nil when the text is not an integer.
    static func parseInt(_ text: String, base: Int) -> Int? {
        var s = strip(text, chars: nil)
        var negative = false
        if let first = s.first, first == "+" || first == "-" {
            negative = first == "-"
            s.removeFirst()
        }
        var radix = base
        let lower = s.lowercased()
        for (prefix, prefixRadix) in [("0x", 16), ("0o", 8), ("0b", 2)] where lower.hasPrefix(prefix) {
            if radix == 0 || radix == prefixRadix {
                radix = prefixRadix
                s.removeFirst(2)
            }
        }
        if radix == 0 { radix = 10 }
        guard (2...36).contains(radix), !s.isEmpty, !s.hasPrefix("_"), !s.hasSuffix("_"), !s.contains("__")
        else { return nil }
        guard let magnitude = Int(s.replacingOccurrences(of: "_", with: ""), radix: radix) else { return nil }
        return negative ? -magnitude : magnitude
    }

    /// Python `float(text)`, or nil when the text is not a number.
    static func parseFloat(_ text: String) -> Double? {
        let s = strip(text, chars: nil)
        guard !s.isEmpty, !s.contains("__") else { return nil }
        let lower = s.lowercased()
        if lower.contains("x") || lower.contains("p") { return nil }
        for (name, value) in [("inf", Double.infinity), ("infinity", .infinity), ("nan", .nan)] {
            if lower == name || lower == "+" + name { return value }
            if lower == "-" + name { return -value }
        }
        return Double(s.replacingOccurrences(of: "_", with: ""))
    }

    /// Python's `urllib.parse.quote`: percent-encodes UTF-8 bytes except unreserved characters and `safe`.
    static func urlQuote(_ s: String, safe: String, forQuery: Bool) -> String {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~".utf8)
        let safeBytes = Set(safe.utf8)
        var out = ""
        for byte in s.utf8 {
            if unreserved.contains(byte) || safeBytes.contains(byte) {
                out.unicodeScalars.append(Unicode.Scalar(byte))
            } else if forQuery && byte == 0x20 {
                out += "+"
            } else {
                out += "%" + String(byte, radix: 16, uppercase: true).leftPadded(to: 2)
            }
        }
        return out
    }

    /// HTML-escapes like markupsafe: `& < > " '`.
    static func htmlEscape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for character in s.unicodeScalars {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&#34;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(character)
            }
        }
        return out
    }

    private static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{A0}",
        "copy": "\u{A9}", "reg": "\u{AE}", "trade": "\u{2122}", "hellip": "\u{2026}",
        "mdash": "\u{2014}", "ndash": "\u{2013}", "lsquo": "\u{2018}", "rsquo": "\u{2019}",
        "ldquo": "\u{201C}", "rdquo": "\u{201D}", "euro": "\u{20AC}", "pound": "\u{A3}",
        "yen": "\u{A5}", "cent": "\u{A2}", "sect": "\u{A7}", "deg": "\u{B0}", "middot": "\u{B7}",
        "laquo": "\u{AB}", "raquo": "\u{BB}", "times": "\u{D7}", "divide": "\u{F7}",
    ]

    /// Decodes HTML character references (numeric and common named ones).
    static func htmlUnescape(_ s: String) -> String {
        let scalars = Py.scalars(s)
        var out: [Unicode.Scalar] = []
        var index = 0
        while index < scalars.count {
            guard scalars[index] == "&", let end = scalars[index...].prefix(34).firstIndex(of: ";") else {
                out.append(scalars[index])
                index += 1
                continue
            }
            let body = Py.string(scalars[(index + 1)..<end])
            var decoded: String?
            if body.hasPrefix("#x") || body.hasPrefix("#X") {
                decoded = UInt32(body.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map(String.init)
            } else if body.hasPrefix("#") {
                decoded = UInt32(body.dropFirst(1)).flatMap(Unicode.Scalar.init).map(String.init)
            } else {
                decoded = namedEntities[body]
            }
            if let decoded {
                out.append(contentsOf: decoded.unicodeScalars)
                index = end + 1
            } else {
                out.append(scalars[index])
                index += 1
            }
        }
        return Py.string(out)
    }
}

extension String {
    func leftPadded(to width: Int, with pad: Character = "0") -> String {
        count >= width ? self : String(repeating: pad, count: width - count) + self
    }
}
