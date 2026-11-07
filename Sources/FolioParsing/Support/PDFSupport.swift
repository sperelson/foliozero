import CoreGraphics
import Foundation
import PDFKit

/// PDFKit helpers shared by the PDF parser, the archive builder and thumbnails.
///
/// PDFKit objects are not `Sendable`. Keep them inside one task and pass only
/// rendered `CGImage`s to other tasks.
public enum PDFUtilities {
    /// Outcome of opening a PDF.
    public struct OpenedDocument {
        public let document: PDFDocument
        /// The file is encrypted (it may still have been unlocked).
        public let isEncrypted: Bool
        /// No password worked; text and pages are not readable.
        public let isLocked: Bool
    }

    /// Opens a PDF and unlocks it with the first password that works.
    /// PDFKit already tries the empty user password. Returns nil when the file is not a readable PDF.
    public static func open(_ url: URL, passwords: [String] = []) -> OpenedDocument? {
        guard let document = PDFDocument(url: url) else { return nil }
        if document.isLocked {
            for password in passwords where document.unlock(withPassword: password) {
                break
            }
        }
        return OpenedDocument(document: document, isEncrypted: document.isEncrypted, isLocked: document.isLocked)
    }

    /// Size in points of `page` as displayed (page rotation and `extraRotation` applied).
    public static func displaySize(of page: PDFPage, box: PDFDisplayBox = .cropBox, extraRotation: Int = 0) -> CGSize {
        let upright = uprightSize(of: page, box: box)
        return ImageOrientation(rotation: extraRotation).orientedSize(upright)
    }

    /// Size with the page's own /Rotate applied.
    static func uprightSize(of page: PDFPage, box: PDFDisplayBox) -> CGSize {
        let bounds = page.bounds(for: box)
        let rotation = ImageOrientation.normalize(page.rotation)
        return rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
    }

    /// Draws `page` upright, rotated a further `extraRotation` degrees clockwise,
    /// scaled to fill `CGRect(origin: .zero, size: targetSize)`. Vector content
    /// and text stay vector when `context` is a PDF context. Annotations
    /// (for example filled form fields) are drawn too.
    public static func draw(
        _ page: PDFPage,
        in context: CGContext,
        targetSize: CGSize,
        extraRotation: Int = 0,
        box: PDFDisplayBox = .cropBox
    ) {
        let upright = uprightSize(of: page, box: box)
        let extra = ImageOrientation(rotation: extraRotation)
        let finalSize = extra.orientedSize(upright)
        guard finalSize.width > 0, finalSize.height > 0 else { return }
        context.saveGState()
        context.scaleBy(x: targetSize.width / finalSize.width, y: targetSize.height / finalSize.height)
        context.concatenate(extra.drawingTransform(rawSize: upright))
        context.clip(to: CGRect(origin: .zero, size: upright))
        // PDFPage.draw applies the page's own rotation and box origin.
        page.draw(with: box, to: context)
        context.restoreGState()
    }

    /// Rasterises `page` at `dpi`, capped so the longest edge is at most `maxPixels`.
    public static func render(
        _ page: PDFPage,
        dpi: CGFloat = 300,
        maxPixels: Int = 5000,
        extraRotation: Int = 0,
        gray: Bool = false
    ) -> CGImage? {
        let size = displaySize(of: page, extraRotation: extraRotation)
        guard size.width > 0, size.height > 0 else { return nil }
        let scale = min(dpi / 72, CGFloat(maxPixels) / max(size.width, size.height))
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let context = ImageUtilities.makeContext(width: width, height: height, gray: gray) else { return nil }
        draw(page, in: context, targetSize: CGSize(width: width, height: height), extraRotation: extraRotation)
        return context.makeImage()
    }

    /// Text of one page, cleaned with `TextNormalizer.postProcess`.
    public static func text(of page: PDFPage) -> String {
        TextNormalizer.postProcess(page.string ?? "")
    }

    /// Raw XMP packet from the document catalog, if any.
    public static func xmpData(of document: PDFDocument) -> Data? {
        guard let catalog = document.documentRef?.catalog else { return nil }
        var stream: CGPDFStreamRef?
        guard CGPDFDictionaryGetStream(catalog, "Metadata", &stream), let stream else { return nil }
        var format = CGPDFDataFormat.raw
        guard let data = CGPDFStreamCopyData(stream, &format) else { return nil }
        return data as Data
    }
}
