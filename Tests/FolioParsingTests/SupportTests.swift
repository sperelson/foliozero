import CoreGraphics
import CoreText
import Foundation
import PDFKit
import Testing
@testable import FolioParsing

@Suite("Text parser")
struct TextParserTests {
    let dir: URL

    init() throws {
        dir = try FixtureFactory.makeDirectory("text")
    }

    @Test func utf8TextWithThumbnail() async throws {
        let url = dir.appendingPathComponent("note.txt")
        try Data("Grüße aus Kapstadt\nSecond line with enough words to detect the language properly.\n".utf8).write(to: url)
        let result = try await TextParser().parse(file: url, mimeType: "text/plain", options: FixtureFactory.options(dir))
        #expect(result.text.hasPrefix("Grüße aus Kapstadt"))
        #expect(result.archiveFile == nil)
        #expect(result.pageCount == nil)
        #expect(isJPEG(result.thumbnailFile))
        let size = try #require(imageSize(result.thumbnailFile))
        #expect(Int(size.height) == 500 && size.width < size.height)
        #expect(result.metadata.contains { $0.key == "encoding" && $0.value == "utf-8" })
    }

    @Test func windows1252Fallback() async throws {
        let url = dir.appendingPathComponent("latin.csv")
        let bytes: [UInt8] = Array("name;price\nCaf".utf8) + [0xE9] + Array(";".utf8) + [0x80] + Array("5\n".utf8)
        try Data(bytes).write(to: url)
        let result = try await TextParser().parse(file: url, mimeType: "text/csv", options: FixtureFactory.options(dir))
        #expect(result.text == "name;price\nCafé;€5\n")
    }

    @Test func utf16WithBOMAndNULRemoval() async throws {
        let url = dir.appendingPathComponent("wide.txt")
        var data = Data([0xFF, 0xFE])
        data.append("Hello\u{0} UTF-16".data(using: .utf16LittleEndian)!)
        try data.write(to: url)
        let result = try await TextParser().parse(file: url, mimeType: "text/plain", options: FixtureFactory.options(dir))
        #expect(result.text == "Hello UTF-16")
    }

    @Test func markdownTitle() async throws {
        let url = dir.appendingPathComponent("readme.md")
        try Data("Intro\n\n# Project Plan\n\nBody".utf8).write(to: url)
        let result = try await TextParser().parse(file: url, mimeType: "text/markdown", options: FixtureFactory.options(dir))
        #expect(result.suggestedTitle == "Project Plan")
    }
}

@Suite("Support")
struct SupportTests {
    @Test func postProcessMatchesPaperless() {
        #expect(TextNormalizer.postProcess("  Hello   world \t\n   next\u{0}line  \r\n\r\nend  ") == "Hello world\nnext line\n\nend")
        #expect(TextNormalizer.postProcess("\n\n  \n") == "")
        #expect(TextNormalizer.postProcess("a\u{0C}b") == "a b")
        #expect(TextNormalizer.nonWhitespaceCount(" a b\n c ") == 3)
    }

    @Test func registryChoosesParsers() {
        let registry = StandardParsers.makeRegistry()
        #expect(registry.parser(for: "application/pdf")?.name == "pdf")
        #expect(registry.parser(for: "image/heic")?.name == "image")
        #expect(registry.parser(for: "text/markdown")?.name == "text")
        #expect(registry.parser(for: "application/zip") == nil)
        #expect(registry.supportedMIMETypes["image/tiff"] == ".tif")
    }

