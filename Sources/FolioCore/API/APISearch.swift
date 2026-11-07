import Foundation
import GRDB

/// Search helpers for the REST API that respect document permissions.
public enum APISearch {
    /// Word completions for the last word of `term`, counted over documents that
    /// `visibility` (a predicate over `documents d`) allows, most common first.
    public static func autocomplete(_ term: String, visibility: SQL, limit: Int, in db: Database) throws -> [String] {
        let prefix = SearchQueryParser.words(in: term).last ?? ""
        guard !prefix.isEmpty else { return [] }
        // Unstemmed words, so completions are whole words rather than Porter stems.
        let table = SearchSchema.wordsTable
        let request = SQLRequest<String>(literal: """
            SELECT i.term FROM \(sql: table)_inst i JOIN documents d ON d.id = i.doc
            WHERE i.term >= \(prefix) AND i.term < \(prefix + "\u{10FFFF}")
              AND d.deleted_at IS NULL AND d.root_document_id IS NULL AND \(visibility)
            GROUP BY i.term ORDER BY COUNT(DISTINCT i.doc) DESC, i.term LIMIT \(limit)
            """)
        return try request.fetchAll(db)
    }

    /// Parses the Paperless-ngx query language in the configured time zone.
    public static func parseQuery(_ text: String, timeZone: TimeZone) throws -> SearchQuery {
        try SearchQueryParser(timeZone: timeZone).parse(text)
    }
}
