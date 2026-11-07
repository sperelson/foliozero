import Foundation
import GRDB
import Testing
@testable import FolioCore

@Suite struct AIIndexTests {
    let longText = (1...80).map { "Line \($0) of the policy covers the car and its insurance." }.joined(separator: "\n")

    @Test func incrementalUpdateEmbedsOnlyChangedDocuments() async throws {
        let dir = TempDir()
        let app = try makeAIApp(dir)
        let embedder = FakeEmbedder()
        let index = LLMIndex(database: app.database, runtime: fakeRuntime(embedder: embedder))
        let longText = self.longText
        let (a, b) = try await app.database.write { db in
            (try insertDocument("Car insurance", content: longText, in: db),
             try insertDocument("Electricity bill", content: "Power usage for March: 300 kWh.", in: db))
        }

        #expect(try await index.update() == "LLM index rebuilt successfully.")
        let status = try index.status()
        #expect(status.documentCount == 2)
        #expect(status.chunkCount > 2)
        #expect(status.model == "fake:bow64")
        #expect(status.lastUpdated != nil)
        let firstRun = embedder.embeddedCount
        #expect(firstRun == status.chunkCount)

        #expect(try await index.update() == "No changes detected in LLM index.")
        #expect(embedder.embeddedCount == firstRun)

        // Changed content: only that document is embedded again.
        try await app.database.write { db in
            var document = try DocumentStore.document(b, in: db)
            document.content = "Power usage for April: 280 kWh."
            try DocumentStore.update(document, in: db)
        }
        #expect(try await index.update() == "LLM index updated successfully.")
        #expect(embedder.embeddedCount == firstRun + 1)

        // A new note changes the indexed text without touching `modified`.
        try await app.database.write { db in
            var note = Note(documentId: b, note: "Paid by debit order")
            try note.insert(db)
        }
        #expect(try await index.update(documentIds: [b]) == "LLM index updated successfully.")
        #expect(embedder.embeddedCount == firstRun + 2)
        let chunk = try await app.database.read { db in
            try String.fetchOne(db, sql: "SELECT text FROM ai_index_chunks WHERE document_id = ?", arguments: [b])
        }
        #expect(chunk?.contains("Notes: Paid by debit order") == true)

        // A new `modified` time with unchanged text only updates the stored time.
        try await app.database.write { db in
            try DocumentStore.update(try DocumentStore.document(a, in: db), in: db)
        }
        #expect(try await index.update() == "No changes detected in LLM index.")
        #expect(embedder.embeddedCount == firstRun + 2)
        let (stored, actual) = try await app.database.read { db in
            (try String.fetchOne(db, sql: "SELECT modified FROM ai_index_documents WHERE document_id = ?", arguments: [a]),
             try String.fetchOne(db, sql: "SELECT modified FROM documents WHERE id = ?", arguments: [a]))
        }
        #expect(stored == actual)
    }

    @Test func modelChangeForcesRebuild() async throws {
        let dir = TempDir()
        let app = try makeAIApp(dir)
        let first = FakeEmbedder(identity: "fake:a")
        let second = FakeEmbedder(identity: "fake:b")
        let id = try await app.database.write { db in try insertDocument("Doc", content: "Some text here.", in: db) }
        _ = try await LLMIndex(database: app.database, runtime: fakeRuntime(embedder: first)).update()

        // Single-document updates never rebuild on their own, and searches skip foreign vectors.
        let switched = LLMIndex(database: app.database, runtime: fakeRuntime(embedder: second))
        #expect(try await switched.search(text: "text", context: .system()).isEmpty)
        try await switched.indexDocument(id)
        #expect(second.embeddedCount == 0)

        #expect(try await switched.update() == "LLM index rebuilt successfully.")
        #expect(second.embeddedCount == 1)
        #expect(try await switched.search(text: "text", context: .system()).count == 1)
        #expect(try switched.status().model == "fake:b")

        // A different chunk size also rebuilds.
        let resized = LLMIndex(database: app.database, runtime: fakeRuntime(aiConfig(chunkSize: 32), embedder: second))
        #expect(try await resized.update() == "LLM index rebuilt successfully.")
    }

    @Test func removalAndPurge() async throws {
        let dir = TempDir()
        let app = try makeAIApp(dir)
        let index = LLMIndex(database: app.database, runtime: fakeRuntime())
        let (a, b) = try await app.database.write { db in
            (try insertDocument("A", content: "alpha text", in: db), try insertDocument("B", content: "beta text", in: db))
        }
        try await index.update()
        #expect(try index.status().documentCount == 2)
        try await index.removeDocument(a)
        #expect(try index.status().documentCount == 1)
        try await app.database.write { db in try DocumentStore.purge(b, in: db) }
        #expect(try index.status() == LLMIndex.Status(documentCount: 0, chunkCount: 0, model: "fake:bow64", lastUpdated: try index.status().lastUpdated))
        #expect(try index.exists() == false)
    }

