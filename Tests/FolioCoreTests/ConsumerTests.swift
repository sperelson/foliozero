import CoreGraphics
import CoreText
import Foundation
import GRDB
import Testing
@testable import FolioCore

/// Writes a one-page PDF with real (selectable) text.
func makeTextPDF(_ text: String, at url: URL) {
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let path = CGPath(rect: box.insetBy(dx: 50, dy: 50), transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    CTFrameDraw(frame, context)
    context.endPDFPage()
    context.closePDF()
}

@Suite(.serialized) struct ConsumerTests {
    func makeApp(_ dir: TempDir, overrides: [String: String] = [:]) throws -> FolioApp {
        var values = ["TIME_ZONE": "UTC"]
        values.merge(overrides) { _, new in new }
        let settings = try SettingsLoader.load(home: dir.url.path, environment: [:], overrides: values)
        return try FolioApp.open(settings: settings)
    }

    @Test func consumesBornDigitalPDF() async throws {
        let dir = TempDir()
        let app = try makeApp(dir)
        try await app.database.write { db in
            var acme = Correspondent(name: "Acme", match: "acme", matchingAlgorithm: .any)
            try acme.insert(db)
            var inbox = Tag(name: "Inbox", isInboxTag: true)
            try inbox.insert(db)
            var invoices = DocumentType(name: "Invoice", match: "invoice number", matchingAlgorithm: .literal)
            try invoices.insert(db)
        }
        let source = dir.file("acme-invoice.pdf")
        makeTextPDF("ACME Trading\nInvoice number 4711\nInvoice date: 14.03.2024\nTotal R 1 250.00", at: source)

        let document = try await app.consumer().consume(ConsumeRequest(file: source, source: .consumeFolder))

        #expect(document.title == "acme-invoice")
        #expect(document.mimeType == "application/pdf")
        #expect(document.content.contains("Invoice number 4711"))
        #expect(document.created == CalendarDate(year: 2024, month: 3, day: 14))
        #expect(document.pageCount == 1)
        #expect(document.filename == "0000001.pdf")
        #expect(document.archiveFilename == nil) // born-digital: no archive in auto mode
        #expect(FileManager.default.fileExists(atPath: app.storage.originalURL(document)!.path))
        #expect(FileManager.default.fileExists(atPath: app.storage.thumbnailURL(documentId: document.id!).path))
        #expect(FileManager.default.fileExists(atPath: source.path)) // source kept without deleteSource

        try await app.database.read { db in
            let stored = try DocumentStore.document(document.id!, in: db)
            #expect(try Correspondent.fetchOne(db, key: stored.correspondentId!)?.name == "Acme")
            #expect(try DocumentType.fetchOne(db, key: stored.documentTypeId!)?.name == "Invoice")
            #expect(try DocumentStore.tags(of: document.id!, in: db).map(\.name) == ["Inbox"])
            #expect(try SearchIndex.search(.term("4711", field: .default), in: db).map(\.documentId) == [document.id!])
            #expect(try AuditLog.entries(objectType: "document", objectId: document.id!, in: db).first?.action == .create)
        }
        // Scratch space is cleaned up.
        #expect(try FileManager.default.contentsOfDirectory(atPath: app.settings.scratchDir.path).isEmpty)
    }

    @Test func applicationConfigurationAppliesToEachConsumption() async throws {
        let dir = TempDir()
        let app = try makeApp(dir)
        // One consumer for several files, like the folder watcher.
        let consumer = app.consumer()
        func store(_ json: String) async throws {
            try await app.database.write { db in
                try db.execute(sql: "INSERT OR REPLACE INTO app_config(id, config) VALUES (1, ?)", arguments: [json])
            }
        }
        try await store(#"{"archive_file_generation": "always"}"#)
        let first = dir.file("first.pdf")
        makeTextPDF("First statement for the archive", at: first)
        let archived = try await consumer.consume(ConsumeRequest(file: first, source: .consumeFolder))
        #expect(archived.archiveFilename != nil) // born-digital, but the stored config says always

        try await store(#"{"archive_file_generation": null}"#)
        let second = dir.file("second.pdf")
        makeTextPDF("Second statement without an archive", at: second)
        let plain = try await consumer.consume(ConsumeRequest(file: second, source: .consumeFolder))
        #expect(plain.archiveFilename == nil) // back to the auto setting
    }

    @Test func overridesWinAndSourceIsDeleted() async throws {
        let dir = TempDir()
        let app = try makeApp(dir)
        let tagId = try await app.database.write { db -> Int in
            var tag = Tag(name: "Manual")
            try tag.insert(db)
            return tag.id!
        }
        let source = dir.file("scan.pdf")
        makeTextPDF("Letter dated 01.02.2023", at: source)
        var overrides = DocumentOverrides(title: "My letter", tagIds: [tagId], created: CalendarDate(year: 2020, month: 5, day: 6), archiveSerialNumber: 12)
        overrides.customFields = [:]
        let document = try await app.consumer().consume(ConsumeRequest(file: source, source: .apiUpload, overrides: overrides, deleteSource: true))
        #expect(document.title == "My letter")
        #expect(document.created == CalendarDate(year: 2020, month: 5, day: 6))
        #expect(document.archiveSerialNumber == 12)
        #expect(!FileManager.default.fileExists(atPath: source.path))
        let tags = try await app.database.read { db in try DocumentStore.tagIds(of: document.id!, in: db) }
        #expect(tags == [tagId])
    }

    @Test func duplicatesAreConsumedOrRejected() async throws {
        let dir = TempDir()
        let first = dir.file("a.pdf")
        makeTextPDF("Same content", at: first)
        let copy = dir.file("b.pdf")
        try FileManager.default.copyItem(at: first, to: copy)

        let app = try makeApp(dir)
        let original = try await app.consumer().consume(ConsumeRequest(file: first, source: .consumeFolder))
        // Default: duplicates are consumed with a warning.
        let second = try await app.consumer().consume(ConsumeRequest(file: copy, source: .consumeFolder))
        #expect(second.id != original.id)
        #expect(second.filename == "0000002.pdf")

        let strictDir = TempDir()
        let strict = try makeApp(strictDir, overrides: ["CONSUMER_DELETE_DUPLICATES": "true"])
        let one = strictDir.file("one.pdf")
        try FileManager.default.copyItem(at: first, to: one)
        let two = strictDir.file("two.pdf")
        try FileManager.default.copyItem(at: first, to: two)
        let kept = try await strict.consumer().consume(ConsumeRequest(file: one, source: .consumeFolder))
        await #expect(throws: ConsumeError.duplicate(fileName: "two.pdf", existingId: kept.id!, inTrash: false)) {
            try await strict.consumer().consume(ConsumeRequest(file: two, source: .consumeFolder, deleteSource: true))
        }
        #expect(!FileManager.default.fileExists(atPath: two.path))
    }

    @Test func unsupportedFilesAndAsnConflictsFailCleanly() async throws {
        let dir = TempDir()
        let app = try makeApp(dir)
        let binary = dir.file("blob.bin")
        try Data([0x00, 0x01, 0x02, 0xFF, 0xFE]).write(to: binary)
        await #expect(throws: ConsumeError.self) {
            try await app.consumer().consume(ConsumeRequest(file: binary, source: .consumeFolder))
        }

        let a = dir.file("a.pdf"), b = dir.file("b.pdf")
        makeTextPDF("First", at: a)
        makeTextPDF("Second", at: b)
        _ = try await app.consumer().consume(ConsumeRequest(file: a, source: .apiUpload, overrides: .init(archiveSerialNumber: 5)))
        await #expect(throws: ConsumeError.asnInUse(5)) {
            try await app.consumer().consume(ConsumeRequest(file: b, source: .apiUpload, overrides: .init(archiveSerialNumber: 5)))
        }
        // The failed run leaves no files behind.
        let originals = try FileManager.default.contentsOfDirectory(atPath: app.settings.originalsDir.path)
        #expect(originals == ["0000001.pdf"])
    }

    @Test func textFilesAreConsumed() async throws {
        let dir = TempDir()
        let app = try makeApp(dir)
        let note = dir.file("notes.txt")
        try "Meeting notes from 3 May 2022\nBring the contract.".write(to: note, atomically: false, encoding: .utf8)
        let document = try await app.consumer().consume(ConsumeRequest(file: note, source: .consumeFolder))
        #expect(document.mimeType == "text/plain")
        #expect(document.created == CalendarDate(year: 2022, month: 5, day: 3))
        #expect(document.filename == "0000001.txt")
    }
}

