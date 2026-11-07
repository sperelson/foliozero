import Foundation

/// When to run OCR. Mirrors `PAPERLESS_OCR_MODE`.
public enum OCRMode: String, Sendable, Codable, CaseIterable {
    /// OCR only when the document has no usable text layer.
    case auto
    /// OCR every page and replace any existing text layer.
    case redo
    /// Rasterise every page, then OCR. Text in the original is ignored.
    case force
    /// Never OCR. PDFs keep their embedded text; images get no text.
    case off
}

/// When to produce an archive PDF. Mirrors `PAPERLESS_ARCHIVE_FILE_GENERATION`.
public enum ArchiveMode: String, Sendable, Codable, CaseIterable {
    /// Produce an archive for scanned or converted documents, skip it for born-digital PDFs.
    case auto
    case always
    case never
}

/// Which OCR engine to use.
public enum OCREngineKind: String, Sendable, Codable, CaseIterable {
    /// Apple Vision. Default.
    case vision
    /// Tesseract CLI (`tesseract` on PATH or `ParseOptions.tesseractPath`).
    case tesseract
}

/// Options for one parse run. Built by FolioCore from configuration.
public struct ParseOptions: Sendable {
    public var ocrMode: OCRMode
    public var archiveMode: ArchiveMode
    public var ocrEngine: OCREngineKind
    /// Recognition languages as BCP-47 tags for Vision ("en-US", "de-DE")
    /// or Tesseract codes ("eng", "afr"). The engine maps what it can.
    public var languages: [String]
    /// OCR only the first N pages. 0 means all pages.
    public var ocrPages: Int
    /// DPI to assume for images that carry no DPI metadata. nil lets the parser guess (300).
    public var imageDPI: Int?
    /// Rotate pages whose detected text orientation is not upright.
    public var rotatePages: Bool
    /// Directory the parser may write temporary and output files into.
    /// The caller creates it and deletes it after the run.
    public var scratchDirectory: URL
    /// Longest edge of the thumbnail in pixels.
    public var thumbnailMaxPixels: Int
    /// Passwords to try on encrypted PDFs.
    public var pdfPasswords: [String]
    /// Path to the Tesseract binary. nil means search PATH and /opt/homebrew/bin.
    public var tesseractPath: String?
    /// Path to LibreOffice `soffice`. nil means search the usual install locations.
    public var libreOfficePath: String?
    /// Path to Ghostscript `gs`, used for PDF/A conversion when `pdfA` is true.
    public var ghostscriptPath: String?
    /// Convert archive PDFs to PDF/A-2b with Ghostscript when it is available.
    public var pdfA: Bool

    public init(
        ocrMode: OCRMode = .auto,
        archiveMode: ArchiveMode = .auto,
        ocrEngine: OCREngineKind = .vision,
        languages: [String] = ["en-US"],
        ocrPages: Int = 0,
        imageDPI: Int? = nil,
        rotatePages: Bool = true,
        scratchDirectory: URL,
        thumbnailMaxPixels: Int = 500,
        pdfPasswords: [String] = [],
        tesseractPath: String? = nil,
        libreOfficePath: String? = nil,
        ghostscriptPath: String? = nil,
        pdfA: Bool = false
    ) {
        self.ocrMode = ocrMode
        self.archiveMode = archiveMode
        self.ocrEngine = ocrEngine
        self.languages = languages
        self.ocrPages = ocrPages
        self.imageDPI = imageDPI
        self.rotatePages = rotatePages
        self.scratchDirectory = scratchDirectory
        self.thumbnailMaxPixels = thumbnailMaxPixels
        self.pdfPasswords = pdfPasswords
        self.tesseractPath = tesseractPath
        self.libreOfficePath = libreOfficePath
        self.ghostscriptPath = ghostscriptPath
        self.pdfA = pdfA
    }
}

/// One metadata entry, shaped like Paperless-ngx `/api/documents/{id}/metadata/`
/// (`original_metadata` / `archive_metadata` items).
public struct MetadataEntry: Sendable, Codable, Hashable {
    public var namespace: String
    public var prefix: String
    public var key: String
    public var value: String

    public init(namespace: String, prefix: String, key: String, value: String) {
        self.namespace = namespace
        self.prefix = prefix
        self.key = key
        self.value = value
    }
}

