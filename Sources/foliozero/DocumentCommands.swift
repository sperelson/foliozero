import ArgumentParser
import FolioCore
import Foundation
import GRDB

struct ListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List documents, newest first.")

    @OptionGroup var global: GlobalOptions

    @Option(name: .shortAndLong, help: "Maximum number of documents.")
    var limit = 25

    @Flag(help: "Include documents in the trash.")
    var trash = false

    @Flag(help: "JSON output.")
    var json = false

    func run() async throws {
        let app = try global.openApp()
        let rows = try await app.database.read { [limit, trash] db in
            try DocumentSummary.fetch(where: trash ? "1" : "d.deleted_at IS NULL", limit: limit, in: db)
        }
        if json {
            print(try Output.json(rows))
        } else {
            print(DocumentSummary.table(rows))
        }
    }
}

struct ShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show one document.")

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Document id.")
    var id: Int

    @Flag(help: "Print the full text content.")
    var content = false

    func run() async throws {
        let app = try global.openApp()
        let (document, summary, notes) = try await app.database.read { [id] db -> (Document, DocumentSummary, [Note]) in
            let document = try DocumentStore.document(id, in: db)
            let summary = try DocumentSummary.fetch(where: "d.id = \(id)", limit: 1, in: db).first!
            let notes = try Note.filter(Column("document_id") == id && Column("deleted_at") == nil).fetchAll(db)
            return (document, summary, notes)
        }
        let storage = app.storage
        var lines = [
            "Document #\(id): \(document.title)",
            "Created:        \(document.created.iso)",
            "Added:          \(ISO8601DateFormatter().string(from: document.added))",
            "Correspondent:  \(summary.correspondent ?? "-")",
            "Document type:  \(summary.documentType ?? "-")",
            "Tags:           \(summary.tags.isEmpty ? "-" : summary.tags.joined(separator: ", "))",
            "ASN:            \(document.archiveSerialNumber.map(String.init) ?? "-")",
            "Type:           \(document.mimeType), \(document.pageCount.map { "\($0) pages" } ?? "-")",
            "Checksum:       \(document.checksum)",
            "Original:       \(storage.originalURL(document)?.path ?? "-")",
            "Archive:        \(storage.archiveURL(document)?.path ?? "-")",
        ]
        if document.deletedAt != nil { lines.append("In trash since: \(ISO8601DateFormatter().string(from: document.deletedAt!))") }
        for note in notes { lines.append("Note:           \(note.note)") }
        print(lines.joined(separator: "\n"))
        if content {
            print("\n" + document.content)
        } else if !document.content.isEmpty {
            print("\n" + String(document.content.prefix(500)) + (document.content.count > 500 ? " …" : ""))
        }
    }
}

struct SearchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "search",
        abstract: "Full-text search with the Paperless-ngx query syntax.",
        discussion: """
        Examples:
          foliozero search invoice unpaid
          foliozero search 'correspondent:"acme corp" created:[2023 to 2024]'
          foliozero search 'tag:bills,unpaid NOT draft'
        """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(parsing: .remaining, help: "Query.")
    var query: [String]

    @Option(name: .shortAndLong, help: "Maximum number of results.")
    var limit = 25

    @Flag(help: "JSON output.")
    var json = false

    func run() async throws {
        let app = try global.openApp()
        let zone = app.settings.timeZone
        let parsed = try SearchQueryParser(timeZone: zone).parse(query.joined(separator: " "))
        let results = try await app.database.read { [limit] db -> [(SearchIndex.Hit, DocumentSummary)] in
            let hits = try SearchIndex.search(parsed, in: db, limit: limit, timeZone: zone)
            guard !hits.isEmpty else { return [] }
            let ids = hits.map { String($0.documentId) }.joined(separator: ",")
            let summaries = Dictionary(uniqueKeysWithValues: try DocumentSummary.fetch(where: "d.id IN (\(ids))", limit: hits.count, in: db).map { ($0.id, $0) })
            return hits.compactMap { hit in summaries[hit.documentId].map { (hit, $0) } }
        }
        if json {
            print(try Output.json(results.map(\.1)))
            return
        }
        if results.isEmpty {
            print("No documents found.")
            return
        }
        for (hit, summary) in results {
            let snippet = hit.highlights
                .replacingOccurrences(of: "<span class=\"match\">", with: "\u{1B}[1m")
                .replacingOccurrences(of: "</span>", with: "\u{1B}[0m")
                .replacingOccurrences(of: "\n", with: " ")
            print("#\(summary.id)  \(summary.title)  [\(summary.created)]  score \(String(format: "%.2f", hit.score))")
            if !snippet.isEmpty { print("    \(snippet)") }
        }
    }
}

/// One line of document listings.
struct DocumentSummary: Codable, Sendable {
    var id: Int
    var title: String
    var created: String
    var correspondent: String?
    var documentType: String?
    var tags: [String]
    var mimeType: String
    var pageCount: Int?
    var asn: Int?

    static func fetch(where predicate: String, limit: Int, in db: Database) throws -> [DocumentSummary] {
        try Row.fetchAll(db, sql: """
            SELECT d.id, d.title, d.created, d.mime_type, d.page_count, d.archive_serial_number,
                   c.name AS correspondent, t.name AS document_type,
                   (SELECT group_concat(tg.name, '\u{1F}') FROM document_tags dt JOIN tags tg ON tg.id = dt.tag_id WHERE dt.document_id = d.id) AS tags
            FROM documents d
            LEFT JOIN correspondents c ON c.id = d.correspondent_id
            LEFT JOIN document_types t ON t.id = d.document_type_id
            WHERE d.root_document_id IS NULL AND \(predicate)
            ORDER BY d.created DESC, d.id DESC LIMIT ?
            """, arguments: [limit]).map { row in
            DocumentSummary(
                id: row["id"], title: row["title"], created: row["created"],
                correspondent: row["correspondent"], documentType: row["document_type"],
                tags: (row["tags"] as String?)?.split(separator: "\u{1F}").map(String.init).sorted() ?? [],
                mimeType: row["mime_type"], pageCount: row["page_count"], asn: row["archive_serial_number"]
            )
        }
    }

    static func table(_ rows: [DocumentSummary]) -> String {
        guard !rows.isEmpty else { return "No documents." }
        return Output.table(
            ["ID", "Created", "Title", "Correspondent", "Type", "Tags", "ASN"],
            rows.map { [String($0.id), $0.created, $0.title, $0.correspondent ?? "", $0.documentType ?? "", $0.tags.joined(separator: ", "), $0.asn.map(String.init) ?? ""] }
        )
    }
}
