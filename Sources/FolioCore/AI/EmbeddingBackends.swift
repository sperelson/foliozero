import Foundation
import NaturalLanguage

/// Turns text into vectors for the LLM index.
///
/// Implementations: `AppleSentenceEmbedding` (on device, default),
/// `OpenAICompatibleEmbedding` and `OllamaEmbedding`.
public protocol EmbeddingBackend: Sendable {
    /// Identifies the model in the index metadata. A change forces a rebuild
    /// (Paperless-ngx `config_mismatch`).
    var modelIdentity: String { get }
    /// One vector per text, in order.
    func embed(_ texts: [String]) async throws -> [[Float]]
}

/// NaturalLanguage sentence embeddings (`NLEmbedding.sentenceEmbedding(for:)`), on device.
///
/// One language per index: vectors of different languages live in different spaces.
/// `AI_LLM_EMBEDDING_MODEL` is a language code such as `en` or `de`; by default the first
/// `OCR_LANGUAGE` is used, falling back to English when NaturalLanguage has no sentence
/// embedding for it.
public struct AppleSentenceEmbedding: EmbeddingBackend {
    public let language: NLLanguage
    public let revision: Int

    public init(languageCode: String) throws {
        var language = NLLanguage(rawValue: languageCode)
        if !SentenceEmbeddingCache.shared.isAvailable(language) {
            guard languageCode.count == 3, let mapped = Self.languageCode(forOCRLanguage: languageCode, fallback: nil) else {
                throw AIError.invalidConfiguration("NaturalLanguage has no sentence embedding for language \"\(languageCode)\"")
            }
            language = NLLanguage(rawValue: mapped)
            guard SentenceEmbeddingCache.shared.isAvailable(language) else {
                throw AIError.invalidConfiguration("NaturalLanguage has no sentence embedding for language \"\(languageCode)\"")
            }
        }
        self.language = language
        revision = NLEmbedding.currentSentenceEmbeddingRevision(for: language)
    }

    public var modelIdentity: String { "apple:sentence:\(language.rawValue):\(revision)" }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        let embedding = try SentenceEmbeddingCache.shared.embedding(for: language)
        return texts.map { text in
            let vector = embedding.vector(for: text)
            return vector.map { $0.map(Float.init) } ?? []
        }
    }

    /// Maps a Tesseract-style OCR language (`deu`, `eng+fra`) to a two-letter code with a
    /// sentence embedding, or `fallback`.
    public static func languageCode(forOCRLanguage ocr: String, fallback: String? = "en") -> String? {
        let first = String(ocr.split(separator: "+").first ?? Substring(ocr)).lowercased()
        let map = [
            "eng": "en", "deu": "de", "ger": "de", "fra": "fr", "fre": "fr", "spa": "es", "ita": "it",
            "por": "pt", "nld": "nl", "dut": "nl", "chi_sim": "zh-Hans", "zho": "zh-Hans",
        ]
        let code = map[first] ?? (first.count == 2 ? first : nil)
        if let code, SentenceEmbeddingCache.shared.isAvailable(NLLanguage(rawValue: code)) { return code }
        return fallback
    }
}

/// Loads each `NLEmbedding` once and serialises access to it.
final class SentenceEmbeddingCache: @unchecked Sendable {
    static let shared = SentenceEmbeddingCache()
    private let lock = NSLock()
    private var loaded: [NLLanguage: LockedEmbedding] = [:]
    private var missing: Set<NLLanguage> = []

    /// True when NaturalLanguage has a sentence embedding for `language` (loads it once).
    func isAvailable(_ language: NLLanguage) -> Bool {
        (try? embedding(for: language)) != nil
    }

    func embedding(for language: NLLanguage) throws -> LockedEmbedding {
        try lock.withLock {
            if let existing = loaded[language] { return existing }
            guard !missing.contains(language), let embedding = NLEmbedding.sentenceEmbedding(for: language) else {
                missing.insert(language)
                throw AIError.invalidConfiguration("NaturalLanguage has no sentence embedding for language \"\(language.rawValue)\"")
            }
            let wrapped = LockedEmbedding(embedding)
            loaded[language] = wrapped
            return wrapped
        }
    }
}

/// An `NLEmbedding` used from one thread at a time.
final class LockedEmbedding: @unchecked Sendable {
    private let embedding: NLEmbedding
    private let lock = NSLock()

    init(_ embedding: NLEmbedding) { self.embedding = embedding }

    var dimension: Int { lock.withLock { embedding.dimension } }

    func vector(for text: String) -> [Double]? {
        lock.withLock { embedding.vector(for: text) }
    }
}

/// Any OpenAI-compatible `/v1/embeddings` API.
public struct OpenAICompatibleEmbedding: EmbeddingBackend {
    public let model: String
    public let endpoint: String
    let apiKey: String?
    let http: AIHTTPClient

    public init(model: String, endpoint: String? = nil, apiKey: String? = nil, timeout: TimeInterval = 120, allowInternalEndpoints: Bool = true) {
        self.model = model
        self.endpoint = endpoint ?? OpenAICompatibleBackend.defaultEndpoint
        self.apiKey = apiKey
        http = AIHTTPClient(timeout: timeout, allowInternalEndpoints: allowInternalEndpoints)
    }

    public var modelIdentity: String { "openai:\(model)" }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let url = try http.url(base: OpenAICompatibleBackend.apiBase(endpoint), path: "embeddings")
        let body: OrderedJSON = .ordered(["model": .string(model), "input": .array(texts.map(OrderedJSON.string))])
        let headers = ["Authorization": "Bearer \(apiKey ?? OpenAICompatibleBackend.placeholderAPIKey)"]
        let data = try await http.postJSON(url, body: body, headers: headers)
        struct Response: Decodable {
            struct Item: Decodable { let index: Int?; let embedding: [Float] }
            let data: [Item]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.data.count == texts.count else {
            throw AIError.invalidResponse("the embeddings answer does not have one vector per input")
        }
        let ordered = response.data.enumerated().sorted { ($0.element.index ?? $0.offset) < ($1.element.index ?? $1.offset) }
        return ordered.map(\.element.embedding)
    }
}

/// An Ollama server's `/api/embed`.
public struct OllamaEmbedding: EmbeddingBackend {
    public let model: String
    public let endpoint: String
    let contextSize: Int
    let http: AIHTTPClient

    public init(model: String, endpoint: String? = nil, contextSize: Int = 8192, timeout: TimeInterval = 120, allowInternalEndpoints: Bool = true) {
        self.model = model
        self.endpoint = endpoint ?? OllamaBackend.defaultEndpoint
        self.contextSize = contextSize
        http = AIHTTPClient(timeout: timeout, allowInternalEndpoints: allowInternalEndpoints)
    }

    public var modelIdentity: String { "ollama:\(model)" }

    public func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let url = try http.url(base: endpoint, path: "api/embed")
        let body: OrderedJSON = .ordered([
            "model": .string(model),
            "input": .array(texts.map(OrderedJSON.string)),
            "options": .ordered(["num_ctx": .int(contextSize)]),
        ])
        let data = try await http.postJSON(url, body: body)
        struct Response: Decodable { let embeddings: [[Float]] }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.embeddings.count == texts.count else {
            throw AIError.invalidResponse("the Ollama embed answer does not have one vector per input")
        }
        return response.embeddings
    }
}
