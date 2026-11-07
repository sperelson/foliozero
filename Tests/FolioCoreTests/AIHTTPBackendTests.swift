import Foundation
import Testing
@testable import FolioCore

@Suite struct AIHTTPBackendTests {
    static let classification = #"{"title":"ACME invoice 42","tags":["Invoice","Hardware"],"matched_tags":["Invoice"],"tag_ids":[3],"correspondents":["ACME"],"matched_correspondents":[],"correspondent_ids":[],"document_types":["Invoice"],"matched_document_types":[],"document_type_ids":[],"storage_paths":[],"matched_storage_paths":[],"storage_path_ids":[],"dates":["2024-03-14"]}"#

    static func jsonString(_ text: String) -> String {
        String(decoding: try! JSONEncoder().encode(text), as: UTF8.self)
    }

    // MARK: OpenAI-compatible

    @Test func openAIClassificationSendsSchemaKeyAndExtraParams() async throws {
        let server = try FakeHTTPServer { _ in
            .json(#"{"id":"x","choices":[{"index":0,"message":{"role":"assistant","content":\#(Self.jsonString(Self.classification))}}]}"#)
        }
        defer { server.stop() }
        let backend = OpenAICompatibleBackend(model: "gpt-test", endpoint: server.baseURL + "/v1", apiKey: "sk-test",
                                              timeout: 5, extraParams: ["reasoning_effort": .string("none"), "stream": .bool(false)])
        let output = try await backend.generateClassification(instructions: "system text", prompt: "document text")
        #expect(output.title == "ACME invoice 42")
        #expect(output.tagIds == [3])
        #expect(output.dates == ["2024-03-14"])

        let request = try #require(server.requests.first)
        #expect(request.method == "POST")
        #expect(request.path == "/v1/chat/completions")
        #expect(request.headers["authorization"] == "Bearer sk-test")
        let body = try #require(request.json)
        #expect(body["model"] == .string("gpt-test"))
        #expect(body["reasoning_effort"] == .string("none"))
        guard case .object(let format)? = body["response_format"], case .object(let schema)? = format["json_schema"] else {
            Issue.record("no response_format")
            return
        }
        #expect(format["type"] == .string("json_schema"))
        #expect(schema["strict"] == .bool(true))
        // Key order is kept: models fill the schema in property order.
        let raw = String(decoding: request.body, as: UTF8.self)
        #expect(raw.hasPrefix(#"{"model":"gpt-test","messages":[{"role":"system","content":"system text"}"#))
        let order = ["\"title\":{", "\"tags\":{", "\"matched_tags\":{", "\"tag_ids\":{", "\"correspondents\":{", "\"dates\":{", "\"reasoning_effort\""]
        let positions = order.compactMap { raw.range(of: $0)?.lowerBound }
        #expect(positions.count == order.count)
        #expect(positions == positions.sorted())
        guard case .array(let messages)? = body["messages"] else { Issue.record("no messages"); return }
        #expect(messages.count == 2)
        #expect(messages.first == .object(["role": .string("system"), "content": .string("system text")]))
    }

    @Test func openAIStreamsServerSentEvents() async throws {
        let events = ["Hello", ", ", "world", "!"].map { #"data: {"choices":[{"delta":{"content":\#(Self.jsonString($0))}}]}"# + "\n\n" }
        let server = try FakeHTTPServer { _ in
            .chunked(contentType: "text/event-stream", chunks: [": keep-alive\n\n"] + events + ["data: [DONE]\n\n"], delay: 0.02)
        }
        defer { server.stop() }
        let backend = OpenAICompatibleBackend(model: "gpt-test", endpoint: server.baseURL, timeout: 5)
        var pieces: [String] = []
        for try await piece in backend.streamChat(instructions: "sys", prompt: "q") { pieces.append(piece) }
        #expect(pieces == ["Hello", ", ", "world", "!"])
        // A bare host gets /v1, and no key means the placeholder key.
        #expect(server.requests.first?.path == "/v1/chat/completions")
        #expect(server.requests.first?.headers["authorization"] == "Bearer fake")
        #expect(server.requests.first?.json?["stream"] == .bool(true))
    }

    @Test func providerErrorsAndTimeouts() async throws {
        let rejecting = try FakeHTTPServer { _ in .json(#"{"error":{"message":"Invalid API key","type":"auth"}}"#, status: 401) }
        defer { rejecting.stop() }
        let backend = OpenAICompatibleBackend(model: "m", endpoint: rejecting.baseURL, timeout: 5)
        await #expect(throws: AIError.providerRejected(status: 401, message: "Invalid API key")) {
            try await backend.generateClassification(instructions: "s", prompt: "p")
        }
        do {
            _ = try await collect(backend.streamChat(instructions: "s", prompt: "p"))
            Issue.record("expected an error")
        } catch let error as AIError {
            #expect(error == .providerRejected(status: 401, message: "Invalid API key"))
            #expect(error.httpStatus == 502)
        }

        let hanging = try FakeHTTPServer { _ in .hang }
        defer { hanging.stop() }
        let slow = OllamaBackend(model: "m", endpoint: hanging.baseURL, timeout: 1)
        let started = Date()
        await #expect(throws: AIError.timeout) {
            try await slow.generateClassification(instructions: "s", prompt: "p")
        }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(AIError.timeout.httpStatus == 503)

        let unreachable = OpenAICompatibleBackend(model: "m", endpoint: "http://127.0.0.1:1", timeout: 5)
        do {
            _ = try await unreachable.generateClassification(instructions: "s", prompt: "p")
            Issue.record("expected an error")
        } catch let error as AIError {
            guard case .unreachable = error else { Issue.record("unexpected \(error)"); return }
        }

        let garbage = try FakeHTTPServer { _ in .json(#"{"choices":[{"message":{"content":"I cannot do JSON"}}]}"#) }
        defer { garbage.stop() }
        await #expect(throws: AIError.self) {
            try await OpenAICompatibleBackend(model: "m", endpoint: garbage.baseURL, timeout: 5).generateClassification(instructions: "s", prompt: "p")
        }
    }

    @Test func internalEndpointsCanBeBlocked() async throws {
        let backend = OpenAICompatibleBackend(model: "m", endpoint: "http://127.0.0.1:9/v1", timeout: 5, allowInternalEndpoints: false)
        await #expect(throws: AIError.blockedEndpoint("127.0.0.1")) {
            try await backend.generateClassification(instructions: "s", prompt: "p")
        }
        let ollama = OllamaEmbedding(model: "m", endpoint: "http://localhost:11434", allowInternalEndpoints: false)
        await #expect(throws: AIError.blockedEndpoint("localhost")) { try await ollama.embed(["x"]) }
        let notHTTP = OllamaBackend(model: "m", endpoint: "file:///etc/passwd")
        await #expect(throws: AIError.self) { try await notHTTP.generateClassification(instructions: "s", prompt: "p") }
    }

    // MARK: Ollama

    @Test func ollamaClassificationSendsFormatAndOptions() async throws {
        let server = try FakeHTTPServer { _ in
            .json(#"{"model":"llama3.1","message":{"role":"assistant","content":\#(Self.jsonString(Self.classification))},"done":true}"#)
        }
        defer { server.stop() }
        let backend = OllamaBackend(model: "llama3.1", endpoint: server.baseURL, contextSize: 4096, timeout: 5, extraParams: ["temperature": .double(0.1)])
        let output = try await backend.generateClassification(instructions: "sys", prompt: "doc")
        #expect(output.correspondents == ["ACME"])

        let body = try #require(server.requests.first?.json)
        #expect(server.requests.first?.path == "/api/chat")
        #expect(body["stream"] == .bool(false))
        #expect(body["think"] == .bool(false))
        #expect(body["options"] == .object(["num_ctx": .int(4096), "temperature": .double(0.1)]))
        guard case .object(let format)? = body["format"] else { Issue.record("no format"); return }
        #expect(format["type"] == .string("object"))
    }

    @Test func ollamaStreamsNDJSON() async throws {
        let lines = ["The ", "answer ", "is 42."].map { #"{"message":{"role":"assistant","content":\#(Self.jsonString($0))},"done":false}"# + "\n" }
        let server = try FakeHTTPServer { _ in
            .chunked(contentType: "application/x-ndjson", chunks: lines + [#"{"message":{"role":"assistant","content":""},"done":true}"# + "\n"], delay: 0.02)
        }
        defer { server.stop() }
        let text = try await collect(OllamaBackend(model: "m", endpoint: server.baseURL, timeout: 5).streamChat(instructions: "s", prompt: "q"))
        #expect(text == "The answer is 42.")
        #expect(server.requests.first?.json?["stream"] == .bool(true))
        #expect(server.requests.first?.json?["format"] == nil)
    }

    @Test func ollamaStreamErrorLine() async throws {
        let server = try FakeHTTPServer { _ in
            .chunked(contentType: "application/x-ndjson", chunks: [#"{"error":"model 'nope' not found"}"# + "\n"], delay: 0.01)
        }
        defer { server.stop() }
        await #expect(throws: AIError.providerRejected(status: 0, message: "model 'nope' not found")) {
            _ = try await collect(OllamaBackend(model: "nope", endpoint: server.baseURL, timeout: 5).streamChat(instructions: "s", prompt: "q"))
        }
    }

    // MARK: Embeddings

    @Test func openAIAndOllamaEmbeddings() async throws {
        let openAI = try FakeHTTPServer { _ in
            .json(#"{"object":"list","data":[{"index":1,"embedding":[0,1]},{"index":0,"embedding":[1,0]}],"model":"e"}"#)
        }
        defer { openAI.stop() }
        let vectors = try await OpenAICompatibleEmbedding(model: "e", endpoint: openAI.baseURL + "/v1", apiKey: "k", timeout: 5).embed(["a", "b"])
        #expect(vectors == [[1, 0], [0, 1]])
        #expect(openAI.requests.first?.path == "/v1/embeddings")
        #expect(openAI.requests.first?.json?["input"] == .array([.string("a"), .string("b")]))

        let ollama = try FakeHTTPServer { _ in .json(#"{"model":"e","embeddings":[[0.5,0.5]]}"#) }
        defer { ollama.stop() }
        let embedding = OllamaEmbedding(model: "embeddinggemma", endpoint: ollama.baseURL, contextSize: 2048, timeout: 5)
        #expect(try await embedding.embed(["x"]) == [[0.5, 0.5]])
        #expect(embedding.modelIdentity == "ollama:embeddinggemma")
        #expect(ollama.requests.first?.path == "/api/embed")
        #expect(ollama.requests.first?.json?["options"] == .object(["num_ctx": .int(2048)]))
    }

    @Test func runtimeBuildsConfiguredBackends() throws {
        var config = aiConfig()
        config.backend = .ollama
        config.endpoint = "http://ollama.local:11434"
        config.embeddingBackend = .openai
        config.embeddingEndpoint = "https://api.example.com/v1"
        let runtime = try AIRuntime(config: config)
        #expect(runtime.llm.kind == .ollama)
        #expect(runtime.llm.modelName == "llama3.1")
        #expect((runtime.embedder as? OpenAICompatibleEmbedding)?.endpoint == "https://api.example.com/v1")
        #expect(runtime.embedder?.modelIdentity == "openai:text-embedding-3-small")
    }
}
