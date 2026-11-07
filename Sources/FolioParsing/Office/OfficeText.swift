import Foundation
import ZIPFoundation

/// Native text and metadata extraction for Office Open XML (docx, xlsx, pptx and
/// their macro and template variants) and OpenDocument (odt, ods, odp, odg).
public enum OfficeText {
    /// Text of an OOXML or ODF package, or nil when the file is not one (or is unreadable).
    public static func extract(from file: URL, mimeType: String) -> String? {
        guard let archive = try? Archive(url: file, accessMode: .read, pathEncoding: nil) else { return nil }
        let kind = OfficeFormat(mimeType: mimeType)
        switch kind?.family {
        case .ooxml:
            switch kind?.content {
            case .wordProcessing: return wordprocessing(archive)
            case .spreadsheet: return spreadsheet(archive)
            case .presentation: return presentation(archive)
            default: return nil
            }
        case .odf:
            guard let content = ZipReader.data(at: "content.xml", in: archive) else { return nil }
            return TextNormalizer.postProcess(ODFTextExtractor.text(from: content))
        default:
            return nil
        }
    }

    // MARK: OOXML

    static func wordprocessing(_ archive: Archive) -> String {
        var parts: [String] = []
        let main = mainDocumentPath(archive) ?? "word/document.xml"
        if let data = ZipReader.data(at: main, in: archive) {
            parts.append(OOXMLTextExtractor.text(from: data, paragraph: "p"))
        }
        // Headers, footers, footnotes and endnotes after the body.
        let extras = archive.map(\.path)
            .filter { $0.hasPrefix("word/") && ($0.contains("/header") || $0.contains("/footer") || $0.hasSuffix("footnotes.xml") || $0.hasSuffix("endnotes.xml")) }
            .sorted(by: naturalOrder)
        for path in extras {
            if let data = ZipReader.data(at: path, in: archive) {
                parts.append(OOXMLTextExtractor.text(from: data, paragraph: "p"))
            }
        }
        return TextNormalizer.postProcess(parts.joined(separator: "\n"))
    }

    static func presentation(_ archive: Archive) -> String {
        let slides = archive.map(\.path)
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted(by: naturalOrder)
        let texts = slides.compactMap { path in
            ZipReader.data(at: path, in: archive).map { OOXMLTextExtractor.text(from: $0, paragraph: "p") }
        }
        return TextNormalizer.postProcess(texts.joined(separator: "\n\n"))
    }

    static func spreadsheet(_ archive: Archive) -> String {
        let shared = ZipReader.data(at: "xl/sharedStrings.xml", in: archive).map(SharedStringsReader.strings) ?? []
        var sheets: [(name: String, path: String)] = []
        if let workbook = ZipReader.data(at: "xl/workbook.xml", in: archive) {
            let relations = ZipReader.data(at: "xl/_rels/workbook.xml.rels", in: archive).map(RelationshipsReader.targets) ?? [:]
            for sheet in WorkbookReader.sheets(workbook) {
                guard let target = relations[sheet.relationship] else { continue }
                let path = target.hasPrefix("/") ? String(target.dropFirst()) : "xl/" + target
                sheets.append((sheet.name, path))
            }
        }
        if sheets.isEmpty {
            sheets = archive.map(\.path)
                .filter { $0.hasPrefix("xl/worksheets/sheet") && $0.hasSuffix(".xml") }
                .sorted(by: naturalOrder)
                .map { (($0 as NSString).deletingPathExtension as NSString).lastPathComponent }
                .map { ($0, "xl/worksheets/\($0).xml") }
        }
        var output: [String] = []
        for sheet in sheets {
            guard let data = ZipReader.data(at: sheet.path, in: archive) else { continue }
            let rows = WorksheetReader.rows(data, sharedStrings: shared)
            guard !rows.isEmpty else { continue }
            output.append(sheet.name)
            output.append(contentsOf: rows)
            output.append("")
        }
        return TextNormalizer.postProcess(output.joined(separator: "\n"))
    }

    /// Target of the officeDocument relationship in `_rels/.rels`.
    static func mainDocumentPath(_ archive: Archive) -> String? {
        guard let data = ZipReader.data(at: "_rels/.rels", in: archive) else { return nil }
        let targets = RelationshipsReader.typedTargets(data)
        guard let target = targets.first(where: { $0.type.hasSuffix("/officeDocument") })?.target else { return nil }
        return target.hasPrefix("/") ? String(target.dropFirst()) : target
    }

    /// "slide2.xml" before "slide10.xml".
    static func naturalOrder(_ a: String, _ b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedAscending
    }

    // MARK: Metadata

