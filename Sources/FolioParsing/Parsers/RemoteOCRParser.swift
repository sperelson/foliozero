import CoreGraphics
import Foundation
import ImageIO
import Logging
import PDFKit
import UniformTypeIdentifiers

/// Sends PDFs and images to a remote OCR engine (Paperless-ngx `RemoteDocumentParser`).
/// The engine returns the text and a searchable PDF, which becomes the archive file.
///
/// - The parser scores 20 when the engine is fully configured, so it wins over the
///   local PDF and image parsers (10). Unconfigured, it scores 0 and is never chosen.
/// - It declares `usesRemoteService`, so the registry skips it unless the caller
///   allows remote processing (`REMOTE_OCR_MODE`, or a workflow asked for it).
/// - A PDF that needs no archive (see `shouldProduceArchive`) never leaves the Mac:
///   its embedded text is used instead. Images always go to the engine.
/// - Errors and timeouts fail the parse, as in Paperless-ngx, so a document is never
///   stored without its text.
public struct RemoteOCRParser: DocumentParser {
    public static let parserName = "remote"
    public static let mimeTypes: [String: String] = [
        "application/pdf": ".pdf",
        "image/png": ".png",
        "image/jpeg": ".jpg",
        "image/tiff": ".tiff",
        "image/bmp": ".bmp",
        "image/gif": ".gif",
        "image/webp": ".webp",
    ]
    /// Paperless-ngx scores the remote parser 20, above the Tesseract parser's 10.
    public static let configuredScore = 20
    /// A PDF is born-digital when its text is longer than this, or the PDF is tagged
    /// (Paperless-ngx `PDF_TEXT_MIN_LENGTH`).
    public static let bornDigitalMinimumLength = 50

    public let name = parserName
    public var supportedMIMETypes: [String: String] { Self.mimeTypes }
    public var usesRemoteService: Bool { true }

    public var config: RemoteOCREngineConfig
    public var transport: any RemoteOCRTransport
    public var isInternalHost: RemoteOCRHostCheck
    /// Wait between status requests when the service sends no `Retry-After`.
    public var pollInterval: Duration = .seconds(1)
    /// Timeout of one HTTP request.
    public var requestTimeout: TimeInterval = 300
    /// Limit for one document, from upload to PDF download.
    public var timeout: TimeInterval = 1800

    static let logger = Logger(label: "foliozero.parsing.remote")

    public init(
        config: RemoteOCREngineConfig,
        transport: any RemoteOCRTransport = URLSessionRemoteOCRTransport.shared,
        isInternalHost: @escaping RemoteOCRHostCheck = { _ in false }
    ) {
        self.config = config
        self.transport = transport
        self.isInternalHost = isInternalHost
    }

    public func score(mimeType: String, fileName: String) -> Int {
        guard config.engineIsValid, Self.mimeTypes[mimeType] != nil else { return 0 }
        return Self.configuredScore
    }

    /// The client for the configured engine, or nil when it is not fully configured.
    public func makeClient() -> AzureDocumentIntelligenceClient? {
        guard config.engineIsValid, config.engineKind == .azureAI, let endpoint = config.endpoint, let apiKey = config.apiKey else {
            return nil
        }
        return AzureDocumentIntelligenceClient(
            endpoint: endpoint,
            apiKey: apiKey,
            transport: transport,
            allowInternalEndpoints: config.allowInternalEndpoints,
            isInternalHost: isInternalHost,
            pollInterval: pollInterval,
            requestTimeout: requestTimeout,
            timeout: timeout
        )
    }

    /// Paperless-ngx `should_produce_archive` for a parser that can produce archives
    /// and needs no PDF rendition: `always` and `never` decide alone; `auto` wants an
    /// archive for images and for PDFs that are not born-digital.
    public static func shouldProduceArchive(mimeType: String, archiveMode: ArchiveMode, pdfText: String?, isTaggedPDF: Bool) -> Bool {
        switch archiveMode {
        case .always: return true
        case .never: return false
        case .auto:
            if mimeType.hasPrefix("image/") { return true }
            if mimeType == "application/pdf" { return !isBornDigital(text: pdfText, isTagged: isTaggedPDF) }
            return false
        }
    }

    /// Paperless-ngx `is_born_digital_text`: real text, and either a tagged PDF or
    /// more than `bornDigitalMinimumLength` characters.
    public static func isBornDigital(text: String?, isTagged: Bool) -> Bool {
        guard let text, !text.isEmpty else { return false }
        return isTagged || text.count > bornDigitalMinimumLength
    }

