import Accelerate
import CryptoKit
import Foundation
import GRDB
import Logging

/// The LLM index (RAG): document chunks with embeddings in SQLite, searched by cosine similarity.
///
/// Mirrors Paperless-ngx `paperless_ai.indexing`: only root documents are indexed (a version
/// is indexed through its root, with the newest version's content), trashed documents stay in
/// the index but are never returned, and purging a document deletes its rows (foreign key
/// cascade). Writers are serialised; searches run concurrently with them.
public final class LLMIndex: Sendable {
    let database: FolioDatabase
    let runtime: AIRuntimeProvider
    let logger: Logging.Logger
    let writeLock = AsyncLock()

    /// Texts per embedding request.
    static let embedBatchSize = 32
    /// Chunks retrieved for taxonomy candidates (Paperless-ngx `TAXONOMY_CANDIDATE_TOP_K`).
    public static let taxonomyTopK = 15

    static let metaModel = "ai_index_model"
    static let metaChunkSize = "ai_index_chunk_size"
    static let metaDimension = "ai_index_dimension"
    static let metaUpdated = "ai_index_updated"

    public init(database: FolioDatabase, runtime: @escaping AIRuntimeProvider, logger: Logging.Logger = Logging.Logger(label: "foliozero.ai.index")) {
        self.database = database
        self.runtime = runtime
        self.logger = logger
    }

    // MARK: - Status

    /// What the index holds (for `/api/status/` `llmindex_*` fields and the CLI).
    public struct Status: Sendable, Equatable {
        public var documentCount: Int
        public var chunkCount: Int
        /// Embedding model identity the index was built with, nil when never built.
        public var model: String?
        /// Time of the last completed update or rebuild.
        public var lastUpdated: Date?
    }

