import Foundation
import NaturalLanguage
import Testing
@testable import FolioCore

/// Runs Apple's on-device model for real. Skipped when Apple Intelligence is unavailable.
@Suite(.serialized) struct AIAppleBackendTests {
    static let modelAvailable = AppleLanguageModelBackend.isAvailable
    static let skipReason: Comment = "Apple's on-device model is unavailable: \(AppleLanguageModelBackend.availabilityError()?.description ?? "")"
    static let embeddingAvailable = NLEmbedding.sentenceEmbedding(for: .english) != nil

    static let invoice = """
        ACME Corporation, 12 Main Road, Cape Town
        INVOICE No. 2024-042
        Invoice date: 14 March 2024
        Bill to: Jane Doe
        2 x USB-C docking station   R 2 400.00
        VAT 15%                      R   360.00
        Total due by 13 April 2024:  R 2 760.00
        """

    @Test(.enabled(if: AIAppleBackendTests.modelAvailable, AIAppleBackendTests.skipReason)) func reportsContextAndTokens() async throws {
        // The reported window varies by OS and load; only its bounds are certain.
        let backend = AppleLanguageModelBackend(contextSize: 100_000)
        let context = await backend.contextSize()
        #expect(context > 0 && context <= 100_000)
        let capped = await AppleLanguageModelBackend(contextSize: 1000).contextSize()
        #expect(capped > 0 && capped <= 1000)
        let tokens = await backend.tokenCount("Hello world, this is a short sentence.")
        #expect(tokens > 0 && tokens < 40)
        #expect(await backend.schemaTokenCount() > 0)
    }

    @Test(.enabled(if: AIAppleBackendTests.modelAvailable, AIAppleBackendTests.skipReason)) func classifiesAnInvoiceWithGuidedGeneration() async throws {
        let backend = AppleLanguageModelBackend(timeout: 180)
        let prompt = AIPrompts.classification(filename: "scan_0001.pdf", content: Self.invoice, taxonomyBlock: "", hasCandidates: false)
        let output = try await backend.generateClassification(instructions: llmSystemPrompt, prompt: prompt)
        #expect(!output.title.isEmpty)
        #expect(output.title.count <= ClassifierOutput.maxTitleLength)
        #expect(output.dates.count <= ClassifierOutput.maxDates)
        #expect(output.correspondents.count <= ClassifierOutput.maxSingleValueNames)
        let everything = ([output.title] + output.correspondents + output.documentTypes + output.tags).joined(separator: " ").lowercased()
        #expect(everything.contains("acme") || everything.contains("invoice"))
    }

    @Test(.enabled(if: AIAppleBackendTests.modelAvailable, AIAppleBackendTests.skipReason)) func streamsAChatAnswer() async throws {
        let backend = AppleLanguageModelBackend(timeout: 180)
        let prompt = AIPrompts.chat(
            context: "title: Car insurance policy\n\nThe annual car insurance premium is 420 EUR, payable in January.",
            query: "How much is the annual car insurance premium?", outputLanguage: nil)
        var pieces: [String] = []
        for try await piece in backend.streamChat(instructions: llmSystemPrompt, prompt: prompt) { pieces.append(piece) }
        #expect(!pieces.isEmpty)
        #expect(pieces.joined().contains("420"))
    }

    @Test(.enabled(if: AIAppleBackendTests.modelAvailable && AIAppleBackendTests.embeddingAvailable, AIAppleBackendTests.skipReason)) func endToEndSuggestionsAndChatOnDevice() async throws {
        let dir = TempDir()
        let app = try makeAIApp(dir)
        var config = try AIConfig(raw: ["AI_ENABLED": "true", "AI_LLM_EMBEDDING_MODEL": "en", "AI_LLM_REQUEST_TIMEOUT": "180"])
        config.embeddingChunkSize = 256
        let runtime = try AIRuntime(config: config)
        #expect(runtime.llm.kind == .apple)
        let ai = FolioAI(app: app, runtime: { runtime })
        let (user, invoice) = try await app.database.write { db -> (User, Int) in
            let user = try makeUser("jane", in: db)
            var acme = Correspondent(name: "ACME Corporation", ownerId: user.id)
            try acme.insert(db)
            var invoiceType = DocumentType(name: "Invoice")
            try invoiceType.insert(db)
            let older = try insertDocument("ACME invoice 2024-001", content: Self.invoice.replacingOccurrences(of: "042", with: "001"), owner: user.id, in: db)
            var document = try DocumentStore.document(older, in: db)
            document.correspondentId = acme.id
            document.documentTypeId = invoiceType.id
            try DocumentStore.update(document, in: db)
            let invoice = try insertDocument("scan_0001", content: Self.invoice, owner: user.id, in: db)
            return (user, invoice)
        }
        #expect(try await ai.index.update() == "LLM index rebuilt successfully.")

        let suggestions = try await ai.suggestions.suggestions(documentId: invoice, context: access(user))
        #expect(!suggestions.title.isEmpty)
        #expect(!(suggestions.correspondents.isEmpty && suggestions.suggestedCorrespondents.isEmpty))

        let response = try await ai.chat.ask("What is the total due on invoice 2024-042?", documentId: invoice, context: access(user))
        #expect(response.references.map(\.id) == [invoice])
        let answer = try await collect(response.tokens)
        #expect(answer.contains("2") && !answer.isEmpty)
    }

    @Test(.enabled(if: AIAppleBackendTests.embeddingAvailable, "NaturalLanguage has no English sentence embedding")) func appleSentenceEmbeddingsRankSimilarTextHigher() async throws {
        let embedding = try AppleSentenceEmbedding(languageCode: "en")
        #expect(embedding.modelIdentity.hasPrefix("apple:sentence:en:"))
        let vectors = try await embedding.embed([
            "The car insurance premium is due in January.",
            "Pay the annual vehicle insurance by January.",
            "Mix flour, water and yeast to make pizza dough.",
            "",
        ])
        #expect(vectors.count == 4)
        let a = LLMIndex.normalised(vectors[0]), b = LLMIndex.blob(LLMIndex.normalised(vectors[1])), c = LLMIndex.blob(LLMIndex.normalised(vectors[2]))
        let similar = try #require(LLMIndex.dot(a, b))
        let unrelated = try #require(LLMIndex.dot(a, c))
        #expect(similar > unrelated)
        #expect(throws: AIError.self) { try AppleSentenceEmbedding(languageCode: "xx") }
        #expect(AppleSentenceEmbedding.languageCode(forOCRLanguage: "eng+deu") == "en")
    }
}
