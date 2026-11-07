import Foundation
import GRDB
import Testing
@testable import FolioCore

@Suite struct AISuggestionsTests {
    struct Fixture: @unchecked Sendable {
        let dir: TempDir
        let app: FolioApp
        let ai: FolioAI
        let llm: FakeLLM
        let alice: User
        let bob: User
        let document: Int
        let ids: [String: Int]
    }

    /// Alice owns an invoice and some taxonomy; Bob has his own private tag.
    func makeFixture(config: AIConfig = aiConfig(), output: ClassifierOutput) async throws -> Fixture {
        let dir = TempDir()
        let app = try makeAIApp(dir)
        let llm = FakeLLM(output: output)
        let ai = FolioAI(app: app, runtime: fakeRuntime(config, llm: llm))
        let (alice, bob, document, ids) = try await app.database.write { db -> (User, User, Int, [String: Int]) in
            let alice = try makeUser("alice", in: db)
            let bob = try makeUser("bob", in: db)
            var ids: [String: Int] = [:]
            var invoice = Tag(name: "Invoice"); try invoice.insert(db); ids["tag.invoice"] = invoice.id
            var hardware = Tag(name: "Hardware", ownerId: alice.id); try hardware.insert(db); ids["tag.hardware"] = hardware.id
            var bobs = Tag(name: "Insurance", ownerId: bob.id); try bobs.insert(db); ids["tag.bob"] = bobs.id
            var acme = Correspondent(name: "ACME Corp."); try acme.insert(db); ids["corr.acme"] = acme.id
            var type = DocumentType(name: "Invoice"); try type.insert(db); ids["type.invoice"] = type.id
            var path = StoragePath(name: "Finance", path: "finance/{{ title }}"); try path.insert(db); ids["path.finance"] = path.id
            let document = try insertDocument("scan_0001", content: "ACME Corp. Invoice 42 for hardware. Date 14.03.2024. Total 120 EUR.", owner: alice.id, in: db)
            try insertDocument("Older ACME invoice", content: "ACME Corp. Invoice 41 for hardware. Total 80 EUR.", owner: alice.id, in: db)
            return (alice, bob, document, ids)
        }
        return Fixture(dir: dir, app: app, ai: ai, llm: llm, alice: alice, bob: bob, document: document, ids: ids)
    }

    static let output = ClassifierOutput(
        title: "ACME invoice 42", tags: ["invoices", "Hardware", "Insurance", "Office"],
        correspondents: ["ACME Corp", "Globex"], documentTypes: ["Invoice"], storagePaths: ["Finance"],
        dates: ["2024-03-14", "2024-04-14"])

