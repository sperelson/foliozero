import CoreGraphics
import Foundation
import Logging
import PDFKit

/// PDF documents: embedded text through PDFKit, OCR through Vision or Tesseract,
/// and an archive PDF with an invisible text layer.
///
/// OCR modes (`ParseOptions.ocrMode`), applied per page within `ocrPages`:
/// - `auto`: OCR pages with fewer than `autoOCRCharacterThreshold` non-whitespace
///   characters of embedded text. Archive pages stay vector; the OCR text is
///   laid over them.
/// - `redo`: OCR every page and rasterise it in the archive, so the new text
///   layer replaces any old one. This approximates OCRmyPDF `--redo-ocr`, which
///   keeps vector content and strips only old OCR text; Core Graphics cannot
///   filter content streams, so FolioZero rasterises instead. If OCR finds no
///   text on a page, its embedded text is kept.
/// - `force`: rasterise and OCR every page; existing text is ignored.
/// - `off`: never OCR.
///
/// Archive modes: `auto` writes an archive only when OCR found text on some page
/// (or, in `redo`/`force`, when any page was OCR'd); `always` always writes one,
/// with born-digital pages copied as vectors with their own text; `never` writes none.
public struct PDFParser: DocumentParser {
    public let name = "pdf"
    public let supportedMIMETypes: [String: String] = ["application/pdf": ".pdf"]

    /// Resolution for rasterising pages for OCR and for raster archive pages.
    public var renderDPI: CGFloat = 300
    /// Longest edge of a rasterised page.
    public var maxRenderPixels = 5000
    /// In `auto` mode, pages with fewer non-whitespace characters than this are OCR'd.
    public var autoOCRCharacterThreshold = 10
    /// Pages recognised at the same time.
    public var concurrency = ConcurrentOCR.defaultConcurrency
    public var jpegQuality = 0.8

    static let logger = Logger(label: "foliozero.parsing.pdf")

    public init() {}

    struct PageOCR: Sendable {
        var result: OCRPageResult?
        /// Rasterised page for the archive (redo/force only).
        var jpegFile: URL?
    }

    public func parse(file: URL, mimeType: String, options: ParseOptions) async throws -> ParseResult {
        let fm = FileManager.default
        try fm.createDirectory(at: options.scratchDirectory, withIntermediateDirectories: true)

        guard let opened = PDFUtilities.open(file, passwords: options.pdfPasswords) else {
            throw ParserError.unreadable(file, "not a readable PDF")
        }
        let document = opened.document
        let metadata = PDFMetadata.entries(for: document, isEncrypted: opened.isEncrypted, isLocked: opened.isLocked)

        if opened.isLocked {
            Self.logger.warning("\(file.lastPathComponent) is encrypted and no password worked; text is empty")
            let image = ThumbnailRenderer.placeholder(label: "ENCRYPTED", maxPixels: options.thumbnailMaxPixels)
            let thumbnail = try ThumbnailRenderer.write(image, to: options.scratchDirectory)
            return ParseResult(
                text: "",
                archiveFile: nil,
                thumbnailFile: thumbnail,
                pageCount: document.pageCount > 0 ? document.pageCount : nil,
                metadata: metadata
            )
        }

        let pageCount = document.pageCount
        let embedded: [String] = (0..<pageCount).map { index in
            autoreleasepool { document.page(at: index).map(PDFUtilities.text(of:)) ?? "" }
        }

        let ocrPages = (0..<pageCount).filter { shouldOCR(page: $0, embeddedText: embedded[$0], options: options) }
        let rasterise = options.ocrMode == .redo || options.ocrMode == .force
        let ocr = try await recognize(
            pages: ocrPages,
            of: document,
            keepRaster: rasterise && options.archiveMode != .never,
            options: options
        )
        defer {
            for case let url? in ocr.values.map(\.jpegFile) { try? fm.removeItem(at: url) }
        }

        let pageTexts = (0..<pageCount).map { index in
            Self.combine(embedded: embedded[index], ocr: ocr[index]?.result?.text, mode: options.ocrMode)
        }
        let text = TextNormalizer.postProcess(pageTexts.filter { !$0.isEmpty }.joined(separator: "\n\n"))
        if !ocrPages.isEmpty, ocr.values.allSatisfy({ $0.result == nil }), text.isEmpty {
            throw ParserError.ocrFailed("OCR failed on every page of \(file.lastPathComponent)")
        }

        let ocrFoundText = ocr.values.contains { !($0.result?.text.isEmpty ?? true) }
        let wantsArchive: Bool = switch options.archiveMode {
        case .never: false
        case .always: pageCount > 0
        case .auto: rasterise ? !ocr.isEmpty : ocrFoundText
        }

        let title = PDFMetadata.title(of: document)
        var archive: URL?
        if wantsArchive {
            var pages: [ArchivePDFBuilder.Page] = []
            for index in 0..<pageCount {
                guard let page = document.page(at: index) else { continue }
                let pageOCR = ocr[index]
                let rotation = pageOCR?.result?.rotation ?? 0
                let size = PDFUtilities.displaySize(of: page, extraRotation: rotation)
                let content: ArchivePDFBuilder.Page.Content = pageOCR?.jpegFile.map { .jpegFile($0) } ?? .pdfPage(page)
                pages.append(ArchivePDFBuilder.Page(
                    content: content,
                    orientation: ImageOrientation(rotation: rotation),
                    size: size,
                    lines: pageOCR?.result?.lines ?? []
                ))
            }
            let attributes = document.documentAttributes ?? [:]
            let builder = ArchivePDFBuilder(
                title: title ?? file.deletingPathExtension().lastPathComponent,
                author: attributes[PDFDocumentAttribute.authorAttribute] as? String,
                subject: attributes[PDFDocumentAttribute.subjectAttribute] as? String,
                jpegQuality: jpegQuality
            )
            let url = options.scratchDirectory.appendingPathComponent("archive.pdf")
            try builder.write(pages: pages, to: url)
            await PDFAConverter.applyIfRequested(to: url, options: options)
            archive = url
        }

        let thumbnailImage: CGImage? = autoreleasepool {
            if let archive, let archived = PDFDocument(url: archive), let first = archived.page(at: 0) {
                return ThumbnailRenderer.image(fromPDFPage: first, maxPixels: options.thumbnailMaxPixels)
            }
            guard let first = document.page(at: 0) else { return nil }
            return ThumbnailRenderer.image(
                fromPDFPage: first,
                maxPixels: options.thumbnailMaxPixels,
                extraRotation: ocr[0]?.result?.rotation ?? 0
            )
        }
        let thumbnail = try ThumbnailRenderer.write(
            thumbnailImage ?? ThumbnailRenderer.placeholder(label: "PDF", maxPixels: options.thumbnailMaxPixels),
            to: options.scratchDirectory
        )

        return ParseResult(
            text: text,
            archiveFile: archive,
            thumbnailFile: thumbnail,
            pageCount: pageCount,
            metadata: metadata,
            metadataDate: PDFMetadata.creationDate(of: document),
            suggestedTitle: title,
            language: LanguageDetector.detect(text)
        )
    }

