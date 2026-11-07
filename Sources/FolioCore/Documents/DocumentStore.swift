import Foundation
import GRDB

public enum DocumentStoreError: Error, CustomStringConvertible, Equatable {
    case notFound(Int)
    case asnInUse(Int)
    case tagTooDeep(String)
    case tagCycle(String)

    public var description: String {
        switch self {
        case .notFound(let id): "Document \(id) does not exist"
        case .asnInUse(let asn): "Archive serial number \(asn) is already in use"
        case .tagTooDeep(let name): "Tag \(name) would exceed the maximum nesting depth of \(Tag.maxNestingDepth)"
        case .tagCycle(let name): "Tag \(name) cannot be its own ancestor"
        }
    }
}

/// Database operations on documents and their relations. All functions run
/// inside the caller's transaction and keep the search index current.
public enum DocumentStore {
    // MARK: Lookups

    public static func document(_ id: Int, in db: Database) throws -> Document {
        guard let document = try Document.fetchOne(db, key: id) else { throw DocumentStoreError.notFound(id) }
        return document
    }

    public static func tagIds(of documentId: Int, in db: Database) throws -> [Int] {
        try Int.fetchAll(db, sql: "SELECT tag_id FROM document_tags WHERE document_id = ? ORDER BY tag_id", arguments: [documentId])
    }

    public static func tags(of documentId: Int, in db: Database) throws -> [Tag] {
        try Tag.fetchAll(db, sql: """
            SELECT t.* FROM tags t JOIN document_tags dt ON dt.tag_id = t.id
            WHERE dt.document_id = ? ORDER BY t.name
            """, arguments: [documentId])
    }

    /// Other documents (including trashed ones) with the same original or archive checksum.
    public static func duplicates(of checksum: String, excluding id: Int? = nil, in db: Database) throws -> [Document] {
        try Document.fetchAll(db, sql: """
            SELECT * FROM documents WHERE (checksum = ? OR archive_checksum = ?) AND id IS NOT ?
            ORDER BY id
            """, arguments: [checksum, checksum, id])
    }

    public static func nextArchiveSerialNumber(in db: Database) throws -> Int {
        (try Int.fetchOne(db, sql: "SELECT MAX(archive_serial_number) FROM documents") ?? 0) + 1
    }

