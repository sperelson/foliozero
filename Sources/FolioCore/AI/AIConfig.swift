import Foundation
import GRDB

/// The language model that generates suggestions and chat answers.
public enum LLMBackendKind: String, Sendable, Codable, CaseIterable {
    /// Apple's on-device model (FoundationModels). Document text never leaves the Mac.
    case apple
    /// Any OpenAI-compatible `/v1/chat/completions` API.
    case openai
    /// An Ollama server (`/api/chat`).
    case ollama

    /// Parses a setting value. Accepts the Paperless-ngx spelling `openai-like`.
    public init?(setting: String) {
        switch setting.trimmingCharacters(in: .whitespaces).lowercased() {
        case "apple", "apple-intelligence", "foundationmodels", "on-device": self = .apple
        case "openai", "openai-like", "openai_like", "openai-compatible": self = .openai
        case "ollama": self = .ollama
        default: return nil
        }
    }

    /// Model used when `AI_LLM_MODEL` is not set (Paperless-ngx defaults for the HTTP backends).
    public var defaultModel: String {
        switch self {
        case .apple: "system"
        case .openai: "gpt-3.5-turbo"
        case .ollama: "llama3.1"
        }
    }
}

/// The embedding model that turns chunks of text into vectors for the LLM index.
public enum EmbeddingBackendKind: String, Sendable, Codable, CaseIterable {
    /// NaturalLanguage sentence embeddings, on device.
    case apple
    /// Any OpenAI-compatible `/v1/embeddings` API.
    case openai
    /// An Ollama server (`/api/embed`).
    case ollama

    public init?(setting: String) {
        switch setting.trimmingCharacters(in: .whitespaces).lowercased() {
        case "apple", "naturallanguage", "on-device": self = .apple
        case "openai", "openai-like", "openai_like", "openai-compatible": self = .openai
        case "ollama": self = .ollama
        default: return nil
        }
    }

    /// Model used when `AI_LLM_EMBEDDING_MODEL` is not set. For `apple` the model is a
    /// language code; nil means "derive it from `OCR_LANGUAGE`".
    public var defaultModel: String? {
        switch self {
        case .apple: nil
        case .openai: "text-embedding-3-small"
        case .ollama: "embeddinggemma"
        }
    }
}

/// AI settings (Paperless-ngx `AIConfig`).
///
/// Read from `Settings.raw` (`FOLIOZERO_AI_*` or `PAPERLESS_AI_*`). Values stored in the
/// database application configuration (`/api/config/`) take precedence, as in Paperless-ngx.
/// Build with `AIConfig(settings:)` or `AIConfig.load(settings:database:)`.
public struct AIConfig: Sendable, Equatable {
    /// `AI_ENABLED`. Master switch, default false.
    public var enabled: Bool = false
    /// `AI_LLM_BACKEND`. Default `apple`.
    public var backend: LLMBackendKind = .apple
    /// `AI_LLM_MODEL`. nil means `backend.defaultModel`.
    public var model: String?
    /// `AI_LLM_API_KEY`.
    public var apiKey: String?
    /// `AI_LLM_ENDPOINT`. Required for Ollama in Paperless-ngx; FolioZero defaults to `http://localhost:11434`.
    public var endpoint: String?
    /// `AI_LLM_EMBEDDING_BACKEND`. Default `apple`; `none` turns the LLM index off.
    public var embeddingBackend: EmbeddingBackendKind? = .apple
    /// `AI_LLM_EMBEDDING_MODEL`. For `apple`, a language code such as `en` or `de`.
    public var embeddingModel: String?
    /// `AI_LLM_EMBEDDING_API_KEY`. Falls back to `apiKey`.
    public var embeddingAPIKey: String?
    /// `AI_LLM_EMBEDDING_ENDPOINT`. Falls back to `endpoint`.
    public var embeddingEndpoint: String?
    /// `AI_LLM_EMBEDDING_CHUNK_SIZE`, in tokens. Default 1024.
    public var embeddingChunkSize: Int = 1024
    /// `AI_LLM_CONTEXT_SIZE`, in tokens. Default 8192. The Apple backend uses the smaller
    /// of this and the on-device model's context window.
    public var contextSize: Int = 8192
    /// `AI_LLM_REQUEST_TIMEOUT`, in seconds. Default 120.
    public var requestTimeout: TimeInterval = 120
    /// `AI_LLM_OUTPUT_LANGUAGE`. nil means the user's UI language.
    public var outputLanguage: String?
    /// `AI_LLM_ALLOW_INTERNAL_ENDPOINTS`. Default true.
    public var allowInternalEndpoints: Bool = true
    /// `AI_LLM_EXTRA_PARAMS`: a JSON object merged into every HTTP request body.
    public var extraParams: [String: JSONValue] = [:]
    /// `LLM_INDEX_TASK_CRON`. Default `10 2 * * *`.
    public var indexTaskCron: String = "10 2 * * *"
    /// First `OCR_LANGUAGE` entry, used to pick the default Apple embedding language.
    public var ocrLanguage: String = "eng"

