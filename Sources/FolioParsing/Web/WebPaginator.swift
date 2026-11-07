import CoreGraphics
import Foundation

/// Cuts the single tall PDF page that WebKit exports into A4 pages. Content
/// stays vector, so text remains selectable; each page clips to its slice, so
/// PDFKit extracts only the text visible on that page.
public enum WebPaginator {
    /// A4 in points.
    public static let a4 = CGSize(width: 595.28, height: 841.89)

    public struct Layout: Sendable {
        public var pageSize: CGSize
        /// Blank border around the content on every page, in points.
        public var margin: CGFloat
        /// A break may move up to this fraction of a page to avoid cutting a line.
        public var maximumBreakShift: CGFloat

        public init(pageSize: CGSize = WebPaginator.a4, margin: CGFloat = 28, maximumBreakShift: CGFloat = 0.3) {
            self.pageSize = pageSize
            self.margin = margin
            self.maximumBreakShift = maximumBreakShift
        }
    }

    /// Positions (CSS pixels from the top) where pages start and end. Each break
    /// is moved up to the top of any line or block it would cut, unless that
    /// would shrink the page by more than `maximumBreakShift`.
    public static func pageBreaks(
        contentHeight: Double,
        pageHeight: Double,
        blocks: [ClosedRange<Double>],
        maximumBreakShift: Double = 0.3
    ) -> [Double] {
        guard contentHeight > 0, pageHeight > 0 else { return [0, max(contentHeight, 1)] }
        let sorted = blocks.sorted { $0.lowerBound < $1.lowerBound }
        var breaks: [Double] = [0]
        var start = 0.0
        while start + pageHeight < contentHeight - 0.5 {
            let hardCut = start + pageHeight
            var cut = hardCut
            var moved = true
            while moved {
                moved = false
                for block in sorted {
                    if block.lowerBound >= cut { break }
                    if block.lowerBound < cut - 0.5, block.upperBound > cut + 0.5, block.lowerBound > start + 0.5 {
                        cut = block.lowerBound
                        moved = true
                    }
                }
                if cut < start + pageHeight * (1 - maximumBreakShift) {
                    cut = hardCut
                    break
                }
            }
            breaks.append(cut)
            start = cut
        }
        breaks.append(contentHeight)
        return breaks
    }

    /// Writes the paginated PDF. Returns the number of pages.
    @discardableResult
    public static func paginate(
        _ page: WebRenderer.Page,
        to url: URL,
        layout: Layout = Layout(),
        title: String? = nil
    ) throws -> Int {
        guard let provider = CGDataProvider(data: page.pdf as CFData),
              let document = CGPDFDocument(provider),
              let source = document.page(at: 1) else {
            throw ParserError.conversionFailed("WebKit produced no PDF")
        }
        let box = source.getBoxRect(.mediaBox)
        let printable = CGSize(width: layout.pageSize.width - 2 * layout.margin, height: layout.pageSize.height - 2 * layout.margin)
        let scale = printable.width / box.width
        // The PDF can be shorter than the reported content height (or the reverse); trust the PDF.
        let contentHeight = Double(box.height)
        let breaks = pageBreaks(
            contentHeight: contentHeight,
            pageHeight: Double(printable.height / scale),
            blocks: page.blockExtents,
            maximumBreakShift: Double(layout.maximumBreakShift)
        )

        var info: [CFString: Any] = [kCGPDFContextCreator: "FolioZero"]
        if let title, !title.isEmpty { info[kCGPDFContextTitle] = title }
        var mediaBox = CGRect(origin: .zero, size: layout.pageSize)
        try? FileManager.default.removeItem(at: url)
        guard let context = CGContext(url as CFURL, mediaBox: &mediaBox, info as CFDictionary) else {
            throw ParserError.conversionFailed("Cannot create PDF at \(url.path)")
        }
        var pages = 0
        for index in 0..<(breaks.count - 1) {
            let top = CGFloat(breaks[index])
            let bottom = CGFloat(breaks[index + 1])
            guard bottom - top > 0.5 else { continue }
            context.beginPage(mediaBox: &mediaBox)
            context.saveGState()
            // Page top-left of the printable area, in PDF (y up) coordinates.
            context.translateBy(x: layout.margin, y: layout.pageSize.height - layout.margin)
            context.scaleBy(x: scale, y: scale)
            // Source y (up) of the slice top is box.maxY - top.
            context.translateBy(x: -box.minX, y: -(box.maxY - top))
            context.clip(to: CGRect(x: box.minX, y: box.maxY - bottom, width: box.width, height: bottom - top))
            context.drawPDFPage(source)
            context.restoreGState()
            context.endPage()
            pages += 1
        }
        context.closePDF()
        return pages
    }
}