    @Test func searchFiltersByPermissionTrashAndScope() async throws {
        let dir = TempDir()
        let app = try makeAIApp(dir)
        let index = LLMIndex(database: app.database, runtime: fakeRuntime())
        let (alice, bob, ids) = try await app.database.write { db -> (User, User, [String: Int]) in
            let alice = try makeUser("alice", in: db)
            let bob = try makeUser("bob", in: db)
            var ids: [String: Int] = [:]
            ids["alice"] = try insertDocument("Alice car insurance", content: "car insurance policy premium", owner: alice.id, in: db)
            ids["bob"] = try insertDocument("Bob car insurance", content: "car insurance policy renewal", owner: bob.id, in: db)
            ids["shared"] = try insertDocument("Shared car insurance", content: "car insurance claim form", owner: alice.id, in: db)
            ids["public"] = try insertDocument("Public car note", content: "car service schedule", in: db)
            ids["trash"] = try insertDocument("Trashed car insurance", content: "car insurance policy old", in: db)
            try PermissionSet(view: .init(users: [bob.id!])).apply(objectType: Document.objectType, objectId: ids["shared"]!, in: db)
            return (alice, bob, ids)
        }
        try await index.update()
        try await app.database.write { db in try DocumentStore.moveToTrash(ids["trash"]!, in: db) }

        let bobs = Set(try await index.search(text: "car insurance policy", context: access(bob), limit: 10).map(\.documentId))
        #expect(bobs == [ids["bob"]!, ids["shared"]!, ids["public"]!])
        let alices = try await index.search(text: "car insurance policy", context: access(alice), limit: 10)
        #expect(Set(alices.map(\.documentId)) == [ids["alice"]!, ids["shared"]!, ids["public"]!])
        #expect(alices.map(\.score) == alices.map(\.score).sorted(by: >))

        let scoped = try await index.search(text: "car", context: .system(), documentIds: [ids["public"]!], limit: 10)
        #expect(scoped.map(\.documentId) == [ids["public"]!])
        let excluded = try await index.search(text: "car", context: .system(), excluding: ids["public"]!, limit: 10)
        #expect(!excluded.contains { $0.documentId == ids["public"]! })
        #expect(try await index.search(text: "car", context: .system(), limit: 2).count == 2)
    }

    @Test func similarDocuments() async throws {
        let dir = TempDir()
        let app = try makeAIApp(dir)
        let index = LLMIndex(database: app.database, runtime: fakeRuntime())
        let (owner, ids) = try await app.database.write { db -> (User, [Int]) in
            let owner = try makeUser("owner", in: db)
            return (owner, [
                try insertDocument("Car insurance 2024", content: "Annual car insurance policy for the family car", in: db),
                try insertDocument("Car insurance 2025", content: "Annual car insurance policy renewal for the car", in: db),
                try insertDocument("Pizza recipe", content: "Flour water yeast tomato mozzarella basil", in: db),
                try insertDocument("Private", content: "Annual car insurance policy", owner: owner.id, in: db),
            ])
        }
        try await index.update()
        let stranger = try await app.database.write { db in try makeUser("stranger", in: db) }
        let similar = try await index.similarDocuments(documentId: ids[0], context: access(stranger), limit: 2)
        #expect(similar.map(\.id) == [ids[1], ids[2]])
        #expect(similar[0].score > similar[1].score)
        await #expect(throws: AIError.permissionDenied) {
            try await index.similarDocuments(documentId: ids[3], context: access(stranger))
        }
        await #expect(throws: AIError.documentNotFound(999)) {
            try await index.similarDocuments(documentId: 999, context: access(owner))
        }
    }

    @Test func indexesVersionsThroughRoot() async throws {
        let dir = TempDir()
        let app = try makeAIApp(dir)
        let index = LLMIndex(database: app.database, runtime: fakeRuntime())
        let (root, version) = try await app.database.write { db -> (Int, Int) in
            let root = try insertDocument("Contract", content: "old wording", in: db)
            var version = Document.fixture("Contract v2", content: "new wording with penalty clause")
            version.rootDocumentId = root
            version.versionIndex = 1
            return (root, try DocumentStore.insert(version, in: db).id!)
        }
        try await index.indexDocument(version)
        let stored = try await app.database.read { db in
            try Row.fetchAll(db, sql: "SELECT document_id, text FROM ai_index_chunks").map { ($0["document_id"] as Int, $0["text"] as String) }
        }
        #expect(stored.count == 1)
        #expect(stored.first?.0 == root)
        #expect(stored.first?.1.contains("penalty clause") == true)
    }

    @Test func vectorHelpers() {
        let normalised = LLMIndex.normalised([3, 4])
        #expect(normalised == [0.6, 0.8])
        let blob = LLMIndex.blob(normalised)
        #expect(blob.count == 8)
        #expect(LLMIndex.vector(from: blob) == normalised)
        #expect(abs((LLMIndex.dot([0.6, 0.8], blob) ?? 0) - 1) < 1e-6)
        #expect(LLMIndex.dot([1, 0, 0], blob) == nil)
        #expect(LLMIndex.normalised([0, 0]).isEmpty)
    }
}
