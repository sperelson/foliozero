import AppKit
import Foundation
import Logging
import PDFKit

/// Word processing, spreadsheet, presentation and drawing files.
///
/// Text: native extraction for OOXML and ODF; AppKit document readers for
/// DOC and RTF. Legacy XLS and PPT have no native text; with LibreOffice the
/// text comes from the converted PDF.
///
/// Archive (always attempted, like Paperless-ngx's Tika/Gotenberg path):
/// LibreOffice when installed; otherwise word-processing files (doc, docx,
/// odt, rtf) are laid out on A4 pages with the AppKit text system; other
/// formats get no archive. Thumbnail: archive page 1, else Quick Look, else a placeholder.
public struct OfficeParser: DocumentParser {
    public let name = "office"
    public let supportedMIMETypes: [String: String] = [
        "application/msword": ".doc",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": ".docx",
        "application/vnd.ms-word.document.macroEnabled.12": ".docm",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.template": ".dotx",
        "application/vnd.ms-excel": ".xls",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": ".xlsx",
        "application/vnd.ms-excel.sheet.macroEnabled.12": ".xlsm",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.template": ".xltx",
        "application/vnd.ms-powerpoint": ".ppt",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": ".pptx",
        "application/vnd.openxmlformats-officedocument.presentationml.slideshow": ".ppsx",
        "application/vnd.openxmlformats-officedocument.presentationml.template": ".potx",
        "application/vnd.ms-powerpoint.presentation.macroEnabled.12": ".pptm",
        "application/vnd.oasis.opendocument.text": ".odt",
        "application/vnd.oasis.opendocument.spreadsheet": ".ods",
        "application/vnd.oasis.opendocument.presentation": ".odp",
        "application/vnd.oasis.opendocument.graphics": ".odg",
        "text/rtf": ".rtf",
        "application/rtf": ".rtf",
    ]

    public var libreOfficeTimeout: Duration = .seconds(180)
    /// Set false to skip LibreOffice even when it is installed.
    public var usesLibreOffice = true

    static let logger = Logger(label: "foliozero.parsing.office")

    public init() {}

    public func parse(file: URL, mimeType: String, options: ParseOptions) async throws -> ParseResult {
        let fm = FileManager.default
        try fm.createDirectory(at: options.scratchDirectory, withIntermediateDirectories: true)
        guard fm.isReadableFile(atPath: file.path) else { throw ParserError.unreadable(file, "file is not readable") }
        guard let format = OfficeFormat(mimeType: mimeType) else { throw ParserError.unsupportedType(mimeType) }

        var text = OfficeText.extract(from: file, mimeType: mimeType) ?? ""
        var metadata = OfficeText.metadata(from: file)
        let archive = options.scratchDirectory.appendingPathComponent("archive.pdf")
        var archiveFile: URL?

        if usesLibreOffice, let soffice = ToolLocator.find("soffice", explicitPath: options.libreOfficePath) {
            do {
                let pdf = try await LibreOffice.convertToPDF(file, soffice: soffice, workDirectory: options.scratchDirectory, timeout: libreOfficeTimeout)
                try? fm.removeItem(at: archive)
                try fm.moveItem(at: pdf, to: archive)
                try? fm.removeItem(at: pdf.deletingLastPathComponent())
                archiveFile = archive
            } catch {
                Self.logger.warning("LibreOffice could not convert \(file.lastPathComponent): \(error)")
            }
        }

        // AppKit document readers: text for DOC/RTF, and the archive for word processing without LibreOffice.
        if let documentType = Self.appKitType(for: mimeType), format.content == .wordProcessing,
           text.isEmpty || archiveFile == nil {
            let needsArchive = archiveFile == nil
            let title = Self.title(in: metadata)
            do {
                let rendered = try await MainActor.run { () -> AppKitDocument in
                    let attributed = try NSAttributedString(url: file, options: [.documentType: documentType], documentAttributes: nil)
                    let pages = needsArchive ? try AttributedTextPDF.write(attributed, to: archive, title: title) : nil
                    return AppKitDocument(text: attributed.string, pages: pages)
                }
                if text.isEmpty { text = TextNormalizer.postProcess(rendered.text) }
                if rendered.pages != nil { archiveFile = archive }
            } catch {
                Self.logger.warning("AppKit could not read \(file.lastPathComponent): \(error)")
            }
        }

        if let archiveFile {
            await PDFAConverter.applyIfRequested(to: archiveFile, options: options)
        }
        let archived = archiveFile.flatMap { PDFDocument(url: $0) }
        if text.isEmpty, let archived {
            text = TextNormalizer.postProcess(archived.string ?? "")
        }
        if format.family == .rtf || format.family == .legacyBinary, metadata.isEmpty {
            metadata = await Self.appKitMetadata(file, mimeType: mimeType)
        }

        let image: CGImage?
        if let page = archived?.page(at: 0) {
            image = ThumbnailRenderer.image(fromPDFPage: page, maxPixels: options.thumbnailMaxPixels)
        } else {
            image = await ThumbnailRenderer.quickLookImage(for: file, maxPixels: options.thumbnailMaxPixels, timeout: .seconds(20))
                .flatMap { ImageUtilities.renderUpright($0, orientation: .up, maxPixels: options.thumbnailMaxPixels) }
        }
        let label = (supportedMIMETypes[mimeType] ?? ".doc").dropFirst().uppercased()
        let thumbnail = try ThumbnailRenderer.write(
            image ?? ThumbnailRenderer.placeholder(label: String(label), maxPixels: options.thumbnailMaxPixels),
            to: options.scratchDirectory
        )

        return ParseResult(
            text: text,
            archiveFile: archiveFile,
            thumbnailFile: thumbnail,
            pageCount: archived?.pageCount,
            metadata: metadata,
            metadataDate: Self.creationDate(in: metadata),
            suggestedTitle: TitleHeuristics.meaningfulTitle(Self.title(in: metadata)),
            language: LanguageDetector.detect(text)
        )
    }