    public func parse(file: URL, mimeType: String, options: ParseOptions) async throws -> ParseResult {
        try FileManager.default.createDirectory(at: options.scratchDirectory, withIntermediateDirectories: true)
        let local = LocalFile(file: file, mimeType: mimeType, passwords: options.pdfPasswords)
        if local.isLockedPDF {
            // The engine cannot read it either; store it without text, as the local parser does.
            Self.logger.warning("\(file.lastPathComponent) is encrypted and no password worked; not sent to remote OCR")
            return try await PDFParser().parse(file: file, mimeType: mimeType, options: options)
        }

        guard let client = makeClient() else {
            Self.logger.warning("No valid remote parser engine is configured, content will be empty.")
            return try local.result(text: "", archive: nil, options: options)
        }

        let produceArchive = Self.shouldProduceArchive(
            mimeType: mimeType, archiveMode: options.archiveMode, pdfText: local.pdfText, isTaggedPDF: local.isTaggedPDF
        )
        if !produceArchive, mimeType == "application/pdf" {
            Self.logger.debug("Remote OCR: skipped, no archive requested; using locally extracted text")
            return try local.result(text: local.pdfText ?? "", archive: nil, options: options)
        }

        // The configured endpoint is checked before anything is sent. Later requests
        // (polling, PDF download) are checked again inside the client.
        do {
            _ = try client.serviceBase()
        } catch {
            throw ParserError.remoteOCRFailed("Invalid remote OCR endpoint: \(error)")
        }

        let analysis: AzureDocumentIntelligenceClient.Analysis
        do {
            let data = try Data(contentsOf: file)
            Self.logger.info("Sending \(file.lastPathComponent) to Azure AI Document Intelligence")
            analysis = try await client.analyze(document: data)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Self.logger.error("Azure AI Vision parsing failed: \(error)")
            throw ParserError.remoteOCRFailed("Azure AI Vision parsing failed: \(error)")
        }

        var archive: URL?
        if produceArchive {
            let url = options.scratchDirectory.appendingPathComponent("archive.pdf")
            try analysis.pdf.write(to: url)
            archive = url
        }
        return try local.result(text: analysis.content, archive: archive, options: options)
    }
}

/// What the parser reads from the file itself: page count, metadata, dates and,
/// for PDFs, the embedded text. PDFKit and ImageIO objects stay inside one parse.
private struct LocalFile {
    let file: URL
    let mimeType: String
    var pdf: PDFUtilities.OpenedDocument?
    var image: CGImageSource?
    var pdfText: String?
    var isTaggedPDF = false

    var isLockedPDF: Bool { pdf?.isLocked ?? false }

    init(file: URL, mimeType: String, passwords: [String]) {
        self.file = file
        self.mimeType = mimeType
        if mimeType == "application/pdf" {
            pdf = PDFUtilities.open(file, passwords: passwords)
            if let opened = pdf, !opened.isLocked {
                let document = opened.document
                let pages = (0..<document.pageCount).map { index in
                    autoreleasepool { document.page(at: index).map(PDFUtilities.text(of:)) ?? "" }
                }
                pdfText = TextNormalizer.postProcess(pages.filter { !$0.isEmpty }.joined(separator: "\n\n"))
                isTaggedPDF = Self.isTagged(document)
            }
        } else {
            image = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        }
    }

    /// Paperless-ngx `is_tagged_pdf`: the catalog has `/MarkInfo` with `/Marked true`.
    static func isTagged(_ document: PDFDocument) -> Bool {
        guard let catalog = document.documentRef?.catalog else { return false }
        var markInfo: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(catalog, "MarkInfo", &markInfo), let markInfo else { return false }
        var marked: CGPDFBoolean = 0
        return CGPDFDictionaryGetBoolean(markInfo, "Marked", &marked) && marked != 0
    }

    /// Frames treated as pages: every TIFF frame, otherwise the primary image.
    var imageFrames: [Int] {
        guard let image, CGImageSourceGetCount(image) > 0 else { return [] }
        let isTIFF = CGImageSourceGetType(image).map { $0 as String } == UTType.tiff.identifier || mimeType == "image/tiff"
        return isTIFF ? Array(0..<CGImageSourceGetCount(image)) : [CGImageSourceGetPrimaryImageIndex(image)]
    }

    func result(text: String, archive: URL?, options: ParseOptions) throws -> ParseResult {
        let maxPixels = options.thumbnailMaxPixels
        let document = pdf.flatMap { $0.isLocked ? nil : $0.document }
        let frames = imageFrames
        let primary = frames.first.flatMap { index in image.map { ImageUtilities.properties(of: $0, at: index) } } ?? [:]

        let thumbnailImage: CGImage? = autoreleasepool {
            if let archive, let archived = PDFDocument(url: archive), let first = archived.page(at: 0) {
                return ThumbnailRenderer.image(fromPDFPage: first, maxPixels: maxPixels)
            }
            if let first = document?.page(at: 0) {
                return ThumbnailRenderer.image(fromPDFPage: first, maxPixels: maxPixels)
            }
            if let image, let index = frames.first {
                return ThumbnailRenderer.image(fromImageSource: image, index: index, maxPixels: maxPixels)
            }
            return nil
        }
        let label = mimeType == "application/pdf" ? "PDF" : "IMAGE"
        let thumbnail = try ThumbnailRenderer.write(
            thumbnailImage ?? ThumbnailRenderer.placeholder(label: label, maxPixels: maxPixels),
            to: options.scratchDirectory
        )

        let metadata: [MetadataEntry]
        let pageCount: Int?
        let metadataDate: Date?
        let title: String?
        if let opened = pdf {
            metadata = PDFMetadata.entries(for: opened.document, isEncrypted: opened.isEncrypted, isLocked: opened.isLocked)
            pageCount = opened.document.pageCount > 0 ? opened.document.pageCount : nil
            metadataDate = document.flatMap(PDFMetadata.creationDate(of:))
            title = document.flatMap(PDFMetadata.title(of:))
        } else if !frames.isEmpty {
            metadata = ImageMetadata.entries(properties: primary, frameCount: frames.count)
            pageCount = frames.count
            metadataDate = ImageMetadata.creationDate(properties: primary)
            title = nil
        } else {
            metadata = []
            pageCount = nil
            metadataDate = nil
            title = nil
        }

        return ParseResult(
            text: text,
            archiveFile: archive,
            thumbnailFile: thumbnail,
            pageCount: pageCount,
            metadata: metadata,
            metadataDate: metadataDate,
            suggestedTitle: title,
            language: LanguageDetector.detect(text)
        )
    }
}