    public func status() throws -> Status {
        try database.read { db in
            let documents = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(AISchema.documentsTable)") ?? 0
            let chunks = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(AISchema.chunksTable)") ?? 0
            let model = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [Self.metaModel])
            let updated = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [Self.metaUpdated])
            return Status(documentCount: documents, chunkCount: chunks, model: model,
                          lastUpdated: updated.flatMap { FolioDateFormat.database.date(from: $0) })
        }
    }

    /// True when at least one chunk is indexed (Paperless-ngx `llm_index_exists`).
    public func exists() throws -> Bool {
        try database.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(AISchema.chunksTable))") ?? false
        }
    }

    // MARK: - Writing

    /// Rebuilds or incrementally updates the index (Paperless-ngx `update_llm_index`).
    ///
    /// Incremental: a document is re-embedded only when the checksum of its indexed text
    /// changed; a changed `modified` time with unchanged text only updates the stored time.
    /// A changed embedding model or chunk size forces a rebuild.
    /// - Parameter documentIds: limits an incremental update to these documents (versions
    ///   map to their root). Ignored on rebuild.
    /// - Returns: the Paperless-ngx result message.
    @discardableResult
    public func update(rebuild: Bool = false, documentIds: [Int]? = nil) async throws -> String {
        let (config, embedder) = try indexRuntime()
        return try await writeLock.withLock { [self] in
            try await self.locked_update(rebuild: rebuild, documentIds: documentIds, config: config, embedder: embedder, allowRebuild: true)
        }
    }

    /// Adds or replaces one document (Paperless-ngx `llm_index_add_or_update_document`).
    /// A version is indexed as its root. When the index needs a rebuild because the embedding
    /// model changed, nothing happens and a warning is logged.
    public func indexDocument(_ documentId: Int) async throws {
        let (config, embedder) = try indexRuntime()
        _ = try await writeLock.withLock { [self] in
            try await self.locked_update(rebuild: false, documentIds: [documentId], config: config, embedder: embedder, allowRebuild: false)
        }
    }

    /// Removes a document's chunks (Paperless-ngx `llm_index_remove_document`).
    public func removeDocument(_ documentId: Int) async throws {
        try await writeLock.withLock { [database] in
            try await database.write { db in
                try db.execute(sql: "DELETE FROM \(AISchema.documentsTable) WHERE document_id = ?", arguments: [documentId])
            }
        }
    }

    /// Deletes every chunk and the stored model information.
    public func clear() async throws {
        try await writeLock.withLock { [database] in
            try await database.write { db in try Self.clear(db) }
        }
    }

    static func clear(_ db: Database) throws {
        try db.execute(sql: "DELETE FROM \(AISchema.documentsTable)")
        try db.execute(sql: "DELETE FROM meta WHERE key IN (?, ?, ?, ?)", arguments: [metaModel, metaChunkSize, metaDimension, metaUpdated])
    }

    func indexRuntime() throws -> (AIConfig, any EmbeddingBackend) {
        let runtime = try runtime()
        guard runtime.config.enabled else { throw AIError.disabled }
        guard let embedder = runtime.embedder else {
            throw AIError.invalidConfiguration("the LLM index needs an embedding backend (AI_LLM_EMBEDDING_BACKEND)")
        }
        return (runtime.config, embedder)
    }

    private func locked_update(rebuild requested: Bool, documentIds: [Int]?, config: AIConfig, embedder: any EmbeddingBackend, allowRebuild: Bool) async throws -> String {
        let chunkSize = config.embeddingChunkSize
        let identity = embedder.modelIdentity
        var rebuild = requested

        let (storedModel, storedChunkSize, hasRows) = try await database.read { db in
            (try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [Self.metaModel]),
             try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [Self.metaChunkSize]).flatMap(Int.init),
             try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM \(AISchema.documentsTable))") ?? false)
        }
        if hasRows, storedModel != identity || storedChunkSize != chunkSize {
            guard allowRebuild else {
                logger.warning("Skipping LLM index update: the embedding model or chunk size changed; run a rebuild first")
                return "LLM index requires a rebuild."
            }
            logger.warning("Embedding model or chunk size changed; forcing LLM index rebuild")
            rebuild = true
        }

        let scope = rebuild ? nil : documentIds
        let candidates: [Int] = try await database.read { db in
            if let scope {
                return try Int.fetchAll(db, sql: """
                    SELECT DISTINCT d.id FROM documents d
                    WHERE d.root_document_id IS NULL AND d.deleted_at IS NULL
                      AND d.id IN (SELECT COALESCE(root_document_id, id) FROM documents WHERE id IN (\(scope.map(String.init).joined(separator: ","))))
                    ORDER BY d.id
                    """)
            }
            return try Int.fetchAll(db, sql: "SELECT id FROM documents WHERE root_document_id IS NULL AND deleted_at IS NULL ORDER BY id")
        }
        if candidates.isEmpty, !rebuild, !hasRows {
            logger.warning("No documents found to index.")
            return "No documents found to index."
        }

        if rebuild {
            logger.info("Rebuilding LLM index")
            try await database.write { db in
                try Self.clear(db)
            }
        }
        try await database.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", arguments: [Self.metaModel, identity])
            try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", arguments: [Self.metaChunkSize, String(chunkSize)])
        }

        let existing: [Int: String] = try await database.read { db in
            var result: [Int: String] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT document_id, checksum FROM \(AISchema.documentsTable)") {
                result[row["document_id"]] = row["checksum"]
            }
            return result
        }

        var changed = 0
        for documentId in candidates {
            try Task.checkCancellation()
            guard let source = try await database.read({ db in try IndexSource.load(documentId: documentId, in: db) }) else { continue }
            let checksum = source.checksum(model: identity, chunkSize: chunkSize)
            if existing[documentId] == checksum {
                try await database.write { db in
                    try db.execute(sql: "UPDATE \(AISchema.documentsTable) SET modified = ? WHERE document_id = ? AND modified != ?",
                                   arguments: [source.modified, documentId, source.modified])
                }
                continue
            }
            try await store(source, checksum: checksum, chunkSize: chunkSize, embedder: embedder)
            changed += 1
        }

        try await database.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)",
                           arguments: [Self.metaUpdated, FolioDateFormat.database.string(from: Date())])
        }
        logger.info("LLM index: \(changed) of \(candidates.count) documents embedded\(rebuild ? " (rebuild)" : "")")
        // Building an empty index from scratch is a rebuild, as in Paperless-ngx.
        if rebuild || (!hasRows && scope == nil) { return "LLM index rebuilt successfully." }
        return changed > 0 ? "LLM index updated successfully." : "No changes detected in LLM index."
    }

    /// Chunks, embeds and stores one document, replacing its previous chunks.
    private func store(_ source: IndexSource, checksum: String, chunkSize: Int, embedder: any EmbeddingBackend) async throws {
        let chunks = TextChunker.chunks(source.text, chunkSize: chunkSize, overlap: min(TextChunker.defaultOverlap, chunkSize - 1))
        var vectors: [[Float]] = []
        var start = 0
        while start < chunks.count {
            let batch = chunks[start..<min(start + Self.embedBatchSize, chunks.count)]
            // The title goes into every chunk's embedding, but is not stored with the chunk.
            let inputs = batch.map { "\(source.title)\n\($0)" }
            let embedded = try await embedder.embed(Array(inputs))
            guard embedded.count == inputs.count else { throw AIError.invalidResponse("embedding count does not match input count") }
            vectors += embedded
            start += Self.embedBatchSize
        }
        let rows: [(Int, String, Data)] = zip(chunks, vectors).enumerated().compactMap { index, pair in
            let normalised = Self.normalised(pair.1)
            return normalised.isEmpty ? nil : (index, pair.0, Self.blob(normalised))
        }
        let dimension = vectors.first(where: { !$0.isEmpty })?.count
        try await database.write { db in
            guard try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM documents WHERE id = ?)", arguments: [source.documentId]) == true else { return }
            try db.execute(sql: "DELETE FROM \(AISchema.documentsTable) WHERE document_id = ?", arguments: [source.documentId])
            try db.execute(sql: """
                INSERT INTO \(AISchema.documentsTable)(document_id, modified, checksum, chunk_count, indexed_at) VALUES (?, ?, ?, ?, ?)
                """, arguments: [source.documentId, source.modified, checksum, rows.count, FolioDateFormat.database.string(from: Date())])
            for (index, text, blob) in rows {
                try db.execute(sql: "INSERT INTO \(AISchema.chunksTable)(document_id, chunk_index, text, embedding) VALUES (?, ?, ?, ?)",
                               arguments: [source.documentId, index, text, blob])
            }
            if let dimension {
                try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", arguments: [Self.metaDimension, String(dimension)])
            }
        }
    }

    // MARK: - Searching

    /// One retrieved chunk.
    public struct Match: Sendable, Equatable {
        public var documentId: Int
        public var chunkIndex: Int
        public var text: String
        /// Cosine similarity, -1...1.
        public var score: Float
    }

    /// A document similar to another one.
    public struct SimilarDocument: Sendable, Equatable, Codable {
        public var id: Int
        /// Best chunk's cosine similarity.
        public var score: Double
    }

    /// Chunks most similar to `text`, limited to documents `context` may view.
    /// Returns nothing while the index was built with a different embedding model
    /// (vectors of different models are not comparable); `update()` then rebuilds it.
    /// - Parameters:
    ///   - documentIds: only search these documents.
    ///   - excluding: never return this document.
    public func search(text: String, context: AccessContext, documentIds: Set<Int>? = nil, excluding: Int? = nil, limit: Int = 5) async throws -> [Match] {
        let (config, embedder) = try indexRuntime()
        let storedModel = try await database.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [Self.metaModel])
        }
        guard storedModel == embedder.modelIdentity else {
            if storedModel != nil { logger.warning("LLM index was built with another embedding model; rebuild it before searching") }
            return []
        }
        let query = TextChunker.prefix(text, tokens: config.embeddingChunkSize)
        guard let vector = try await embedder.embed([query]).first, !vector.isEmpty else { return [] }
        let normalised = Self.normalised(vector)
        return try await database.read { db in
            try Self.search(normalised, context: context, documentIds: documentIds, excluding: excluding, limit: limit, in: db)
        }
    }

    /// Chunks most similar to `vector` (any length; it is normalised here).
    public func search(vector: [Float], context: AccessContext, documentIds: Set<Int>? = nil, excluding: Int? = nil, limit: Int = 5) throws -> [Match] {
        let query = Self.normalised(vector)
        return try database.read { db in
            try Self.search(query, context: context, documentIds: documentIds, excluding: excluding, limit: limit, in: db)
        }
    }

    /// Brute-force cosine search over the visible chunks, keeping the best `limit`.
    static func search(_ query: [Float], context: AccessContext, documentIds: Set<Int>?, excluding: Int?, limit: Int, in db: Database) throws -> [Match] {
        guard !query.isEmpty, limit > 0 else { return [] }
        if let documentIds, documentIds.isEmpty { return [] }
        var sql: SQL = """
            SELECT c.id, c.document_id, c.embedding FROM \(sql: AISchema.chunksTable) c
            JOIN documents d ON d.id = c.document_id
            WHERE d.deleted_at IS NULL AND d.root_document_id IS NULL
              AND \(context.visibilityPredicate(objectType: Document.objectType, alias: "d"))
            """
        if let documentIds { sql += " AND c.document_id IN \(Array(documentIds))" }
        if let excluding { sql += " AND c.document_id != \(excluding)" }
        var top: [(chunkId: Int64, documentId: Int, score: Float)] = []
        let cursor = try Row.fetchCursor(db, SQLRequest<Row>(literal: sql))
        while let row = try cursor.next() {
            guard let score = try row.withUnsafeData(atIndex: 2, { Self.dot(query, $0) }) else { continue }
            if top.count < limit || score > top[top.count - 1].score {
                let entry = (chunkId: row[0] as Int64, documentId: row[1] as Int, score: score)
                let position = top.firstIndex { $0.score < score } ?? top.count
                top.insert(entry, at: position)
                if top.count > limit { top.removeLast() }
            }
        }
        guard !top.isEmpty else { return [] }
        var texts: [Int64: (Int, String)] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, chunk_index, text FROM \(AISchema.chunksTable) WHERE id IN (\(top.map { String($0.chunkId) }.joined(separator: ",")))") {
            texts[row["id"]] = (row["chunk_index"], row["text"])
        }
        return top.compactMap { entry in
            texts[entry.chunkId].map { Match(documentId: entry.documentId, chunkIndex: $0.0, text: $0.1, score: entry.score) }
        }
    }

    /// Chunks of other documents similar to `documentId` (Paperless-ngx `retrieve_similar_nodes`):
    /// the query is the document's title and content cut to one chunk.
    public func similarChunks(to documentId: Int, context: AccessContext, limit: Int = LLMIndex.taxonomyTopK) async throws -> [Match] {
        let text = try await database.read { db -> String? in
            guard let source = try IndexSource.load(documentId: documentId, in: db, includeTrashed: true) else { return nil }
            return source.title + "\n" + source.content
        }
        guard let text else { throw AIError.documentNotFound(documentId) }
        return try await search(text: text, context: context, excluding: documentId, limit: limit)
    }

    /// Documents most similar to `documentId` that `context` may view, best first.
    /// Each document scores with its best chunk.
    public func similarDocuments(documentId: Int, context: AccessContext, limit: Int = 10) async throws -> [SimilarDocument] {
        let visible = try await database.read { db -> Bool? in
            guard let document = try Document.fetchOne(db, key: documentId) else { return nil }
            return try context.can(.view, objectType: Document.objectType, objectId: documentId, ownerId: document.ownerId, in: db)
        }
        guard let visible else { throw AIError.documentNotFound(documentId) }
        guard visible else { throw AIError.permissionDenied }
        let matches = try await similarChunks(to: documentId, context: context, limit: max(limit * 3, Self.taxonomyTopK))
        var best: [Int: Float] = [:]
        for match in matches { best[match.documentId] = max(best[match.documentId] ?? -2, match.score) }
        return best.map { SimilarDocument(id: $0.key, score: Double($0.value)) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.id < $1.id }
            .prefix(limit).map { $0 }
    }

    // MARK: - Vectors

    static func normalised(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return [] }
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        let norm = sumOfSquares.squareRoot()
        guard norm > 0, norm.isFinite else { return [] }
        var result = [Float](repeating: 0, count: vector.count)
        var divisor = norm
        vDSP_vsdiv(vector, 1, &divisor, &result, 1, vDSP_Length(vector.count))
        return result
    }

    static func blob(_ vector: [Float]) -> Data {
        var data = Data(capacity: vector.count * 4)
        for value in vector {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    static func vector(from blob: Data) -> [Float] {
        stride(from: 0, to: blob.count - 3, by: 4).map { offset in
            Float(bitPattern: blob.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)) })
        }
    }

    /// Dot product of `query` with a stored vector; nil when the dimensions differ.
    static func dot(_ query: [Float], _ blob: Data?) -> Float? {
        guard let blob, blob.count == query.count * 4 else { return nil }
        return blob.withUnsafeBytes { raw -> Float in
            var result: Float = 0
            if let base = raw.baseAddress, Int(bitPattern: base) % MemoryLayout<Float>.alignment == 0 {
                let stored = base.assumingMemoryBound(to: Float.self)
                vDSP_dotpr(query, 1, stored, 1, &result, vDSP_Length(query.count))
            } else {
                for index in 0..<query.count {
                    result += query[index] * Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
                }
            }
            return result
        }
    }
}

