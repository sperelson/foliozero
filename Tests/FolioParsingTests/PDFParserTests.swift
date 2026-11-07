import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
@testable import FolioParsing

let bornDigitalPages = [
    ["Quarterly report for the finance team", "Revenue grew by twelve percent this quarter", "Born digital text layer"],
    ["Second page talks about expenses", "Travel and equipment costs were stable"],
]

func pdfString(_ url: URL) -> String {
    PDFDocument(url: url)?.string ?? ""
}

func isJPEG(_ url: URL) -> Bool {
    guard let data = try? Data(contentsOf: url) else { return false }
    return data.starts(with: [0xFF, 0xD8, 0xFF])
}

func imageSize(_ url: URL) -> CGSize? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return ImageUtilities.pixelSize(properties: ImageUtilities.properties(of: source, at: 0))
}

@Suite("PDF parser")
struct PDFParserTests {
    let dir: URL

    init() throws {
        dir = try FixtureFactory.makeDirectory("pdf")
    }

    func bornDigital(_ name: String = "digital.pdf") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FixtureFactory.bornDigitalPDF(pages: bornDigitalPages, to: url)
        return url
    }

    func scanned(_ name: String = "scan.pdf", pages: Int = 1, rotation: Int = 0) throws -> URL {
        let url = dir.appendingPathComponent(name)
        let images = (0..<pages).map { index in
            FixtureFactory.rotate(
                FixtureFactory.textImage(FixtureFactory.sampleLines + ["Page number \(index + 1)"]),
                clockwise: rotation
            )
        }
        try FixtureFactory.scannedPDF(images: images, to: url)
        return url
    }

    @Test func bornDigitalAutoUsesEmbeddedTextWithoutArchive() async throws {
        let options = FixtureFactory.options(dir)
        let result = try await PDFParser().parse(file: bornDigital(), mimeType: "application/pdf", options: options)
        #expect(result.text.contains("Revenue grew by twelve percent this quarter"))
        #expect(result.text.contains("Travel and equipment costs were stable"))
        #expect(result.archiveFile == nil)
        #expect(result.pageCount == 2)
        #expect(result.suggestedTitle == "Quarterly Report")
        #expect(result.metadataDate != nil)
        #expect(result.language == "en")
        #expect(isJPEG(result.thumbnailFile))
        let size = try #require(imageSize(result.thumbnailFile))
        #expect(Int(max(size.width, size.height)) == options.thumbnailMaxPixels)

        let keys = Dictionary(result.metadata.map { ("\($0.prefix):\($0.key)", $0.value) }, uniquingKeysWith: { a, _ in a })
        #expect(keys["dc:title"] == "Quarterly Report")
        #expect(keys["dc:creator"] == "Jane Example")
        #expect(keys["xmp:CreatorTool"] == "FolioParsingTests")
        #expect(keys["foliozero:pageCount"] == "2")
        #expect(keys["foliozero:encrypted"] == "false")
        #expect(keys["pdf:PDFVersion"] != nil)
        #expect(keys["xmp:CreateDate"] != nil)
    }

    @Test func scannedAutoProducesSearchableArchive() async throws {
        let result = try await PDFParser().parse(file: scanned(), mimeType: "application/pdf", options: FixtureFactory.options(dir))
        #expect(containsSampleWords(result.text), "got: \(result.text)")
        let archive = try #require(result.archiveFile)
        let archived = try #require(PDFDocument(url: archive))
        #expect(archived.pageCount == 1)
        #expect(containsSampleWords(archived.string ?? ""), "archive text: \(archived.string ?? "")")
        #expect(archived.documentAttributes?[PDFDocumentAttribute.creatorAttribute] as? String == "FolioZero")
        // Auto mode keeps the original page as vector content: the archive is about the size of the input.
        let original = try Data(contentsOf: dir.appendingPathComponent("scan.pdf")).count
        let archiveSize = try Data(contentsOf: archive).count
        #expect(archiveSize < original * 2 + 50_000)
        // The text layer is invisible: rendering the archive looks like the original.
        let page = try #require(archived.page(at: 0))
        let selection = try #require(archived.findString("INVOICE", withOptions: .caseInsensitive).first)
        let bounds = selection.bounds(for: page)
        #expect(bounds.minY > page.bounds(for: .cropBox).height * 0.7, "INVOICE should be near the top, got \(bounds)")
    }

    @Test func scannedOffModeHasNoTextAndNoArchive() async throws {
        let result = try await PDFParser().parse(
            file: scanned(), mimeType: "application/pdf",
            options: FixtureFactory.options(dir, ocrMode: .off)
        )
        #expect(result.text.isEmpty)
        #expect(result.archiveFile == nil)
        #expect(isJPEG(result.thumbnailFile))
    }

    @Test func forceRasterisesAndIgnoresExistingText() async throws {
        let result = try await PDFParser().parse(
            file: bornDigital(), mimeType: "application/pdf",
            options: FixtureFactory.options(dir, ocrMode: .force)
        )
        let lower = result.text.lowercased()
        #expect(lower.contains("revenue") && lower.contains("expenses"), "got: \(result.text)")
        let archive = try #require(result.archiveFile)
        let data = try Data(contentsOf: archive)
        #expect(data.range(of: Data("DCTDecode".utf8)) != nil, "force mode pages are JPEG images")
        #expect(pdfString(archive).lowercased().contains("revenue"))
        #expect(PDFDocument(url: archive)?.pageCount == 2)
    }

    @Test func redoReplacesTextLayer() async throws {
        let result = try await PDFParser().parse(
            file: scanned(), mimeType: "application/pdf",
            options: FixtureFactory.options(dir, ocrMode: .redo)
        )
        #expect(containsSampleWords(result.text))
        let archive = try #require(result.archiveFile)
        #expect(containsSampleWords(pdfString(archive)))
    }

    @Test func neverModeSkipsArchiveEvenWhenOCRing() async throws {
        let result = try await PDFParser().parse(
            file: scanned(), mimeType: "application/pdf",
            options: FixtureFactory.options(dir, ocrMode: .force, archiveMode: .never)
        )
        #expect(containsSampleWords(result.text))
        #expect(result.archiveFile == nil)
    }

    @Test func alwaysModeCopiesBornDigitalPagesAsVectors() async throws {
        let result = try await PDFParser().parse(
            file: bornDigital(), mimeType: "application/pdf",
            options: FixtureFactory.options(dir, ocrMode: .off, archiveMode: .always)
        )
        let archive = try #require(result.archiveFile)
        let text = pdfString(archive)
        #expect(text.contains("Revenue grew by twelve percent this quarter"))
        let data = try Data(contentsOf: archive)
        #expect(data.range(of: Data("DCTDecode".utf8)) == nil, "vector pages need no images")
    }

    @Test func ocrPagesLimitsOCR() async throws {
        let result = try await PDFParser().parse(
            file: scanned(pages: 2), mimeType: "application/pdf",
            options: FixtureFactory.options(dir, ocrPages: 1)
        )
        #expect(result.text.contains("1"))
        #expect(result.text.lowercased().contains("page number 1"))
        #expect(!result.text.lowercased().contains("page number 2"))
        #expect(result.pageCount == 2)
    }

    @Test func encryptedWithoutPasswordReturnsEmptyText() async throws {
        let url = dir.appendingPathComponent("locked.pdf")
        try FixtureFactory.bornDigitalPDF(pages: bornDigitalPages, to: url, userPassword: "secret")
        let result = try await PDFParser().parse(file: url, mimeType: "application/pdf", options: FixtureFactory.options(dir))
        #expect(result.text.isEmpty)
        #expect(result.archiveFile == nil)
        #expect(isJPEG(result.thumbnailFile))
        #expect(result.metadata.contains { $0.key == "encrypted" && $0.value == "true" })
        #expect(result.metadata.contains { $0.key == "locked" && $0.value == "true" })
    }

    @Test func encryptedWithPasswordIsReadable() async throws {
        let url = dir.appendingPathComponent("locked.pdf")
        try FixtureFactory.bornDigitalPDF(pages: bornDigitalPages, to: url, userPassword: "secret")
        let result = try await PDFParser().parse(
            file: url, mimeType: "application/pdf",
            options: FixtureFactory.options(dir, archiveMode: .always, passwords: ["wrong", "secret"])
        )
        #expect(result.text.contains("Revenue grew by twelve percent this quarter"))
        #expect(result.metadata.contains { $0.key == "encrypted" && $0.value == "true" })
        #expect(!result.metadata.contains { $0.key == "locked" })
        // The archive is written without encryption.
        let archive = try #require(result.archiveFile)
        let archived = try #require(PDFDocument(url: archive))
        #expect(!archived.isEncrypted)
        #expect((archived.string ?? "").contains("Revenue grew"))
    }

    @Test func sidewaysScanIsRotatedInArchive() async throws {
        let result = try await PDFParser().parse(
            file: scanned("sideways.pdf", rotation: 90), mimeType: "application/pdf",
            options: FixtureFactory.options(dir)
        )
        #expect(containsSampleWords(result.text), "got: \(result.text)")
        let archive = try #require(result.archiveFile)
        let page = try #require(PDFDocument(url: archive)?.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        #expect(bounds.height > bounds.width, "archive page should be portrait after rotation, got \(bounds)")
        let thumb = try #require(imageSize(result.thumbnailFile))
        #expect(thumb.height > thumb.width)
    }

    @Test(.enabled(if: ToolLocator.find("gs") != nil, "Ghostscript is not installed"))
    func pdfAConversion() async throws {
        let result = try await PDFParser().parse(
            file: scanned(), mimeType: "application/pdf",
            options: FixtureFactory.options(dir, pdfA: true)
        )
        let archive = try #require(result.archiveFile)
        let data = try Data(contentsOf: archive)
        #expect(data.range(of: Data("pdfaid".utf8)) != nil, "XMP declares PDF/A conformance")
        // Keep the document alive: the catalog pointer is not retained.
        let document = try #require(CGPDFDocument(archive as CFURL))
        let catalog = try #require(document.catalog)
        var intents: CGPDFArrayRef?
        let hasIntents = CGPDFDictionaryGetArray(catalog, "OutputIntents", &intents)
        #expect(hasIntents, "PDF/A needs an output intent")
        // The text layer survives Ghostscript (see ArchivePDFBuilder.textLayerFontName).
        #expect(containsSampleWords(pdfString(archive)), "archive text: \(pdfString(archive))")
    }

    @Test func unreadableFileThrows() async throws {
        let url = dir.appendingPathComponent("broken.pdf")
        try Data("%PDF-1.7 this is not really a pdf".utf8).write(to: url)
        await #expect(throws: ParserError.self) {
            _ = try await PDFParser().parse(file: url, mimeType: "application/pdf", options: FixtureFactory.options(dir))
        }
    }

    @Test func tenPageScanParsesInSeconds() async throws {
        let url = try scanned("ten.pdf", pages: 10)
        let clock = ContinuousClock()
        var result: ParseResult?
        let elapsed = try await clock.measure {
            result = try await PDFParser().parse(file: url, mimeType: "application/pdf", options: FixtureFactory.options(dir))
        }
        let parsed = try #require(result)
        print("TIMING 10-page scanned PDF: \(elapsed)")
        #expect(parsed.pageCount == 10)
        #expect(parsed.text.lowercased().contains("page number 10"))
        #expect(PDFDocument(url: try #require(parsed.archiveFile))?.pageCount == 10)
        #expect(elapsed < .seconds(60))
    }
}
