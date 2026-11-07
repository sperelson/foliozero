import Foundation

/// Implements the Paperless-ngx matching algorithms (`documents/matching.py`).
///
/// `auto` always returns false here; the classifier handles it.
public struct Matcher: Sendable {
    /// Maximum time a user regex may run. A runaway regex is abandoned (returns false).
    public var regexTimeout: TimeInterval

    public init(regexTimeout: TimeInterval = 1.0) {
        self.regexTimeout = regexTimeout
    }

    /// The reason a match succeeded, for logs. nil when there is no match.
    public func matchReason(algorithm: MatchingAlgorithm, match: String, isInsensitive: Bool, content: String) -> String? {
        guard !match.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let options: NSRegularExpression.Options = isInsensitive ? [.caseInsensitive] : []

        switch algorithm {
        case .none, .auto:
            return nil

        case .all:
            for word in Self.splitMatch(match) {
                guard Self.search(pattern: "\\b\(word)\\b", in: content, options: options) != nil else { return nil }
            }
            return "it contains all of these words: \(match)"

        case .any:
            for word in Self.splitMatch(match) {
                if Self.search(pattern: "\\b\(word)\\b", in: content, options: options) != nil {
                    return "it contains this word: \(word)"
                }
            }
            return nil

        case .literal:
            let pattern = "\\b\(NSRegularExpression.escapedPattern(for: match))\\b"
            return Self.search(pattern: pattern, in: content, options: options) != nil
                ? "it contains this string: \"\(match)\""
                : nil

        case .regex:
            guard let found = safeRegexSearch(pattern: match, in: content, options: options) else { return nil }
            return "the string \(found) matches the regular expression \(match)"

        case .fuzzy:
            var needle = Self.stripPunctuation(match)
            var haystack = Self.stripPunctuation(content)
            if isInsensitive {
                needle = needle.lowercased()
                haystack = haystack.lowercased()
            }
            return Fuzzy.partialRatio(needle, haystack, scoreCutoff: 90) != nil
                ? "parts of the document content somehow match the string \(match)"
                : nil
        }
    }

    public func matches(algorithm: MatchingAlgorithm, match: String, isInsensitive: Bool, content: String) -> Bool {
        matchReason(algorithm: algorithm, match: match, isInsensitive: isInsensitive, content: content) != nil
    }

    public func matches<M: MatchingObject>(_ object: M, content: String) -> Bool {
        matches(algorithm: object.matchingAlgorithm, match: object.match, isInsensitive: object.isInsensitive, content: content)
    }

    /// Splits a match string into escaped regex words; quoted phrases stay together
    /// and their inner whitespace becomes `\s+`.
    ///
    /// `  some random  words "with   quotes  " and   spaces` gives
    /// `some`, `random`, `words`, `with\s+quotes`, `and`, `spaces`.
    static func splitMatch(_ match: String) -> [String] {
        var terms: [String] = []
        var index = match.startIndex
        while index < match.endIndex {
            let char = match[index]
            if char.isWhitespace {
                index = match.index(after: index)
                continue
            }
            if char == "\"", let close = match[match.index(after: index)...].firstIndex(of: "\""),
               close > match.index(after: index) {
                terms.append(String(match[match.index(after: index)..<close]))
                index = match.index(after: close)
                continue
            }
            let end = match[index...].firstIndex(where: \.isWhitespace) ?? match.endIndex
            terms.append(String(match[index..<end]))
            index = end
        }
        return terms.map { term in
            let normalized = term
                .split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
            return NSRegularExpression.escapedPattern(for: normalized)
                .replacingOccurrences(of: " ", with: "\\s+")
        }.filter { !$0.isEmpty }
    }

