import AppKit
import Foundation

/// Lays out an attributed string on A4 pages with the AppKit text system and
/// writes a PDF with selectable text. AppKit text objects are main-thread
/// objects here: build the string and call `write` inside `MainActor.run`.
public enum AttributedTextPDF {
    /// Writes `string` to `url`. Returns the number of pages (at least 1).
    @MainActor
    @discardableResult
    public static func write(
        _ string: NSAttributedString,
        to url: URL,
        pageSize: CGSize = WebPaginator.a4,
        margin: CGFloat = 56,
        title: String? = nil
    ) throws -> Int {
        let storage = NSTextStorage(attributedString: string)
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let textSize = CGSize(width: pageSize.width - 2 * margin, height: pageSize.height - 2 * margin)

        var containers: [NSTextContainer] = []
        while containers.count < 5000 {
            let container = NSTextContainer(size: textSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            containers.append(container)
            let range = layoutManager.glyphRange(for: container)
            if NSMaxRange(range) >= layoutManager.numberOfGlyphs { break }
            // Nothing fits (for example an image taller than the page): stop instead of looping.
            if range.length == 0, containers.count > 1 { break }
        }

        var info: [CFString: Any] = [kCGPDFContextCreator: "FolioZero"]
        if let title, !title.isEmpty { info[kCGPDFContextTitle] = title }
        var box = CGRect(origin: .zero, size: pageSize)
        try? FileManager.default.removeItem(at: url)
        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw ParserError.conversionFailed("Cannot create PDF at \(url.path)")
        }
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        var pages = 0
        for container in containers {
            let range = layoutManager.glyphRange(for: container)
            if range.length == 0, pages > 0 { continue }
            context.beginPage(mediaBox: &box)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            context.saveGState()
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            let origin = CGPoint(x: margin, y: margin)
            layoutManager.drawBackground(forGlyphRange: range, at: origin)
            layoutManager.drawGlyphs(forGlyphRange: range, at: origin)
            context.restoreGState()
            NSGraphicsContext.restoreGraphicsState()
            context.endPage()
            pages += 1
        }
        context.closePDF()
        return max(pages, 1)
    }

    /// Plain text in a readable body font, with an optional bold heading block.
    @MainActor
    public static func plainDocument(heading: [(String, String)] = [], body: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let labelFont = NSFont.boldSystemFont(ofSize: 10)
        let valueFont = NSFont.systemFont(ofSize: 10)
        for (label, value) in heading {
            result.append(NSAttributedString(string: label + ": ", attributes: [.font: labelFont]))
            result.append(NSAttributedString(string: value + "\n", attributes: [.font: valueFont]))
        }
        if !heading.isEmpty {
            result.append(NSAttributedString(string: "\n", attributes: [.font: valueFont]))
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        result.append(NSAttributedString(string: body, attributes: [
            .font: NSFont.userFixedPitchFont(ofSize: 9.5) ?? NSFont.systemFont(ofSize: 10),
            .paragraphStyle: paragraph,
        ]))
        return result
    }
}