    struct AppKitDocument: Sendable {
        var text: String
        var pages: Int?
    }

    static func appKitType(for mimeType: String) -> NSAttributedString.DocumentType? {
        switch mimeType {
        case "application/msword": .docFormat
        case "text/rtf", "application/rtf": .rtf
        case "application/vnd.oasis.opendocument.text": .openDocument
        default: mimeType.contains("wordprocessingml") || mimeType.hasPrefix("application/vnd.ms-word.") ? .officeOpenXML : nil
        }
    }

    static func title(in metadata: [MetadataEntry]) -> String? {
        metadata.first { $0.key == "title" }?.value
    }

    /// dcterms:created (OOXML), meta:creation-date (ODF) or the AppKit creation time.
    static func creationDate(in metadata: [MetadataEntry]) -> Date? {
        for key in ["created", "creation-date", "creationTime"] {
            if let value = metadata.first(where: { $0.key == key })?.value, let date = FlexibleDate.parse(value) {
                return date
            }
        }
        return nil
    }

    /// Title, author and dates from AppKit's document attributes (RTF and DOC).
    static func appKitMetadata(_ file: URL, mimeType: String) async -> [MetadataEntry] {
        guard let type = appKitType(for: mimeType) else { return [] }
        return await MainActor.run { () -> [MetadataEntry] in
            var attributes: NSDictionary?
            guard (try? NSAttributedString(url: file, options: [.documentType: type], documentAttributes: &attributes)) != nil,
                  let attributes = attributes as? [NSAttributedString.DocumentAttributeKey: Any] else { return [] }
            var entries: [MetadataEntry] = []
            let dc = MetadataNamespace.dublinCore
            if let title = attributes[.title] as? String, !title.isEmpty { entries.append(MetadataEntry(dc, "title", title)) }
            if let author = attributes[.author] as? String, !author.isEmpty { entries.append(MetadataEntry(dc, "creator", author)) }
            if let subject = attributes[.subject] as? String, !subject.isEmpty { entries.append(MetadataEntry(dc, "subject", subject)) }
            if let created = attributes[.creationTime] as? Date {
                entries.append(MetadataEntry(MetadataNamespace.folio, "creationTime", iso8601(created)))
            }
            if let modified = attributes[.modificationTime] as? Date {
                entries.append(MetadataEntry(MetadataNamespace.folio, "modificationTime", iso8601(modified)))
            }
            return entries
        }
    }
}