    /// Document properties: `docProps/core.xml` (OOXML) or `meta.xml` (ODF).
    public static func metadata(from file: URL) -> [MetadataEntry] {
        guard let archive = try? Archive(url: file, accessMode: .read, pathEncoding: nil) else { return [] }
        if let core = ZipReader.data(at: "docProps/core.xml", in: archive) {
            return PropertyLeafReader.entries(core)
        }
        if let meta = ZipReader.data(at: "meta.xml", in: archive) {
            return PropertyLeafReader.entries(meta)
        }
        return []
    }
}

/// What kind of Office file a MIME type is.
struct OfficeFormat {
    enum Family { case ooxml, odf, legacyBinary, rtf }
    enum Content { case wordProcessing, spreadsheet, presentation, drawing }

    var family: Family
    var content: Content

    init?(mimeType: String) {
        let mime = mimeType.lowercased()
        switch mime {
        case "application/msword": (family, content) = (.legacyBinary, .wordProcessing)
        case "application/vnd.ms-excel": (family, content) = (.legacyBinary, .spreadsheet)
        case "application/vnd.ms-powerpoint": (family, content) = (.legacyBinary, .presentation)
        case "text/rtf", "application/rtf": (family, content) = (.rtf, .wordProcessing)
        case "application/vnd.oasis.opendocument.text": (family, content) = (.odf, .wordProcessing)
        case "application/vnd.oasis.opendocument.spreadsheet": (family, content) = (.odf, .spreadsheet)
        case "application/vnd.oasis.opendocument.presentation": (family, content) = (.odf, .presentation)
        case "application/vnd.oasis.opendocument.graphics": (family, content) = (.odf, .drawing)
        default:
            if mime.contains("wordprocessingml") || mime.hasPrefix("application/vnd.ms-word.") {
                (family, content) = (.ooxml, .wordProcessing)
            } else if mime.contains("spreadsheetml") || mime.hasPrefix("application/vnd.ms-excel.") {
                (family, content) = (.ooxml, .spreadsheet)
            } else if mime.contains("presentationml") || mime.hasPrefix("application/vnd.ms-powerpoint.") {
                (family, content) = (.ooxml, .presentation)
            } else {
                return nil
            }
        }
    }
}

// MARK: - XML readers

/// Text of `<w:t>` / `<a:t>` runs; paragraphs end with a newline; tabs and breaks kept.
final class OOXMLTextExtractor: NSObject, XMLParserDelegate {
    private let paragraph: String
    private var output = ""
    private var inText = 0

    private init(paragraph: String) {
        self.paragraph = paragraph
    }

    static func text(from data: Data, paragraph: String) -> String {
        let delegate = OOXMLTextExtractor(paragraph: paragraph)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.output
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "t": inText += 1
        case "tab": output += "\t"
        case "br", "cr": output += "\n"
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "t" { inText = max(0, inText - 1) }
        if elementName == paragraph { output += "\n" }
        // Table cells: the cell's last paragraph break becomes a tab; rows end with a newline.
        if elementName == "tc" {
            if output.hasSuffix("\n") { output.removeLast() }
            output += "\t"
        }
        if elementName == "tr" {
            while output.hasSuffix("\t") { output.removeLast() }
            output += "\n"
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText > 0 { output += string }
    }
}

/// `xl/sharedStrings.xml`: one string per `<si>`, phonetic runs skipped.
final class SharedStringsReader: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inItem = false
    private var inText = false
    private var inPhonetic = false

    static func strings(_ data: Data) -> [String] {
        let delegate = SharedStringsReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.strings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "si": inItem = true; current = ""
        case "t": inText = true
        case "rPh": inPhonetic = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "si": strings.append(current); inItem = false
        case "t": inText = false
        case "rPh": inPhonetic = false
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inItem, inText, !inPhonetic { current += string }
    }
}

/// `xl/workbook.xml` sheets in workbook order.
final class WorkbookReader: NSObject, XMLParserDelegate {
    private var sheets: [(name: String, relationship: String)] = []

    static func sheets(_ data: Data) -> [(name: String, relationship: String)] {
        let delegate = WorkbookReader()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.parse()
        return delegate.sheets
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "sheet" || elementName.hasSuffix(":sheet") else { return }
        let relationship = attributeDict.first { $0.key == "r:id" || $0.key.hasSuffix(":id") }?.value ?? ""
        sheets.append((attributeDict["name"] ?? "Sheet", relationship))
    }
}

/// Relationship part (`*.rels`): Id to Target, and Type/Target pairs.
final class RelationshipsReader: NSObject, XMLParserDelegate {
    private var items: [(id: String, type: String, target: String)] = []