    @Test func processRunnerCapturesOutput() async throws {
        let result = try await ProcessRunner.run(
            URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "echo out; echo err >&2; cat; exit 3"],
            standardInput: Data("piped".utf8)
        )
        #expect(result.exitCode == 3)
        #expect(result.outputString == "out\npiped")
        #expect(result.errorString == "err\n")
        #expect(!result.timedOut)
    }

    @Test func processRunnerTimesOut() async throws {
        let clock = ContinuousClock()
        let start = clock.now
        let result = try await ProcessRunner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"], timeout: .milliseconds(300))
        #expect(result.timedOut)
        #expect(!result.succeeded)
        #expect(clock.now - start < .seconds(10))
    }

    @Test func processRunnerLaunchFailure() async {
        await #expect(throws: ProcessRunnerError.self) {
            _ = try await ProcessRunner.run(URL(fileURLWithPath: "/nonexistent/tool"), arguments: [])
        }
    }

    @Test func toolLocator() {
        #expect(ToolLocator.find("sh")?.path == "/bin/sh")
        #expect(ToolLocator.find("definitely-not-a-tool-\(UUID().uuidString)") == nil)
        #expect(ToolLocator.find("whatever", explicitPath: "/bin/sh")?.path == "/bin/sh")
        #expect(ToolLocator.find("sh", explicitPath: "/nonexistent/sh")?.path == "/bin/sh")
    }

    @Test func orientationTransforms() {
        let raw = CGSize(width: 200, height: 100)
        // Raw top-left corner (0, 100 in y-up space) goes to the top-right after 90 degrees clockwise.
        let r90 = ImageOrientation(rotation: 90)
        #expect(r90.orientedSize(raw) == CGSize(width: 100, height: 200))
        #expect(CGPoint(x: 0, y: 100).applying(r90.drawingTransform(rawSize: raw)) == CGPoint(x: 100, y: 200))
        let r270 = ImageOrientation(rotation: 270)
        #expect(CGPoint(x: 0, y: 100).applying(r270.drawingTransform(rawSize: raw)) == CGPoint(x: 0, y: 0))
        let mirrored = ImageOrientation(.upMirrored)
        #expect(CGPoint(x: 0, y: 100).applying(mirrored.drawingTransform(rawSize: raw)) == CGPoint(x: 200, y: 100))
        for exif: CGImagePropertyOrientation in [.up, .upMirrored, .down, .downMirrored, .left, .leftMirrored, .right, .rightMirrored] {
            #expect(ImageOrientation(exif).exifOrientation == exif)
        }
        #expect(ImageOrientation(rotation: 270).rotated(byClockwise: 180).rotation == 90)
    }

    @Test func exifDates() {
        let date = ImageMetadata.parseEXIFDate("2023:12:31 23:59:58", offset: "-05:00")
        #expect(date == Date(timeIntervalSince1970: 1_704_085_198))
        #expect(ImageMetadata.parseEXIFDate("0000:00:00 00:00:00") == nil)
        #expect(ImageMetadata.parseEXIFDate("garbage") == nil)
    }

    @Test func titleHeuristics() {
        #expect(TitleHeuristics.meaningfulTitle("  Annual Report 2025 ") == "Annual Report 2025")
        #expect(TitleHeuristics.meaningfulTitle("Microsoft Word - Offer Letter.docx") == nil)
        #expect(TitleHeuristics.meaningfulTitle("Microsoft Word - Offer Letter") == "Offer Letter")
        #expect(TitleHeuristics.meaningfulTitle("untitled") == nil)
        #expect(TitleHeuristics.meaningfulTitle("scan0001.pdf") == nil)
        #expect(TitleHeuristics.meaningfulTitle("C:\\Users\\x\\doc") == nil)
        #expect(TitleHeuristics.meaningfulTitle("12345") == nil)
        #expect(TitleHeuristics.meaningfulTitle(nil) == nil)
    }

    @Test func xmpReader() {
        let xmp = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:dc="http://purl.org/dc/elements/1.1/"
              xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmp:CreateDate="2024-01-02T03:04:05Z">
           <dc:format>application/pdf</dc:format>
           <dc:title><rdf:Alt><rdf:li xml:lang="x-default">Hello XMP</rdf:li></rdf:Alt></dc:title>
           <dc:creator><rdf:Seq><rdf:li>Ann</rdf:li><rdf:li>Bob</rdf:li></rdf:Seq></dc:creator>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        """
        let entries = XMPReader.entries(from: Data(xmp.utf8))
        let map = Dictionary(entries.map { ("\($0.prefix):\($0.key)", $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(map["dc:format"] == "application/pdf")
        #expect(map["dc:title"] == "Hello XMP")
        #expect(map["dc:creator"] == "Ann, Bob")
        #expect(map["xmp:CreateDate"] == "2024-01-02T03:04:05Z")
        #expect(entries.first { $0.key == "title" }?.namespace == "http://purl.org/dc/elements/1.1/")
    }
}

@Suite("Archive and thumbnails")
struct ArchiveAndThumbnailTests {
    @Test func invisibleTextLayerIsExtractableButNotVisible() throws {
        let dir = try FixtureFactory.makeDirectory()
        let url = dir.appendingPathComponent("layer.pdf")
        let blank = ImageUtilities.makeContext(width: 850, height: 1100)!.makeImage()!
        let lines = [
            OCRLine(text: "Hidden searchable words", boundingBox: CGRect(x: 0.1, y: 0.1, width: 0.6, height: 0.03), confidence: 1),
            OCRLine(text: "Second hidden line", boundingBox: CGRect(x: 0.1, y: 0.5, width: 0.4, height: 0.03), confidence: 1),
        ]
        let builder = ArchivePDFBuilder(title: "Layer Test")
        try builder.write(pages: [
            .init(content: .image(blank, lossless: false), size: CGSize(width: 612, height: 792), lines: lines),
        ], to: url)

        let document = try #require(PDFDocument(url: url))
        let text = document.string ?? ""
        #expect(text.contains("Hidden searchable words"))
        #expect(text.contains("Second hidden line"))
        #expect(document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Layer Test")
        #expect(document.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String == "FolioZero")

        let page = try #require(document.page(at: 0))
        let selection = try #require(document.findString("searchable", withOptions: []).first)
        let bounds = selection.bounds(for: page)
        #expect(bounds.minY > 792 * 0.85 && bounds.maxY < 792 * 0.91, "line box should map to the top area, got \(bounds)")

        let rendered = try #require(PDFUtilities.render(page, dpi: 72, gray: true))
        let context = ImageUtilities.makeContext(width: rendered.width, height: rendered.height, gray: true)!
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
        let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
        var dark = 0
        for y in 0..<rendered.height {
            for x in 0..<rendered.width where pixels[y * context.bytesPerRow + x] < 200 { dark += 1 }
        }
        #expect(dark == 0, "text layer must be invisible, found \(dark) dark pixels")
    }

    @Test func thumbnailsFitMaxPixels() async throws {
        let text = try #require(ThumbnailRenderer.image(fromText: String(repeating: "line\n", count: 200), maxPixels: 400))
        #expect(text.height == 400 && text.width < 400)
        let placeholder = ThumbnailRenderer.placeholder(label: "DOCX", maxPixels: 300)
        #expect(placeholder.height == 300)
        let photo = FixtureFactory.textImage(["Wide"], width: 2000, height: 1000, fontSize: 80)
        let small = try #require(ThumbnailRenderer.image(fromImage: photo, maxPixels: 500))
        #expect(small.width == 500 && small.height == 250)
    }

    @Test func genericThumbnailFallsBack() async throws {
        let dir = try FixtureFactory.makeDirectory()
        let url = dir.appendingPathComponent("blob.qqq")
        try Data((0..<1000).map { UInt8($0 % 251) }).write(to: url)
        let image = await ThumbnailRenderer.genericImage(for: url, maxPixels: 256, timeout: .seconds(10))
        #expect(max(image.width, image.height) <= 256)
        let written = try await ThumbnailRenderer.writeGeneric(for: url, to: dir, maxPixels: 256)
        #expect(isJPEG(written))
    }
}
