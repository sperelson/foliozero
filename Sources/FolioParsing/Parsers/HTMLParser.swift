import Foundation
import Logging
import PDFKit

/// HTML files and Safari web archives. WebKit renders the page into a
/// paginated A4 archive PDF with selectable text; the text comes from the DOM.
/// When WebKit fails (for example in a LaunchDaemon without a GUI session) the
/// parser falls back to text extracted from the markup, with no archive.
///
/// Like Paperless-ngx's converting parsers, the archive is written whatever
/// `ParseOptions.archiveMode` says, because the original cannot be shown as a page.
public struct HTMLParser: DocumentParser {
    public let name = "html"
    public let supportedMIMETypes: [String: String] = [
        "text/html": ".html",
        "application/xhtml+xml": ".xhtml",
        FileTypeDetector.webArchive: ".webarchive",
    ]

    public var renderOptions: WebRenderer.Options

    static let logger = Logger(label: "foliozero.parsing.html")

    public init(renderOptions: WebRenderer.Options = WebRenderer.Options()) {
        self.renderOptions = renderOptions
    }

    public func parse(file: URL, mimeType: String, options: ParseOptions) async throws -> ParseResult {
        try FileManager.default.createDirectory(at: options.scratchDirectory, withIntermediateDirectories: true)
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw ParserError.unreadable(file, error.localizedDescription)
        }

        let source: WebRenderer.Source
        var fallbackHTML: String?
        if mimeType == FileTypeDetector.webArchive {
            let archive = WebArchive(data: data)
            fallbackHTML = archive?.mainHTML
            source = .data(data, mimeType: FileTypeDetector.webArchive, baseURL: archive?.mainURL ?? file.deletingLastPathComponent())
        } else {
            fallbackHTML = TextEncodingDetector.decode(data).text
            source = .file(file, readAccess: file.deletingLastPathComponent())
        }

        do {
            let page = try await WebRenderer.render(source, options: renderOptions)
            var result = try WebDocument.result(for: page, options: options, fallbackTitle: file.deletingPathExtension().lastPathComponent)
            if result.text.isEmpty, let fallbackHTML {
                result.text = HTMLText.plainText(fallbackHTML)
            }
            if let archive = result.archiveFile {
                await PDFAConverter.applyIfRequested(to: archive, options: options)
            }
            return result
        } catch {
            Self.logger.warning("WebKit could not render \(file.lastPathComponent): \(error). Using text only, no archive.")
            return try WebDocument.textOnlyResult(html: fallbackHTML ?? "", options: options)
        }
    }
}

/// Shared result building for rendered web content (HTML files, URL captures).
enum WebDocument {
    /// Paginates `page` into `archive.pdf`, renders the thumbnail and collects metadata.
    static func result(for page: WebRenderer.Page, options: ParseOptions, fallbackTitle: String?) throws -> ParseResult {
        let title = TitleHeuristics.meaningfulTitle(page.title)
        let archive = options.scratchDirectory.appendingPathComponent("archive.pdf")
        let pageCount = try WebPaginator.paginate(page, to: archive, title: title ?? fallbackTitle)

        let image = autoreleasepool { () -> CGImage? in
            guard let document = PDFDocument(url: archive), let first = document.page(at: 0) else { return nil }
            return ThumbnailRenderer.image(fromPDFPage: first, maxPixels: options.thumbnailMaxPixels)
        }
        let thumbnail = try ThumbnailRenderer.write(
            image ?? ThumbnailRenderer.placeholder(label: "HTML", maxPixels: options.thumbnailMaxPixels),
            to: options.scratchDirectory
        )

        let text = TextNormalizer.postProcess(page.text)
        return ParseResult(
            text: text,
            archiveFile: archive,
            thumbnailFile: thumbnail,
            pageCount: pageCount,
            metadata: metadata(for: page),
            metadataDate: FlexibleDate.publicationDate(meta: page.meta, times: page.times),
            suggestedTitle: title,
            language: LanguageDetector.detect(text) ?? page.language
        )
    }

    /// Result when WebKit is unavailable: text from the markup, a text thumbnail, no archive.
    static func textOnlyResult(html: String, options: ParseOptions) throws -> ParseResult {
        let text = HTMLText.plainText(html)
        let image = ThumbnailRenderer.image(fromText: text, maxPixels: options.thumbnailMaxPixels)
            ?? ThumbnailRenderer.placeholder(label: "HTML", maxPixels: options.thumbnailMaxPixels)
        let thumbnail = try ThumbnailRenderer.write(image, to: options.scratchDirectory)
        let meta = HTMLText.metaTags(html)
        return ParseResult(
            text: text,
            archiveFile: nil,
            thumbnailFile: thumbnail,
            pageCount: nil,
            metadata: meta.sorted { $0.key < $1.key }.prefix(50).map {
                MetadataEntry(namespace: htmlNamespace, prefix: "meta", key: $0.key, value: $0.value)
            },
            metadataDate: FlexibleDate.publicationDate(meta: meta),
            suggestedTitle: TitleHeuristics.meaningfulTitle(HTMLText.title(html)),
            language: LanguageDetector.detect(text)
        )
    }

    static let htmlNamespace = "http://www.w3.org/1999/xhtml"
    static let ignoredMeta: Set<String> = ["viewport", "theme-color", "color-scheme", "format-detection", "referrer", "robots", "content-type"]

    static func metadata(for page: WebRenderer.Page) -> [MetadataEntry] {
        var entries = page.meta
            .filter { !ignoredMeta.contains($0.key) && !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .prefix(50)
            .map { MetadataEntry(namespace: htmlNamespace, prefix: "meta", key: $0.key, value: String($0.value.prefix(1000))) }
        if let url = page.finalURL, url.scheme == "http" || url.scheme == "https" {
            entries.append(MetadataEntry(MetadataNamespace.folio, "sourceURL", url.absoluteString))
        }
        return entries
    }
}

/// The main resource of a Safari `.webarchive` (a property list).
struct WebArchive {
    var mainHTML: String?
    var mainURL: URL?

    init?(data: Data) {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let main = plist["WebMainResource"] as? [String: Any] else { return nil }
        if let body = main["WebResourceData"] as? Data {
            let encodingName = main["WebResourceTextEncodingName"] as? String
            let encoding = encodingName.map {
                String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringConvertIANACharSetNameToEncoding($0 as CFString)))
            }
            mainHTML = encoding.flatMap { String(data: body, encoding: $0) } ?? TextEncodingDetector.decode(body).text
        }
        mainURL = (main["WebResourceURL"] as? String).flatMap(URL.init(string:))
    }
}
