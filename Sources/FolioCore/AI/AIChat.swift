import Foundation
import GRDB
import Logging

/// Document chat (Paperless-ngx `paperless_ai.chat`): answers a question from the content of
/// one document or of every document the user may view, retrieved from the LLM index.
public final class AIChat: Sendable {
    /// Separates the answer from the JSON trailer listing the sources.
    public static let metadataDelimiter = "\n\n__PAPERLESS_CHAT_METADATA__"
    public static let errorMessage = "Sorry, something went wrong while generating a response."
    public static let noContentMessage = "Sorry, I couldn't find any content to answer your question."
    /// Paperless-ngx `MAX_CHAT_REFERENCES`.
    public static let maxReferences = 3
    /// Paperless-ngx `CHAT_RETRIEVER_TOP_K`.
    public static let retrieverTopK = 5
    /// Paperless-ngx `ChatStreamingSerializer.q` max length.
    public static let maxQuestionLength = 4000

    /// A source document of an answer.
    public struct Reference: Codable, Sendable, Equatable {
        public var id: Int
        public var title: String
    }

    /// A chat answer: the sources (known before the first token) and the streamed answer.
    public struct Response: Sendable {
        /// At most `maxReferences` documents the retrieved context came from.
        public let references: [Reference]
        /// Answer pieces in order. Backend failures end the stream with an `AIError`.
        public let tokens: AsyncThrowingStream<String, Error>

