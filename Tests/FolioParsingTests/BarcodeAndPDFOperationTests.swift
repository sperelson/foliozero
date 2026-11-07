import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import FolioParsing

enum BarcodeFixtures {
    static func cgImage(_ image: CIImage, scale: CGFloat) -> CGImage {
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        return CIContext().createCGImage(scaled, from: scaled.extent)!
    }

    static func qr(_ text: String) -> CGImage {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        return cgImage(filter.outputImage!, scale: 8)
    }

    static func code128(_ text: String) -> CGImage {
        let filter = CIFilter.code128BarcodeGenerator()
        filter.message = Data(text.utf8)
        filter.quietSpace = 10
        return cgImage(filter.outputImage!, scale: 3)
    }

    /// A white letter-size page image (150 DPI) with `code` near the top left.
    static func page(with code: CGImage?) -> CGImage {
        let context = ImageUtilities.makeContext(width: 1275, height: 1650)!
        if let code {
            context.interpolationQuality = .none
            context.draw(code, in: CGRect(x: 100, y: 1650 - 100 - code.height, width: code.width, height: code.height))
        }
        return context.makeImage()!
    }

    /// PDF whose pages are images; nil entries are blank pages.
    static func pdf(_ codes: [CGImage?], to url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &box, nil)!
        for code in codes {
            context.beginPDFPage(nil)
            context.draw(page(with: code), in: box)
            context.endPDFPage()
        }
        context.closePDF()
    }
}

@Suite("Barcodes")
struct BarcodeTests {
    @Test func pdfPagesWithQRAndCode128() async throws {
        let dir = try FixtureFactory.makeDirectory("barcodes")
        let url = dir.appendingPathComponent("separated.pdf")
        try BarcodeFixtures.pdf([nil, BarcodeFixtures.qr("PATCHT"), BarcodeFixtures.code128("ASN00042"), nil], to: url)
        let found = try await BarcodeReader.detect(file: url, mimeType: "application/pdf", maxPages: 0, dpi: 300, upscale: 0)
        #expect(found == [
            DetectedBarcode(page: 1, value: "PATCHT", format: "QRCode"),
            DetectedBarcode(page: 2, value: "ASN00042", format: "Code128"),
        ])
        let limited = try await BarcodeReader.detect(file: url, mimeType: "application/pdf", maxPages: 2, dpi: 150, upscale: 0)
        #expect(limited.map(\.value) == ["PATCHT"])
    }

    @Test func tiffFramesAndImages() async throws {
        let dir = try FixtureFactory.makeDirectory("barcodes")
        let tiff = dir.appendingPathComponent("scan.tif")
        try FixtureFactory.writeMultiPageTIFF([
            BarcodeFixtures.page(with: nil),
            BarcodeFixtures.page(with: BarcodeFixtures.qr("TAG:invoices")),
        ], to: tiff)
        let frames = try await BarcodeReader.detect(file: tiff, mimeType: "image/tiff", maxPages: 0, dpi: 300, upscale: 0)
        #expect(frames == [DetectedBarcode(page: 1, value: "TAG:invoices", format: "QRCode")])

        let png = dir.appendingPathComponent("code.png")
        try FixtureFactory.writeImage(BarcodeFixtures.page(with: BarcodeFixtures.code128("ASN1234")), type: .png, to: png)
        let image = try await BarcodeReader.detect(file: png, mimeType: "image/png", maxPages: 0, dpi: 300, upscale: 1.5)
        #expect(image == [DetectedBarcode(page: 0, value: "ASN1234", format: "Code128")])

        await #expect(throws: ParserError.self) {
            _ = try await BarcodeReader.detect(file: png, mimeType: "text/plain", maxPages: 0, dpi: 300, upscale: 0)
        }
    }
}

@Suite("PDF operations")
struct PDFOperationTests {
    let dir: URL
    let source: URL

    init() throws {
        dir = try FixtureFactory.makeDirectory("pdfops")
        source = dir.appendingPathComponent("four.pdf")
        try FixtureFactory.bornDigitalPDF(pages: (1...4).map { ["Page marker \($0)"] }, to: source)
    }

    func markers(_ url: URL) -> [Int] {
        guard let document = PDFDocument(url: url) else { return [] }
        return (0..<document.pageCount).compactMap { index in
            document.page(at: index)?.string?
                .components(separatedBy: "Page marker ").dropFirst().first
                .flatMap { Int($0.prefix { $0.isNumber }) }
        }
    }

    func rotations(_ url: URL) -> [Int] {
        guard let document = PDFDocument(url: url) else { return [] }
        return (0..<document.pageCount).compactMap { document.page(at: $0)?.rotation }
    }