    private static func parse(_ data: Data) -> [(id: String, type: String, target: String)] {
        let delegate = RelationshipsReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    static func targets(_ data: Data) -> [String: String] {
        Dictionary(parse(data).map { ($0.id, $0.target) }, uniquingKeysWith: { first, _ in first })
    }

    static func typedTargets(_ data: Data) -> [(type: String, target: String)] {
        parse(data).map { ($0.type, $0.target) }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard elementName == "Relationship" else { return }
        items.append((attributeDict["Id"] ?? "", attributeDict["Type"] ?? "", attributeDict["Target"] ?? ""))
    }
}

/// Worksheet rows as tab-separated cell values.
final class WorksheetReader: NSObject, XMLParserDelegate {
    private let shared: [String]
    private var rows: [String] = []
    private var cells: [String] = []
    private var cellType = ""
    private var value = ""
    private var inValue = false
    private var inInline = false

    private init(shared: [String]) {
        self.shared = shared
    }

    static func rows(_ data: Data, sharedStrings: [String]) -> [String] {
        let delegate = WorksheetReader(shared: sharedStrings)
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.rows
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "row": cells = []
        case "c": cellType = attributeDict["t"] ?? ""; value = ""
        case "v": inValue = true
        case "is": inInline = true
        case "t" where inInline: inValue = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "v", "t": inValue = false
        case "is": inInline = false
        case "c":
            var text = value
            switch cellType {
            case "s": text = Int(value.trimmingCharacters(in: .whitespaces)).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
            case "b": text = value == "1" ? "TRUE" : "FALSE"
            default: break
            }
            cells.append(text)
        case "row":
            while cells.last?.isEmpty == true { cells.removeLast() }
            if !cells.isEmpty { rows.append(cells.joined(separator: "\t")) }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue { value += string }
    }
}

/// OpenDocument `content.xml`: paragraphs and headings, tables as tab-separated rows.
final class ODFTextExtractor: NSObject, XMLParserDelegate {
    private static let textNS = "urn:oasis:names:tc:opendocument:xmlns:text:1.0"
    private static let tableNS = "urn:oasis:names:tc:opendocument:xmlns:table:1.0"
    private var output = ""
    private var paragraphDepth = 0
    private var skipDepth = 0

    static func text(from data: Data) -> String {
        let delegate = ODFTextExtractor()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.delegate = delegate
        parser.parse()
        return delegate.output
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if namespaceURI == Self.textNS {
            switch elementName {
            case "p", "h": paragraphDepth += 1
            case "s":
                let count = Int(attributeDict.first { $0.key.hasSuffix("c") }?.value ?? "1") ?? 1
                if paragraphDepth > 0, skipDepth == 0 { output += String(repeating: " ", count: min(count, 100)) }
            case "tab": if paragraphDepth > 0, skipDepth == 0 { output += "\t" }
            case "line-break": if paragraphDepth > 0, skipDepth == 0 { output += "\n" }
            case "tracked-changes", "note-citation": skipDepth += 1
            default: break
            }
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if namespaceURI == Self.textNS {
            switch elementName {
            case "p", "h":
                paragraphDepth = max(0, paragraphDepth - 1)
                if paragraphDepth == 0, skipDepth == 0 { output += "\n" }
            case "tracked-changes", "note-citation": skipDepth = max(0, skipDepth - 1)
            default: break
            }
        } else if namespaceURI == Self.tableNS {
            if elementName == "table-cell" || elementName == "covered-table-cell" {
                if output.hasSuffix("\n") { output.removeLast() }
                output += "\t"
            } else if elementName == "table-row" {
                while output.hasSuffix("\t") { output.removeLast() }
                if !output.hasSuffix("\n") { output += "\n" }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if paragraphDepth > 0, skipDepth == 0 { output += string }
    }
}

/// Leaf elements with text (document properties), as metadata entries.
final class PropertyLeafReader: NSObject, XMLParserDelegate {
    private var entries: [MetadataEntry] = []
    private var prefixes: [String: String] = [
        "http://purl.org/dc/elements/1.1/": "dc",
        "http://purl.org/dc/terms/": "dcterms",
        "http://schemas.openxmlformats.org/package/2006/metadata/core-properties": "cp",
        "urn:oasis:names:tc:opendocument:xmlns:meta:1.0": "meta",
    ]
    private var text = ""
    private var depth = 0
    private var hadChild: [Bool] = []

    static func entries(_ data: Data) -> [MetadataEntry] {
        let delegate = PropertyLeafReader()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = true
        parser.delegate = delegate
        parser.parse()
        return delegate.entries
    }

    func parser(_ parser: XMLParser, didStartMappingPrefix prefix: String, toURI namespaceURI: String) {
        if prefixes[namespaceURI] == nil { prefixes[namespaceURI] = prefix }
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if !hadChild.isEmpty { hadChild[hadChild.count - 1] = true }
        hadChild.append(false)
        text = ""
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let isLeaf = !(hadChild.popLast() ?? true)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        guard isLeaf, !value.isEmpty, hadChild.count >= 1 else { return }
        let uri = namespaceURI ?? ""
        entries.append(MetadataEntry(namespace: uri, prefix: prefixes[uri] ?? "", key: elementName, value: value))
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }
}
