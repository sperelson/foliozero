import Foundation
import GRDB

/// Keeps the FTS5 table in step with documents and runs searches.
public enum SearchIndex {
    // MARK: - Maintenance

    /// Insert or replace the index row of one document. Call inside the write
    /// transaction that changed the document or its relations.
    public static func update(documentId: Int, in db: Database) throws {
        guard let row = try Row.fetchOne(db, sql: """
            SELECT d.id, d.title, d.content, d.original_filename, d.deleted_at, d.root_document_id,
                   c.name AS correspondent, t.name AS document_type, p.name AS storage_path
            FROM documents d
            LEFT JOIN correspondents c ON c.id = d.correspondent_id
            LEFT JOIN document_types t ON t.id = d.document_type_id
            LEFT JOIN storage_paths p ON p.id = d.storage_path_id
            WHERE d.id = ?
            """, arguments: [documentId]) else {
            try remove(documentId: documentId, in: db)
            return
        }
        // Versions are searched through their root document.
        if row["root_document_id"] as Int? != nil {
            try remove(documentId: documentId, in: db)
            return
        }

        let tags = try String.fetchAll(db, sql: """
            SELECT t.name FROM document_tags dt JOIN tags t ON t.id = dt.tag_id
            WHERE dt.document_id = ? ORDER BY t.name
            """, arguments: [documentId])
        let notes = try Row.fetchAll(db, sql: """
            SELECT n.note, u.username FROM notes n LEFT JOIN users u ON u.id = n.user_id
            WHERE n.document_id = ? AND n.deleted_at IS NULL
            """, arguments: [documentId])
        let fields = try Row.fetchAll(db, sql: """
            SELECT f.name, f.data_type, f.extra_data, i.* FROM custom_field_instances i
            JOIN custom_fields f ON f.id = i.field_id
            WHERE i.document_id = ? AND i.deleted_at IS NULL
            """, arguments: [documentId])
        let barcodes = try Row.fetchAll(db, sql: "SELECT value, format FROM document_barcodes WHERE document_id = ?", arguments: [documentId])

        // Content of the newest version, when the document has versions.
        let latestVersionContent = try String.fetchOne(db, sql: """
            SELECT content FROM documents WHERE root_document_id = ? AND deleted_at IS NULL
            ORDER BY version_index DESC LIMIT 1
            """, arguments: [documentId])

        let values: [String] = [
            row["title"] ?? "",
            latestVersionContent ?? row["content"] ?? "",
            row["correspondent"] ?? "",
            row["document_type"] ?? "",
            row["storage_path"] ?? "",
            tags.joined(separator: "\n"),
            row["original_filename"] ?? "",
            notes.map { $0["note"] as String? ?? "" }.joined(separator: "\n"),
            notes.compactMap { $0["username"] as String? }.joined(separator: " "),
            fields.map { $0["name"] as String? ?? "" }.joined(separator: "\n"),
            fields.map(customFieldText).joined(separator: "\n"),
            barcodes.map { $0["value"] as String? ?? "" }.joined(separator: "\n"),
            barcodes.map { $0["format"] as String? ?? "" }.joined(separator: " "),
        ]
        try remove(documentId: documentId, in: db)
        let placeholders = Array(repeating: "?", count: values.count).joined(separator: ", ")
        try db.execute(
            sql: "INSERT INTO \(SearchSchema.table)(rowid, \(SearchSchema.columns.joined(separator: ", "))) VALUES (?, \(placeholders))",
            arguments: StatementArguments([documentId] + values)
        )
        try db.execute(
            sql: "INSERT INTO \(SearchSchema.wordsTable)(rowid, title, content) VALUES (?, ?, ?)",
            arguments: [documentId, values[0], values[1]]
        )
    }

    public static func remove(documentId: Int, in db: Database) throws {
        try db.execute(sql: "DELETE FROM \(SearchSchema.table) WHERE rowid = ?", arguments: [documentId])
        try db.execute(sql: "DELETE FROM \(SearchSchema.wordsTable) WHERE rowid = ?", arguments: [documentId])
    }

