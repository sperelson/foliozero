import Foundation
import Logging

/// Captures a URL as a document: web pages are rendered with WebKit into a
/// paginated archive PDF (the original is saved as a `.webarchive`); URLs that
/// return a PDF, image, text or Office file are downloaded and handed to the
/// matching parser.
///
/// FolioZero's "no internal hosts" checks belong to the caller; this type
/// fetches whatever URL it is given (http, https or file).
public enum WebCapture {
    static let logger = Logger(label: "foliozero.parsing.capture")

    /// A captured document: the original file to store plus the parse result.
    public struct CapturedDocument: Sendable {
        /// The original inside `ParseOptions.scratchDirectory`: a `.webarchive`
        /// for rendered pages, otherwise the downloaded file.
        public var originalFile: URL
        public var mimeType: String
        /// File name for the stored original, derived from the page title or the download.
        public var suggestedFileName: String
        /// URL after redirects.
        public var finalURL: URL
        public var result: ParseResult
    }

    public enum CaptureError: Error, Sendable, CustomStringConvertible {
        case unsupportedScheme(String)
        case httpStatus(Int)
        case downloadFailed(String)

        public var description: String {
            switch self {
            case .unsupportedScheme(let scheme): "Cannot capture URLs with scheme \(scheme)"
            case .httpStatus(let status): "The server answered with HTTP status \(status)"
            case .downloadFailed(let why): "Download failed: \(why)"
            }
        }
    }

    /// Captures `url` and returns the parse result. See `captureDocument` for the original file.
    public static func capture(url: URL, options: ParseOptions) async throws -> ParseResult {
        try await captureDocument(url: url, options: options).result
    }

    /// Captures `url`: downloads it (60 s timeout), then renders HTML with WebKit
    /// or delegates PDFs, images and other supported files to their parser.
    public static func captureDocument(
        url: URL,
        options: ParseOptions,
        timeout: Duration = .seconds(60),
        userAgent: String? = nil
    ) async throws -> CapturedDocument {
        let fm = FileManager.default
        try fm.createDirectory(at: options.scratchDirectory, withIntermediateDirectories: true)
        let scheme = url.scheme?.lowercased() ?? ""

        let downloaded: URL
        var mimeType: String
        var finalURL = url
        var serverFileName: String?
        switch scheme {
        case "file":
            downloaded = url
            mimeType = try FileTypeDetector.mimeType(of: url)
        case "http", "https":
            let download = try await self.download(url, into: options.scratchDirectory, timeout: timeout, userAgent: userAgent)
            downloaded = download.file
            finalURL = download.finalURL
            serverFileName = download.suggestedFileName
            mimeType = try FileTypeDetector.mimeType(of: download.file)
            let declared = download.contentType ?? ""
            if declared.contains("html"), mimeType == "text/plain" || mimeType == FileTypeDetector.octetStream || mimeType == "application/xml" {
                mimeType = "text/html"
            }
        default:
            throw CaptureError.unsupportedScheme(scheme)
        }

        if mimeType == "text/html" || mimeType == "application/xhtml+xml" {
            return try await capturePage(
                source: scheme == "file" ? .file(url, readAccess: url.deletingLastPathComponent()) : .url(finalURL),
                downloaded: downloaded,
                finalURL: finalURL,
                options: options,
                timeout: timeout,
                userAgent: userAgent
            )
        }

        let registry = ParserRegistry(parsers: StandardParsers.all.filter { $0.name != URLShortcutParser.parserName })
        guard let parser = registry.parser(for: mimeType, fileName: downloaded.lastPathComponent) else {
            throw ParserError.unsupportedType(mimeType)
        }
        let ext = FileTypeDetector.defaultExtension(for: mimeType)
        var fileName = serverFileName ?? finalURL.lastPathComponent
        if fileName.isEmpty || fileName == "/" { fileName = finalURL.host ?? "download" }
        if !ext.isEmpty, (fileName as NSString).pathExtension.isEmpty { fileName += ext }
        // Give the downloaded file its real extension; some parsers look at it.
        var original = downloaded
        if scheme != "file" {
            original = options.scratchDirectory.appendingPathComponent("original" + (ext.isEmpty ? "" : ext))
            if original != downloaded {
                try? fm.removeItem(at: original)
                try fm.moveItem(at: downloaded, to: original)
            }
        }
        var result = try await parser.parse(file: original, mimeType: mimeType, options: options)
        result.metadata.append(MetadataEntry(MetadataNamespace.folio, "sourceURL", finalURL.absoluteString))
        return CapturedDocument(
            originalFile: original,
            mimeType: mimeType,
            suggestedFileName: sanitizedFileName(fileName),
            finalURL: finalURL,
            result: result
        )
    }

