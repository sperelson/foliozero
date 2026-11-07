import Foundation
import ImageIO
import PDFKit

/// XMP namespaces used for `MetadataEntry`, as Paperless-ngx reports them.
public enum MetadataNamespace {
    public static let dublinCore = (uri: "http://purl.org/dc/elements/1.1/", prefix: "dc")
    public static let pdf = (uri: "http://ns.adobe.com/pdf/1.3/", prefix: "pdf")
    public static let xmp = (uri: "http://ns.adobe.com/xap/1.0/", prefix: "xmp")
    public static let exif = (uri: "http://ns.adobe.com/exif/1.0/", prefix: "exif")
    public static let tiff = (uri: "http://ns.adobe.com/tiff/1.0/", prefix: "tiff")
    public static let iptc = (uri: "http://iptc.org/std/Iptc4xmpCore/1.0/xmlns/", prefix: "Iptc4xmpCore")
    /// FolioZero facts that have no standard XMP property (page count, encryption, encoding).
    public static let folio = (uri: "urn:foliozero:metadata", prefix: "foliozero")

    static let knownPrefixes: [String: String] = [
        dublinCore.uri: dublinCore.prefix, pdf.uri: pdf.prefix, xmp.uri: xmp.prefix, exif.uri: exif.prefix,
        tiff.uri: tiff.prefix, iptc.uri: iptc.prefix,
        "http://ns.adobe.com/xap/1.0/mm/": "xmpMM",
        "http://ns.adobe.com/xap/1.0/rights/": "xmpRights",
        "http://ns.adobe.com/photoshop/1.0/": "photoshop",
        "http://www.aiim.org/pdfa/ns/id/": "pdfaid",
        "http://ns.adobe.com/pdfx/1.3/": "pdfx",
        "http://ns.adobe.com/exif/1.0/aux/": "aux",
        "http://ns.apple.com/namespace/1.0/": "apple",
    ]
}

extension MetadataEntry {
    init(_ ns: (uri: String, prefix: String), _ key: String, _ value: String) {
        self.init(namespace: ns.uri, prefix: ns.prefix, key: key, value: value)
    }
}

/// Metadata of PDF files.
public enum PDFMetadata {
    /// Entries from the XMP packet, then Info dictionary values that XMP lacks,
    /// then PDF version, page count and encryption state.
    public static func entries(for document: PDFDocument, isEncrypted: Bool, isLocked: Bool) -> [MetadataEntry] {
        var entries: [MetadataEntry] = []
        if !isLocked, let xmp = PDFUtilities.xmpData(of: document) {
            entries = XMPReader.entries(from: xmp)
        }
        func has(_ ns: (uri: String, prefix: String), _ key: String) -> Bool {
            entries.contains { $0.namespace == ns.uri && $0.key == key }
        }
        func add(_ ns: (uri: String, prefix: String), _ key: String, _ value: String?) {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty,
                  !has(ns, key) else { return }
            entries.append(MetadataEntry(ns, key, value))
        }

        if !isLocked {
            let info = document.documentAttributes ?? [:]
            add(MetadataNamespace.dublinCore, "title", info[PDFDocumentAttribute.titleAttribute] as? String)
            add(MetadataNamespace.dublinCore, "creator", info[PDFDocumentAttribute.authorAttribute] as? String)
            add(MetadataNamespace.dublinCore, "description", info[PDFDocumentAttribute.subjectAttribute] as? String)
            add(MetadataNamespace.pdf, "Keywords", keywords(info[PDFDocumentAttribute.keywordsAttribute]))
            add(MetadataNamespace.xmp, "CreatorTool", info[PDFDocumentAttribute.creatorAttribute] as? String)
            add(MetadataNamespace.pdf, "Producer", info[PDFDocumentAttribute.producerAttribute] as? String)
            add(MetadataNamespace.xmp, "CreateDate", (info[PDFDocumentAttribute.creationDateAttribute] as? Date).map(iso8601))
            add(MetadataNamespace.xmp, "ModifyDate", (info[PDFDocumentAttribute.modificationDateAttribute] as? Date).map(iso8601))
        }
        add(MetadataNamespace.pdf, "PDFVersion", "\(document.majorVersion).\(document.minorVersion)")
        if document.pageCount > 0 { add(MetadataNamespace.folio, "pageCount", String(document.pageCount)) }
        entries.append(MetadataEntry(MetadataNamespace.folio, "encrypted", isEncrypted ? "true" : "false"))
        if isLocked { entries.append(MetadataEntry(MetadataNamespace.folio, "locked", "true")) }
        return entries
    }