    public static func isArchiveSerialNumberFree(_ asn: Int, excluding id: Int? = nil, in db: Database) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM documents WHERE archive_serial_number = ? AND id IS NOT ?", arguments: [asn, id]) == 0
    }

    // MARK: Writes

    /// Insert a new document with its tags, then index it.
    @discardableResult
    public static func insert(_ document: Document, tagIds: [Int] = [], actorId: Int? = nil, auditEnabled: Bool = true, in db: Database) throws -> Document {
        var document = document
        if let asn = document.archiveSerialNumber, try !isArchiveSerialNumberFree(asn, in: db) {
            throw DocumentStoreError.asnInUse(asn)
        }
        try document.insert(db)
        try setTags(documentId: document.id!, tagIds: tagIds, in: db)
        try SearchIndex.update(documentId: document.id!, in: db)
        if auditEnabled {
            try AuditLog.record(.create, objectType: Document.objectType, objectId: document.id!, repr: document.title, actorId: actorId, in: db)
        }
        return document
    }

    /// Save changes to a document, record what changed, and reindex.
    public static func update(_ document: Document, actorId: Int? = nil, auditEnabled: Bool = true, in db: Database) throws {
        guard let id = document.id else { return }
        let before = try self.document(id, in: db)
        if let asn = document.archiveSerialNumber, asn != before.archiveSerialNumber,
           try !isArchiveSerialNumberFree(asn, excluding: id, in: db) {
            throw DocumentStoreError.asnInUse(asn)
        }
        var updated = document
        updated.modified = Date()
        try updated.update(db)
        try SearchIndex.update(documentId: id, in: db)
        if auditEnabled {
            let changes = AuditLog.diff(before, updated)
            if !changes.isEmpty {
                try AuditLog.record(.update, objectType: Document.objectType, objectId: id, repr: updated.title, changes: changes, actorId: actorId, in: db)
            }
        }
    }

    /// Replace the tags of a document. Ancestors of every tag are added too (nested tags).
    public static func setTags(documentId: Int, tagIds: [Int], in db: Database) throws {
        let withAncestors = try expandWithAncestors(Set(tagIds), in: db)
        try db.execute(sql: "DELETE FROM document_tags WHERE document_id = ?", arguments: [documentId])
        for tagId in withAncestors.sorted() {
            try DocumentTag(documentId: documentId, tagId: tagId).insert(db, onConflict: .ignore)
        }
    }

    /// Add tags (and their ancestors). Existing tags stay.
    public static func addTags(documentId: Int, tagIds: [Int], in db: Database) throws {
        let current = try Set(self.tagIds(of: documentId, in: db))
        try setTags(documentId: documentId, tagIds: Array(current.union(tagIds)), in: db)
    }

    /// Remove tags and all their descendants (nested tags).
    public static func removeTags(documentId: Int, tagIds: [Int], in db: Database) throws {
        var removed = Set(tagIds)
        for id in tagIds { removed.formUnion(try descendants(of: id, in: db)) }
        let current = try Set(self.tagIds(of: documentId, in: db))
        try db.execute(sql: "DELETE FROM document_tags WHERE document_id = ?", arguments: [documentId])
        for tagId in current.subtracting(removed).sorted() {
            try DocumentTag(documentId: documentId, tagId: tagId).insert(db)
        }
    }

    /// Move to the trash.
    public static func moveToTrash(_ id: Int, actorId: Int? = nil, in db: Database) throws {
        try db.execute(sql: "UPDATE documents SET deleted_at = ? WHERE id = ? OR root_document_id = ?",
                       arguments: [FolioDateFormat.database.string(from: Date()), id, id])
        try SearchIndex.update(documentId: id, in: db)
        try AuditLog.record(.delete, objectType: Document.objectType, objectId: id, repr: "", actorId: actorId, in: db)
    }

    public static func restoreFromTrash(_ id: Int, in db: Database) throws {
        try db.execute(sql: "UPDATE documents SET deleted_at = NULL, restored_at = ? WHERE id = ? OR root_document_id = ?",
                       arguments: [FolioDateFormat.database.string(from: Date()), id, id])
        try SearchIndex.update(documentId: id, in: db)
    }

    /// Remove rows for good. The caller deletes the files.
    public static func purge(_ id: Int, in db: Database) throws {
        try SearchIndex.remove(documentId: id, in: db)
        try PermissionSet.removeAll(objectType: Document.objectType, objectId: id, in: db)
        try db.execute(sql: "DELETE FROM documents WHERE id = ?", arguments: [id])
    }

    // MARK: Tag hierarchy

    static func expandWithAncestors(_ ids: Set<Int>, in db: Database) throws -> Set<Int> {
        var result = ids
        for id in ids { result.formUnion(try ancestors(of: id, in: db)) }
        return result
    }

    public static func ancestors(of tagId: Int, in db: Database) throws -> [Int] {
        try Int.fetchAll(db, sql: """
            WITH RECURSIVE up(id, parent_id, depth) AS (
                SELECT id, parent_id, 0 FROM tags WHERE id = ?
                UNION ALL
                SELECT t.id, t.parent_id, up.depth + 1 FROM tags t JOIN up ON t.id = up.parent_id WHERE up.depth < 32
            )
            SELECT id FROM up WHERE id != ?
            """, arguments: [tagId, tagId])
    }

    public static func descendants(of tagId: Int, in db: Database) throws -> [Int] {
        try Int.fetchAll(db, sql: """
            WITH RECURSIVE down(id, depth) AS (
                SELECT id, 0 FROM tags WHERE parent_id = ?
                UNION ALL
                SELECT t.id, down.depth + 1 FROM tags t JOIN down ON t.parent_id = down.id WHERE down.depth < 32
            )
            SELECT id FROM down
            """, arguments: [tagId])
    }

    /// Validates a new parent for a tag: no cycles, depth at most `Tag.maxNestingDepth`.
    /// After the change, documents with the tag also get the new ancestors.
    public static func setParent(tagId: Int, parentId: Int?, in db: Database) throws {
        guard var tag = try Tag.fetchOne(db, key: tagId) else { return }
        if let parentId {
            let parentAncestors = try ancestors(of: parentId, in: db)
            if parentId == tagId || parentAncestors.contains(tagId) { throw DocumentStoreError.tagCycle(tag.name) }
            let subtreeHeight = try subtreeHeight(of: tagId, in: db)
            if parentAncestors.count + 2 + subtreeHeight > Tag.maxNestingDepth { throw DocumentStoreError.tagTooDeep(tag.name) }
        }
        tag.parentId = parentId
        try tag.update(db)
        guard parentId != nil else { return }
        let affected = try Int.fetchAll(db, sql: "SELECT document_id FROM document_tags WHERE tag_id IN (SELECT ? UNION SELECT id FROM tags WHERE parent_id = ?)", arguments: [tagId, tagId])
        for documentId in Set(affected) {
            try addTags(documentId: documentId, tagIds: [tagId], in: db)
            try SearchIndex.update(documentId: documentId, in: db)
        }
    }

    static func subtreeHeight(of tagId: Int, in db: Database) throws -> Int {
        try Int.fetchOne(db, sql: """
            WITH RECURSIVE down(id, depth) AS (
                SELECT id, 1 FROM tags WHERE parent_id = ?
                UNION ALL
                SELECT t.id, down.depth + 1 FROM tags t JOIN down ON t.parent_id = down.id WHERE down.depth < 32
            )
            SELECT COALESCE(MAX(depth), 0) FROM down
            """, arguments: [tagId]) ?? 0
    }
}

