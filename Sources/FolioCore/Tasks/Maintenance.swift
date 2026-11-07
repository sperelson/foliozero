import Foundation
import GRDB

/// Periodic housekeeping jobs.
public enum Maintenance {
    /// Permanently deletes documents that have been in the trash longer than `EMPTY_TRASH_DELAY` days.
    /// With `olderThan: nil`, empties the whole trash. Returns the number of documents removed.
    @discardableResult
    public static func emptyTrash(app: FolioApp, olderThan days: Int? = nil, ids: [Int]? = nil) async throws -> Int {
        let cutoff = days.map { Date().addingTimeInterval(-Double($0) * 86_400) }
        let documents = try await app.database.read { db -> [Document] in
            var request = Document.filter(Column("deleted_at") != nil)
            if let cutoff { request = request.filter(Column("deleted_at") <= FolioDateFormat.database.string(from: cutoff)) }
            if let ids { request = request.filter(ids.contains(Column("id"))) }
            return try request.fetchAll(db)
        }
        // Versions go with their root document.
        let trashedIds = Set(documents.compactMap(\.id))
        let roots = documents.filter { document in
            guard let root = document.rootDocumentId else { return true }
            return !trashedIds.contains(root)
        }
        for document in roots {
            guard let id = document.id else { continue }
            let versions = try await app.database.read { db in try Document.filter(Column("root_document_id") == id).fetchAll(db) }
            try await app.database.write { db in try DocumentStore.purge(id, in: db) }
            for file in [document] + versions { app.storage.deleteFiles(of: file) }
            app.logger.info("Deleted document #\(id) \"\(document.title)\" from the trash")
        }
        return roots.count
    }

    public static func purgeSessions(app: FolioApp) async {
        try? await app.database.write { db in try UserStore.purgeExpiredSessions(in: db) }
    }

    public static func optimizeIndex(app: FolioApp) async throws {
        try await app.database.write { db in try SearchIndex.optimize(in: db) }
    }
}
