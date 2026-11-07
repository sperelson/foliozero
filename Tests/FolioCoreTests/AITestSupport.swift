import Foundation
import GRDB
import Network
@testable import FolioCore

// MARK: - App and data

func makeAIApp(_ dir: TempDir) throws -> FolioApp {
    let settings = try SettingsLoader.load(home: dir.url.path, environment: [:], overrides: ["TIME_ZONE": "UTC"])
    return try FolioApp.open(settings: settings)
}

/// AI on, with the given backends.
func aiConfig(enabled: Bool = true, chunkSize: Int = 64, contextSize: Int = 8192) -> AIConfig {
    var config = AIConfig()
    config.enabled = enabled
    config.embeddingChunkSize = chunkSize
    config.contextSize = contextSize
    return config
}

func makeUser(_ name: String, superuser: Bool = false, in db: Database) throws -> User {
    var user = User(username: name, isSuperuser: superuser)
    try user.insert(db)
    return user
}

func access(_ user: User, groups: [Int] = []) -> AccessContext {
    AccessContext(user: user, groupIds: groups, permissions: Set(Permission.all))
}

@discardableResult
func insertDocument(_ title: String, content: String, owner: Int? = nil, filename: String? = nil, in db: Database) throws -> Int {
    var document = Document.fixture(title, content: content)
    document.ownerId = owner
    document.filename = filename
    return try DocumentStore.insert(document, in: db).id!
}

// MARK: - Fake backends

/// A scripted language model that records what it was asked.
final class FakeLLM: LLMBackend, @unchecked Sendable {
    let kind = LLMBackendKind.openai
    let modelName = "fake"
    private let lock = NSLock()
    private var _output: ClassifierOutput
    private var _prompts: [String] = []
    private var _chatPrompts: [String] = []
    var answer: [String]
    var error: AIError?
    var context: Int

    init(output: ClassifierOutput = ClassifierOutput(), answer: [String] = ["Hello", " world"], context: Int = 8192) {
        _output = output
        self.answer = answer
        self.context = context
    }

    var output: ClassifierOutput {
        get { lock.withLock { _output } }
        set { lock.withLock { _output = newValue } }
    }
    var prompts: [String] { lock.withLock { _prompts } }
    var chatPrompts: [String] { lock.withLock { _chatPrompts } }

    func contextSize() async -> Int { context }
    func tokenCount(_ text: String) async -> Int { estimatedTokenCount(text) }

    func generateClassification(instructions: String, prompt: String) async throws -> ClassifierOutput {
        lock.withLock { _prompts.append(prompt) }
        if let error { throw error }
        return output
    }

    func streamChat(instructions: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        lock.withLock { _chatPrompts.append(prompt) }
        let answer = self.answer
        let error = self.error
        return AsyncThrowingStream { continuation in
            for piece in answer { continuation.yield(piece) }
            continuation.finish(throwing: error)
        }
    }
}

/// Deterministic bag-of-words embedding: each lower-cased word adds 1 to one of 64 buckets.
final class FakeEmbedder: EmbeddingBackend, @unchecked Sendable {
    let modelIdentity: String
    private let lock = NSLock()
    private var _embedded: [String] = []

    init(identity: String = "fake:bow64") { modelIdentity = identity }

    var embeddedCount: Int { lock.withLock { _embedded.count } }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        lock.withLock { _embedded += texts }
        return texts.map(Self.vector)
    }

    static func vector(_ text: String) -> [Float] {
        var vector = [Float](repeating: 0, count: 64)
        for word in text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            var hash: UInt32 = 2166136261
            for byte in word.utf8 { hash = (hash ^ UInt32(byte)) &* 16777619 }
            vector[Int(hash % 64)] += 1
        }
        return vector
    }
}

func fakeRuntime(_ config: AIConfig = aiConfig(), llm: FakeLLM = FakeLLM(), embedder: (any EmbeddingBackend)? = FakeEmbedder()) -> AIRuntimeProvider {
    { AIRuntime(config: config, llm: llm, embedder: embedder) }
}

// MARK: - Fake HTTP server

/// A tiny HTTP/1.1 server on localhost. Each connection serves one request.
final class FakeHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data

        var json: [String: JSONValue]? { try? JSONDecoder().decode([String: JSONValue].self, from: body) }
    }

    enum Reply: Sendable {
        case full(status: Int, contentType: String, body: Data)
        /// Any status with extra response headers (`Location`, `Operation-Location`, ...).
        case custom(status: Int, headers: [String: String], body: Data)
        case chunked(contentType: String, chunks: [String], delay: TimeInterval)
        case hang

        static func json(_ text: String, status: Int = 200) -> Reply {
            .full(status: status, contentType: "application/json", body: Data(text.utf8))
        }
    }

    let listener: NWListener
    private let queue = DispatchQueue(label: "fake-http")
    private let lock = NSLock()
    private var received: [Request] = []
    private var connections: [NWConnection] = []
    private let handler: @Sendable (Request) -> Reply

    var port: Int { Int(listener.port!.rawValue) }
    var baseURL: String { "http://127.0.0.1:\(port)" }
    var requests: [Request] { lock.withLock { received } }

    init(_ handler: @escaping @Sendable (Request) -> Reply) throws {
        self.handler = handler
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    func stop() {
        listener.cancel()
        lock.withLock { connections.forEach { $0.cancel() } }
    }

    private final class Buffer: @unchecked Sendable { var data = Data() }

    private func serve(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        receive(connection, into: Buffer())
    }

    private func receive(_ connection: NWConnection, into buffer: Buffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [self] data, _, done, _ in
            if let data { buffer.data.append(data) }
            if let request = Self.parse(buffer.data) {
                lock.withLock { received.append(request) }
                respond(connection, handler(request))
                return
            }
            if !done { receive(connection, into: buffer) }
        }
    }

    static func parse(_ buffer: Data) -> Request? {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = buffer[end.upperBound...]
        guard body.count >= length else { return nil }
        return Request(method: String(requestLine.first ?? ""), path: requestLine.count > 1 ? String(requestLine[1]) : "/",
                       headers: headers, body: Data(body.prefix(length)))
    }

    private func respond(_ connection: NWConnection, _ reply: Reply) {
        switch reply {
        case .hang:
            return
        case let .full(status, contentType, body):
            var data = Data("HTTP/1.1 \(status) Status\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            data.append(body)
            connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        case let .custom(status, headers, body):
            let extra = headers.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value)\r\n" }.joined()
            var data = Data("HTTP/1.1 \(status) Status\r\n\(extra)Content-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
            data.append(body)
            connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        case let .chunked(contentType, chunks, delay):
            let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
            connection.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
            for (index, chunk) in chunks.enumerated() {
                queue.asyncAfter(deadline: .now() + delay * Double(index + 1)) {
                    let bytes = Data(chunk.utf8)
                    var frame = Data(String(bytes.count, radix: 16).utf8)
                    frame.append(Data("\r\n".utf8))
                    frame.append(bytes)
                    frame.append(Data("\r\n".utf8))
                    connection.send(content: frame, completion: .contentProcessed { _ in })
                }
            }
            queue.asyncAfter(deadline: .now() + delay * Double(chunks.count + 1)) {
                connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}

/// Collects a stream into one string.
func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> String {
    var text = ""
    for try await piece in stream { text += piece }
    return text
}

func collect(_ stream: AsyncStream<String>) async -> String {
    var text = ""
    for await piece in stream { text += piece }
    return text
}
