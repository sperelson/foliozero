import Foundation

/// The AI configuration and backends in effect for one request.
public struct AIRuntime: Sendable {
    public var config: AIConfig
    public var llm: any LLMBackend
    /// nil when the LLM index is off (`AI_LLM_EMBEDDING_BACKEND=none`).
    public var embedder: (any EmbeddingBackend)?

    public init(config: AIConfig, llm: any LLMBackend, embedder: (any EmbeddingBackend)?) {
        self.config = config
        self.llm = llm
        self.embedder = embedder
    }

    /// Backends built from `config`. No embedder is built while the LLM index is off.
    public init(config: AIConfig) throws {
        self.config = config
        llm = Self.makeLLM(config)
        embedder = config.llmIndexEnabled ? try Self.makeEmbedder(config) : nil
    }

    /// The LLM backend `config` selects.
    public static func makeLLM(_ config: AIConfig) -> any LLMBackend {
        switch config.backend {
        case .apple:
            return AppleLanguageModelBackend(contextSize: config.contextSize, timeout: config.requestTimeout)
        case .openai:
            return OpenAICompatibleBackend(
                model: config.resolvedModel, endpoint: config.endpoint, apiKey: config.apiKey,
                contextSize: config.contextSize, timeout: config.requestTimeout,
                allowInternalEndpoints: config.allowInternalEndpoints, extraParams: config.extraParams)
        case .ollama:
            return OllamaBackend(
                model: config.resolvedModel, endpoint: config.endpoint, contextSize: config.contextSize,
                timeout: config.requestTimeout, allowInternalEndpoints: config.allowInternalEndpoints,
                extraParams: config.extraParams)
        }
    }

    /// The embedding backend `config` selects, or nil when the index is off.
    public static func makeEmbedder(_ config: AIConfig) throws -> (any EmbeddingBackend)? {
        guard let kind = config.embeddingBackend, let model = config.resolvedEmbeddingModel else { return nil }
        switch kind {
        case .apple:
            return try AppleSentenceEmbedding(languageCode: model)
        case .openai:
            return OpenAICompatibleEmbedding(
                model: model, endpoint: config.resolvedEmbeddingEndpoint, apiKey: config.resolvedEmbeddingAPIKey,
                timeout: config.requestTimeout, allowInternalEndpoints: config.allowInternalEndpoints)
        case .ollama:
            return OllamaEmbedding(
                model: model, endpoint: config.resolvedEmbeddingEndpoint, contextSize: config.contextSize,
                timeout: config.requestTimeout, allowInternalEndpoints: config.allowInternalEndpoints)
        }
    }
}

/// Produces the runtime for a request. The default re-reads settings and the database
/// application configuration each time, as Paperless-ngx does, so `/api/config/` changes
/// apply without a restart.
public typealias AIRuntimeProvider = @Sendable () throws -> AIRuntime

/// Entry point to the AI features: suggestions, the LLM index and chat.
///
/// Use `FolioAI.shared(for: app)` so every caller (HTTP handlers, workflows, scheduler)
/// shares one suggestion cache and one index writer.
public final class FolioAI: Sendable {
    public let app: FolioApp
    public let index: LLMIndex
    public let suggestions: AISuggestions
    public let chat: AIChat
    let runtime: AIRuntimeProvider

    /// - Parameter runtime: overrides how configuration and backends are resolved (tests).
    public init(app: FolioApp, runtime: AIRuntimeProvider? = nil) {
        self.app = app
        let provider: AIRuntimeProvider = runtime ?? { [app] in
            try AIRuntime(config: AIConfig.load(settings: app.settings, database: app.database))
        }
        self.runtime = provider
        index = LLMIndex(database: app.database, runtime: provider, logger: app.logger)
        suggestions = AISuggestions(app: app, index: index, runtime: provider)
        chat = AIChat(database: app.database, index: index, runtime: provider, logger: app.logger)
    }

    /// The configuration in effect now.
    public func config() throws -> AIConfig { try runtime().config }

    private static let registry = FolioAIRegistry()

    /// The process-wide instance for `app`.
    public static func shared(for app: FolioApp) -> FolioAI {
        registry.instance(for: app)
    }
}

final class FolioAIRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var instances: [ObjectIdentifier: FolioAI] = [:]

    func instance(for app: FolioApp) -> FolioAI {
        lock.withLock {
            if let existing = instances[ObjectIdentifier(app)] { return existing }
            let created = FolioAI(app: app)
            instances[ObjectIdentifier(app)] = created
            return created
        }
    }
}

/// A mutex for async code: one holder at a time, FIFO.
final class AsyncLock: Sendable {
    private actor State {
        var locked = false
        var waiters: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !locked {
                locked = true
                return
            }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            if waiters.isEmpty {
                locked = false
            } else {
                waiters.removeFirst().resume()
            }
        }
    }

    private let state = State()

    func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        await state.acquire()
        do {
            let value = try await body()
            await state.release()
            return value
        } catch {
            await state.release()
            throw error
        }
    }
}
