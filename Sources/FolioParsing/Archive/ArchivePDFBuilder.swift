import CoreGraphics
import CoreText
import Foundation
import PDFKit

/// Writes archive PDFs: each page shows the original (a vector copy of a PDF
/// page, or an image) with an invisible OCR text layer on top, so PDFKit text
/// extraction, text selection and Spotlight work.
///
/// Not `Sendable`: pages may hold PDFKit objects. Build and write in one task.
public struct ArchivePDFBuilder {
    public struct Page {
        public enum Content {
            /// Vector copy of a PDF page. Its own text stays selectable.
            case pdfPage(PDFPage)
            /// JPEG bytes, embedded untouched (DCT passthrough).
            case jpeg(Data)
            /// A JPEG file, read when the page is written (keeps memory low for long documents).
            case jpegFile(URL)
            /// Any image. Lossless images are embedded as-is (Flate); others are
            /// encoded as JPEG at `jpegQuality` first.
            case image(CGImage, lossless: Bool)
        }

        public var content: Content
        /// Orientation applied to the content. For images: EXIF orientation plus
        /// any OCR rotation. For PDF pages: only the extra clockwise rotation (the
        /// page's own /Rotate is always honoured); mirroring is ignored.
        public var orientation: ImageOrientation
        /// Page size in points, after orientation.
        public var size: CGSize
        /// Invisible text lines, normalised to the upright page (origin top-left).
        public var lines: [OCRLine]

        public init(content: Content, orientation: ImageOrientation = .up, size: CGSize, lines: [OCRLine] = []) {
            self.content = content
            self.orientation = orientation
            self.size = size
            self.lines = lines
        }
    }

    public var title: String?
    public var author: String?
    public var subject: String?
    public var keywords: [String]
    public var creator: String
    public var jpegQuality: Double
    /// Font for the invisible text layer. Core Text falls back to other fonts for
    /// characters it lacks. Hiragino Sans is the default because Core Graphics
    /// embeds it (a CFF font) with a ToUnicode map, which survives Ghostscript's
    /// PDF/A conversion. Helvetica and other TrueType fonts are embedded with
    /// MacRoman encoding and no ToUnicode map; Ghostscript's PDF/A output then
    /// uses an `Adobe-Identity-UCS2` CMap that PDFKit cannot read, and the text
    /// layer disappears for PDFKit and Spotlight.
    public var textLayerFontName: String

    public init(
        title: String? = nil,
        author: String? = nil,
        subject: String? = nil,
        keywords: [String] = [],
        creator: String = "FolioZero",
        jpegQuality: Double = 0.8,
        textLayerFontName: String = "HiraginoSans-W3"
    ) {
        self.title = title
        self.author = author
        self.subject = subject
        self.keywords = keywords
        self.creator = creator
        self.jpegQuality = jpegQuality
        self.textLayerFontName = textLayerFontName
    }

    /// Writes `pages` to `url`.
    public func write(pages: [Page], to url: URL) throws {
        var info: [CFString: Any] = [kCGPDFContextCreator: creator]
        if let title, !title.isEmpty { info[kCGPDFContextTitle] = title }
        if let author, !author.isEmpty { info[kCGPDFContextAuthor] = author }
        if let subject, !subject.isEmpty { info[kCGPDFContextSubject] = subject }
        if !keywords.isEmpty { info[kCGPDFContextKeywords] = keywords.joined(separator: ", ") }

        try? FileManager.default.removeItem(at: url)
        guard let context = CGContext(url as CFURL, mediaBox: nil, info as CFDictionary) else {
            throw ParserError.conversionFailed("Cannot create PDF at \(url.path)")
        }
        let font = CTFontCreateWithName(textLayerFontName as CFString, 1, nil)

        for page in pages {
            try autoreleasepool {
                try writePage(page, into: context, font: font)
            }
        }
        context.closePDF()
    }

    private func writePage(_ page: Page, into context: CGContext, font: CTFont) throws {
        var mediaBox = CGRect(origin: .zero, size: page.size)
        guard mediaBox.width > 0, mediaBox.height > 0 else { return }
        context.beginPage(mediaBox: &mediaBox)

        switch page.content {
        case .pdfPage(let pdfPage):
            PDFUtilities.draw(pdfPage, in: context, targetSize: page.size, extraRotation: page.orientation.rotation)
        case .jpeg(let data):
            drawJPEG(data, orientation: page.orientation, size: page.size, in: context)
        case .jpegFile(let url):
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            drawJPEG(data, orientation: page.orientation, size: page.size, in: context)
        case .image(let image, let lossless):
            if !lossless, let data = ImageUtilities.jpegData(image, quality: jpegQuality) {
                drawJPEG(data, orientation: page.orientation, size: page.size, in: context)
            } else {
                drawImage(image, orientation: page.orientation, size: page.size, in: context)
            }
        }

        Self.drawInvisibleText(page.lines, pageSize: page.size, font: font, in: context)
        context.endPage()
    }

    private func drawJPEG(_ data: Data, orientation: ImageOrientation, size: CGSize, in context: CGContext) {
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent
              ) else { return }
        drawImage(image, orientation: orientation, size: size, in: context)
    }

    private func drawImage(_ image: CGImage, orientation: ImageOrientation, size: CGSize, in context: CGContext) {
        let raw = CGSize(width: image.width, height: image.height)
        let oriented = orientation.orientedSize(raw)
        context.saveGState()
        context.scaleBy(x: size.width / oriented.width, y: size.height / oriented.height)
        context.concatenate(orientation.drawingTransform(rawSize: raw))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(origin: .zero, size: raw))
        context.restoreGState()
    }

    /// Draws `lines` as invisible text (PDF text render mode 3). Each line is
    /// sized so its ascent plus descent fills the box height, then stretched
    /// horizontally to fill the box width.
    public static func drawInvisibleText(_ lines: [OCRLine], pageSize: CGSize, font: CTFont, in context: CGContext) {
        guard !lines.isEmpty else { return }
        context.saveGState()
        context.setTextDrawingMode(.invisible)
        let unitAscent = CTFontGetAscent(font)
        let unitDescent = CTFontGetDescent(font)
        let unitHeight = max(0.1, unitAscent + unitDescent)

        for line in lines {
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let box = CGRect(
                x: line.boundingBox.minX * pageSize.width,
                y: (1 - line.boundingBox.maxY) * pageSize.height,
                width: line.boundingBox.width * pageSize.width,
                height: line.boundingBox.height * pageSize.height
            )
            guard box.width > 0.5, box.height > 0.5 else { continue }

            let fontSize = box.height / unitHeight
            let sized = CTFontCreateCopyWithAttributes(font, fontSize, nil, nil)
            let attributed = NSAttributedString(
                string: text,
                attributes: [NSAttributedString.Key(kCTFontAttributeName as String): sized]
            )
            let ctLine = CTLineCreateWithAttributedString(attributed)
            let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
            guard width > 0 else { continue }
            let horizontalScale = min(50, max(0.02, box.width / width))

            context.saveGState()
            context.translateBy(x: box.minX, y: box.minY + unitDescent * fontSize)
            context.scaleBy(x: horizontalScale, y: 1)
            context.textMatrix = .identity
            context.textPosition = .zero
            CTLineDraw(ctLine, context)
            context.restoreGState()
        }
        context.restoreGState()
    }
}