/// Document history (Paperless-ngx audit log).
public enum AuditLog {
    public static func record(
        _ action: AuditLogEntry.Action, objectType: String, objectId: Int, repr: String,
        changes: [String: [String?]]? = nil, actorId: Int?, remoteAddr: String? = nil, in db: Database
    ) throws {
        var entry = AuditLogEntry(actorId: actorId, action: action, objectType: objectType, objectId: objectId, objectRepr: repr, changes: changes, remoteAddr: remoteAddr)
        try entry.insert(db)
    }

    /// Field-level differences between two versions of a document.
    static func diff(_ a: Document, _ b: Document) -> [String: [String?]] {
        var changes: [String: [String?]] = [:]
        func compare<T: Equatable>(_ name: String, _ x: T?, _ y: T?) {
            if x != y { changes[name] = [x.map { "\($0)" }, y.map { "\($0)" }] }
        }
        compare("title", a.title, b.title)
        compare("content", a.content == b.content ? nil : "…", a.content == b.content ? nil : "…")
        compare("correspondent", a.correspondentId, b.correspondentId)
        compare("document_type", a.documentTypeId, b.documentTypeId)
        compare("storage_path", a.storagePathId, b.storagePathId)
        compare("owner", a.ownerId, b.ownerId)
        compare("created", a.created, b.created)
        compare("archive_serial_number", a.archiveSerialNumber, b.archiveSerialNumber)
        compare("filename", a.filename, b.filename)
        compare("archive_filename", a.archiveFilename, b.archiveFilename)
        return changes
    }

    public static func entries(objectType: String, objectId: Int, in db: Database) throws -> [AuditLogEntry] {
        try AuditLogEntry
            .filter(Column("object_type") == objectType && Column("object_id") == objectId)
            .order(Column("timestamp").desc, Column("id").desc)
            .fetchAll(db)
    }
}
