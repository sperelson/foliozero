import Foundation
import GRDB
import Testing
@testable import FolioCore

@Suite(.serialized) struct FolderWatcherTests {
    func waitFor(_ seconds: Double, _ condition: () async throws -> Bool) async rethrows -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if try await condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return try await condition()
    }

    func run(polling: Bool) async throws {
        let dir = TempDir()
        var overrides = ["TIME_ZONE": "UTC", "CONSUMER_STABILITY_DELAY": "0.5", "CONSUMER_RECURSIVE": "true", "CONSUMER_SUBDIRS_AS_TAGS": "true"]
        if polling { overrides["CONSUMER_POLLING_INTERVAL"] = "0.3" }
        let settings = try SettingsLoader.load(home: dir.url.path, environment: [:], overrides: overrides)
        let app = try FolioApp.open(settings: settings)
        let queue = TaskQueue(database: app.database, workers: 2, logger: app.logger)
        let watcher = FolderWatcher(app: app, queue: queue)
        await watcher.start()
        defer { Task { await watcher.stop() } }

        let consume = settings.consumptionDir
        let folder = consume.appendingPathComponent("Bank/2026", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let source = dir.file("statement.pdf")
        makeTextPDF("Bank statement", at: source)
        try FileManager.default.copyItem(at: source, to: folder.appendingPathComponent("statement.pdf"))
        FileManager.default.createFile(atPath: consume.appendingPathComponent(".DS_Store").path, contents: Data("x".utf8))
        FileManager.default.createFile(atPath: consume.appendingPathComponent("._statement.pdf").path, contents: Data("x".utf8))

        let consumed = try await waitFor(20) {
            try await app.database.read { db in try Document.fetchCount(db) } == 1
        }
        #expect(consumed)
        await queue.waitUntilIdle()
        let (tags, count) = try await app.database.read { db -> ([String], Int) in
            let document = try Document.fetchOne(db)!
            return (try DocumentStore.tags(of: document.id!, in: db).map(\.name), try Document.fetchCount(db))
        }
        #expect(Set(tags) == ["Bank", "2026"])
        #expect(count == 1)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("statement.pdf").path))
        // Ignored files stay and are not consumed.
        #expect(FileManager.default.fileExists(atPath: consume.appendingPathComponent(".DS_Store").path))
        // Give the watcher time to (wrongly) pick up ignored files.
        try await Task.sleep(for: .seconds(1.5))
        #expect(try await app.database.read { db in try Document.fetchCount(db) } == 1)
    }

    @Test func fsEventsMode() async throws { try await run(polling: false) }
    @Test func pollingMode() async throws { try await run(polling: true) }
}
