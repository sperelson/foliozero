import Foundation

/// HTTP plumbing shared by the OpenAI-compatible and Ollama backends: endpoint checks,
/// timeouts, no redirects, and error mapping to `AIError`.
struct AIHTTPClient: Sendable {
    let timeout: TimeInterval
    let allowInternalEndpoints: Bool
    var session: URLSession { Self.sharedSession }

    /// One session for every backend: no cookies, no cache, no redirects. Each request
    /// carries its own timeout.
    static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }()

    init(timeout: TimeInterval, allowInternalEndpoints: Bool) {
        self.timeout = timeout
        self.allowInternalEndpoints = allowInternalEndpoints
    }

    /// Builds `base` + `path`, checking scheme and (unless allowed) internal addresses.
    func url(base: String, path: String) throws -> URL {
        guard var components = URLComponents(string: base.trimmingCharacters(in: .whitespaces)),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty else {
            throw AIError.invalidConfiguration("AI endpoint \"\(base)\" is not an http(s) URL")
        }
        if !allowInternalEndpoints, NetworkPolicy.isInternal(host: host) {
            throw AIError.blockedEndpoint(host)
        }
        var basePath = components.path
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.path = path.hasPrefix("/") ? basePath + path : basePath + "/" + path
        guard let url = components.url else { throw AIError.invalidConfiguration("AI endpoint \"\(base)\" is not a valid URL") }
        return url
    }

    func request(_ url: URL, body: OrderedJSON, headers: [String: String]) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        request.httpBody = body.data
        return request
    }

    /// POST a JSON body; returns the response body of a 2xx answer.
    func postJSON(_ url: URL, body: OrderedJSON, headers: [String: String] = [:]) async throws -> Data {
        let request = request(url, body: body, headers: headers)
        let session = self.session
        do {
            return try await withAITimeout(timeout) {
                let (data, response) = try await session.data(for: request)
                try Self.check(response, body: data)
                return data
            }
        } catch {
            throw Self.map(error)
        }
    }

    /// POST a JSON body and stream the response line by line (SSE or NDJSON).
    func streamLines(_ url: URL, body: OrderedJSON, headers: [String: String] = [:]) -> AsyncThrowingStream<String, Error> {
        let session = self.session
        let request = request(url, body: body, headers: headers)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        var data = Data()
                        for try await byte in bytes {
                            data.append(byte)
                            if data.count > 64 * 1024 { break }
                        }
                        try Self.check(response, body: data)
                    }
                    for try await line in bytes.lines {
                        continuation.yield(line)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.map(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func check(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw AIError.providerRejected(status: http.statusCode, message: providerMessage(body))
        }
    }

    /// The provider's error message (`{"error": {"message": ...}}` or `{"error": "..."}`), shortened.
    static func providerMessage(_ body: Data) -> String {
        var message = String(decoding: body.prefix(2000), as: UTF8.self)
        if let object = try? JSONDecoder().decode([String: JSONValue].self, from: body) {
            switch object["error"] {
            case .string(let text)?: message = text
            case .object(let error)?: message = error["message"]?.stringValue ?? message
            default: break
            }
        }
        message = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.count > 300 ? String(message.prefix(300)) + "…" : message
    }

    static func map(_ error: Error) -> Error {
        if error is AIError || error is CancellationError { return error }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return AIError.timeout
            case .cancelled: return CancellationError()
            default: return AIError.unreachable(error.localizedDescription)
            }
        }
        return AIError.invalidResponse(error.localizedDescription)
    }
}

/// Refuses redirects so a request cannot be bounced to another (possibly internal) host.
private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

// MARK: - OpenAI-compatible

/// Any OpenAI-compatible chat completions API (`AI_LLM_BACKEND=openai`).
///
/// Classification uses `response_format` with a strict JSON schema; chat streams
/// server-sent events. The endpoint is the API base, e.g. `https://api.openai.com/v1`.
public struct OpenAICompatibleBackend: LLMBackend {
    public static let defaultEndpoint = "https://api.openai.com/v1"
    /// openai-python rejects empty keys; Paperless-ngx sends this placeholder.
    static let placeholderAPIKey = "fake"