    /// Info dictionary CreationDate.
    public static func creationDate(of document: PDFDocument) -> Date? {
        document.documentAttributes?[PDFDocumentAttribute.creationDateAttribute] as? Date
    }

    /// Info dictionary Title when it looks like a real title.
    public static func title(of document: PDFDocument) -> String? {
        TitleHeuristics.meaningfulTitle(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
    }

    static func keywords(_ value: Any?) -> String? {
        if let string = value as? String { return string }
        if let array = value as? [String] { return array.joined(separator: ", ") }
        return nil
    }
}

/// Metadata of image files from ImageIO property dictionaries.
public enum ImageMetadata {
    public static func entries(properties: [CFString: Any], frameCount: Int) -> [MetadataEntry] {
        var entries: [MetadataEntry] = []
        let sections: [(CFString, (uri: String, prefix: String), String)] = [
            (kCGImagePropertyTIFFDictionary, MetadataNamespace.tiff, ""),
            (kCGImagePropertyExifDictionary, MetadataNamespace.exif, ""),
            (kCGImagePropertyGPSDictionary, MetadataNamespace.exif, "GPS"),
            (kCGImagePropertyIPTCDictionary, MetadataNamespace.iptc, ""),
        ]
        for (key, ns, prefix) in sections {
            guard let dictionary = properties[key] as? [CFString: Any] else { continue }
            for (name, value) in dictionary.sorted(by: { ($0.key as String) < ($1.key as String) }) {
                let name = name as String
                guard name != "MakerNote", let text = stringValue(value) else { continue }
                let fullKey = prefix.isEmpty || name.hasPrefix(prefix) ? name : prefix + name
                entries.append(MetadataEntry(ns, fullKey, text))
            }
        }
        let topLevel: [(CFString, String)] = [
            (kCGImagePropertyPixelWidth, "pixelWidth"), (kCGImagePropertyPixelHeight, "pixelHeight"),
            (kCGImagePropertyDPIWidth, "dpiWidth"), (kCGImagePropertyDPIHeight, "dpiHeight"),
            (kCGImagePropertyColorModel, "colorModel"), (kCGImagePropertyDepth, "bitDepth"),
            (kCGImagePropertyOrientation, "orientation"), (kCGImagePropertyProfileName, "colorProfile"),
        ]
        for (key, name) in topLevel {
            if let value = properties[key], let text = stringValue(value) {
                entries.append(MetadataEntry(MetadataNamespace.folio, name, text))
            }
        }
        entries.append(MetadataEntry(MetadataNamespace.folio, "pageCount", String(frameCount)))
        return entries
    }

    /// EXIF DateTimeOriginal (then DateTimeDigitized, then TIFF DateTime), using
    /// the matching EXIF offset tag when present and the local time zone otherwise.
    public static func creationDate(properties: [CFString: Any]) -> Date? {
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let candidates: [(String?, String?)] = [
            (exif[kCGImagePropertyExifDateTimeOriginal] as? String, exif[kCGImagePropertyExifOffsetTimeOriginal] as? String),
            (exif[kCGImagePropertyExifDateTimeDigitized] as? String, exif[kCGImagePropertyExifOffsetTimeDigitized] as? String),
            (tiff[kCGImagePropertyTIFFDateTime] as? String, exif[kCGImagePropertyExifOffsetTime] as? String),
        ]
        for (value, offset) in candidates {
            if let value, let date = parseEXIFDate(value, offset: offset) { return date }
        }
        return nil
    }

    /// Parses "yyyy:MM:dd HH:mm:ss" with an optional "+02:00" offset.
    public static func parseEXIFDate(_ value: String, offset: String? = nil) -> Date? {
        let digits = value.trimmingCharacters(in: .whitespaces)
        let parts = digits.split(whereSeparator: { $0 == ":" || $0 == " " || $0 == "-" || $0 == "T" })
        guard parts.count >= 6,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              let hour = Int(parts[3]), let minute = Int(parts[4]), let second = Int(parts[5].prefix(2)),
              year > 1800, (1...12).contains(month), (1...31).contains(day) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = offset.flatMap(timeZone(fromOffset:)) ?? .current
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))
    }

    static func timeZone(fromOffset offset: String) -> TimeZone? {
        let trimmed = offset.trimmingCharacters(in: .whitespaces)
        guard let sign = trimmed.first, sign == "+" || sign == "-" else { return nil }
        let parts = trimmed.dropFirst().split(separator: ":")
        guard let hours = parts.first.flatMap({ Int($0) }) else { return nil }
        let minutes = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let seconds = (hours * 3600 + minutes * 60) * (sign == "-" ? -1 : 1)
        return TimeZone(secondsFromGMT: seconds)
    }

    static func stringValue(_ value: Any) -> String? {
        switch value {
        case let string as String:
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
            return trimmed.isEmpty ? nil : trimmed
        case let number as NSNumber:
            return number.stringValue
        case let array as [Any]:
            let items = array.compactMap(stringValue)
            return items.isEmpty ? nil : items.joined(separator: ", ")
        case let dictionary as [String: Any]:
            let items = dictionary.sorted { $0.key < $1.key }.compactMap { key, value in
                stringValue(value).map { "\(key)=\($0)" }
            }
            return items.isEmpty ? nil : items.joined(separator: ", ")
        default:
            return nil
        }
    }
}

