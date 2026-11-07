import CoreGraphics
import CoreImage
import CoreText
import Foundation
import GRDB
import Testing
@testable import FolioCore

/// A PDF whose pages each show text and, optionally, a QR code.
func makePDF(pages: [(text: String, qr: String?)], at url: URL) {
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    let ciContext = CIContext()
    for page in pages {
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(box)
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: page.text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font]))
        context.textPosition = CGPoint(x: 60, y: 760)
        CTLineDraw(line, context)
        if let value = page.qr, let filter = CIFilter(name: "CIQRCodeGenerator") {
            filter.setValue(Data(value.utf8), forKey: "inputMessage")
            filter.setValue("M", forKey: "inputCorrectionLevel")
            if let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
               let image = ciContext.createCGImage(output, from: output.extent) {
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 60, y: 300, width: 250, height: 250))
            }
        }
        context.endPDFPage()
    }
    context.closePDF()
}

@Suite(.serialized) struct ConsumerFormatsTests {
    func makeApp(_ dir: TempDir, _ overrides: [String: String] = [:]) throws -> FolioApp {
        let settings = try SettingsLoader.load(home: dir.url.path, environment: [:], overrides: ["TIME_ZONE": "UTC"].merging(overrides) { _, n in n })
        return try FolioApp.open(settings: settings)
    }

    @Test func separatorBarcodeSplitsDocument() async throws {
        let dir = TempDir()
        let app = try makeApp(dir, ["CONSUMER_ENABLE_BARCODES": "true", "CONSUMER_STORE_BARCODE_VALUES": "true"])
        let file = dir.file("batch.pdf")
        makePDF(pages: [("First letter page one", nil), ("First letter page two", nil), ("separator", "PATCHT"), ("Second letter", nil)], at: file)
        let first = try await app.consumer().consume(ConsumeRequest(file: file, source: .consumeFolder))
        let documents = try await app.database.read { db in try Document.order(Column("id")).fetchAll(db) }
        #expect(documents.count == 2)
        #expect(first.id == documents.first?.id)
        #expect(documents.map(\.pageCount) == [2, 1])
        #expect(documents[0].originalFilename == "batch_01.pdf")
        #expect(documents[1].content.contains("Second letter"))
    }

    @Test func asnAndTagBarcodes() async throws {
        let dir = TempDir()
        let app = try makeApp(dir, ["CONSUMER_ENABLE_ASN_BARCODE": "true", "CONSUMER_ENABLE_TAG_BARCODE": "true", "CONSUMER_STORE_BARCODE_VALUES": "true"])
        let file = dir.file("labelled.pdf")
        makePDF(pages: [("Contract", "ASN00042"), ("Signature page", "TAG:Contracts")], at: file)
        let document = try await app.consumer().consume(ConsumeRequest(file: file, source: .consumeFolder))
        #expect(document.archiveSerialNumber == 42)
        let (tags, codes) = try await app.database.read { db in
            (try DocumentStore.tags(of: document.id!, in: db).map(\.name), try DocumentBarcode.fetchAll(db))
        }
        #expect(tags == ["Contracts"])
        #expect(codes.map(\.value).sorted() == ["ASN00042", "TAG:Contracts"])
        #expect(codes.first { $0.value == "ASN00042" }?.page == 1)
    }

    @Test func doubleSidedCollation() async throws {
        let dir = TempDir()
        let app = try makeApp(dir, ["CONSUMER_ENABLE_COLLATE_DOUBLE_SIDED": "true"])
        let folder = app.settings.consumptionDir.appendingPathComponent("double-sided", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let odd = folder.appendingPathComponent("odd.pdf")
        makePDF(pages: [("Page one", nil), ("Page three", nil)], at: odd)
        await #expect(throws: ConsumeStopped.self) {
            try await app.consumer().consume(ConsumeRequest(file: odd, source: .consumeFolder, deleteSource: true))
        }
        let even = folder.appendingPathComponent("even.pdf")
        makePDF(pages: [("Page four", nil), ("Page two", nil)], at: even)
        let document = try await app.consumer().consume(ConsumeRequest(file: even, source: .consumeFolder, deleteSource: true))
        #expect(document.pageCount == 4)
        let order = ["one", "two", "three", "four"].map { document.content.range(of: "Page \($0)")?.lowerBound }
        #expect(order.allSatisfy { $0 != nil })
        #expect(zip(order, order.dropFirst()).allSatisfy { $0! < $1! })
    }

    @Test func emailFileUsesSubjectAsTitle() async throws {
        let dir = TempDir()
        let app = try makeApp(dir)
        let eml = dir.file("message.eml")
        try """
        From: Rates Office <rates@city.example>
        To: me@example.com
        Subject: =?UTF-8?B?UmF0ZXMgc3RhdGVtZW50IOKAkyBNw6RyeiAyMDI2?=
        Date: Tue, 03 Mar 2026 10:00:00 +0200
        MIME-Version: 1.0
        Content-Type: text/plain; charset=utf-8

        Your municipal rates statement is attached.
        """.replacingOccurrences(of: "\n", with: "\r\n").write(to: eml, atomically: false, encoding: .utf8)
        let document = try await app.consumer().consume(ConsumeRequest(file: eml, source: .mailFetch))
        #expect(document.mimeType == "message/rfc822")
        #expect(document.title == "Rates statement – März 2026")
        #expect(document.content.contains("municipal rates statement"))
        #expect(document.created == CalendarDate(year: 2026, month: 3, day: 3))
    }

    @Test func capturesLocalWebPage() async throws {
        let dir = TempDir()
        let app = try makeApp(dir)
        let html = dir.file("page.html")
        try "<html><head><title>Load shedding schedule</title></head><body><h1>Stage 2</h1><p>Cape Town area 7, 14 March 2026.</p></body></html>"
            .write(to: html, atomically: false, encoding: .utf8)
        let document = try await URLCapture.consume(url: html, app: app)
        #expect(document.title == "Load shedding schedule")
        #expect(document.content.contains("Stage 2"))
        #expect(document.archiveFilename != nil)
    }
}
