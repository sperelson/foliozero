import Foundation
import Testing
@testable import FolioCore

@Suite struct AIConfigTests {
    @Test func defaults() throws {
        let config = try AIConfig(raw: [:])
        #expect(config.enabled == false)
        #expect(config.backend == .apple)
        #expect(config.embeddingBackend == .apple)
        #expect(config.embeddingChunkSize == 1024)
        #expect(config.contextSize == 8192)
        #expect(config.requestTimeout == 120)
        #expect(config.allowInternalEndpoints)
        #expect(config.extraParams.isEmpty)
        #expect(config.indexTaskCron == "10 2 * * *")
        #expect(config.llmIndexEnabled == false)
        #expect(config.resolvedModel == "system")
    }

    @Test func readsEverySetting() throws {
        let config = try AIConfig(raw: [
            "AI_ENABLED": "yes", "AI_LLM_BACKEND": "openai-like", "AI_LLM_MODEL": "gpt-4o-mini",
            "AI_LLM_API_KEY": "sk-1", "AI_LLM_ENDPOINT": "http://gw:8080/v1",
            "AI_LLM_EMBEDDING_BACKEND": "ollama", "AI_LLM_EMBEDDING_MODEL": "nomic-embed-text",
            "AI_LLM_EMBEDDING_CHUNK_SIZE": "512", "AI_LLM_CONTEXT_SIZE": "4096", "AI_LLM_REQUEST_TIMEOUT": "30",
            "AI_LLM_OUTPUT_LANGUAGE": "de", "AI_LLM_ALLOW_INTERNAL_ENDPOINTS": "false",
            "AI_LLM_EXTRA_PARAMS": #"{"reasoning_effort": "none", "temperature": 0.2}"#,
            "LLM_INDEX_TASK_CRON": "0 3 * * *",
        ])
        #expect(config.enabled)
        #expect(config.backend == .openai)
        #expect(config.resolvedModel == "gpt-4o-mini")
        #expect(config.apiKey == "sk-1")
        #expect(config.embeddingBackend == .ollama)
        #expect(config.resolvedEmbeddingModel == "nomic-embed-text")
        #expect(config.resolvedEmbeddingEndpoint == "http://gw:8080/v1")
        #expect(config.resolvedEmbeddingAPIKey == "sk-1")
        #expect(config.embeddingChunkSize == 512)
        #expect(config.contextSize == 4096)
        #expect(config.requestTimeout == 30)
        #expect(config.outputLanguage == "de")
        #expect(config.allowInternalEndpoints == false)
        #expect(config.extraParams["reasoning_effort"] == .string("none"))
        #expect(config.extraParams["temperature"] == .double(0.2))
        #expect(config.indexTaskCron == "0 3 * * *")
        #expect(config.llmIndexEnabled)
        #expect(config.cacheIdentity == "openai:gpt-4o-mini:http://gw:8080/v1")
    }

    @Test func embeddingBackendNoneTurnsIndexOff() throws {
        let config = try AIConfig(raw: ["AI_ENABLED": "true", "AI_LLM_EMBEDDING_BACKEND": "none"])
        #expect(config.embeddingBackend == nil)
        #expect(config.llmIndexEnabled == false)
        #expect(try AIRuntime.makeEmbedder(config) == nil)
    }

    @Test func rejectsInvalidValues() {
        #expect(throws: AIError.self) { try AIConfig(raw: ["AI_ENABLED": "maybe"]) }
        #expect(throws: AIError.self) { try AIConfig(raw: ["AI_LLM_BACKEND": "bard"]) }
        #expect(throws: AIError.self) { try AIConfig(raw: ["AI_LLM_EMBEDDING_BACKEND": "huggingface"]) }
        #expect(throws: AIError.self) { try AIConfig(raw: ["AI_LLM_EMBEDDING_CHUNK_SIZE": "0"]) }
        #expect(throws: AIError.self) { try AIConfig(raw: ["AI_LLM_EXTRA_PARAMS": "[1, 2]"]) }
    }

