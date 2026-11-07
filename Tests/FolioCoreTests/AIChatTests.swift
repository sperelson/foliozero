import Foundation
import GRDB
import Testing
@testable import FolioCore

@Suite struct AIChatTests {
    struct Fixture: @unchecked Sendable {
        let dir: TempDir
        let app: FolioApp
        let ai: FolioAI
        let llm: FakeLLM
        let alice: User
        let bob: User
        let ids: [String: Int]
    }

    func makeFixture(config: AIConfig = aiConfig(), embedder: (any EmbeddingBackend)? = FakeEmbedder(), buildIndex: Bool = true) async throws -> Fixture {
        let dir = TempDir()
        let app = try makeAIApp(dir)
        let llm = FakeLLM(answer: ["The premium ", "is 420 EUR."])
        let ai = FolioAI(app: app, runtime: fakeRuntime(config, llm: llm, embedder: embedder))
        let (alice, bob, ids) = try await app.database.write { db -> (User, User, [String: Int]) in
            let alice = try makeUser("alice", in: db)
            let bob = try makeUser("bob", in: db)
            var ids: [String: Int] = [:]
            ids["policy"] = try insertDocument("Car insurance policy", content: "The annual car insurance premium is 420 EUR.", owner: alice.id, in: db)
            ids["recipe"] = try insertDocument("Pizza", content: "Flour, water, yeast and tomatoes.", owner: alice.id, in: db)
            ids["secret"] = try insertDocument("Bob's car insurance", content: "Bob pays 999 EUR car insurance premium.", owner: bob.id, in: db)
            return (alice, bob, ids)
        }
        if buildIndex { try await ai.index.update() }
        return Fixture(dir: dir, app: app, ai: ai, llm: llm, alice: alice, bob: bob, ids: ids)
    }

    @Test func answersFromVisibleDocumentsWithReferences() async throws {
        let f = try await makeFixture()
        let response = try await f.ai.chat.ask("How much is the car insurance premium?", context: access(f.alice))
        #expect(response.references.first == AIChat.Reference(id: f.ids["policy"]!, title: "Car insurance policy"))
        #expect(!response.references.contains { $0.id == f.ids["secret"]! })
        #expect(response.references.count <= AIChat.maxReferences)

        let body = await collect(response.paperlessBody())
        let parts = body.components(separatedBy: AIChat.metadataDelimiter)
        #expect(parts.count == 2)
        #expect(parts[0] == "The premium is 420 EUR.")
        let trailer = try JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: [[String: Any]]]
        #expect(trailer?["references"]?.first?["id"] as? Int == f.ids["policy"]!)
        #expect(trailer?["references"]?.first?["title"] as? String == "Car insurance policy")

        let prompt = try #require(f.llm.chatPrompts.first)
        #expect(prompt.contains("420 EUR"))
        #expect(prompt.contains("title: Car insurance policy"))
        #expect(!prompt.contains("999 EUR"))
        #expect(prompt.hasSuffix("Query: How much is the car insurance premium?\nAnswer:"))
        #expect(!prompt.contains("Respond in"))
    }

    @Test func singleDocumentChat() async throws {
        var config = aiConfig()
        config.outputLanguage = "de"
        let f = try await makeFixture(config: config)
        let response = try await f.ai.chat.ask("What is this about?", documentId: f.ids["recipe"]!, context: access(f.alice))
        #expect(response.references == [AIChat.Reference(id: f.ids["recipe"]!, title: "Pizza")])
        #expect(try await collect(response.tokens) == "The premium is 420 EUR.")
        let prompt = try #require(f.llm.chatPrompts.first)
        #expect(prompt.contains("Flour, water"))
        #expect(!prompt.contains("420 EUR"))
        #expect(prompt.contains("Respond in de.\nQuery:"))
    }

    @Test func requestErrorsComeBeforeStreaming() async throws {
        let f = try await makeFixture()
        await #expect(throws: AIError.permissionDenied) {
            try await f.ai.chat.ask("q", documentId: f.ids["secret"]!, context: access(f.alice))
        }
        await #expect(throws: AIError.documentNotFound(999)) {
            try await f.ai.chat.ask("q", documentId: 999, context: access(f.alice))
        }
        await #expect(throws: AIError.self) { try await f.ai.chat.ask("   ", context: access(f.alice)) }
        await #expect(throws: AIError.self) {
            try await f.ai.chat.ask(String(repeating: "x", count: AIChat.maxQuestionLength + 1), context: access(f.alice))
        }
        let off = FolioAI(app: f.app, runtime: fakeRuntime(aiConfig(enabled: false)))
        await #expect(throws: AIError.disabled) { try await off.chat.ask("q", context: access(f.alice)) }
        // The Paperless-shaped stream turns early failures into the error message.
        #expect(await collect(off.chat.stream("q", context: access(f.alice))) == AIChat.errorMessage)
    }

    @Test func noContentAndMidStreamFailure() async throws {
        let f = try await makeFixture()
        let carol = try await f.app.database.write { db in try makeUser("carol", in: db) }
        let empty = try await f.ai.chat.ask("anything", context: access(carol))
        #expect(empty.references.isEmpty)
        #expect(await collect(empty.paperlessBody()) == AIChat.noContentMessage)

        f.llm.error = .timeout
        let failing = try await f.ai.chat.ask("car insurance premium", context: access(f.alice))
        #expect(await collect(failing.paperlessBody()) == "The premium is 420 EUR." + AIChat.errorMessage)
        let again = try await f.ai.chat.ask("car insurance premium", context: access(f.alice))
        await #expect(throws: AIError.timeout) { _ = try await collect(again.tokens) }
    }

    @Test func fallsBackToDocumentTextWithoutIndex() async throws {
        let f = try await makeFixture(embedder: nil, buildIndex: false)
        let single = try await f.ai.chat.ask("premium?", documentId: f.ids["policy"]!, context: access(f.alice))
        #expect(single.references.map(\.id) == [f.ids["policy"]!])
        _ = try await collect(single.tokens)
        #expect(f.llm.chatPrompts.last?.contains("420 EUR") == true)

        // All documents: full-text search picks the candidates, still permission filtered.
        let all = try await f.ai.chat.ask("insurance premium", context: access(f.alice))
        #expect(all.references.map(\.id) == [f.ids["policy"]!])
    }

    @Test func trailerEscapesTitles() {
        let trailer = AIChat.metadataTrailer([.init(id: 7, title: "A \"quoted\" title\nwith newline")])
        #expect(trailer == "\n\n__PAPERLESS_CHAT_METADATA__{\"references\":[{\"id\":7,\"title\":\"A \\\"quoted\\\" title\\nwith newline\"}]}")
    }
}
