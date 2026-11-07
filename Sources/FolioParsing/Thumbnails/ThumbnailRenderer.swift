import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import QuickLookThumbnailing
import Synchronization

/// Renders JPEG thumbnails on a white background. JPEG because ImageIO cannot
/// write WebP on macOS.
public enum ThumbnailRenderer {
    /// Portrait page aspect ratio (width / height) used for text and placeholder thumbnails.
    public static let pageAspect: CGFloat = 1 / 1.4142

    /// File name used inside the scratch directory.
    public static let defaultFileName = "thumbnail.jpg"

    // MARK: Sources

    /// First page (or `page`) of a PDF, scaled so the longest edge is `maxPixels`.
    public static func image(fromPDFPage page: PDFPage, maxPixels: Int, extraRotation: Int = 0) -> CGImage? {
        let size = PDFUtilities.displaySize(of: page, extraRotation: extraRotation)
        let (w, h) = fitted(size, maxPixels: maxPixels)
        guard let context = ImageUtilities.makeContext(width: w, height: h) else { return nil }
        PDFUtilities.draw(page, in: context, targetSize: CGSize(width: w, height: h), extraRotation: extraRotation)
        return context.makeImage()
    }

    /// First page of the PDF at `url`. Nil when the file is unreadable or locked.
    public static func image(fromPDF url: URL, passwords: [String] = [], maxPixels: Int) -> CGImage? {
        guard let opened = PDFUtilities.open(url, passwords: passwords), !opened.isLocked,
              let page = opened.document.page(at: 0) else { return nil }
        return image(fromPDFPage: page, maxPixels: maxPixels)
    }

    /// `image` drawn upright with `orientation`, on white.
    public static func image(fromImage image: CGImage, orientation: ImageOrientation = .up, maxPixels: Int) -> CGImage? {
        ImageUtilities.renderUpright(image, orientation: orientation, maxPixels: maxPixels)
    }

    /// Frame `index` of an image file, with EXIF orientation and a further
    /// clockwise `extraRotation` applied. Uses ImageIO subsampling, so it is fast
    /// for large photos.
    public static func image(fromImageSource source: CGImageSource, index: Int, maxPixels: Int, extraRotation: Int = 0) -> CGImage? {
        guard let thumb = ImageUtilities.uprightThumbnail(source: source, index: index, maxPixels: maxPixels) else {
            return nil
        }
        return ImageUtilities.renderUpright(thumb, orientation: ImageOrientation(rotation: extraRotation), maxPixels: maxPixels)
    }

