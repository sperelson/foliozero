import Foundation
import FolioCore
import GRDB

/// Related rows of a page of documents, loaded in a few queries.
struct DocumentRelations: Sendable {
    var tags: [Int: [Int]] = [:]
    var notes: [Int: [JSON]] = [:]
    var customFields: [Int: [JSON]] = [:]
    var correspondentNames: [Int: String] = [:]
    var versions: [Int: [Document]] = [:]
    var grants = GrantTable()
}

struct DocumentSerializeOptions: Sendable {
    var fields: Set<String>?
    var truncateContent = false
    var duplicates: [JSON]?
    var searchHit: JSON?

    init(_ request: APIRequest? = nil) {
        if let request {
            if let raw = request.query["fields"], !raw.isEmpty {
                fields = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            }
            truncateContent = request.query.flag("truncate_content")
        }
    }
}

extension API {
    static let maxPublicFilenameBytes = 255

    /// Paperless-ngx `Document.__str__`: `<created> <correspondent> <title>`.
    static func documentString(_ document: Document, correspondent: String?) -> String {
        var text = document.created.iso
        if let correspondent { text += " \(correspondent)" }
        if !document.title.isEmpty { text += " \(document.title)" }
        return text
    }

    /// Paperless-ngx `get_public_filename`: sanitized, at most 255 UTF-8 bytes, extension kept.
    static func publicFilename(_ document: Document, correspondent: String?, archive: Bool, counter: Int = 0) -> String {
        let ext = (counter > 0 ? String(format: "_%02d", counter) : "") + (archive ? ".pdf" : document.fileExtension)
        var head = documentString(document, correspondent: correspondent)
        let budget = max(0, maxPublicFilenameBytes - ext.utf8.count)
        while head.utf8.count > budget { head.removeLast() }
        return sanitizeFilename(head + ext)
    }