    public init() {}

    /// Reads every AI setting from `settings.raw`.
    public init(settings: Settings) throws {
        try self.init(raw: settings.raw)
        ocrLanguage = settings.ocrLanguage.first ?? "eng"
    }

    /// Reads AI settings from prefix-stripped keys (`AI_ENABLED`, `AI_LLM_BACKEND`, ...).
    public init(raw: [String: String]) throws {
        func value(_ key: String) -> String? {
            guard let v = raw[key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
            return v
        }
        if let v = value("AI_ENABLED") { enabled = try Self.bool("AI_ENABLED", v) }
        if let v = value("AI_LLM_BACKEND") { backend = try Self.llmBackend(v) }
        model = value("AI_LLM_MODEL")
        apiKey = value("AI_LLM_API_KEY")
        endpoint = value("AI_LLM_ENDPOINT")
        if let v = value("AI_LLM_EMBEDDING_BACKEND") { embeddingBackend = try Self.embeddingBackend(v) }
        embeddingModel = value("AI_LLM_EMBEDDING_MODEL")
        embeddingAPIKey = value("AI_LLM_EMBEDDING_API_KEY")
        embeddingEndpoint = value("AI_LLM_EMBEDDING_ENDPOINT")
        if let v = value("AI_LLM_EMBEDDING_CHUNK_SIZE") { embeddingChunkSize = try Self.positiveInt("AI_LLM_EMBEDDING_CHUNK_SIZE", v) }
        if let v = value("AI_LLM_CONTEXT_SIZE") { contextSize = try Self.positiveInt("AI_LLM_CONTEXT_SIZE", v) }
        if let v = value("AI_LLM_REQUEST_TIMEOUT") { requestTimeout = TimeInterval(try Self.positiveInt("AI_LLM_REQUEST_TIMEOUT", v)) }
        outputLanguage = value("AI_LLM_OUTPUT_LANGUAGE")
        if let v = value("AI_LLM_ALLOW_INTERNAL_ENDPOINTS") { allowInternalEndpoints = try Self.bool("AI_LLM_ALLOW_INTERNAL_ENDPOINTS", v) }
        if let v = value("AI_LLM_EXTRA_PARAMS") { extraParams = try Self.jsonObject("AI_LLM_EXTRA_PARAMS", v) }
        if let v = value("LLM_INDEX_TASK_CRON") { indexTaskCron = v }
    }

    /// Settings plus the database application configuration, which wins where set.
    public static func load(settings: Settings, database: FolioDatabase) throws -> AIConfig {
        var config = try AIConfig(settings: settings)
        let stored = try database.read { db in
            try String.fetchOne(db, sql: "SELECT config FROM app_config WHERE id = 1")
        }
        if let stored, let data = stored.data(using: .utf8),
           let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            try config.applyApplicationConfiguration(object)
        }
        return config
    }