    /// Drop and rebuild the whole index.
    public static func rebuild(in db: Database, stemming: Bool? = nil) throws {
        let stored = try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = 'fts_stemming'")
        let useStemming = stemming ?? ((stored ?? "1") == "1")
        try SearchSchema.dropIndex(db)
        try SearchSchema.createIndex(db, stemming: useStemming)
        let ids = try Int.fetchAll(db, sql: "SELECT id FROM documents WHERE root_document_id IS NULL")
        for id in ids {
            try update(documentId: id, in: db)
        }
    }

    /// Merge FTS segments (Paperless-ngx "index optimize").
    public static func optimize(in db: Database) throws {
        try db.execute(sql: "INSERT INTO \(SearchSchema.table)(\(SearchSchema.table)) VALUES('optimize')")
    }

    private static func customFieldText(_ row: Row) -> String {
        let candidates: [String?] = [
            row["value_text"], row["value_url"], row["value_date"], row["value_monetary"], row["value_long_text"],
            (row["value_int"] as Int?).map(String.init), (row["value_float"] as Double?).map { String($0) },
            (row["value_bool"] as Bool?).map { $0 ? "true" : "false" },
        ]
        if let select = row["value_select"] as String? {
            // Index the option label, not its id.
            if let extra = row["extra_data"] as String?, let data = extra.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(CustomField.ExtraData.self, from: data),
               let label = decoded.selectOptions?.first(where: { $0.id == select })?.label {
                return label
            }
            return select
        }
        return candidates.compactMap { $0 }.first ?? ""
    }

    // MARK: - Searching

    public struct Hit: Sendable, Hashable {
        public var documentId: Int
        /// Higher is better, 0...1 relative to the best hit.
        public var score: Double
        /// Content excerpt with `<span class="match">` around matched words.
        public var highlights: String
        /// Position in the result list, from 0.
        public var rank: Int
    }

    /// Run a parsed query. `visibility` restricts the documents (alias `d`), e.g. for permissions.
    public static func search(
        _ query: SearchQuery,
        in db: Database,
        visibility: SQL? = nil,
        includeDeleted: Bool = false,
        limit: Int? = nil,
        timeZone: TimeZone = .current
    ) throws -> [Hit] {
        var compiler = SearchCompiler(db: db, timeZone: timeZone)
        let predicate = try compiler.compile(query)
        let rankExpression = compiler.rankExpression

        var sql: SQL = "SELECT d.id"
        if let rankExpression {
            sql += """
                , r.rank, r.highlights FROM documents d
                LEFT JOIN (
                    SELECT rowid, bm25(\(sql: SearchSchema.table), \(sql: SearchCompiler.bm25Weights)) AS rank,
                           snippet(\(sql: SearchSchema.table), 1, '<span class="match">', '</span>', ' … ', 24) AS highlights
                    FROM \(sql: SearchSchema.table) WHERE \(sql: SearchSchema.table) MATCH \(rankExpression)
                ) r ON r.rowid = d.id
                """
        } else {
            sql += ", NULL AS rank, NULL AS highlights FROM documents d"
        }
        sql += " WHERE d.root_document_id IS NULL AND \(predicate)"
        if !includeDeleted { sql += " AND d.deleted_at IS NULL" }
        if let visibility { sql += " AND (\(visibility))" }
        sql += rankExpression != nil ? " ORDER BY r.rank IS NULL, r.rank, d.created DESC, d.id DESC" : " ORDER BY d.created DESC, d.id DESC"
        if let limit { sql += " LIMIT \(limit)" }

        let rows = try Row.fetchAll(db, SQLRequest<Row>(literal: sql))
        let ranks = rows.compactMap { $0["rank"] as Double? }
        let best = ranks.min() ?? -1 // bm25: more negative is better
        return rows.enumerated().map { index, row in
            let rank = row["rank"] as Double?
            let score = rank.map { best < 0 ? max(0, $0 / best) : 1 } ?? 0
            return Hit(documentId: row["id"], score: score, highlights: row["highlights"] ?? "", rank: index)
        }
    }