/// Reads simple properties from an XMP packet.
public enum XMPReader {
    public static func entries(from data: Data) -> [MetadataEntry] {
        let delegate = XMPDelegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }
}

private final class XMPDelegate: NSObject, XMLParserDelegate {
    private static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    var entries: [MetadataEntry] = []
    private var prefixes: [String: String] = MetadataNamespace.knownPrefixes
    private var uriForPrefix: [String: String] = [:]
    /// Property elements currently open (namespace, name), outermost first.
    private var stack: [(uri: String, name: String, isRDF: Bool)] = []
    private var text = ""
    private var listItems: [String] = []
    private var inDescription = 0

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        if prefixes[namespaceURI] == nil { prefixes[namespaceURI] = prefix }
        uriForPrefix[prefix] = namespaceURI
    }

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]
    ) {
        let uri = namespaceURI ?? ""
        let isRDF = uri == Self.rdf
        if isRDF, elementName == "Description" {
            inDescription += 1
            // Abbreviated syntax: properties as attributes. Only for top-level
            // descriptions, not for structures nested inside a property.
            let topLevel = stack.allSatisfy { $0.isRDF || $0.uri == "adobe:ns:meta/" }
            for (qualified, value) in attributeDict where topLevel {
                let parts = qualified.split(separator: ":", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let prefix = String(parts[0])
                guard prefix != "rdf", prefix != "xmlns", prefix != "x",
                      let nsURI = uriForPrefix[prefix] else { continue }
                append(uri: nsURI, key: String(parts[1]), value: value)
            }
        }
        stack.append((uri, elementName, isRDF))
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let element = stack.popLast() else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        if element.isRDF {
            if element.name == "li", !value.isEmpty { listItems.append(value) }
            if element.name == "Description" { inDescription -= 1 }
            return
        }
        guard inDescription > 0, element.uri != "adobe:ns:meta/" else { return }
        // A property element directly under rdf:Description.
        let parentIsDescription = stack.last.map { $0.isRDF && $0.name == "Description" } ?? false
        guard parentIsDescription else { return }
        let combined = listItems.isEmpty ? value : listItems.joined(separator: ", ")
        listItems = []
        append(uri: element.uri, key: element.name, value: combined)
    }

    private func append(uri: String, key: String, value: String) {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let prefix = prefixes[uri] ?? ""
        entries.append(MetadataEntry(namespace: uri, prefix: prefix, key: key, value: value))
    }
}

/// Decides whether a title stored in file metadata is worth showing.
public enum TitleHeuristics {
    static let placeholders: Set<String> = [
        "untitled", "untitled document", "document", "unknown", "title", "(anonymous)", "anonymous",
        "microsoft word document", "pdf", "scan", "scanned document", "image", "none", "null",
    ]
    static let fileExtensions: Set<String> = [
        "pdf", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "odt", "ods", "odp", "rtf", "txt",
        "jpg", "jpeg", "png", "tif", "tiff", "html", "htm", "indd", "ai", "psd", "qxd", "tmp",
    ]

    /// The trimmed title, without "Microsoft Word - " style prefixes; nil when it
    /// is empty, a placeholder, a file name or a path, or has fewer than two letters.
    public static func meaningfulTitle(_ raw: String?) -> String? {
        guard var title = raw?.trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters)),
              !title.isEmpty else { return nil }
        for prefix in ["Microsoft Word - ", "Microsoft PowerPoint - ", "Microsoft Excel - "]
            where title.hasPrefix(prefix) {
            title = String(title.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        let lower = title.lowercased()
        if placeholders.contains(lower) { return nil }
        if title.contains("/") && !title.contains(" ") || title.contains("\\") { return nil }
        let ext = (title as NSString).pathExtension.lowercased()
        if fileExtensions.contains(ext) { return nil }
        if title.filter(\.isLetter).count < 2 { return nil }
        return title
    }
}

func iso8601(_ date: Date) -> String {
    date.formatted(.iso8601)
}