    /// `re.sub(r"[^\w\s]", "", text)`.
    static func stripPunctuation(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            scalar == "_" || CharacterSet.alphanumerics.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar)
        }))
    }

    static func search(pattern: String, in text: String, options: NSRegularExpression.Options) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let found = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(found.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    /// Runs a user-supplied regex with a time limit. On timeout the search is
    /// abandoned on its background thread and nil is returned.
    func safeRegexSearch(pattern: String, in text: String, options: NSRegularExpression.Options) -> String? {
        guard (try? NSRegularExpression(pattern: pattern, options: options)) != nil else { return nil }
        let box = ResultBox()
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        // A dedicated thread, not a shared queue: under load a queued block may not start
        // before the timeout, which would make valid patterns fail at random.
        let thread = Thread {
            started.signal()
            box.set(Self.search(pattern: pattern, in: text, options: options))
            finished.signal()
        }
        thread.stackSize = 4 << 20
        thread.start()
        started.wait()
        guard finished.wait(timeout: .now() + regexTimeout) == .success else { return nil }
        return box.get()
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: String?
        func set(_ newValue: String?) { lock.withLock { value = newValue } }
        func get() -> String? { lock.withLock { value } }
    }
}

/// RapidFuzz-compatible fuzzy ratios.
enum Fuzzy {
    /// `fuzz.ratio`: normalised InDel similarity in 0...100.
    static func ratio(_ a: [UInt32], _ b: [UInt32]) -> Double {
        let total = a.count + b.count
        guard total > 0 else { return 100 }
        return 200.0 * Double(lcsLength(a, b)) / Double(total)
    }

    /// `fuzz.partial_ratio(s1, s2, score_cutoff:)`: best `ratio` of the shorter
    /// string against any same-length window of the longer one (windows that
    /// run off either end are shortened, as in RapidFuzz). Returns nil below the cutoff.
    static func partialRatio(_ s1: String, _ s2: String, scoreCutoff: Double = 0) -> Double? {
        var shorter = s1.unicodeScalars.map(\.value)
        var longer = s2.unicodeScalars.map(\.value)
        if shorter.count > longer.count { swap(&shorter, &longer) }
        let m = shorter.count
        guard m > 0 else { return longer.isEmpty ? 100 : (scoreCutoff > 0 ? nil : 0) }

        let needleSet = Set(shorter)
        var best = 0.0

        // Only windows that start or end with a needle character are scored.
        // RapidFuzz prunes the same way (it checks the window's last character).
        func consider(_ window: ArraySlice<UInt32>) -> Bool {
            let score = ratio(shorter, Array(window))
            if score > best { best = score }
            return best >= 100
        }

        // Prefix windows shorter than m.
        if m > 1 {
            for length in stride(from: 1, to: min(m, longer.count + 1), by: 1) where needleSet.contains(longer[length - 1]) {
                if consider(longer[0..<length]) { return 100 }
            }
        }
        // Full-length windows.
        if longer.count >= m {
            for start in 0...(longer.count - m) {
                guard needleSet.contains(longer[start]) || needleSet.contains(longer[start + m - 1]) else { continue }
                if consider(longer[start..<(start + m)]) { return 100 }
            }
        }
        // Suffix windows shorter than m.
        if m > 1 && longer.count > 1 {
            let firstStart = max(longer.count - m + 1, 1)
            for start in firstStart..<longer.count where needleSet.contains(longer[start]) {
                if consider(longer[start...]) { return 100 }
            }
        }
        return best >= scoreCutoff ? best : nil
    }

    /// Length of the longest common subsequence. Bit-parallel (Hyyrö) when the
    /// first string has at most 64 scalars; dynamic programming otherwise.
    static func lcsLength(_ a: [UInt32], _ b: [UInt32]) -> Int {
        if a.isEmpty || b.isEmpty { return 0 }
        if a.count <= 64 {
            var masks: [UInt32: UInt64] = [:]
            for (i, ch) in a.enumerated() { masks[ch, default: 0] |= (1 << UInt64(i)) }
            var v: UInt64 = ~0
            for ch in b {
                let match = masks[ch] ?? 0
                let u = v & match
                v = (v &+ u) | (v & ~match)
            }
            let used: UInt64 = a.count == 64 ? ~0 : ((1 << UInt64(a.count)) - 1)
            return (~v & used).nonzeroBitCount
        }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for i in 1...a.count {
            for j in 1...b.count {
                current[j] = a[i - 1] == b[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