        /// The exact Paperless-ngx response body, piece by piece: the answer, then
        /// `metadataDelimiter` + `{"references":[...]}` when there are sources. A failure
        /// mid-stream ends the body with `errorMessage` instead of an error.
        public func paperlessBody(logger: Logging.Logger? = nil) -> AsyncStream<String> {
            let tokens = self.tokens
            let references = self.references
            return AsyncStream { continuation in
                let task = Task {
                    do {
                        for try await token in tokens { continuation.yield(token) }
                        if !references.isEmpty { continuation.yield(AIChat.metadataTrailer(references)) }
                    } catch {
                        logger?.error("Failed to stream document chat response: \(error)")
                        continuation.yield(AIChat.errorMessage)
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    let database: FolioDatabase
    let index: LLMIndex
    let runtime: AIRuntimeProvider
    let logger: Logging.Logger

    public init(database: FolioDatabase, index: LLMIndex, runtime: @escaping AIRuntimeProvider, logger: Logging.Logger = Logging.Logger(label: "foliozero.ai.chat")) {
        self.database = database
        self.index = index
        self.runtime = runtime
        self.logger = logger
    }

    /// Answers `question` about one document (`documentId`) or all documents `context` may view.
    ///
    /// Throws before streaming when AI is off (`disabled`), the question is empty or too long
    /// (`invalidRequest`), the document does not exist (`documentNotFound`; Paperless-ngx
    /// answers 400 here) or the user may not view it (`permissionDenied`).
    /// Retrieval uses the LLM index; without index content it falls back to the document's own
    /// text (single document) or full-text search (all documents).
    public func ask(_ question: String, documentId: Int? = nil, context: AccessContext) async throws -> Response {
        let runtime = try runtime()
        guard runtime.config.enabled else { throw AIError.disabled }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { throw AIError.invalidRequest("q: This field may not be blank.") }
        guard question.count <= Self.maxQuestionLength else {
            throw AIError.invalidRequest("q: Ensure this field has no more than \(Self.maxQuestionLength) characters.")
        }

        var scope: Set<Int>?
        if let documentId {
            let visible = try await database.read { db -> Bool? in
                guard let document = try Document.fetchOne(db, key: documentId) else { return nil }
                return try context.can(.view, objectType: Document.objectType, objectId: documentId, ownerId: document.ownerId, in: db)
            }
            guard let visible else { throw AIError.documentNotFound(documentId) }
            guard visible else { throw AIError.permissionDenied }
            let root = try await database.read { db in
                try Int.fetchOne(db, sql: "SELECT COALESCE(root_document_id, id) FROM documents WHERE id = ?", arguments: [documentId])
            }
            scope = [root ?? documentId]
        }

        let language = try await outputLanguage(runtime.config, userId: context.user.id)
        let passages = try await retrieve(question, scope: scope, context: context, runtime: runtime)
        guard !passages.isEmpty else {
            logger.warning("No content found for the chat question")
            return Response(references: [], tokens: AsyncThrowingStream { $0.yield(Self.noContentMessage); $0.finish() })
        }

        let llm = runtime.llm
        let budget = max(256, await llm.contextSize() - llmReservedOutputTokens - (await llm.tokenCount(llmSystemPrompt))
            - (await llm.tokenCount(AIPrompts.chat(context: "", query: question, outputLanguage: language))))
        var blocks: [String] = []
        var used = 0
        var referenced: [Int] = []
        for passage in passages {
            let block = passage.promptText
            let tokens = await llm.tokenCount(block)
            if used + tokens > budget {
                if blocks.isEmpty {
                    // Keep at least part of the best passage.
                    blocks.append(TextChunker.prefix(block, tokens: budget))
                    referenced.append(passage.documentId)
                }
                break
            }
            blocks.append(block)
            used += tokens
            referenced.append(passage.documentId)
        }

        var references: [Reference] = []
        for passage in passages where referenced.contains(passage.documentId) && !references.contains(where: { $0.id == passage.documentId }) {
            references.append(Reference(id: passage.documentId, title: passage.title))
            if references.count >= Self.maxReferences { break }
        }

        let prompt = AIPrompts.chat(context: blocks.joined(separator: "\n\n"), query: question, outputLanguage: language)
        return Response(references: references, tokens: llm.streamChat(instructions: llmSystemPrompt, prompt: prompt))
    }

    /// Answer pieces then the sources trailer, as Paperless-ngx streams them. Failures before
    /// or during the answer become `errorMessage`; use `ask` to turn early failures into HTTP errors.
    public func stream(_ question: String, documentId: Int? = nil, context: AccessContext) -> AsyncStream<String> {
        let logger = self.logger
        return AsyncStream { continuation in
            let task = Task {
                do {
                    let response = try await self.ask(question, documentId: documentId, context: context)
                    for await piece in response.paperlessBody(logger: logger) { continuation.yield(piece) }
                } catch {
                    logger.error("Failed to stream document chat response: \(error)")
                    continuation.yield(Self.errorMessage)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// `metadataDelimiter` + `{"references":[{"id":1,"title":"..."}]}`.
    public static func metadataTrailer(_ references: [Reference]) -> String {
        let items = references.map { "{\"id\":\($0.id),\"title\":\(AIPrompts.pythonJSONString($0.title))}" }
        return metadataDelimiter + "{\"references\":[\(items.joined(separator: ","))]}"
    }

    // MARK: - Retrieval

    /// A retrieved piece of a document, with the metadata the model sees.
    struct Passage: Sendable {
        var documentId: Int
        var title: String
        var text: String
        var metadata: String

        var promptText: String { metadata.isEmpty ? text : metadata + "\n\n" + text }
    }

    func retrieve(_ question: String, scope: Set<Int>?, context: AccessContext, runtime: AIRuntime) async throws -> [Passage] {
        var hits: [(documentId: Int, text: String)] = []
        if runtime.embedder != nil, try index.exists() {
            hits = try await index.search(text: question, context: context, documentIds: scope, limit: Self.retrieverTopK)
                .map { ($0.documentId, $0.text) }
        }
        let chunkSize = runtime.config.embeddingChunkSize
        if hits.isEmpty {
            // Not indexed (yet): read the text directly.
            hits = try await database.read { db -> [(documentId: Int, text: String)] in
                let ids: [Int]
                if let scope {
                    ids = Array(scope)
                } else {
                    let words = SearchQueryParser.words(in: question).filter { $0.count > 2 }
                    guard !words.isEmpty else { return [] }
                    let query = SearchQuery.or(words.map { .term($0, field: .default) })
                    ids = try SearchIndex.search(
                        query, in: db,
                        visibility: context.visibilityPredicate(objectType: Document.objectType, alias: "d"),
                        limit: Self.retrieverTopK).map(\.documentId)
                }
                return try ids.flatMap { id -> [(documentId: Int, text: String)] in
                    guard let source = try IndexSource.load(documentId: id, in: db) else { return [] }
                    let chunks = TextChunker.chunks(source.text, chunkSize: chunkSize, overlap: min(TextChunker.defaultOverlap, chunkSize - 1))
                    return chunks.prefix(scope == nil ? 1 : Self.retrieverTopK).map { (id, $0) }
                }
            }
        }
        guard !hits.isEmpty else { return [] }
        let found = hits
        return try await database.read { db in
            var metadata: [Int: (String, String)] = [:]
            for id in Set(found.map(\.documentId)) {
                guard let document = try Document.fetchOne(db, key: id),
                      try context.can(.view, objectType: Document.objectType, objectId: id, ownerId: document.ownerId, in: db) else { continue }
                metadata[id] = (document.title.isEmpty ? (document.filename ?? "") : document.title, try Self.metadataText(document, in: db))
            }
            return found.compactMap { hit in
                metadata[hit.documentId].map { Passage(documentId: hit.documentId, title: $0.0, text: hit.text, metadata: $0.1) }
            }
        }
    }

    /// The node metadata llama-index shows the model (every key except `document_id`).
    static func metadataText(_ document: Document, in db: Database) throws -> String {
        let correspondent = try document.correspondentId.flatMap { try String.fetchOne(db, sql: "SELECT name FROM correspondents WHERE id = ?", arguments: [$0]) }
        let type = try document.documentTypeId.flatMap { try String.fetchOne(db, sql: "SELECT name FROM document_types WHERE id = ?", arguments: [$0]) }
        let path = try document.storagePathId.flatMap { try String.fetchOne(db, sql: "SELECT name FROM storage_paths WHERE id = ?", arguments: [$0]) }
        let tags = try DocumentStore.tags(of: document.id ?? 0, in: db).map(\.name)
        var lines = ["title: \(document.title)"]
        if !tags.isEmpty { lines.append("tags: \(tags.joined(separator: ", "))") }
        if let correspondent { lines.append("correspondent: \(correspondent)") }
        if let type { lines.append("document_type: \(type)") }
        if let path { lines.append("storage_path: \(path)") }
        if let filename = document.filename { lines.append("filename: \(filename)") }
        if let asn = document.archiveSerialNumber { lines.append("archive_serial_number: \(asn)") }
        lines.append("created: \(document.created)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Language

    func outputLanguage(_ config: AIConfig, userId: Int?) async throws -> String? {
        if let language = config.outputLanguage { return language }
        guard let userId else { return nil }
        return try await Self.uiLanguage(userId: userId, database: database)
    }

    /// The `language` of the user's UI settings, if set.
    static func uiLanguage(userId: Int, database: FolioDatabase) async throws -> String? {
        let stored = try await database.read { db in
            try String.fetchOne(db, sql: "SELECT settings FROM ui_settings WHERE user_id = ?", arguments: [userId])
        }
        guard let stored, let data = stored.data(using: .utf8),
              let object = try? JSONDecoder().decode([String: JSONValue].self, from: data),
              let language = object["language"]?.stringValue, !language.isEmpty else { return nil }
        return language
    }
}