    public let kind = LLMBackendKind.openai
    public let modelName: String
    public let endpoint: String
    let apiKey: String?
    let configuredContextSize: Int
    let extraParams: [String: JSONValue]
    let http: AIHTTPClient

    public init(model: String, endpoint: String? = nil, apiKey: String? = nil, contextSize: Int = 8192,
                timeout: TimeInterval = 120, allowInternalEndpoints: Bool = true, extraParams: [String: JSONValue] = [:]) {
        modelName = model
        self.endpoint = endpoint ?? Self.defaultEndpoint
        self.apiKey = apiKey
        configuredContextSize = contextSize
        self.extraParams = extraParams
        http = AIHTTPClient(timeout: timeout, allowInternalEndpoints: allowInternalEndpoints)
    }

    public func contextSize() async -> Int { configuredContextSize }
    public func tokenCount(_ text: String) async -> Int { estimatedTokenCount(text) }

    var headers: [String: String] { ["Authorization": "Bearer \(apiKey ?? Self.placeholderAPIKey)"] }

    /// `<endpoint>/chat/completions`; a bare host gets `/v1` added.
    func chatURL() throws -> URL {
        try http.url(base: Self.apiBase(endpoint), path: "chat/completions")
    }

    static func apiBase(_ endpoint: String) -> String {
        var base = endpoint.trimmingCharacters(in: .whitespaces)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/chat/completions") { base.removeLast("/chat/completions".count) }
        if base.hasSuffix("/embeddings") { base.removeLast("/embeddings".count) }
        if let components = URLComponents(string: base), components.path.isEmpty { base += "/v1" }
        return base
    }

    func body(instructions: String, prompt: String, stream: Bool, responseFormat: OrderedJSON?) -> OrderedJSON {
        var members: [OrderedJSON.Member] = [
            .init(key: "model", value: .string(modelName)),
            .init(key: "messages", value: .array([
                .ordered(["role": .string("system"), "content": .string(instructions)]),
                .ordered(["role": .string("user"), "content": .string(prompt)]),
            ])),
            .init(key: "stream", value: .bool(stream)),
        ]
        if let responseFormat { members.append(.init(key: "response_format", value: responseFormat)) }
        return OrderedJSON.object(members).merging(extraParams)
    }

    public func generateClassification(instructions: String, prompt: String) async throws -> ClassifierOutput {
        let format: OrderedJSON = .ordered([
            "type": .string("json_schema"),
            "json_schema": .ordered([
                "name": .string("DocumentClassifierSchema"),
                "schema": ClassifierOutput.orderedJSONSchema,
                "strict": .bool(true),
            ]),
        ])
        let body = body(instructions: instructions,
                        prompt: prompt + "\n\nAnswer with a single JSON object that matches the DocumentClassifierSchema.",
                        stream: false, responseFormat: format)
        let data = try await http.postJSON(try chatURL(), body: body, headers: headers)
        guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              case .array(let choices)? = object["choices"], case .object(let choice)? = choices.first,
              case .object(let message)? = choice["message"] else {
            throw AIError.invalidResponse("no choices in the chat completion")
        }
        if case .string(let refusal)? = message["refusal"], !refusal.isEmpty {
            throw AIError.providerRejected(status: 200, message: "the model refused: \(refusal.prefix(200))")
        }
        guard case .string(let content)? = message["content"] else {
            throw AIError.invalidResponse("the chat completion has no content")
        }
        return try ClassifierOutput.decode(fromModelText: content)
    }