    /// Simple search over title and content (`?text=`) or title only (`?title_search=`).
    /// Every word must appear as a word prefix.
    public static func simpleQuery(_ text: String, titleOnly: Bool) -> SearchQuery {
        let words = SearchQueryParser.words(in: text)
        guard !words.isEmpty else { return .all }
        let field: SearchQuery.TextField = titleOnly ? .title : .default
        let terms = words.map { SearchQuery.term($0 + "*", field: field) }
        return terms.count == 1 ? terms[0] : .and(terms)
    }

    /// Documents similar to `documentId` (`?more_like_id=`), by the source document's top TF-IDF terms.
    public static func moreLikeThis(documentId: Int, in db: Database, visibility: SQL? = nil, limit: Int = 50) throws -> [Hit] {
        let total = max(1, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(SearchSchema.table)") ?? 1)
        let rows = try Row.fetchAll(db, sql: """
            SELECT i.term, COUNT(*) AS tf, v.doc AS df
            FROM \(SearchSchema.table)_inst i JOIN \(SearchSchema.table)_vocab v ON v.term = i.term
            WHERE i.doc = ? AND i.col IN ('title', 'content')
            GROUP BY i.term
            """, arguments: [documentId])
        let scored = rows.compactMap { row -> (String, Double)? in
            let term: String = row["term"]
            guard term.count > 2, !term.allSatisfy(\.isNumber) else { return nil }
            let tf = Double(row["tf"] as Int)
            let df = Double(row["df"] as Int)
            return (term, tf * log(Double(total) / df))
        }
        let top = scored.sorted { $0.1 > $1.1 }.prefix(25).map(\.0)
        guard !top.isEmpty else { return [] }
        let query = SearchQuery.or(top.map { .term($0, field: .default) })
        let exclude: SQL = "d.id != \(documentId)"
        let combined: SQL = visibility.map { "(\($0)) AND \(exclude)" } ?? exclude
        return try search(query, in: db, visibility: combined, limit: limit)
    }

    /// Word completions for a prefix (`/api/search/autocomplete/`), most common first.
    public static func autocomplete(_ term: String, in db: Database, limit: Int = 10) throws -> [String] {
        let prefix = SearchQueryParser.words(in: term).last ?? ""
        guard !prefix.isEmpty else { return [] }
        return try String.fetchAll(db, sql: """
            SELECT term FROM \(SearchSchema.wordsTable)_inst
            WHERE term >= ? AND term < ? GROUP BY term ORDER BY COUNT(DISTINCT doc) DESC, term LIMIT ?
            """, arguments: [prefix, prefix + "\u{10FFFF}", limit])
    }
}

/// Compiles a `SearchQuery` into an SQL predicate over `documents d`.
struct SearchCompiler {
    let db: Database
    let timeZone: TimeZone
    /// FTS expressions of positive (not negated) text leaves, ORed for ranking.
    private(set) var positiveExpressions: [String] = []
    private var negationDepth = 0

    /// Column weights for bm25, in `SearchSchema.columns` order. Title and names weigh more than content.
    static let bm25Weights = "10.0, 1.0, 5.0, 5.0, 2.0, 5.0, 2.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0"

    init(db: Database, timeZone: TimeZone = .current) {
        self.db = db
        self.timeZone = timeZone
    }

    var rankExpression: String? {
        positiveExpressions.isEmpty ? nil : positiveExpressions.map { "(\($0))" }.joined(separator: " OR ")
    }

