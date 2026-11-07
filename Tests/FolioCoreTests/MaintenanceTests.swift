import Foundation
import GRDB
import Testing
@testable import FolioCore

@Suite(.serialized) struct MaintenanceTests {
    func makeApp(_ dir: TempDir, _ overrides: [String: String] = [:]) throws -> FolioApp {
        let settings = try SettingsLoader.load(home: dir.url.path, environment: [:], overrides: ["TIME_ZONE": "UTC"].merging(overrides) { _, n in n })
        return try FolioApp.open(settings: settings)
    }

    func consume(_ app: FolioApp, _ dir: TempDir, _ name: String, _ text: String) async throws -> Document {
        let file = dir.file(name)
        makeTextPDF(text, at: file)
        return try await app.consumer().consume(ConsumeRequest(file: file, source: .consumeFolder))
    }

    @Test func sanityCheckFindsProblems() async throws {
        let dir = TempDir()
        let app = try makeApp(dir)
        let good = try await consume(app, dir, "good.pdf", "Fine")
        let bad = try await consume(app, dir, "bad.pdf", "Broken")
        #expect(try await DocumentMaintenance.sanityCheck(app: app).filter { $0.level != .info }.isEmpty)

        try Data("tampered".utf8).write(to: app.storage.originalURL(bad)!)
        try FileManager.default.removeItem(at: app.storage.thumbnailURL(documentId: good.id!))
        FileManager.default.createFile(atPath: app.settings.originalsDir.appendingPathComponent("stray.pdf").path, contents: Data())

        let messages = try await DocumentMaintenance.sanityCheck(app: app).map(\.description)
        #expect(messages.contains { $0.contains("#\(bad.id!)") && $0.contains("Checksum mismatch") })
        #expect(messages.contains { $0.contains("#\(good.id!)") && $0.contains("Thumbnail missing") })
        #expect(messages.contains { $0.contains("Orphaned file") && $0.contains("stray.pdf") })
    }

    @Test func renamerAppliesNewFormat() async throws {
        let dir = TempDir()
        let first = try makeApp(dir)
        let document = try await consume(first, dir, "electricity.pdf", "Power bill 01.02.2026")
        #expect(document.filename == "0000001.pdf")

        let renamedApp = try makeApp(dir, ["FILENAME_FORMAT": "{{ created_year }}/{{ title }}"])
        #expect(try await DocumentMaintenance.renameAll(app: renamedApp) == 1)
        let stored = try await renamedApp.database.read { db in try DocumentStore.document(document.id!, in: db) }
        #expect(stored.filename == "2026/electricity.pdf")
        #expect(FileManager.default.fileExists(atPath: renamedApp.storage.originalURL(stored)!.path))
        #expect(!FileManager.default.fileExists(atPath: renamedApp.settings.originalsDir.appendingPathComponent("0000001.pdf").path))
    }

    @Test func retaggerAssignsNewMatches() async throws {
        let dir = TempDir()
        let app = try makeApp(dir)
        let document = try await consume(app, dir, "water.pdf", "Rand Water account statement")
        let (tagId, correspondentId) = try await app.database.write { db -> (Int, Int) in
            var tag = Tag(name: "Utilities", match: "water", matchingAlgorithm: .any); try tag.insert(db)
            var c = Correspondent(name: "Rand Water", match: "rand water", matchingAlgorithm: .literal); try c.insert(db)
            return (tag.id!, c.id!)
        }
        let changed = try await DocumentMaintenance.retag(app: app, options: .init(correspondents: true, tags: true))
        #expect(changed == [document.id!])
        let (stored, tags) = try await app.database.read { db in (try DocumentStore.document(document.id!, in: db), try DocumentStore.tagIds(of: document.id!, in: db)) }
        #expect(stored.correspondentId == correspondentId)
        #expect(tags == [tagId])
        #expect(try await DocumentMaintenance.retag(app: app, options: .init(correspondents: true, tags: true)).isEmpty)
    }

    @Test func reprocessAndThumbnails() async throws {
        let dir = TempDir()
        let app = try makeApp(dir)
        let document = try await consume(app, dir, "a.pdf", "Original text")
        try await app.database.write { db in
            try db.execute(sql: "UPDATE documents SET content = 'wrong', page_count = NULL WHERE id = ?", arguments: [document.id!])
        }
        try await DocumentMaintenance.reprocess(app: app, documentId: document.id!)
        let stored = try await app.database.read { db in try DocumentStore.document(document.id!, in: db) }
        #expect(stored.content.contains("Original text"))
        #expect(stored.pageCount == 1)

        try FileManager.default.removeItem(at: app.storage.thumbnailURL(documentId: document.id!))
        #expect(try await DocumentMaintenance.regenerateThumbnails(app: app) == 1)
        #expect(FileManager.default.fileExists(atPath: app.storage.thumbnailURL(documentId: document.id!).path))
    }
}