    public func streamChat(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        let body = body(instructions: instructions, prompt: prompt, stream: true, responseFormat: nil)
        let url = Result { try chatURL() }
        let http = self.http
        let headers = self.headers
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in http.streamLines(try url.get(), body: body, headers: headers) {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        guard let data = payload.data(using: .utf8),
                              let event = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { continue }
                        if event["error"] != nil {
                            throw AIError.providerRejected(status: 0, message: AIHTTPClient.providerMessage(data))
                        }
                        if case .array(let choices)? = event["choices"], case .object(let choice)? = choices.first,
                           case .object(let delta)? = choice["delta"], case .string(let text)? = delta["content"], !text.isEmpty {
                            continuation.yield(text)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Ollama

/// An Ollama server (`AI_LLM_BACKEND=ollama`), default `http://localhost:11434`.
///
/// Classification passes the JSON schema as `format`; chat streams NDJSON.
/// `AI_LLM_CONTEXT_SIZE` is sent as `num_ctx`, and `AI_LLM_EXTRA_PARAMS` go into `options`.
public struct OllamaBackend: LLMBackend {
    public static let defaultEndpoint = "http://localhost:11434"

    public let kind = LLMBackendKind.ollama
    public let modelName: String
    public let endpoint: String
    let configuredContextSize: Int
    let extraParams: [String: JSONValue]
    let http: AIHTTPClient

    public init(model: String, endpoint: String? = nil, contextSize: Int = 8192, timeout: TimeInterval = 120,
                allowInternalEndpoints: Bool = true, extraParams: [String: JSONValue] = [:]) {
        modelName = model
        self.endpoint = endpoint ?? Self.defaultEndpoint
        configuredContextSize = contextSize
        self.extraParams = extraParams
        http = AIHTTPClient(timeout: timeout, allowInternalEndpoints: allowInternalEndpoints)
    }

    public func contextSize() async -> Int { configuredContextSize }
    public func tokenCount(_ text: String) async -> Int { estimatedTokenCount(text) }

    var options: OrderedJSON { OrderedJSON.ordered(["num_ctx": .int(configuredContextSize)]).merging(extraParams) }

    func body(instructions: String, prompt: String, stream: Bool, format: OrderedJSON?) -> OrderedJSON {
        var members: [OrderedJSON.Member] = [
            .init(key: "model", value: .string(modelName)),
            .init(key: "messages", value: .array([
                .ordered(["role": .string("system"), "content": .string(instructions)]),
                .ordered(["role": .string("user"), "content": .string(prompt)]),
            ])),
            .init(key: "stream", value: .bool(stream)),
            .init(key: "options", value: options),
        ]
        if let format {
            members.append(.init(key: "format", value: format))
            members.append(.init(key: "think", value: .bool(false)))
        }
        return .object(members)
    }

    public func generateClassification(instructions: String, prompt: String) async throws -> ClassifierOutput {
        let url = try http.url(base: endpoint, path: "api/chat")
        let data = try await http.postJSON(url, body: body(instructions: instructions, prompt: prompt, stream: false, format: ClassifierOutput.orderedJSONSchema))
        guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            throw AIError.invalidResponse("the Ollama answer is not JSON")
        }
        if object["error"] != nil { throw AIError.providerRejected(status: 0, message: AIHTTPClient.providerMessage(data)) }
        guard case .object(let message)? = object["message"], case .string(let content)? = message["content"] else {
            throw AIError.invalidResponse("the Ollama answer has no message")
        }
        return try ClassifierOutput.decode(fromModelText: content)
    }

    public func streamChat(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        let url = Result { try http.url(base: endpoint, path: "api/chat") }
        let body = body(instructions: instructions, prompt: prompt, stream: true, format: nil)
        let http = self.http
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await line in http.streamLines(try url.get(), body: body) {
                        guard let data = line.data(using: .utf8),
                              let event = try? JSONDecoder().decode([String: JSONValue].self, from: data) else { continue }
                        if event["error"] != nil {
                            throw AIError.providerRejected(status: 0, message: AIHTTPClient.providerMessage(data))
                        }
                        if case .object(let message)? = event["message"], case .string(let text)? = message["content"], !text.isEmpty {
                            continuation.yield(text)
                        }
                        if event["done"]?.boolValue == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