    /// `pathvalidate.sanitize_filename(..., replacement_text="-")`.
    static func sanitizeFilename(_ name: String) -> String {
        let invalid = Set("\"*/:<>?\\|")
        var result = ""
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F || invalid.contains(Character(scalar)) {
                result += "-"
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        while let last = result.last, last == " " || last == "." { result.removeLast() }
        return result
    }

    func loadDocumentRelations(_ documents: [Document], in db: Database) throws -> DocumentRelations {
        var relations = DocumentRelations()
        let ids = documents.compactMap(\.id)
        guard !ids.isEmpty else { return relations }
        for row in try Row.fetchAll(db, SQLRequest<Row>(literal: "SELECT document_id, tag_id FROM document_tags WHERE document_id IN \(ids) ORDER BY tag_id")) {
            relations.tags[row["document_id"], default: []].append(row["tag_id"])
        }
        for row in try Row.fetchAll(db, SQLRequest<Row>(literal: """
            SELECT n.id, n.document_id, n.note, n.created, n.user_id, u.username, u.first_name, u.last_name
            FROM notes n LEFT JOIN users u ON u.id = n.user_id
            WHERE n.document_id IN \(ids) AND n.deleted_at IS NULL ORDER BY n.created DESC, n.id DESC
            """)) {
            let created = (row["created"] as String?).flatMap { FolioDateFormat.database.date(from: $0) }
            var user: JSON = .null
            if let userId = row["user_id"] as Int?, let username = row["username"] as String? {
                user = .object(JSONObject([
                    ("id", .int(userId)), ("username", .string(username)),
                    ("first_name", .string(row["first_name"] ?? "")), ("last_name", .string(row["last_name"] ?? "")),
                ]))
            }
            relations.notes[row["document_id"], default: []].append(.object(JSONObject([
                ("id", .int(row["id"])), ("note", .string(row["note"])), ("created", datetime(created)), ("user", user),
            ])))
        }
        let instances = try CustomFieldInstance
            .filter(ids.contains(Column("document_id")) && Column("deleted_at") == nil)
            .order(Column("created"), Column("id")).fetchAll(db)
        if !instances.isEmpty {
            let fields = Dictionary(uniqueKeysWithValues: try CustomField.fetchAll(db).map { ($0.id ?? 0, $0) })
            for instance in instances {
                guard let field = fields[instance.fieldId] else { continue }
                relations.customFields[instance.documentId, default: []].append(.object(JSONObject([
                    ("value", JSON(CustomFieldValues.value(of: instance, field: field))), ("field", .int(instance.fieldId)),
                ])))
            }
        }
        let correspondentIds = Array(Set(documents.compactMap(\.correspondentId)))
        if !correspondentIds.isEmpty {
            for row in try Row.fetchAll(db, SQLRequest<Row>(literal: "SELECT id, name FROM correspondents WHERE id IN \(correspondentIds)")) {
                relations.correspondentNames[row["id"]] = row["name"]
            }
        }
        for version in try Document.fetchAll(db, SQLRequest<Document>(literal: """
            SELECT * FROM documents WHERE root_document_id IN \(ids) ORDER BY version_index DESC, id DESC
            """)) {
            relations.versions[version.rootDocumentId ?? 0, default: []].append(version)
        }
        relations.grants = try GrantTable.load(objectType: Document.objectType, ids: ids, in: db)
        return relations
    }

    func documentJSON(_ document: Document, relations: DocumentRelations, context: SerializeContext, options: DocumentSerializeOptions) -> JSON {
        let id = document.id ?? 0
        let versions = relations.versions[id] ?? []
        let latest = versions.first { $0.deletedAt == nil }
        let correspondentName = document.correspondentId.flatMap { relations.correspondentNames[$0] }
        var json = JSONObject()
        json["id"] = .int(id)
        json["correspondent"] = JSON(document.correspondentId)
        json["document_type"] = JSON(document.documentTypeId)
        json["storage_path"] = JSON(document.storagePathId)
        json["title"] = .string(document.title)
        var content = latest?.content ?? document.content
        if options.truncateContent { content = String(content.prefix(550)) }
        json["content"] = .string(content)
        json["tags"] = JSON(relations.tags[id] ?? [])
        json["created"] = date(document.created)
        json["created_date"] = date(document.created)
        json["modified"] = datetime(document.modified)
        json["added"] = datetime(document.added)
        json["deleted_at"] = datetime(document.deletedAt)
        json["archive_serial_number"] = JSON(document.archiveSerialNumber)
        json["original_file_name"] = JSON(document.originalFilename)
        json["archived_file_name"] = document.hasArchiveVersion
            ? .string(Self.publicFilename(document, correspondent: correspondentName, archive: true)) : .null
        json["duplicate_documents"] = .array(options.duplicates ?? [])
        relations.grants.addOwnedFields(to: &json, id: id, ownerId: document.ownerId, context: context, sharedFlag: true)
        json["notes"] = .array(relations.notes[id] ?? [])
        json["custom_fields"] = .array(relations.customFields[id] ?? [])
        json["page_count"] = JSON(latest?.pageCount ?? document.pageCount)
        json["mime_type"] = .string(document.mimeType)
        json["root_document"] = JSON(document.rootDocumentId)
        let all = (versions + [document]).map { version in
            JSON.object(JSONObject([
                ("id", JSON(version.id)), ("added", datetime(version.added)), ("version_label", JSON(version.versionLabel)),
                ("checksum", .string(version.checksum)), ("is_root", .bool(version.id == id)),
            ]))
        }
        json["versions"] = .array(all)
        if let fields = options.fields { json = json.filtered(fields) }
        if let hit = options.searchHit { json["__search_hit__"] = hit }
        return .object(json)
    }

    /// Serializes documents (one page) with their relations.
    func documentsJSON(_ documents: [Document], context: SerializeContext, options: DocumentSerializeOptions,
                       hits: [Int: JSON] = [:], in db: Database) throws -> [JSON] {
        let relations = try loadDocumentRelations(documents, in: db)
        return documents.map { document in
            var perDocument = options
            perDocument.searchHit = hits[document.id ?? 0]
            return documentJSON(document, relations: relations, context: context, options: perDocument)
        }
    }

    /// Other root documents (including trashed ones) with the same checksum, that the caller may see.
    func duplicatesJSON(_ document: Document, access: AccessContext, in db: Database) throws -> [JSON] {
        var checksums = [document.checksum]
        if let archive = document.archiveChecksum, !archive.isEmpty { checksums.append(archive) }
        let rows = try Document.fetchAll(db, SQLRequest<Document>(literal: """
            SELECT o.* FROM documents o
            WHERE (o.checksum IN \(checksums) OR o.archive_checksum IN \(checksums)) AND o.id != \(document.id ?? 0)
              AND o.root_document_id IS NULL AND \(access.visibilityPredicate(objectType: Document.objectType, alias: "o"))
            ORDER BY o.created DESC, o.id DESC
            """))
        return rows.map { JSON.object(JSONObject([("id", JSON($0.id)), ("title", .string($0.title)), ("deleted_at", datetime($0.deletedAt))])) }
    }

    /// `selection_data`: per object, how many of the selected documents use it.
    func selectionDataJSON(documentIds: SQL, in db: Database) throws -> JSON {
        func counts(_ sql: SQL) throws -> [Int: Int] {
            var result: [Int: Int] = [:]
            for row in try Row.fetchAll(db, SQLRequest<Row>(literal: sql)) {
                if let id = row["object_id"] as Int? { result[id] = row["n"] }
            }
            return result
        }
        func list(_ table: String, _ counts: [Int: Int]) throws -> JSON {
            let ids = try Int.fetchAll(db, sql: "SELECT id FROM \(table) ORDER BY id")
            return .array(ids.map { JSON.object(JSONObject([("id", .int($0)), ("document_count", .int(counts[$0] ?? 0))])) })
        }
        let correspondents = try counts("SELECT correspondent_id AS object_id, COUNT(*) AS n FROM documents WHERE id IN (\(documentIds)) GROUP BY correspondent_id")
        let types = try counts("SELECT document_type_id AS object_id, COUNT(*) AS n FROM documents WHERE id IN (\(documentIds)) GROUP BY document_type_id")
        let paths = try counts("SELECT storage_path_id AS object_id, COUNT(*) AS n FROM documents WHERE id IN (\(documentIds)) GROUP BY storage_path_id")
        let tags = try counts("SELECT tag_id AS object_id, COUNT(DISTINCT document_id) AS n FROM document_tags WHERE document_id IN (\(documentIds)) GROUP BY tag_id")
        let fields = try counts("""
            SELECT field_id AS object_id, COUNT(DISTINCT document_id) AS n FROM custom_field_instances
            WHERE deleted_at IS NULL AND document_id IN (\(documentIds)) GROUP BY field_id
            """)
        return .object(JSONObject([
            ("selected_correspondents", try list("correspondents", correspondents)),
            ("selected_tags", try list("tags", tags)),
            ("selected_document_types", try list("document_types", types)),
            ("selected_storage_paths", try list("storage_paths", paths)),
            ("selected_custom_fields", try list("custom_fields", fields)),
        ]))
    }
}
