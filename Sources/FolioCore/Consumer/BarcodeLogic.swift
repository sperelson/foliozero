import Foundation

/// A barcode found in a file, as the consumer sees it.
public struct FoundBarcode: Sendable, Hashable {
    /// 0-based page index.
    public var page: Int
    public var value: String
    public var format: String

    public init(page: Int, value: String, format: String) {
        self.page = page
        self.value = value
        self.format = format
    }
}

/// Barcode decisions from Paperless-ngx `documents/barcodes.py`: separator pages,
/// how to split, the ASN, and tag barcodes.
public struct BarcodeLogic: Sendable {
    public var separatorString: String
    public var retainSplitPages: Bool
    public var enableSplitting: Bool
    public var enableASN: Bool
    public var asnPrefix: String
    public var enableTags: Bool
    public var tagSplit: Bool
    /// Regex pattern to replacement (Python `\g<1>` group syntax accepted).
    public var tagMapping: [String: String]

    public init(settings: Settings) {
        separatorString = settings.consumerBarcodeString
        retainSplitPages = settings.consumerBarcodeRetainSplitPages
        enableSplitting = settings.consumerEnableBarcodes
        enableASN = settings.consumerEnableASNBarcode
        asnPrefix = settings.consumerASNBarcodePrefix
        enableTags = settings.consumerEnableTagBarcode
        tagSplit = settings.consumerTagBarcodeSplit
        tagMapping = settings.consumerTagBarcodeMapping
    }

    public init(separatorString: String = "PATCHT", retainSplitPages: Bool = false, enableSplitting: Bool = true, enableASN: Bool = false,
                asnPrefix: String = "ASN", enableTags: Bool = false, tagSplit: Bool = false, tagMapping: [String: String] = ["TAG:(.*)": "\\g<1>"]) {
        self.separatorString = separatorString; self.retainSplitPages = retainSplitPages; self.enableSplitting = enableSplitting
        self.enableASN = enableASN; self.asnPrefix = asnPrefix; self.enableTags = enableTags; self.tagSplit = tagSplit; self.tagMapping = tagMapping
    }

    /// True when any barcode feature needs the file scanned.
    public static func isNeeded(_ settings: Settings) -> Bool {
        settings.consumerEnableBarcodes || settings.consumerEnableASNBarcode || settings.consumerEnableTagBarcode || settings.consumerStoreBarcodeValues
    }

    public func isSeparator(_ code: FoundBarcode) -> Bool { code.value == separatorString }
    public func isASN(_ code: FoundBarcode) -> Bool { code.value.hasPrefix(asnPrefix) }
    public func isTag(_ code: FoundBarcode) -> Bool { tagMapping.keys.contains { Self.matches($0, code.value) } }

    /// Page index to "keep this page" for every page that starts a new document.
    public func separationPages(_ codes: [FoundBarcode]) -> [Int: Bool] {
        var pages: [Int: Bool] = [:]
        if enableSplitting {
            for code in codes where isSeparator(code) && (!retainSplitPages || code.page > 0) {
                pages[code.page] = retainSplitPages
            }
        }
        // ASN and tag barcodes split before their page, never on the first page.
        if enableASN {
            for code in codes where isASN(code) && code.page != 0 { pages[code.page] = true }
        }
        if enableTags && tagSplit {
            for code in codes where isTag(code) && code.page != 0 { pages[code.page] = true }
        }
        return pages
    }

    /// Page lists of the resulting documents; empty documents are dropped.
    public static func splitPlan(pageCount: Int, separationPages: [Int: Bool]) -> [[Int]] {
        var documents: [[Int]] = [[]]
        for index in 0..<pageCount {
            if let keep = separationPages[index] {
                documents.append(keep ? [index] : [])
            } else {
                documents[documents.count - 1].append(index)
            }
        }
        return documents.filter { !$0.isEmpty }
    }

    /// The first ASN barcode's number: prefix removed, non-digits dropped.
    public func asn(_ codes: [FoundBarcode]) -> Int? {
        guard enableASN, let code = codes.first(where: isASN) else { return nil }
        let digits = code.value.dropFirst(asnPrefix.count).filter(\.isNumber)
        return Int(digits)
    }

    /// Tag names from tag barcodes. A barcode value may hold several comma-separated tags.
    public func tagNames(_ codes: [FoundBarcode]) -> [String] {
        guard enableTags else { return [] }
        var names: [String] = []
        for code in codes {
            for raw in code.value.split(separator: ",").map(String.init) {
                for (pattern, replacement) in tagMapping.sorted(by: { $0.key < $1.key }) where Self.matches(pattern, raw) {
                    let name = replacement.isEmpty ? raw : Self.substitute(pattern, replacement, raw)
                    if !name.isEmpty, !names.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { names.append(name) }
                    break
                }
            }
        }
        return names
    }

    /// Python `re.match` semantics: anchored at the start, case-insensitive.
    static func matches(_ pattern: String, _ value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return false }
        return regex.firstMatch(in: value, options: [.anchored], range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// Python `re.sub` with `\g<n>` / `\n` group references.
    static func substitute(_ pattern: String, _ replacement: String, _ value: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return value }
        var template = NSRegularExpression.escapedTemplate(for: replacement)
        if let groups = try? NSRegularExpression(pattern: "\\\\\\\\g<(\\d+)>|\\\\\\\\(\\d+)") {
            template = groups.stringByReplacingMatches(in: template, range: NSRange(template.startIndex..., in: template), withTemplate: "\\$$1$2")
        }
        return regex.stringByReplacingMatches(in: value, range: NSRange(value.startIndex..., in: value), withTemplate: template)
    }
}