/// Output of a parser.
public struct ParseResult: Sendable {
    /// Extracted or recognised text. Never nil; empty when there is none.
    public var text: String
    /// Archive PDF with a text layer, inside `ParseOptions.scratchDirectory`. nil when none was produced.
    public var archiveFile: URL?
    /// JPEG thumbnail inside `ParseOptions.scratchDirectory`.
    public var thumbnailFile: URL
    /// Page count of the original (or the archive, for converted documents). nil when not meaningful.
    public var pageCount: Int?
    /// Metadata of the original file.
    public var metadata: [MetadataEntry]
    /// A creation date found in file metadata (PDF CreationDate, EXIF DateTimeOriginal, email Date header).
    /// FolioCore prefers dates found in the content and falls back to this.
    public var metadataDate: Date?
    /// Title suggested by the file itself (HTML <title>, email Subject, PDF Title). nil when none.
    public var suggestedTitle: String?
    /// Detected language of the text as a BCP-47 tag, if known.
    public var language: String?

    public init(
        text: String,
        archiveFile: URL?,
        thumbnailFile: URL,
        pageCount: Int?,
        metadata: [MetadataEntry] = [],
        metadataDate: Date? = nil,
        suggestedTitle: String? = nil,
        language: String? = nil
    ) {
        self.text = text
        self.archiveFile = archiveFile
        self.thumbnailFile = thumbnailFile
        self.pageCount = pageCount
        self.metadata = metadata
        self.metadataDate = metadataDate
        self.suggestedTitle = suggestedTitle
        self.language = language
    }
}

public enum ParserError: Error, Sendable, CustomStringConvertible {
    case unsupportedType(String)
    case unreadable(URL, String)
    case encrypted(URL)
    case ocrFailed(String)
    case conversionFailed(String)
    case toolMissing(String)
    /// The remote OCR engine failed; the message names the engine, as Paperless-ngx does.
    case remoteOCRFailed(String)

    public var description: String {
        switch self {
        case .unsupportedType(let mime): "Unsupported file type: \(mime)"
        case .unreadable(let url, let why): "Cannot read \(url.lastPathComponent): \(why)"
        case .encrypted(let url): "\(url.lastPathComponent) is encrypted and no password worked"
        case .ocrFailed(let why): "OCR failed: \(why)"
        case .conversionFailed(let why): "Conversion failed: \(why)"
        case .toolMissing(let tool): "Required tool not found: \(tool)"
        case .remoteOCRFailed(let message): message
        }
    }
}

/// A parser for one family of file types.
///
/// Parsers are stateless. FolioCore calls `parse` from a background task, so
/// implementations must not assume the main thread. Parsers that need the main
/// thread (WebKit) hop to the main actor themselves.
public protocol DocumentParser: Sendable {
    /// Stable identifier, for logs and the `/api/status/` report ("pdf", "image", "text", ...).
    var name: String { get }

    /// MIME types this parser handles, mapped to their default file extension (with the dot).
    var supportedMIMETypes: [String: String] { get }

    /// Higher wins when several parsers support a MIME type. Default parsers use 10.
    func score(mimeType: String, fileName: String) -> Int

    /// True when the parser sends content to a remote service (Paperless-ngx
    /// `uses_remote_service`). The registry skips such parsers unless remote use is allowed.
    var usesRemoteService: Bool { get }

    /// Parse `file`. Write any output files into `options.scratchDirectory`.
    func parse(file: URL, mimeType: String, options: ParseOptions) async throws -> ParseResult
}

extension DocumentParser {
    public func score(mimeType: String, fileName: String) -> Int {
        supportedMIMETypes[mimeType] == nil ? 0 : 10
    }

    public var usesRemoteService: Bool { false }
}

/// Chooses a parser for a MIME type.
public struct ParserRegistry: Sendable {
    public private(set) var parsers: [any DocumentParser]

    public init(parsers: [any DocumentParser]) {
        self.parsers = parsers
    }

    public mutating func register(_ parser: any DocumentParser) {
        parsers.append(parser)
    }

    /// The highest-scoring parser. With `allowRemote` false, parsers that use a remote
    /// service are skipped, so the document never leaves the Mac.
    public func parser(for mimeType: String, fileName: String = "", allowRemote: Bool = true) -> (any DocumentParser)? {
        parsers
            .filter { allowRemote || !$0.usesRemoteService }
            .map { ($0, $0.score(mimeType: mimeType, fileName: fileName)) }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?
            .0
    }

    /// All supported MIME types mapped to their default extension.
    public var supportedMIMETypes: [String: String] {
        parsers.reduce(into: [:]) { result, parser in
            result.merge(parser.supportedMIMETypes) { current, _ in current }
        }
    }

    public func isSupported(_ mimeType: String) -> Bool {
        parser(for: mimeType) != nil
    }
}