    static func capturePage(
        source: WebRenderer.Source,
        downloaded: URL,
        finalURL: URL,
        options: ParseOptions,
        timeout: Duration,
        userAgent: String?
    ) async throws -> CapturedDocument {
        let renderOptions = WebRenderer.Options(timeout: timeout, createsWebArchive: true, userAgent: userAgent)
        let page: WebRenderer.Page
        do {
            page = try await WebRenderer.render(source, options: renderOptions)
        } catch {
            logger.warning("WebKit could not render \(finalURL.absoluteString): \(error). Using text only, no archive.")
            let html = (try? Data(contentsOf: downloaded)).map { TextEncodingDetector.decode($0).text } ?? ""
            var result = try WebDocument.textOnlyResult(html: html, options: options)
            result.metadata.append(MetadataEntry(MetadataNamespace.folio, "sourceURL", finalURL.absoluteString))
            let original = options.scratchDirectory.appendingPathComponent("original.html")
            if original != downloaded {
                try? FileManager.default.removeItem(at: original)
                try FileManager.default.copyItem(at: downloaded, to: original)
            }
            let base = result.suggestedTitle ?? finalURL.host ?? "page"
            return CapturedDocument(
                originalFile: original, mimeType: "text/html",
                suggestedFileName: sanitizedFileName(base) + ".html", finalURL: finalURL, result: result
            )
        }

        var result = try WebDocument.result(for: page, options: options, fallbackTitle: finalURL.host)
        if let archive = result.archiveFile {
            await PDFAConverter.applyIfRequested(to: archive, options: options)
        }
        if !result.metadata.contains(where: { $0.key == "sourceURL" }) {
            result.metadata.append(MetadataEntry(MetadataNamespace.folio, "sourceURL", (page.finalURL ?? finalURL).absoluteString))
        }
        if result.suggestedTitle == nil { result.suggestedTitle = finalURL.host }

        let base = sanitizedFileName(result.suggestedTitle ?? finalURL.host ?? "page")
        let original: URL
        let mimeType: String
        if let archive = page.webArchive {
            original = options.scratchDirectory.appendingPathComponent("original.webarchive")
            try archive.write(to: original, options: .atomic)
            mimeType = FileTypeDetector.webArchive
        } else {
            original = options.scratchDirectory.appendingPathComponent("original.html")
            if original != downloaded {
                try? FileManager.default.removeItem(at: original)
                try FileManager.default.copyItem(at: downloaded, to: original)
            }
            mimeType = "text/html"
        }
        // The download was only used to detect the type; WebKit fetched the page itself.
        if downloaded != original, downloaded.path.hasPrefix(options.scratchDirectory.path) {
            try? FileManager.default.removeItem(at: downloaded)
        }
        return CapturedDocument(
            originalFile: original,
            mimeType: mimeType,
            suggestedFileName: base + FileTypeDetector.defaultExtension(for: mimeType),
            finalURL: page.finalURL ?? finalURL,
            result: result
        )
    }

    struct Download {
        var file: URL
        var finalURL: URL
        var contentType: String?
        var suggestedFileName: String?
    }

    static func download(_ url: URL, into directory: URL, timeout: Duration, userAgent: String?) async throws -> Download {
        let configuration = URLSessionConfiguration.ephemeral
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        configuration.timeoutIntervalForRequest = seconds
        configuration.timeoutIntervalForResource = seconds
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        var request = URLRequest(url: url)
        request.setValue(userAgent ?? "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) FolioZero", forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/pdf,image/*;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")

        let (temporary, response): (URL, URLResponse)
        do {
            (temporary, response) = try await session.download(for: request)
        } catch {
            throw CaptureError.downloadFailed(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw CaptureError.httpStatus(http.statusCode)
        }
        let file = directory.appendingPathComponent("download-\(UUID().uuidString.prefix(8))")
        try FileManager.default.moveItem(at: temporary, to: file)
        return Download(
            file: file,
            finalURL: response.url ?? url,
            contentType: response.mimeType?.lowercased(),
            suggestedFileName: response.suggestedFilename
        )
    }

    /// A file name without path separators or control characters, at most 120 characters.
    static func sanitizedFileName(_ name: String) -> String {
        let cleaned = name
            .components(separatedBy: CharacterSet(charactersIn: "/\\:?*\"<>|").union(.controlCharacters).union(.newlines))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ".-")))
        return cleaned.isEmpty ? "page" : String(cleaned.prefix(120))
    }
}
