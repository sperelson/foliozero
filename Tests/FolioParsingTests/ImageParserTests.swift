import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import FolioParsing

@Suite("Image parser")
struct ImageParserTests {
    let dir: URL

    init() throws {
        dir = try FixtureFactory.makeDirectory("image")
    }

    func parse(_ url: URL, _ mime: String, _ options: ParseOptions? = nil) async throws -> ParseResult {
        try await ImageParser().parse(file: url, mimeType: mime, options: options ?? FixtureFactory.options(dir))
    }

    @Test func pngWithDPIGivesSearchableArchive() async throws {
        let url = dir.appendingPathComponent("scan.png")
        try FixtureFactory.writeImage(
            FixtureFactory.textImage(), type: .png, to: url,
            properties: [kCGImagePropertyDPIWidth: 200, kCGImagePropertyDPIHeight: 200]
        )
        let result = try await parse(url, "image/png")
        #expect(containsSampleWords(result.text), "got: \(result.text)")
        #expect(result.pageCount == 1)
        let archive = try #require(result.archiveFile)
        let document = try #require(PDFDocument(url: archive))
        #expect(containsSampleWords(document.string ?? ""))
        // 1700 x 2200 px at 200 DPI = 612 x 792 pt (US Letter).
        let bounds = try #require(document.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(bounds.width - 612) < 1 && abs(bounds.height - 792) < 1, "got \(bounds)")
        #expect(isJPEG(result.thumbnailFile))
        #expect(result.metadata.contains { $0.key == "pixelWidth" && $0.value == "1700" })
    }

    @Test func jpegIsEmbeddedUntouched() async throws {
        let url = dir.appendingPathComponent("photo.jpg")
        try FixtureFactory.writeImage(
            FixtureFactory.textImage(), type: .jpeg, to: url,
            properties: [kCGImageDestinationLossyCompressionQuality: 0.7]
        )
        let result = try await parse(url, "image/jpeg")
        let archive = try #require(result.archiveFile)
        let original = try Data(contentsOf: url)
        let archived = try Data(contentsOf: archive)
        #expect(archived.range(of: original.prefix(2048)) != nil, "original JPEG bytes should be in the archive")
        #expect(archived.count < original.count + 100_000)
        // No DPI metadata: 300 DPI default gives 1700 px = 408 pt.
        let bounds = try #require(PDFDocument(url: archive)?.page(at: 0)).bounds(for: .mediaBox)
        #expect(abs(bounds.width - 408) < 1, "got \(bounds)")
    }

    @Test func exifOrientationIsHonoured() async throws {
        // Store the pixels rotated 90 degrees clockwise and tag EXIF orientation 8 ("left")
        // so viewers rotate them back, as iPhone photos do.
        let url = dir.appendingPathComponent("iphone.jpg")
        let stored = FixtureFactory.rotate(FixtureFactory.textImage(), clockwise: 90)
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2024:03:15 09:30:00",
                                     kCGImagePropertyExifOffsetTimeOriginal: "+02:00"]
        try FixtureFactory.writeImage(stored, type: .jpeg, to: url, properties: [
            kCGImagePropertyOrientation: CGImagePropertyOrientation.left.rawValue,
            kCGImagePropertyExifDictionary: exif,
        ])
        let result = try await parse(url, "image/jpeg")
        #expect(containsSampleWords(result.text), "got: \(result.text)")
        let archive = try #require(result.archiveFile)
        let page = try #require(PDFDocument(url: archive)?.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)
        #expect(bounds.height > bounds.width, "upright page is portrait, got \(bounds)")
        let thumb = try #require(imageSize(result.thumbnailFile))
        #expect(thumb.height > thumb.width)
        let selection = try #require(PDFDocument(url: archive)?.findString("INVOICE", withOptions: .caseInsensitive).first)
        #expect(selection.bounds(for: page).minY > bounds.height * 0.7)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 2 * 3600)!
        let expected = calendar.date(from: DateComponents(year: 2024, month: 3, day: 15, hour: 9, minute: 30))
        #expect(result.metadataDate == expected)
        #expect(result.metadata.contains { $0.prefix == "exif" && $0.key == "DateTimeOriginal" })
    }

    @Test func multiPageTIFF() async throws {
        let url = dir.appendingPathComponent("two.tif")
        try FixtureFactory.writeMultiPageTIFF([
            FixtureFactory.textImage(["First page invoice", "Account 998877"]),
            FixtureFactory.textImage(["Second page receipt", "Reference 554433"]),
        ], to: url)
        let result = try await parse(url, "image/tiff")
        #expect(result.pageCount == 2)
        let lower = result.text.lowercased()
        #expect(lower.contains("998877") && lower.contains("554433"), "got: \(result.text)")
        #expect(lower.range(of: "998877")!.lowerBound < lower.range(of: "554433")!.lowerBound)
        let archive = try #require(result.archiveFile)
        #expect(PDFDocument(url: archive)?.pageCount == 2)
    }

    @Test func gifUsesFirstFrame() async throws {
        let url = dir.appendingPathComponent("scan.gif")
        try FixtureFactory.writeImage(FixtureFactory.textImage(), type: .gif, to: url)
        let result = try await parse(url, "image/gif")
        #expect(result.pageCount == 1)
        #expect(containsSampleWords(result.text), "got: \(result.text)")
    }

    @Test func offModeStillArchivesWithoutText() async throws {
        let url = dir.appendingPathComponent("scan.png")
        try FixtureFactory.writeImage(FixtureFactory.textImage(), type: .png, to: url)
        let result = try await parse(url, "image/png", FixtureFactory.options(dir, ocrMode: .off))
        #expect(result.text.isEmpty)
        let archive = try #require(result.archiveFile)
        let archiveText = pdfString(archive).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(archiveText.isEmpty)
    }

    @Test func neverModeHasNoArchive() async throws {
        let url = dir.appendingPathComponent("scan.png")
        try FixtureFactory.writeImage(FixtureFactory.textImage(), type: .png, to: url)
        let result = try await parse(url, "image/png", FixtureFactory.options(dir, archiveMode: .never))
        #expect(result.archiveFile == nil)
        #expect(containsSampleWords(result.text))
    }

    @Test func largeHEICParsesInSeconds() async throws {
        let url = dir.appendingPathComponent("photo.heic")
        let lines = FixtureFactory.sampleLines + ["Large photo of a receipt", "Thank you for shopping"]
        let image = FixtureFactory.textImage(lines, width: 4032, height: 3024, fontSize: 110)
        try FixtureFactory.writeImage(image, type: .heic, to: url, properties: [kCGImageDestinationLossyCompressionQuality: 0.8])
        let clock = ContinuousClock()
        var result: ParseResult?
        let elapsed = try await clock.measure {
            result = try await parse(url, "image/heic")
        }
        print("TIMING 4032x3024 HEIC: \(elapsed)")
        let parsed = try #require(result)
        #expect(containsSampleWords(parsed.text), "got: \(parsed.text)")
        let archive = try #require(parsed.archiveFile)
        let archiveSize = try Data(contentsOf: archive).count
        #expect(archiveSize < 4_000_000, "archive is \(archiveSize) bytes")
        #expect(try Data(contentsOf: archive).range(of: Data("DCTDecode".utf8)) != nil)
        #expect(elapsed < .seconds(30))
    }
}