    /// A page-shaped image showing the first ~50 lines of `text` in a monospaced font.
    public static func image(fromText text: String, maxPixels: Int) -> CGImage? {
        let height = max(64, maxPixels)
        let width = Int((CGFloat(height) * pageAspect).rounded())
        guard let context = ImageUtilities.makeContext(width: width, height: height) else { return nil }

        let lineCount = 50
        let margin = CGFloat(width) * 0.05
        let fontSize = (CGFloat(height) - 2 * margin) / CGFloat(lineCount) / 1.2
        let font = CTFontCreateWithName("Menlo" as CFString, fontSize, nil)
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .prefix(lineCount)
            .map { String($0.prefix(200)) }
            .joined(separator: "\n")

        let attributed = NSAttributedString(string: lines, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.1, alpha: 1),
        ])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let rect = CGRect(x: margin, y: margin, width: CGFloat(width) - 2 * margin, height: CGFloat(height) - 2 * margin)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
        return context.makeImage()
    }

    /// A plain page-shaped placeholder with a centred label.
    public static func placeholder(label: String, maxPixels: Int) -> CGImage {
        let height = max(64, maxPixels)
        let width = Int((CGFloat(height) * pageAspect).rounded())
        guard let context = ImageUtilities.makeContext(width: width, height: height) else {
            // A 1x1 white image; makeContext only fails for absurd sizes.
            return ImageUtilities.makeContext(width: 1, height: 1)!.makeImage()!
        }
        let inset = CGFloat(width) * 0.04
        context.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
        context.setLineWidth(max(1, CGFloat(width) / 150))
        context.stroke(CGRect(x: inset, y: inset, width: CGFloat(width) - 2 * inset, height: CGFloat(height) - 2 * inset))

        let fontSize = CGFloat(width) / 9
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributed = NSAttributedString(string: label, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0.45, alpha: 1),
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetImageBounds(line, context)
        let scale = min(1, (CGFloat(width) - 4 * inset) / max(1, bounds.width))
        context.saveGState()
        context.translateBy(x: CGFloat(width) / 2, y: CGFloat(height) / 2)
        context.scaleBy(x: scale, y: scale)
        context.textPosition = CGPoint(x: -bounds.midX, y: -bounds.midY)
        CTLineDraw(line, context)
        context.restoreGState()
        return context.makeImage() ?? ImageUtilities.makeContext(width: 1, height: 1)!.makeImage()!
    }

    /// Thumbnail of any file from Quick Look (Office files, web archives, ...).
    /// Nil when Quick Look has no generator for the file or exceeds `timeout`.
    public static func quickLookImage(for url: URL, maxPixels: Int, timeout: Duration = .seconds(20)) async -> CGImage? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CGImage?, Never>) in
            let once = OnceContinuation(continuation)
            Task.detached {
                let request = QLThumbnailGenerator.Request(
                    fileAt: url,
                    size: CGSize(width: maxPixels, height: maxPixels),
                    scale: 1,
                    representationTypes: .thumbnail
                )
                let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                once.resume(representation?.cgImage)
            }
            Task.detached {
                try? await Task.sleep(for: timeout)
                once.resume(nil)
            }
        }
    }

    /// Quick Look thumbnail flattened on white, or a placeholder labelled with
    /// the file extension when Quick Look fails.
    public static func genericImage(for url: URL, maxPixels: Int, timeout: Duration = .seconds(20)) async -> CGImage {
        if let ql = await quickLookImage(for: url, maxPixels: maxPixels, timeout: timeout),
           let flat = ImageUtilities.renderUpright(ql, orientation: .up, maxPixels: maxPixels) {
            return flat
        }
        let ext = url.pathExtension.uppercased()
        return placeholder(label: ext.isEmpty ? "FILE" : ext, maxPixels: maxPixels)
    }

    // MARK: Output

    /// Writes `image` as JPEG into `directory` and returns the file URL.
    @discardableResult
    public static func write(_ image: CGImage, to directory: URL, fileName: String = defaultFileName, quality: Double = 0.85) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(fileName)
        try ImageUtilities.writeJPEG(image, to: url, quality: quality)
        return url
    }

    /// Convenience: QuickLook-or-placeholder thumbnail of `file`, written into `directory`.
    public static func writeGeneric(for file: URL, to directory: URL, maxPixels: Int) async throws -> URL {
        let image = await genericImage(for: file, maxPixels: maxPixels)
        return try write(image, to: directory)
    }

    static func fitted(_ size: CGSize, maxPixels: Int) -> (Int, Int) {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return (1, 1) }
        let scale = CGFloat(maxPixels) / longest
        return (max(1, Int((size.width * scale).rounded())), max(1, Int((size.height * scale).rounded())))
    }
}

/// A continuation that is resumed at most once, from any thread.
final class OnceContinuation<T: Sendable>: Sendable {
    private let state: Mutex<CheckedContinuation<T, Never>?>

    init(_ continuation: CheckedContinuation<T, Never>) {
        state = Mutex(continuation)
    }

    func resume(_ value: T) {
        let continuation = state.withLock { stored -> CheckedContinuation<T, Never>? in
            defer { stored = nil }
            return stored
        }
        continuation?.resume(returning: value)
    }
}