    @Test func rotateDeleteEditReorder() throws {
        let original = try Data(contentsOf: source)
        let out = dir.appendingPathComponent("out", isDirectory: true)

        let rotated = try PDFOperations.rotate(source, pages: [2, 4], degrees: 90, outputDirectory: out)
        #expect(rotations(rotated) == [0, 90, 0, 90])
        #expect(markers(rotated) == [1, 2, 3, 4])
        let all = try PDFOperations.rotate(rotated, degrees: -90, outputDirectory: out)
        #expect(rotations(all) == [270, 0, 270, 0])

        let deleted = try PDFOperations.deletePages(source, pages: [1, 3], outputDirectory: out)
        #expect(markers(deleted) == [2, 4])

        let edited = try PDFOperations.editPages(source, specs: [.init(page: 3, rotation: 180), .init(page: 1), .init(page: 1, rotation: 90)], outputDirectory: out)
        #expect(markers(edited) == [3, 1, 1])
        #expect(rotations(edited) == [180, 0, 90])

        let reordered = try PDFOperations.reorder(source, order: [4, 3, 2, 1], outputDirectory: out)
        #expect(markers(reordered) == [4, 3, 2, 1])

        #expect(try Data(contentsOf: source) == original, "inputs are never modified")
        #expect(throws: PDFOperations.OperationError.pageOutOfRange(page: 5, pageCount: 4)) {
            try PDFOperations.deletePages(source, pages: [5], outputDirectory: out)
        }
        #expect(throws: PDFOperations.OperationError.noPages) {
            try PDFOperations.deletePages(source, pages: [1, 2, 3, 4], outputDirectory: out)
        }
        #expect(throws: PDFOperations.OperationError.invalidRotation(45)) {
            try PDFOperations.rotate(source, degrees: 45, outputDirectory: out)
        }
    }

    @Test func mergeAndSplit() throws {
        let other = dir.appendingPathComponent("two.pdf")
        try FixtureFactory.bornDigitalPDF(pages: [["Page marker 7"], ["Page marker 8"]], to: other)
        let out = dir.appendingPathComponent("out", isDirectory: true)

        let merged = try PDFOperations.merge([source, other], outputDirectory: out)
        #expect(markers(merged) == [1, 2, 3, 4, 7, 8])
        #expect(PDFDocument(url: merged)?.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String == "Quarterly Report")

        let parts = try PDFOperations.split(source, pageGroups: [[1, 2], [3], [4, 1]], outputDirectory: out)
        #expect(parts.map(markers) == [[1, 2], [3], [4, 1]])
        let ranges = try PDFOperations.split(source, ranges: [1...3, 4...4], outputDirectory: out)
        #expect(ranges.map(markers) == [[1, 2, 3], [4]])
        #expect(Set(parts + ranges).count == 5, "every output has its own file")
    }

    @Test func removePassword() throws {
        let locked = dir.appendingPathComponent("locked.pdf")
        try FixtureFactory.bornDigitalPDF(pages: [["Page marker 1"], ["Page marker 2"]], to: locked, userPassword: "s3cret")
        let out = dir.appendingPathComponent("out", isDirectory: true)
        #expect(try PDFOperations.removePassword(locked, passwords: ["wrong"], outputDirectory: out) == nil)
        let unlocked = try #require(try PDFOperations.removePassword(locked, passwords: ["wrong", "s3cret"], outputDirectory: out))
        let document = try #require(PDFDocument(url: unlocked))
        #expect(!document.isEncrypted)
        #expect(markers(unlocked) == [1, 2])
        #expect(throws: PDFOperations.OperationError.locked("locked.pdf")) {
            try PDFOperations.rotate(locked, degrees: 90, outputDirectory: out)
        }
        let rotated = try PDFOperations.rotate(locked, degrees: 90, outputDirectory: out, passwords: ["s3cret"])
        #expect(PDFDocument(url: rotated)?.isEncrypted == false)
    }

    @Test func doubleSidedCollation() throws {
        let odd = dir.appendingPathComponent("odd.pdf")
        let even = dir.appendingPathComponent("even.pdf")
        try FixtureFactory.bornDigitalPDF(pages: [["Page marker 1"], ["Page marker 3"], ["Page marker 5"]], to: odd)
        // The scanner feeds the stack back to front for the even side.
        try FixtureFactory.bornDigitalPDF(pages: [["Page marker 6"], ["Page marker 4"], ["Page marker 2"]], to: even)
        let out = dir.appendingPathComponent("out", isDirectory: true)
        let collated = try PDFOperations.collateDoubleSided(odd: odd, even: even, outputDirectory: out)
        #expect(markers(collated) == [1, 2, 3, 4, 5, 6])

        let shortEven = dir.appendingPathComponent("short-even.pdf")
        try FixtureFactory.bornDigitalPDF(pages: [["Page marker 4"], ["Page marker 2"]], to: shortEven)
        #expect(markers(try PDFOperations.collateDoubleSided(odd: odd, even: shortEven, outputDirectory: out)) == [1, 2, 3, 4, 5])

        #expect(throws: PDFOperations.OperationError.evenHasMorePages(odd: 2, even: 3)) {
            try PDFOperations.collateDoubleSided(odd: shortEven, even: even, outputDirectory: out)
        }
    }
}