/// The text of one document as the index sees it (Paperless-ngx `build_llm_index_text`):
/// notes, custom fields, then the content, normalised.
struct IndexSource: Sendable {
    var documentId: Int
    var title: String
    /// `documents.modified` exactly as stored.
    var modified: String
    /// Effective content: the newest version's content when the document has versions.
    var content: String
    var text: String

    static func load(documentId: Int, in db: Database, includeTrashed: Bool = false) throws -> IndexSource? {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT id, title, content, modified, root_document_id, deleted_at FROM documents WHERE id = ?
            """, arguments: [documentId]) else { return nil }
        guard row["root_document_id"] as Int? == nil else { return nil }
        if !includeTrashed, row["deleted_at"] as String? != nil { return nil }
        let latestVersionContent = try String.fetchOne(db, sql: """
            SELECT content FROM documents WHERE root_document_id = ? AND deleted_at IS NULL
            ORDER BY version_index DESC LIMIT 1
            """, arguments: [documentId])
        let content: String = latestVersionContent ?? row["content"] ?? ""
        let notes = try String.fetchAll(db, sql: """
            SELECT note FROM notes WHERE document_id = ? AND deleted_at IS NULL ORDER BY created, id
            """, arguments: [documentId])
        var lines = ["Notes: \(notes.joined(separator: ","))"]
        for field in try Row.fetchAll(db, sql: """
            SELECT f.name, f.extra_data, i.* FROM custom_field_instances i JOIN custom_fields f ON f.id = i.field_id
            WHERE i.document_id = ? AND i.deleted_at IS NULL ORDER BY f.name
            """, arguments: [documentId]) {
            lines.append("Custom Field - \(field["name"] as String? ?? ""): \(customFieldText(field))")
        }
        lines.append("\nContent:\n")
        lines.append(content)
        return IndexSource(
            documentId: documentId, title: row["title"] ?? "", modified: row["modified"] ?? "",
            content: content, text: TextChunker.normalize(lines.joined(separator: "\n")))
    }

    /// SHA-256 over everything that shapes the stored chunks and vectors.
    func checksum(model: String, chunkSize: Int) -> String {
        var hasher = SHA256()
        for part in [model, String(chunkSize), title, text] {
            // Length-prefixed, so field boundaries cannot shift between documents.
            hasher.update(data: Data("\(part.utf8.count):".utf8))
            hasher.update(data: Data(part.utf8))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func customFieldText(_ row: Row) -> String {
        if let select = row["value_select"] as String? {
            if let extra = row["extra_data"] as String?, let data = extra.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(CustomField.ExtraData.self, from: data),
               let label = decoded.selectOptions?.first(where: { $0.id == select })?.label {
                return label
            }
            return select
        }
        let candidates: [String?] = [
            row["value_text"], row["value_url"], row["value_date"], row["value_monetary"], row["value_long_text"],
            (row["value_int"] as Int?).map(String.init), (row["value_float"] as Double?).map { String($0) },
            (row["value_bool"] as Bool?).map { $0 ? "True" : "False" },
            (row["value_document_ids"] as String?),
        ]
        return candidates.compactMap { $0 }.first ?? "None"
    }
}
