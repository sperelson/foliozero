import Foundation
import GRDB

/// Tables of the LLM index (migration `v2-ai`).
///
/// - `ai_index_documents`: one row per indexed document: its `modified` time and a checksum
///   of the indexed text at indexing time. Deleting the document deletes the row.
/// - `ai_index_chunks`: the chunks of each document with their embedding, stored as
///   little-endian Float32 values, L2-normalised so a dot product is the cosine similarity.
///
/// The embedding model identity, vector dimension and chunk size live in `meta`
/// (`ai_index_model`, `ai_index_dimension`, `ai_index_chunk_size`).
enum AISchema {
    static let documentsTable = "ai_index_documents"
    static let chunksTable = "ai_index_chunks"

    static func migrate(_ db: Database) throws {
        try db.create(table: documentsTable) { t in
            t.primaryKey("document_id", .integer).references("documents", onDelete: .cascade)
            t.column("modified", .text).notNull()
            t.column("checksum", .text).notNull()
            t.column("chunk_count", .integer).notNull()
            t.column("indexed_at", .datetime).notNull()
        }
        try db.create(table: chunksTable) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("document_id", .integer).notNull().indexed()
                .references(documentsTable, column: "document_id", onDelete: .cascade)
            t.column("chunk_index", .integer).notNull()
            t.column("text", .text).notNull()
            t.column("embedding", .blob).notNull()
            t.uniqueKey(["document_id", "chunk_index"])
        }
    }
}