    /// Overlays Paperless-ngx `ApplicationConfiguration` fields (`ai_enabled`, `llm_backend`, ...).
    /// Null and empty values leave the setting unchanged.
    public mutating func applyApplicationConfiguration(_ object: [String: JSONValue]) throws {
        func string(_ key: String) -> String? {
            guard let v = object[key]?.stringValue?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
            return v
        }
        if let v = object["ai_enabled"]?.boolValue { enabled = v }
        if let v = string("llm_backend") { backend = try Self.llmBackend(v) }
        if let v = string("llm_model") { model = v }
        if let v = string("llm_api_key") { apiKey = v }
        if let v = string("llm_endpoint") { endpoint = v }
        if let v = string("llm_embedding_backend") { embeddingBackend = try Self.embeddingBackend(v) }
        if let v = string("llm_embedding_model") { embeddingModel = v }
        if let v = string("llm_embedding_api_key") { embeddingAPIKey = v }
        if let v = string("llm_embedding_endpoint") { embeddingEndpoint = v }
        if let v = object["llm_embedding_chunk_size"]?.intValue, v > 0 { embeddingChunkSize = v }
        if let v = object["llm_context_size"]?.intValue, v > 0 { contextSize = v }
        if let v = object["llm_request_timeout"]?.intValue, v > 0 { requestTimeout = TimeInterval(v) }
        if let v = string("llm_output_language") { outputLanguage = v }
    }

    /// True when AI is on and an embedding backend is set (Paperless-ngx `llm_index_enabled`).
    public var llmIndexEnabled: Bool { enabled && embeddingBackend != nil }

    /// The model name actually used by the LLM backend.
    public var resolvedModel: String { model ?? backend.defaultModel }

    /// The embedding model actually used. For `apple`, a language code.
    public var resolvedEmbeddingModel: String? {
        guard let embeddingBackend else { return nil }
        if let embeddingModel { return embeddingModel }
        return embeddingBackend.defaultModel ?? AppleSentenceEmbedding.languageCode(forOCRLanguage: ocrLanguage)
    }

    /// Embedding endpoint with the Paperless-ngx fallback to the LLM endpoint.
    public var resolvedEmbeddingEndpoint: String? { embeddingEndpoint ?? endpoint }

    /// Embedding API key with the Paperless-ngx fallback to the LLM API key.
    public var resolvedEmbeddingAPIKey: String? { embeddingAPIKey ?? apiKey }

    /// Identifies the backend configuration in cache keys (Paperless-ngx `llm_cache_backend`).
    public var cacheIdentity: String {
        [backend.rawValue, resolvedModel, endpoint].compactMap { $0 }.joined(separator: ":")
    }

    // MARK: Parsing helpers

    static func bool(_ key: String, _ raw: String) throws -> Bool {
        switch raw.lowercased() {
        case "1", "true", "yes", "y", "on", "t": return true
        case "0", "false", "no", "n", "off", "f": return false
        default: throw AIError.invalidConfiguration("\(key) must be true or false, not \"\(raw)\"")
        }
    }

    static func positiveInt(_ key: String, _ raw: String) throws -> Int {
        guard let value = Int(raw), value >= 1 else {
            throw AIError.invalidConfiguration("\(key) must be an integer >= 1, not \"\(raw)\"")
        }
        return value
    }

    static func llmBackend(_ raw: String) throws -> LLMBackendKind {
        guard let kind = LLMBackendKind(setting: raw) else {
            throw AIError.invalidConfiguration("Unsupported LLM backend \"\(raw)\" (expected apple, openai or ollama)")
        }
        return kind
    }

    static func embeddingBackend(_ raw: String) throws -> EmbeddingBackendKind? {
        if ["none", "off", "disabled", "false", "no"].contains(raw.lowercased()) { return nil }
        if raw.lowercased() == "huggingface" {
            throw AIError.invalidConfiguration("The huggingface embedding backend is not available in FolioZero; use apple for on-device embeddings")
        }
        guard let kind = EmbeddingBackendKind(setting: raw) else {
            throw AIError.invalidConfiguration("Unsupported embedding backend \"\(raw)\" (expected apple, openai, ollama or none)")
        }
        return kind
    }

    static func jsonObject(_ key: String, _ raw: String) throws -> [String: JSONValue] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) else {
            throw AIError.invalidConfiguration("\(key) must be a JSON object")
        }
        return object
    }
}