    mutating func compile(_ query: SearchQuery) throws -> SQL {
        switch query {
        case .all:
            return "1"

        case let .term(word, field):
            guard let expression = try ftsTerm(word, field: field) else { return "0" }
            return ftsPredicate(expression)

        case let .phrase(words, field):
            let phrase = words.map { $0.replacingOccurrences(of: "\"", with: "\"\"") }.joined(separator: " ")
            return ftsPredicate("\(columnFilter(field)) : \"\(phrase)\"")

        case let .and(parts):
            let compiled = try parts.map { try compile($0) }
            return "(" + compiled.joined(separator: " AND ") + ")"

        case let .or(parts):
            let compiled = try parts.map { try compile($0) }
            return "(" + compiled.joined(separator: " OR ") + ")"

        case let .not(inner):
            negationDepth += 1
            defer { negationDepth -= 1 }
            return "NOT (\(try compile(inner)))"

        case let .number(field, lower, upper):
            let column: SQL
            switch field {
            case .asn: column = "d.archive_serial_number"
            case .pageCount: column = "d.page_count"
            case .numNotes: column = "(SELECT COUNT(*) FROM notes n WHERE n.document_id = d.id AND n.deleted_at IS NULL)"
            }
            var conditions: [SQL] = ["\(column) IS NOT NULL"]
            if let lower { conditions.append("\(column) >= \(lower)") }
            if let upper { conditions.append("\(column) <= \(upper)") }
            return "(" + conditions.joined(separator: " AND ") + ")"

        case let .date(field, from, to):
            var conditions: [SQL] = []
            switch field {
            case .created:
                // `created` is a calendar date: compare dates in the configured zone.
                let zone = timeZone
                if let from { conditions.append("d.created >= \(CalendarDate(from, in: zone).iso)") }
                if let to { conditions.append("d.created <= \(CalendarDate(to.addingTimeInterval(-0.001), in: zone).iso)") }
            case .added, .modified:
                let column: SQL = field == .added ? "d.added" : "d.modified"
                if let from { conditions.append("\(column) >= \(FolioDateFormat.database.string(from: from))") }
                if let to { conditions.append("\(column) < \(FolioDateFormat.database.string(from: to))") }
            }
            return conditions.isEmpty ? "1" : "(" + conditions.joined(separator: " AND ") + ")"

        case let .tag(name):
            if SearchQueryParser.isWildcard(name) {
                let pattern = name.lowercased().replacingOccurrences(of: "[!", with: "[^")
                return "EXISTS (SELECT 1 FROM document_tags dt JOIN tags t ON t.id = dt.tag_id WHERE dt.document_id = d.id AND lower(t.name) GLOB \(pattern))"
            }
            return "EXISTS (SELECT 1 FROM document_tags dt JOIN tags t ON t.id = dt.tag_id WHERE dt.document_id = d.id AND t.name = \(name) COLLATE NOCASE)"

        case let .checksum(value, prefix):
            return prefix ? "d.checksum LIKE \(value + "%")" : "d.checksum = \(value)"
        }
    }

    private mutating func ftsPredicate(_ expression: String) -> SQL {
        if negationDepth == 0 { positiveExpressions.append(expression) }
        return "d.id IN (SELECT rowid FROM \(sql: SearchSchema.table) WHERE \(sql: SearchSchema.table) MATCH \(expression))"
    }

    private func columnFilter(_ field: SearchQuery.TextField) -> String {
        "{" + field.columns.joined(separator: " ") + "}"
    }

    /// FTS expression for one word. Trailing `*` becomes an FTS prefix query;
    /// other wildcards expand against the index vocabulary. nil when nothing can match.
    private func ftsTerm(_ word: String, field: SearchQuery.TextField) throws -> String? {
        let filter = columnFilter(field)
        let body = word.hasSuffix("*") ? String(word.dropLast()) : word
        if !SearchQueryParser.isWildcard(body) {
            let words = SearchQueryParser.words(in: body)
            guard !words.isEmpty else { return nil }
            if word.hasSuffix("*") {
                // FTS5 allows a prefix only on the last token of a phrase.
                return "\(filter) : \"\(words.joined(separator: " "))\" *"
            }
            return "\(filter) : \"\(words.joined(separator: " "))\""
        }
        let pattern = word.lowercased().replacingOccurrences(of: "[!", with: "[^")
        let terms = try String.fetchAll(db, sql: """
            SELECT term FROM \(SearchSchema.table)_vocab WHERE term GLOB ? ORDER BY doc DESC LIMIT 200
            """, arguments: [pattern])
        guard !terms.isEmpty else { return nil }
        return "\(filter) : (" + terms.map { "\"\($0)\"" }.joined(separator: " OR ") + ")"
    }
}