    @Test func settingsPrefixesAndDatabaseOverride() async throws {
        let dir = TempDir()
        let settings = try SettingsLoader.load(home: dir.url.path, environment: [
            "PAPERLESS_AI_ENABLED": "true", "FOLIOZERO_AI_LLM_BACKEND": "ollama", "PAPERLESS_OCR_LANGUAGE": "deu",
        ])
        let app = try FolioApp.open(settings: settings)
        var config = try AIConfig.load(settings: app.settings, database: app.database)
        #expect(config.enabled)
        #expect(config.backend == .ollama)
        #expect(config.resolvedModel == "llama3.1")
        // Apple embeddings follow OCR_LANGUAGE when NaturalLanguage has that language.
        #expect(["de", "en"].contains(config.resolvedEmbeddingModel ?? ""))

        try await app.database.write { db in
            try db.execute(sql: "INSERT INTO app_config(id, config) VALUES (1, ?)", arguments: [
                #"{"ai_enabled": false, "llm_backend": "openai-like", "llm_model": "m", "llm_context_size": 2048, "llm_output_language": null}"#,
            ])
        }
        config = try AIConfig.load(settings: app.settings, database: app.database)
        #expect(config.enabled == false)
        #expect(config.backend == .openai)
        #expect(config.resolvedModel == "m")
        #expect(config.contextSize == 2048)
        #expect(config.outputLanguage == nil)
    }

    @Test func errorStatusesMatchPaperless() {
        #expect(AIError.timeout.httpStatus == 503)
        #expect(AIError.providerRejected(status: 400, message: "bad").httpStatus == 502)
        #expect(AIError.disabled.httpStatus == 400)
        #expect(AIError.permissionDenied.httpStatus == 403)
        #expect(AIError.timeout.paperlessErrorBody == ["ai": ["AI backend request timed out."]])
        #expect(AIError.providerRejected(status: 500, message: "x").paperlessErrorBody == ["ai": ["AI backend rejected the request. Check logs for details."]])
        #expect(AIError.timeout.isTransient)
        #expect(AIError.providerRejected(status: 400, message: "x").isTransient == false)
    }
}

@Suite struct AIChunkingTests {
    @Test func normalisesOCRLeadersAndWhitespace() {
        #expect(TextChunker.normalize("Total.........12.00\t\t EUR") == "Total 12.00 EUR")
        #expect(TextChunker.normalize("a____b\nc  d") == "a b\nc d")
    }

    @Test func shortTextIsOneChunk() {
        #expect(TextChunker.chunks("Hello world.", chunkSize: 64) == ["Hello world."])
        #expect(TextChunker.chunks("   \n ", chunkSize: 64).isEmpty)
    }

    @Test func chunksRespectSizeAndOverlap() {
        let sentences = (1...200).map { "Sentence number \($0) is here." }
        let text = sentences.joined(separator: " ")
        let chunks = TextChunker.chunks(text, chunkSize: 50, overlap: 10)
        #expect(chunks.count > 5)
        for chunk in chunks { #expect(chunk.count <= 200) }
        // Every sentence survives, and consecutive chunks share text.
        let joined = chunks.joined(separator: " ")
        for sentence in sentences { #expect(joined.contains(sentence)) }
        for (a, b) in zip(chunks, chunks.dropFirst()) {
            let lastWords = a.split(separator: " ").suffix(3).joined(separator: " ")
            #expect(b.contains(lastWords))
        }
        // Chunks end at sentence boundaries when possible.
        #expect(chunks.dropLast().allSatisfy { $0.hasSuffix(".") })
    }

    @Test func overlongWordsAreSplit() {
        let text = String(repeating: "x", count: 1000)
        let chunks = TextChunker.chunks(text, chunkSize: 25, overlap: 0)
        #expect(chunks.count == 10)
        #expect(chunks.allSatisfy { $0.count == 100 })
    }

    @Test func prefixCutsAtWordBoundary() {
        let text = (1...100).map { "word\($0)" }.joined(separator: " ")
        let head = TextChunker.prefix(text, tokens: 10)
        #expect(head.count <= 40)
        #expect(text.hasPrefix(head))
        #expect(!head.hasSuffix(" "))
        #expect(head.split(separator: " ").allSatisfy { $0.hasPrefix("word") && Int($0.dropFirst(4)) != nil })
    }
}