    @Test func suggestionsMatchPaperlessShapeAndPermissions() async throws {
        let f = try await makeFixture(output: Self.output)
        let response = try await f.ai.suggestions.suggestions(documentId: f.document, context: access(f.alice))
        #expect(response.title == "ACME invoice 42")
        // "invoices" fuzzily matches Invoice; Bob's private "Insurance" tag is invisible to Alice.
        #expect(response.tags == [f.ids["tag.invoice"]!, f.ids["tag.hardware"]!])
        #expect(response.suggestedTags == ["invoices", "Insurance", "Office"])
        #expect(response.correspondents == [f.ids["corr.acme"]!])
        #expect(response.suggestedCorrespondents == ["Globex"])
        #expect(response.documentTypes == [f.ids["type.invoice"]!])
        #expect(response.suggestedDocumentTypes == [])
        #expect(response.storagePaths == [f.ids["path.finance"]!])
        #expect(response.dates == ["2024-03-14", "2024-04-14"])

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any]
        #expect(Set(json?.keys.map { $0 } ?? []) == [
            "title", "tags", "suggested_tags", "correspondents", "suggested_correspondents", "document_types",
            "suggested_document_types", "storage_paths", "suggested_storage_paths", "dates",
        ])

        // The prompt carries the document, never another user's data.
        let prompt = try #require(f.llm.prompts.first)
        #expect(prompt.contains("ACME Corp. Invoice 42"))
        #expect(prompt.hasPrefix("You are a document classification assistant."))
    }

    @Test func cachesPerUserAndResolvesPerRequester() async throws {
        let f = try await makeFixture(output: Self.output)
        try await f.app.database.write { db in
            try PermissionSet(change: .init(users: [f.bob.id!])).apply(objectType: Document.objectType, objectId: f.document, in: db)
        }
        _ = try await f.ai.suggestions.suggestions(documentId: f.document, context: access(f.alice))
        _ = try await f.ai.suggestions.suggestions(documentId: f.document, context: access(f.alice))
        #expect(f.llm.prompts.count == 1)

        // Bob gets his own cache entry and his own tag resolved.
        let bobs = try await f.ai.suggestions.suggestions(documentId: f.document, context: access(f.bob))
        #expect(f.llm.prompts.count == 2)
        #expect(bobs.tags.contains(f.ids["tag.bob"]!))
        #expect(!bobs.tags.contains(f.ids["tag.hardware"]!))

        // Changing the document invalidates its entries.
        try await f.app.database.write { db in
            var document = try DocumentStore.document(f.document, in: db)
            document.content += " Paid."
            try DocumentStore.update(document, in: db)
        }
        _ = try await f.ai.suggestions.suggestions(documentId: f.document, context: access(f.alice))
        #expect(f.llm.prompts.count == 3)
        f.ai.suggestions.invalidate(documentId: f.document)
        _ = try await f.ai.suggestions.suggestions(documentId: f.document, context: access(f.alice))
        #expect(f.llm.prompts.count == 4)
    }

    @Test func checksInPaperlessOrder() async throws {
        let f = try await makeFixture(config: aiConfig(enabled: false), output: Self.output)
        await #expect(throws: AIError.documentNotFound(999)) {
            try await f.ai.suggestions.suggestions(documentId: 999, context: access(f.alice))
        }
        await #expect(throws: AIError.permissionDenied) {
            try await f.ai.suggestions.suggestions(documentId: f.document, context: access(f.bob))
        }
        await #expect(throws: AIError.disabled) {
            try await f.ai.suggestions.suggestions(documentId: f.document, context: access(f.alice))
        }
    }

    @Test func backendErrorsPropagate() async throws {
        let f = try await makeFixture(output: Self.output)
        f.llm.error = .timeout
        await #expect(throws: AIError.timeout) {
            try await f.ai.suggestions.suggestions(documentId: f.document, context: access(f.alice))
        }
    }

    @Test func taxonomyCandidatesAndRAGContextFromIndex() async throws {
        let f = try await makeFixture(output: ClassifierOutput(
            title: "t", tags: ["Bills"], matchedTags: ["Bills"], tagIds: [-1]))
        let older = try await f.app.database.read { db in
            try Int.fetchOne(db, sql: "SELECT id FROM documents WHERE title = 'Older ACME invoice'")!
        }
        let hardware = f.ids["tag.hardware"]!
        try await f.app.database.write { db in
            var document = try DocumentStore.document(older, in: db)
            document.correspondentId = f.ids["corr.acme"]
            try DocumentStore.update(document, in: db)
            try DocumentStore.addTags(documentId: older, tagIds: [hardware], in: db)
        }
        try await f.ai.index.update()
        f.llm.output = ClassifierOutput(title: "t", tags: ["Hardware stuff"], matchedTags: ["Hardware stuff"], tagIds: [hardware])
        let response = try await f.ai.suggestions.suggestions(documentId: f.document, context: access(f.alice))
        // The model's mapping to a candidate it was shown is accepted.
        #expect(response.tags == [hardware])
        #expect(response.suggestedTags == [])

        let prompt = try #require(f.llm.prompts.last)
        #expect(prompt.contains("Available tags, document types, correspondents, and storage paths from similar documents"))
        #expect(prompt.contains(#"{"tags": [{"id": \#(hardware), "name": "Hardware"}], "correspondents": [{"id": \#(f.ids["corr.acme"]!), "name": "ACME Corp."}]}"#))
        #expect(prompt.contains("TITLE: Older ACME invoice"))
        #expect(prompt.contains("matched_* field"))
    }

    @Test func localizesWithoutTouchingIds() async throws {
        var config = aiConfig()
        config.outputLanguage = "de"
        let f = try await makeFixture(config: config, output: Self.output)
        let response = try await f.ai.suggestions.suggestions(documentId: f.document, context: access(f.alice))
        #expect(f.llm.prompts.count == 2)
        #expect(f.llm.prompts[1].contains("fields in German"))
        #expect(response.correspondents == [f.ids["corr.acme"]!])
    }

    // MARK: Workflow action

    @Test func applyFillsEmptyFieldsAndAddsTags() async throws {
        let f = try await makeFixture(output: Self.output)
        let updated = try await f.ai.suggestions.apply(
            to: f.document, fields: Set(AISuggestionField.allCases), createMissing: false, overwrite: false)
        // The title and created date are never empty, so without overwrite they stay.
        #expect(updated == ["correspondent", "document_type", "storage_path", "tags"])
        let (document, tags) = try await f.app.database.read { db in
            (try DocumentStore.document(f.document, in: db), try DocumentStore.tagIds(of: f.document, in: db))
        }
        #expect(document.title == "scan_0001")
        #expect(document.correspondentId == f.ids["corr.acme"])
        #expect(document.documentTypeId == f.ids["type.invoice"])
        #expect(document.storagePathId == f.ids["path.finance"])
        #expect(Set(tags) == [f.ids["tag.invoice"]!, f.ids["tag.hardware"]!])
    }

    @Test func applyOverwritesAndCreatesMissing() async throws {
        let f = try await makeFixture(output: ClassifierOutput(
            title: "  New title  ", tags: ["Office", "Hardware"], correspondents: ["Globex"], documentTypes: ["Receipt"],
            storagePaths: ["Archive/2024"], dates: ["not a date", "2024-02-30", "2024-03-15"]))
        let updated = try await f.ai.suggestions.apply(
            to: f.document, fields: Set(AISuggestionField.allCases), createMissing: true, overwrite: true)
        #expect(updated == ["title", "correspondent", "document_type", "created", "tags"])
        try await f.app.database.read { db in
            let document = try DocumentStore.document(f.document, in: db)
            #expect(document.title == "New title")
            #expect(document.created == CalendarDate(year: 2024, month: 3, day: 15))
            let correspondent = try Correspondent.fetchOne(db, key: document.correspondentId!)
            #expect(correspondent?.name == "Globex")
            #expect(correspondent?.ownerId == f.alice.id)
            #expect(try DocumentType.fetchOne(db, key: document.documentTypeId!)?.name == "Receipt")
            // Storage paths are never created.
            #expect(document.storagePathId == nil)
            #expect(try StoragePath.fetchCount(db) == 1)
            let tags = try DocumentStore.tags(of: f.document, in: db).map(\.name)
            #expect(tags == ["Hardware", "Office"])
            #expect(try Tag.filter(Column("name") == "Office").fetchOne(db)?.ownerId == f.alice.id)
        }
        // Running again reuses the created objects.
        _ = try await f.ai.suggestions.apply(to: f.document, fields: [.correspondent, .tags], createMissing: true, overwrite: true)
        let counts = try await f.app.database.read { db in
            (try Correspondent.filter(Column("name") == "Globex").fetchCount(db), try Tag.filter(Column("name") == "Office").fetchCount(db))
        }
        #expect(counts == (1, 1))
    }

    @Test func applySkipsWithoutContentFieldsOrAI() async throws {
        let f = try await makeFixture(output: Self.output)
        #expect(try await f.ai.suggestions.apply(to: f.document, fields: [], createMissing: false, overwrite: true) == [])
        let empty = try await f.app.database.write { db in try insertDocument("Empty", content: "  \n ", in: db) }
        #expect(try await f.ai.suggestions.apply(to: empty, fields: [.title], createMissing: false, overwrite: true) == [])
        #expect(f.llm.prompts.isEmpty)

        let off = FolioAI(app: f.app, runtime: fakeRuntime(aiConfig(enabled: false), llm: f.llm))
        #expect(try await off.suggestions.apply(to: f.document, fields: [.title], createMissing: false, overwrite: true) == [])

        let broken = FolioAI(app: f.app, runtime: { throw AIError.invalidConfiguration("bad") })
        #expect(try await broken.suggestions.apply(to: f.document, fields: [.title], createMissing: false, overwrite: true) == [])

        f.llm.error = .timeout
        await #expect(throws: AIError.timeout) {
            try await f.ai.suggestions.apply(to: f.document, fields: [.title], createMissing: false, overwrite: true)
        }
    }

    @Test func unownedDocumentOnlyUsesUnownedTaxonomy() async throws {
        let f = try await makeFixture(output: ClassifierOutput(title: "x", tags: ["Hardware", "Invoice"]))
        let unowned = try await f.app.database.write { db in try insertDocument("Unowned", content: "Hardware invoice", in: db) }
        let updated = try await f.ai.suggestions.apply(to: unowned, fields: [.tags], createMissing: false, overwrite: false)
        #expect(updated == ["tags"])
        let tags = try await f.app.database.read { db in try DocumentStore.tagIds(of: unowned, in: db) }
        // Alice's "Hardware" tag is not visible without a user.
        #expect(tags == [f.ids["tag.invoice"]!])
    }
}