    func shouldOCR(page index: Int, embeddedText: String, options: ParseOptions) -> Bool {
        if options.ocrPages > 0, index >= options.ocrPages { return false }
        switch options.ocrMode {
        case .off: return false
        case .redo, .force: return true
        case .auto: return TextNormalizer.nonWhitespaceCount(embeddedText) < autoOCRCharacterThreshold
        }
    }

    /// Page text from embedded text and OCR text (nil when the page was not OCR'd or OCR failed).
    static func combine(embedded: String, ocr: String?, mode: OCRMode) -> String {
        switch mode {
        case .force:
            return ocr ?? embedded
        case .redo:
            if let ocr, !ocr.isEmpty { return ocr }
            return embedded
        case .auto, .off:
            guard let ocr, !ocr.isEmpty else { return embedded }
            if embedded.isEmpty || ocr.contains(embedded) { return ocr }
            return embedded + "\n" + ocr
        }
    }

    /// Renders and recognises `pages`, at most `concurrency` at a time. Rendering
    /// stays on the calling task (PDFKit is not thread-safe per document); only
    /// rendered images go to child tasks.
    func recognize(
        pages: [Int],
        of document: PDFDocument,
        keepRaster: Bool,
        options: ParseOptions
    ) async throws -> [Int: PageOCR] {
        guard !pages.isEmpty else { return [:] }
        let recognizer = PageRecognizer(options: options)
        let scratch = options.scratchDirectory
        let quality = jpegQuality
        let dpi = renderDPI
        let maxPixels = maxRenderPixels
        let limit = max(1, concurrency)
        var results: [Int: PageOCR] = [:]

        try await withThrowingTaskGroup(of: (Int, PageOCR).self) { group in
            var inFlight = 0
            for index in pages {
                if inFlight >= limit, let next = try await group.next() {
                    results[next.0] = next.1
                    inFlight -= 1
                }
                try Task.checkCancellation()
                let image: CGImage? = autoreleasepool {
                    guard let page = document.page(at: index) else { return nil }
                    return PDFUtilities.render(page, dpi: dpi, maxPixels: maxPixels, gray: !keepRaster)
                }
                guard let image else {
                    Self.logger.warning("Cannot render page \(index + 1) for OCR")
                    results[index] = PageOCR()
                    continue
                }
                group.addTask {
                    var output = PageOCR()
                    do {
                        output.result = try await recognizer.recognize(image)
                    } catch {
                        Self.logger.warning("OCR failed on page \(index + 1): \(error)")
                    }
                    if keepRaster {
                        let url = scratch.appendingPathComponent(String(format: "page-%05d.jpg", index + 1))
                        if let data = ImageUtilities.jpegData(image, quality: quality), (try? data.write(to: url)) != nil {
                            output.jpegFile = url
                        }
                    }
                    return (index, output)
                }
                inFlight += 1
            }
            for try await (index, output) in group {
                results[index] = output
            }
        }
        return results
    }
}