@Suite(.serialized) struct VersionTests {
    @Test func newVersionKeepsMetadataAndReplacesSearchContent() async throws {
        let dir = TempDir()
        let settings = try SettingsLoader.load(home: dir.url.path, environment: [:], overrides: ["TIME_ZONE": "UTC"])
        let app = try FolioApp.open(settings: settings)
        let first = dir.file("contract.pdf")
        makeTextPDF("Draft contract alpha", at: first)
        let root = try await app.consumer().consume(ConsumeRequest(file: first, source: .apiUpload, overrides: .init(title: "Lease")))

        let second = dir.file("contract-signed.pdf")
        makeTextPDF("Signed contract omega", at: second)
        let version = try await app.consumer().consume(ConsumeRequest(file: second, source: .apiUpload, versionOf: root.id, versionLabel: "signed"))

        #expect(version.rootDocumentId == root.id)
        #expect(version.versionIndex == 1)
        #expect(version.versionLabel == "signed")
        #expect(version.title == "Lease")
        #expect(version.filename == "0000001_v1.pdf")
        try await app.database.read { db throws in
            #expect(try SearchIndex.search(.term("omega", field: .default), in: db).map { $0.documentId } == [root.id!])
            #expect(try SearchIndex.search(.term("alpha", field: .default), in: db).isEmpty)
        }
    }
}
