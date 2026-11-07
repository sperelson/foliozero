import Foundation
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import FolioParsing

/// A page long enough for several A4 pages, with a title and a publication date.
func longHTML(title: String = "Annual Garden Report", paragraphs: Int = 60) -> String {
    let body = (1...paragraphs).map { index in
        "<p>Paragraph \(index): The tomatoes in bed \(index) grew well this season and the compost was turned weekly.</p>"
    }.joined(separator: "\n")
    return """
    <!DOCTYPE html>
    <html lang="en"><head><meta charset="utf-8">
    <title>\(title)</title>
    <meta property="article:published_time" content="2025-06-14T08:30:00+02:00">
    <meta name="description" content="Garden notes">
    <style>body { font-family: Helvetica; font-size: 16px; } h1 { color: #036; }</style>
    </head><body>
    <h1>\(title)</h1>
    <p>Unique marker: ZEBRA-QUARTZ-7781</p>
    \(body)
    <p>Final line FINIS-4420</p>
    </body></html>
    """
}

@Suite("Web pages")
struct WebTests {
    let dir: URL

    init() throws {
        dir = try FixtureFactory.makeDirectory("web")
    }

    @Test func htmlFileBecomesPaginatedArchive() async throws {
        let url = dir.appendingPathComponent("garden.html")
        try Data(longHTML().utf8).write(to: url)
        #expect(try FileTypeDetector.mimeType(of: url) == "text/html")
        let result = try await HTMLParser().parse(file: url, mimeType: "text/html", options: FixtureFactory.options(dir))

        #expect(result.text.contains("ZEBRA-QUARTZ-7781"))
        #expect(result.text.contains("FINIS-4420"))
        #expect(result.suggestedTitle == "Annual Garden Report")
        #expect(result.metadataDate == FlexibleDate.parse("2025-06-14T08:30:00+02:00"))
        #expect(result.metadata.contains { $0.key == "description" && $0.value == "Garden notes" })
        let archive = try #require(result.archiveFile)
        let document = try #require(PDFDocument(url: archive))
        #expect(document.pageCount >= 2)
        #expect(result.pageCount == document.pageCount)
        let bounds = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(bounds.width - 595.28) < 1 && abs(bounds.height - 841.89) < 1)
        // Selectable text, each marker exactly once (pages clip their slice).
        let text = document.string ?? ""
        #expect(text.components(separatedBy: "ZEBRA-QUARTZ-7781").count == 2, "archive text: \(text.prefix(300))")
        #expect(text.components(separatedBy: "FINIS-4420").count == 2)
        #expect(document.page(at: 0)?.string?.contains("ZEBRA-QUARTZ-7781") == true)
        #expect(document.page(at: document.pageCount - 1)?.string?.contains("FINIS-4420") == true)
        #expect(isJPEG(result.thumbnailFile))
    }

    @Test(.enabled(if: ToolLocator.find("gs") != nil, "Ghostscript is not installed"))
    func pdfAKeepsWebArchiveText() async throws {
        let url = dir.appendingPathComponent("garden-a.html")
        try Data(longHTML(paragraphs: 5).utf8).write(to: url)
        let result = try await HTMLParser().parse(file: url, mimeType: "text/html", options: FixtureFactory.options(dir, pdfA: true))
        let archive = try #require(result.archiveFile)
        // Either Ghostscript kept the text, or the converter kept the plain PDF.
        #expect(pdfString(archive).contains("ZEBRA-QUARTZ-7781"))
    }

    @Test func pageBreaksAvoidCuttingLines() {
        let lines = stride(from: 0.0, to: 3000, by: 20).map { $0...($0 + 16) }
        let breaks = WebPaginator.pageBreaks(contentHeight: 3000, pageHeight: 1010, blocks: lines)
        #expect(breaks.first == 0 && breaks.last == 3000)
        for cut in breaks.dropFirst().dropLast() {
            #expect(!lines.contains { $0.lowerBound < cut - 0.5 && $0.upperBound > cut + 0.5 }, "cut \(cut) splits a line")
            #expect(cut.truncatingRemainder(dividingBy: 1010) != 0 || cut == 0)
        }
        // A block taller than a page cannot be kept whole: hard cut.
        let tall = WebPaginator.pageBreaks(contentHeight: 2000, pageHeight: 800, blocks: [10...1990])
        #expect(tall == [0, 800, 1600, 2000])
    }

    @Test func webArchiveIsRendered() async throws {
        let html = longHTML(title: "Archived Recipe", paragraphs: 5)
        let plist: [String: Any] = [
            "WebMainResource": [
                "WebResourceData": Data(html.utf8),
                "WebResourceMIMEType": "text/html",
                "WebResourceTextEncodingName": "UTF-8",
                "WebResourceURL": "https://example.com/recipe",
                "WebResourceFrameName": "",
            ],
        ]
        let url = dir.appendingPathComponent("recipe.webarchive")
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0).write(to: url)
        #expect(try FileTypeDetector.mimeType(of: url) == FileTypeDetector.webArchive)
        let result = try await HTMLParser().parse(file: url, mimeType: FileTypeDetector.webArchive, options: FixtureFactory.options(dir))
        #expect(result.text.contains("ZEBRA-QUARTZ-7781"))
        #expect(result.suggestedTitle == "Archived Recipe")
        let archive = try #require(result.archiveFile)
        #expect(pdfString(archive).contains("ZEBRA-QUARTZ-7781"))
    }

    @Test func textFallbackWithoutWebKit() throws {
        let options = FixtureFactory.options(dir)
        try FileManager.default.createDirectory(at: options.scratchDirectory, withIntermediateDirectories: true)
        let result = try WebDocument.textOnlyResult(html: longHTML(paragraphs: 2), options: options)
        #expect(result.archiveFile == nil)
        #expect(result.text.contains("ZEBRA-QUARTZ-7781"))
        #expect(!result.text.contains("font-family"), "style blocks are removed")
        #expect(result.suggestedTitle == "Annual Garden Report")
        #expect(result.metadataDate != nil)
    }

    @Test func htmlTextHelpers() {
        let html = "<html><head><title>A &amp; B</title><script>var x=1;</script></head><body><p>One&nbsp;two</p><div>Caf&eacute; &#8364;5 &#x41;</div><ul><li>x</li></ul></body></html>"
        #expect(HTMLText.title(html) == "A & B")
        let text = HTMLText.plainText(html)
        #expect(text.contains("One\u{00A0}two") || text.contains("One two"))
        #expect(text.contains("Café €5 A"))
        #expect(!text.contains("var x"))
        #expect(HTMLText.escape("<a href=\"x\">&</a>") == "&lt;a href=&quot;x&quot;&gt;&amp;&lt;/a&gt;")
        #expect(FlexibleDate.parse("2024-02-29") != nil)
        #expect(FlexibleDate.parse("Thu, 29 Feb 2024 10:00:00 +0000") == Date(timeIntervalSince1970: 1_709_200_800))
        #expect(FlexibleDate.publicationDate(meta: ["date": "nonsense", "dc.date": "2024-01-05"]) != nil)
    }

    @Test func urlCaptureOfPagePDFAndImage() async throws {
        let pdfURL = dir.appendingPathComponent("served.pdf")
        try FixtureFactory.bornDigitalPDF(pages: [["Served PDF document", "Invoice ORCA-5512"]], to: pdfURL)
        let pngURL = dir.appendingPathComponent("served.png")
        try FixtureFactory.writeImage(FixtureFactory.textImage(), type: .png, to: pngURL)
        let server = try await TestHTTPServer(routes: [
            "/article": .init(contentType: "text/html; charset=utf-8", body: Data(longHTML(title: "Captured Article", paragraphs: 10).utf8)),
            "/doc": .init(contentType: "application/pdf", body: try Data(contentsOf: pdfURL)),
            "/scan": .init(contentType: "image/png", body: try Data(contentsOf: pngURL)),
        ])
        defer { server.stop() }

        let page = try await WebCapture.captureDocument(url: server.url("/article"), options: FixtureFactory.options(dir))
        #expect(page.result.text.contains("ZEBRA-QUARTZ-7781"))
        #expect(page.result.suggestedTitle == "Captured Article")
        #expect(page.result.archiveFile != nil)
        #expect(page.mimeType == FileTypeDetector.webArchive)
        #expect(try FileTypeDetector.mimeType(of: page.originalFile) == FileTypeDetector.webArchive)
        #expect(page.suggestedFileName == "Captured Article.webarchive")
        #expect(page.result.metadata.contains { $0.key == "sourceURL" && $0.value.hasSuffix("/article") })

        let pdf = try await WebCapture.captureDocument(url: server.url("/doc"), options: FixtureFactory.options(dir))
        #expect(pdf.mimeType == "application/pdf")
        #expect(pdf.result.text.contains("ORCA-5512"))
        #expect(pdf.originalFile.pathExtension == "pdf")

        let image = try await WebCapture.capture(url: server.url("/scan"), options: FixtureFactory.options(dir))
        #expect(containsSampleWords(image.text))

        await #expect(throws: WebCapture.CaptureError.self) {
            _ = try await WebCapture.capture(url: server.url("/missing"), options: FixtureFactory.options(dir))
        }
        await #expect(throws: WebCapture.CaptureError.self) {
            _ = try await WebCapture.capture(url: URL(string: "ftp://example.com/x")!, options: FixtureFactory.options(dir))
        }
    }

    @Test func urlShortcutsAreCaptured() async throws {
        let server = try await TestHTTPServer(routes: [
            "/linked": .init(contentType: "text/html", body: Data(longHTML(title: "Linked Page", paragraphs: 3).utf8)),
        ])
        defer { server.stop() }

        let webloc = dir.appendingPathComponent("link.webloc")
        try PropertyListSerialization.data(fromPropertyList: ["URL": server.url("/linked").absoluteString], format: .binary, options: 0)
            .write(to: webloc)
        let urlFile = dir.appendingPathComponent("link.url")
        try Data("[InternetShortcut]\r\nURL=\(server.url("/linked").absoluteString)\r\n".utf8).write(to: urlFile)

        for file in [webloc, urlFile] {
            let mime = try FileTypeDetector.mimeType(of: file)
            #expect(mime == FileTypeDetector.urlShortcut)
            let parser = try #require(StandardParsers.makeRegistry().parser(for: mime))
            let result = try await parser.parse(file: file, mimeType: mime, options: FixtureFactory.options(dir))
            #expect(result.suggestedTitle == "Linked Page")
            #expect(result.text.contains("ZEBRA-QUARTZ-7781"))
            #expect(result.metadata.contains { $0.key == "sourceURL" })
        }

        // A dead link still gives a document with the URL as text.
        let dead = dir.appendingPathComponent("dead.url")
        try Data("[InternetShortcut]\nURL=\(server.url("/gone").absoluteString)\n".utf8).write(to: dead)
        let result = try await URLShortcutParser().parse(file: dead, mimeType: FileTypeDetector.urlShortcut, options: FixtureFactory.options(dir))
        #expect(result.text.hasSuffix("/gone"))
        #expect(result.archiveFile == nil)
    }
}
