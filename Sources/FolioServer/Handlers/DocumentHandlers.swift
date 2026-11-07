import Foundation
import FolioCore
import FolioParsing
import GRDB
import HTTPTypes
import Hummingbird

extension API {
    static let searchParameters = ["text", "title_search", "query", "more_like_id"]

    /// Base predicate of the documents list: root documents, not trashed, visible, filtered.
    func documentPredicate(_ query: QueryItems, access: AccessContext, in db: Database) throws -> SQL {
        let filter = DocumentFilter(access: access, timeZone: settings.timeZone)
        let filters: SQL
        do {
            filters = try filter.predicate(query.items, in: db)
        } catch let error as FilterError {
            throw Self.filterError(error)
        }
        return "d.root_document_id IS NULL AND d.deleted_at IS NULL AND \(access.visibilityPredicate(objectType: Document.objectType, alias: "d")) AND \(filters)"
    }

    static func filterError(_ error: FilterError) -> APIError {
        var value: JSON = [.string(error.message)]
        for key in error.path.reversed() { value = .object(JSONObject([(key, value)])) }
        return .validation(.object(JSONObject([(error.field, value)])))
    }

    func documentOrdering(_ param: String?, access: AccessContext, in db: Database) throws -> SQL {
        do {
            return try DocumentFilter(access: access, timeZone: settings.timeZone).ordering(param, in: db)
        } catch let error as FilterError {
            throw Self.filterError(error)
        }
    }

    // MARK: - List

    func listDocuments(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, Document.objectType)
        let query = request.query
        let active = Self.searchParameters.filter { query.contains($0) }
        if !active.isEmpty { return try await searchDocuments(request, active: active) }
        let context = SerializeContext(request)
        let options = DocumentSerializeOptions(request)
        let body = try await read { db -> JSONObject in
            let predicate = try self.documentPredicate(query, access: access, in: db)
            let order = try self.documentOrdering(query["ordering"], access: access, in: db)
            let count = try Int.fetchOne(db, SQLRequest<Int>(literal: "SELECT COUNT(*) FROM documents d WHERE \(predicate)")) ?? 0
            let page = try PageRequest.resolve(query, count: count)
            let documents = try Document.fetchAll(db, SQLRequest<Document>(literal: """
                SELECT d.* FROM documents d WHERE \(predicate) ORDER BY \(order) LIMIT \(page.size) OFFSET \(page.offset)
                """))
            let results = try self.documentsJSON(documents, context: context, options: options, in: db)
            let all = request.version < 10
                ? try Int.fetchAll(db, SQLRequest<Int>(literal: "SELECT d.id FROM documents d WHERE \(predicate) ORDER BY \(order)")) : nil
            var envelope = self.paginated(request, page: page, count: count, results: results, allIds: all)
            if query.flag("include_selection_data") {
                envelope["selection_data"] = try self.selectionDataJSON(documentIds: "SELECT d.id FROM documents d WHERE \(predicate)", in: db)
            }
            return envelope
        }
        return .json(.object(body))
    }

    /// Full-text search (`text`, `title_search`, `query`, `more_like_id`) with `__search_hit__`.
    func searchDocuments(_ request: APIRequest, active: [String]) async throws -> Response {
        let access = request.access
        let query = request.query
        let combinable: Set<Set<String>> = [["text", "query"], ["title_search", "query"]]
        if active.count > 1 && !combinable.contains(Set(active)) {
            throw APIError.validation(["detail": "Specify only one of text, title_search, query, or more_like_id."])
        }
        for name in active where (query[name]?.count ?? 0) > 4096 {
            throw APIError.validation(["query": ["Query must be at most 4096 characters"]])
        }
        let searchQuery: SearchQuery?
        let moreLikeId: Int?
        if active.contains("more_like_id") {
            guard let id = query.int("more_like_id") else { throw APIError.forbiddenText("Invalid more_like_id") }
            moreLikeId = id
            searchQuery = nil
        } else {
            moreLikeId = nil
            var parts: [SearchQuery] = []
            if let text = query["text"] { parts.append(SearchIndex.simpleQuery(text, titleOnly: false)) }
            if let text = query["title_search"] { parts.append(SearchIndex.simpleQuery(text, titleOnly: true)) }
            if let text = query["query"] {
                do {
                    parts.append(try APISearch.parseQuery(text, timeZone: settings.timeZone))
                } catch let error as SearchQueryError {
                    throw APIError.validation(["query": [.string(error.message)]])
                }
            }
            searchQuery = parts.count == 1 ? parts[0] : .and(parts)
        }
        let ordering = query["ordering"]
        let context = SerializeContext(request)
        let options = DocumentSerializeOptions(request)
        let timeZone = settings.timeZone
        let body = try await read { db -> JSONObject in
            let predicate = try self.documentPredicate(query, access: access, in: db)
            var hits: [SearchIndex.Hit]
            if let moreLikeId {
                guard let source = try Document.fetchOne(db, key: moreLikeId) else { throw APIError.forbiddenText("Invalid more_like_id") }
                let root = source.rootDocumentId ?? moreLikeId
                let rootDocument = try Document.fetchOne(db, key: root) ?? source
                guard try access.can(.view, objectType: Document.objectType, objectId: root, ownerId: rootDocument.ownerId, in: db) else {
                    throw APIError.forbiddenText("Insufficient permissions.")
                }
                hits = try SearchIndex.moreLikeThis(documentId: root, in: db, visibility: predicate, limit: 1000)
                hits = hits.map { var hit = $0; hit.score = 0; hit.highlights = ""; return hit }
            } else {
                hits = try SearchIndex.search(searchQuery ?? .all, in: db, visibility: predicate, timeZone: timeZone)
            }
            var orderedIds = hits.map(\.documentId)
            let field = ordering?.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            if let ordering, !ordering.isEmpty, field != "score" {
                let order = try self.documentOrdering(ordering, access: access, in: db)
                orderedIds = try Int.fetchAll(db, SQLRequest<Int>(literal: "SELECT d.id FROM documents d WHERE d.id IN \(Self.idSet(orderedIds)) ORDER BY \(order)"))
            } else if ordering == "score" {
                orderedIds.reverse()
            }
            let hitById = Dictionary(hits.map { ($0.documentId, $0) }, uniquingKeysWith: { a, _ in a })
            let count = orderedIds.count
            let page = try PageRequest.resolve(query, count: count)
            let pageIds = Array(orderedIds.dropFirst(page.offset).prefix(page.size))
            let documents = try Document.fetchAll(db, keys: pageIds)
            let byId = Dictionary(documents.map { ($0.id ?? 0, $0) }, uniquingKeysWith: { a, _ in a })
            var hitJSON: [Int: JSON] = [:]
            for (index, id) in pageIds.enumerated() {
                let hit = hitById[id]
                hitJSON[id] = .object(JSONObject([
                    ("score", .double(hit?.score ?? 0)),
                    ("highlights", .string(hit?.highlights ?? "")),
                    ("note_highlights", .null),
                    ("rank", .int(page.offset + index + 1)),
                ]))
            }
            let results = try self.documentsJSON(pageIds.compactMap { byId[$0] }, context: context, options: options, hits: hitJSON, in: db)
            var envelope = self.paginated(request, page: page, count: count, results: results, allIds: orderedIds)
            envelope["corrected_query"] = .null
            if query.flag("include_selection_data") {
                envelope["selection_data"] = try self.selectionDataJSON(documentIds: "SELECT d.id FROM documents d WHERE d.id IN \(Self.idSet(orderedIds))", in: db)
            }
            return envelope
        }
        return .json(.object(body))
    }

    // MARK: - Single document

    /// A root document that is not trashed and that the caller may see, else 404.
    func loadVisibleDocument(_ id: Int, access: AccessContext, in db: Database) throws -> Document {
        guard let document = try Document.fetchOne(db, key: id), document.deletedAt == nil, document.rootDocumentId == nil,
              try access.can(.view, objectType: Document.objectType, objectId: id, ownerId: document.ownerId, in: db) else {
            throw APIError.notFound("Document")
        }
        return document
    }

    /// Paperless-ngx `has_perms_owner_aware` on the root document.
    func canAccess(_ document: Document, _ kind: ObjectPermission.Kind, access: AccessContext, in db: Database) throws -> Bool {
        let root = try document.rootDocumentId.flatMap { try Document.fetchOne(db, key: $0) } ?? document
        return try access.can(kind, objectType: Document.objectType, objectId: root.id ?? 0, ownerId: root.ownerId, in: db)
    }

    func singleDocumentJSON(_ id: Int, context: SerializeContext, options: DocumentSerializeOptions, includeDuplicates: Bool, in db: Database) throws -> JSON {
        let document = try loadVisibleDocument(id, access: context.access, in: db)
        var options = options
        if includeDuplicates { options.duplicates = try duplicatesJSON(document, access: context.access, in: db) }
        return try documentsJSON([document], context: context, options: options, in: db)[0]
    }

    func getDocument(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, Document.objectType)
        let id = try request.intParam("id")
        let context = SerializeContext(request)
        let options = DocumentSerializeOptions(request)
        let version = request.query["version"]
        let json = try await read { db -> JSON in
            var json = try self.singleDocumentJSON(id, context: context, options: options, includeDuplicates: true, in: db)
            // `?version=`: content and page count of that version.
            if let version, case .object(var object) = json {
                let root = try DocumentStore.document(id, in: db)
                let file = try self.effectiveVersion(of: root, requested: root, version: version, in: db)
                if object.contains("content") { object["content"] = .string(file.content) }
                if object.contains("page_count") { object["page_count"] = JSON(file.pageCount) }
                json = .object(object)
            }
            return json
        }
        return .json(json)
    }

    func nextASN(_ request: APIRequest) async throws -> Response {
        try request.access.require(.view, Document.objectType)
        let next = try await read { db in try DocumentStore.nextArchiveSerialNumber(in: db) }
        return .json(.int(next))
    }

    func documentRoot(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, Document.objectType)
        let id = try request.intParam("id")
        let root = try await read { db -> Int in
            guard let document = try Document.fetchOne(db, key: id) else { throw APIError.notFound() }
            guard try self.canAccess(document, .view, access: access, in: db) else { throw APIError.forbiddenText() }
            return document.rootDocumentId ?? id
        }
        return .json(["root_id": .int(root)])
    }

    // MARK: - Update

    /// Validated changes from a PUT or PATCH body.
    struct DocumentChanges: Sendable {
        var title: String?
        var content: String?
        var correspondent: Int??
        var documentType: Int??
        var storagePath: Int??
        var tags: [Int]?
        var created: CalendarDate?
        var asn: Int??
        var owner: Int??
        var permissions: PermissionSpec?
        var customFields: [(Int, JSON?)]?
        var removeInboxTags = false
    }

    func parseDocumentChanges(_ data: RequestData, partial: Bool, in db: Database) throws -> DocumentChanges {
        var changes = DocumentChanges()
        var errors = JSONObject()
        func capture(_ block: () throws -> Void) throws {
            do { try block() } catch let error as APIError {
                if case .json(.object(let object)) = error.body, error.status == .badRequest {
                    for (key, value) in object { errors[key] = value }
                } else {
                    throw error
                }
            }
        }
        if !partial {
            for key in ["correspondent", "document_type", "storage_path", "tags"] where !data.has(key) {
                errors[key] = [.string(APIError.requiredField)]
            }
        }
        try capture {
            if let title = data["title"] {
                guard let text = title.string else { throw APIError.field("title", "Not a valid string.") }
                guard text.count <= 128 else { throw APIError.field("title", "Ensure this field has no more than 128 characters.") }
                changes.title = text
            }
        }
        if let content = data["content"] {
            if content.isNull { errors["content"] = ["This field may not be null."] } else { changes.content = content.string ?? "" }
        }
        try capture { changes.correspondent = try data.foreignKey("correspondent", table: "correspondents", in: db) }
        try capture { changes.documentType = try data.foreignKey("document_type", table: "document_types", in: db) }
        try capture { changes.storagePath = try data.foreignKey("storage_path", table: "storage_paths", in: db) }
        try capture {
            if let tags = try data.idList("tags") {
                for tag in tags where try Tag.fetchOne(db, key: tag) == nil {
                    throw APIError.field("tags", APIError.invalidPK(String(tag)))
                }
                changes.tags = tags
            }
        }
        try capture {
            for key in ["created", "created_date"] {
                guard let raw = data[key], !raw.isNull, changes.created == nil else { continue }
                guard let text = raw.string, let date = self.parseCreated(text) else {
                    throw APIError.field(key, "Date has wrong format. Use one of these formats instead: YYYY-MM-DD.")
                }
                changes.created = date
            }
        }
        try capture {
            if let raw = data["archive_serial_number"] {
                if raw.isNull || raw.string == "" {
                    changes.asn = .some(nil)
                } else {
                    guard let asn = raw.int else { throw APIError.field("archive_serial_number", "A valid integer is required.") }
                    guard asn >= 0 else { throw APIError.field("archive_serial_number", "Ensure this value is greater than or equal to 0.") }
                    guard asn <= 4_294_967_295 else { throw APIError.field("archive_serial_number", "Ensure this value is less than or equal to 4294967295.") }
                    changes.asn = .some(asn)
                }
            }
        }
        try capture { if data.has("owner") { changes.owner = try data.foreignKey("owner", table: "users", in: db) } }
        try capture { changes.permissions = try PermissionSpec.parse(data["set_permissions"], in: db) }
        try capture {
            if let raw = data["custom_fields"] {
                guard let items = raw.isNull ? [] : raw.array else {
                    throw APIError.field("custom_fields", "Expected a list of items but got type \"\(raw.typeName)\".")
                }
                var fields: [(Int, JSON?)] = []
                for item in items {
                    guard let object = item.object, let fieldValue = object["field"] else {
                        throw APIError.validation(["custom_fields": [["field": ["This field is required."]]]])
                    }
                    guard let fieldId = fieldValue.int, let field = try CustomField.fetchOne(db, key: fieldId) else {
                        throw APIError.validation(["custom_fields": [["field": [.string(APIError.invalidPK(fieldValue.string ?? ""))]]]])
                    }
                    let value = object["value"]
                    if let value, !value.isNull {
                        var scratch = CustomFieldInstance(documentId: 0, fieldId: fieldId)
                        do {
                            try CustomFieldValues.assign(value.jsonValue, field: field, to: &scratch)
                        } catch let error as CustomFieldValueError {
                            throw APIError.validation(["custom_fields": [["non_field_errors": [.string(error.description)]]]])
                        }
                    }
                    fields.append((fieldId, value))
                }
                changes.customFields = fields
            }
        }
        try capture { changes.removeInboxTags = try data.optionalBool("remove_inbox_tags") ?? false }
        if !errors.isEmpty { throw APIError.validation(.object(errors)) }
        return changes
    }

    /// `2024-03-14`, or an ISO datetime (converted to the configured zone's date).
    func parseCreated(_ text: String) -> CalendarDate? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count == 10 { return CalendarDate(iso: trimmed) }
        return QueryFilters.parseDateTime(trimmed, timeZone: settings.timeZone).map { CalendarDate($0, in: settings.timeZone) }
    }

    /// Paperless-ngx tag semantics: removing a tag removes its descendants; adding one adds its ancestors.
    func resolveTagChange(current: Set<Int>, requested: Set<Int>, in db: Database) throws -> Set<Int> {
        func withAncestors(_ ids: Set<Int>) throws -> Set<Int> {
            var result = ids
            for id in ids { result.formUnion(try DocumentStore.ancestors(of: id, in: db)) }
            return result
        }
        func withDescendants(_ ids: Set<Int>) throws -> Set<Int> {
            var result = ids
            for id in ids { result.formUnion(try DocumentStore.descendants(of: id, in: db)) }
            return result
        }
        let required = try withAncestors(requested.subtracting(current))
        let blocked = try withDescendants(current.subtracting(requested)).subtracting(required)
        return try withAncestors(requested).subtracting(blocked)
    }

    /// Applies validated changes inside a transaction. Returns the saved document.
    func applyDocumentChanges(_ changes: DocumentChanges, to original: Document, access: AccessContext, in db: Database) throws -> Document {
        let id = original.id ?? 0
        var document = original
        if changes.owner != nil || changes.permissions != nil {
            let ownerChanges = changes.owner.map { $0 != original.ownerId } ?? false
            if ownerChanges || changes.permissions != nil {
                guard access.isOwner(ownerId: original.ownerId) else { throw APIError.insufficientPermissions }
            }
        }
        if let title = changes.title { document.title = title }
        if let content = changes.content {
            if let latest = try Document.filter(Column("root_document_id") == id).order(Column("version_index").desc).fetchOne(db) {
                var version = latest
                version.content = content
                version.modified = Date()
                try version.update(db)
            } else {
                document.content = content
            }
        }
        if case .some(let value) = changes.correspondent { document.correspondentId = value }
        if case .some(let value) = changes.documentType { document.documentTypeId = value }
        if case .some(let value) = changes.storagePath { document.storagePathId = value }
        if let created = changes.created { document.created = created }
        if case .some(let value) = changes.owner { document.ownerId = value }
        if case .some(let asn) = changes.asn, let asn, asn != original.archiveSerialNumber {
            let inTrash = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM documents WHERE archive_serial_number = ? AND deleted_at IS NOT NULL AND id != ?", arguments: [asn, id]) ?? 0
            if inTrash > 0 { throw APIError.field("archive_serial_number", "Document with this Archive Serial Number already exists in the trash.") }
        }
        if case .some(let asn) = changes.asn { document.archiveSerialNumber = asn }
        do {
            try DocumentStore.update(document, actorId: access.user.id, auditEnabled: settings.auditLogEnabled, in: db)
        } catch DocumentStoreError.asnInUse {
            throw APIError.field("archive_serial_number", "Document with this Archive Serial Number already exists.")
        }

        let currentTags = Set(try DocumentStore.tagIds(of: id, in: db))
        var finalTags = currentTags
        if let requested = changes.tags {
            finalTags = try resolveTagChange(current: currentTags, requested: Set(requested), in: db)
        }
        if changes.removeInboxTags {
            let added = finalTags.subtracting(currentTags)
            var keep = added
            for tag in added { keep.formUnion(try DocumentStore.ancestors(of: tag, in: db)) }
            var inbox = Set(try Classification.inboxTagIds(in: db)).subtracting(keep)
            for tag in inbox { inbox.formUnion(try DocumentStore.descendants(of: tag, in: db)) }
            finalTags.subtract(inbox.subtracting(keep))
        }
        if finalTags != currentTags {
            try DocumentStore.setTags(documentId: id, tagIds: Array(finalTags), in: db)
            if settings.auditLogEnabled {
                try AuditLog.record(.update, objectType: Document.objectType, objectId: id, repr: document.title,
                                    changes: ["tags": [currentTags.sorted().map(String.init).joined(separator: ","),
                                                       Set(try DocumentStore.tagIds(of: id, in: db)).sorted().map(String.init).joined(separator: ",")]],
                                    actorId: access.user.id, in: db)
            }
        }
        if let fields = changes.customFields {
            try validateDocumentLinks(fields, access: access, in: db)
            let incoming = Set(fields.map(\.0))
            for existing in try Int.fetchAll(db, sql: "SELECT field_id FROM custom_field_instances WHERE document_id = ?", arguments: [id])
            where !incoming.contains(existing) {
                try CustomFieldValues.remove(fieldId: existing, documentId: id, in: db)
            }
            for (fieldId, value) in fields {
                try CustomFieldValues.set(fieldId: fieldId, value: value?.jsonValue ?? .null, documentId: id, in: db)
            }
        }
        try changes.permissions?.apply(objectType: Document.objectType, objectIds: [id], merge: false, in: db)

        // Rename files when naming inputs changed.
        var saved = try DocumentStore.document(id, in: db)
        do {
            let named = try app.storage.applyNaming(to: saved, in: db)
            if named.filename != saved.filename || named.archiveFilename != saved.archiveFilename {
                saved.filename = named.filename
                saved.archiveFilename = named.archiveFilename
                try saved.update(db)
            }
        } catch {
            logger.warning("Could not rename files of document #\(id): \(error)")
        }
        try SearchIndex.update(documentId: id, in: db)
        return saved
    }

    /// Document link targets must exist and be changeable by the caller.
    func validateDocumentLinks(_ fields: [(Int, JSON?)], access: AccessContext, in db: Database) throws {
        for (fieldId, value) in fields {
            guard let field = try CustomField.fetchOne(db, key: fieldId), field.dataType == .documentlink,
                  let ids = value?.array?.compactMap(\.int), !ids.isEmpty else { continue }
            let documents = try Document.fetchAll(db, keys: ids)
            if documents.count != Set(ids).count {
                throw APIError.validation(["custom_fields": [["value": ["Some documents in value don't exist or were specified twice."]]]])
            }
            for document in documents where try !access.can(.change, objectType: Document.objectType, objectId: document.id ?? 0, ownerId: document.ownerId, in: db) {
                throw APIError.insufficientPermissions
            }
        }
    }

    func updateDocument(_ request: APIRequest, partial: Bool) async throws -> Response {
        let access = request.access
        try access.require(.change, Document.objectType)
        let id = try request.intParam("id")
        let data = try request.data()
        let context = SerializeContext(request, fullPerms: true)
        let options = DocumentSerializeOptions(request)
        let json = try await write { db -> JSON in
            let document = try self.loadVisibleDocument(id, access: access, in: db)
            guard try access.can(.change, objectType: Document.objectType, objectId: id, ownerId: document.ownerId, in: db) else {
                throw APIError.permissionDenied
            }
            let changes = try self.parseDocumentChanges(data, partial: partial, in: db)
            _ = try self.applyDocumentChanges(changes, to: document, access: access, in: db)
            return try self.singleDocumentJSON(id, context: context, options: options, includeDuplicates: false, in: db)
        }
        // "Document Updated" workflows, after the edit is committed (Paperless `document_updated`).
        await WorkflowEngine(app: app).documentUpdated(id)
        await publishDocumentUpdated(id)
        return .json(json)
    }

    func deleteDocument(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.delete, Document.objectType)
        let id = try request.intParam("id")
        try await write { db in
            let document = try self.loadVisibleDocument(id, access: access, in: db)
            guard access.isOwner(ownerId: document.ownerId) else { throw APIError.permissionDenied }
            try DocumentStore.moveToTrash(id, actorId: access.user.id, in: db)
        }
        await publishDocumentsDeleted([id])
        return .noContent()
    }

    // MARK: - Files

    /// A document (trashed or not) and the document whose file to serve, after the view check on its root.
    ///
    /// The file document is `?version=<id>` when given, the requested document when it is a version,
    /// otherwise the newest version of the root (Paperless-ngx `_get_effective_file_doc`). Its title,
    /// created date and correspondent come from the root, which owns the metadata.
    func loadFileDocument(_ id: Int, version: String?, access: AccessContext, includeDeleted: Bool = true) async throws -> (Document, String?) {
        try await read { db -> (Document, String?) in
            guard let document = try Document.fetchOne(db, key: id), includeDeleted || document.deletedAt == nil else {
                throw APIError.notFound("Document")
            }
            guard try self.canAccess(document, .view, access: access, in: db) else { throw APIError.forbiddenText() }
            let root = try document.rootDocumentId.flatMap { try Document.fetchOne(db, key: $0) } ?? document
            var file = try self.effectiveVersion(of: root, requested: document, version: version, in: db)
            file.title = root.title
            file.created = root.created
            file.correspondentId = root.correspondentId
            let correspondent = try root.correspondentId.flatMap { try Correspondent.fetchOne(db, key: $0)?.name }
            return (file, correspondent)
        }
    }

    /// `?version=` resolution for a root document.
    func effectiveVersion(of root: Document, requested: Document, version: String?, in db: Database) throws -> Document {
        let rootId = root.id ?? 0
        if let version {
            guard let versionId = Int(version), let found = try Document.fetchOne(db, key: versionId),
                  found.id == rootId || found.rootDocumentId == rootId else {
                throw APIError.detail(.notFound, "Invalid version parameter")
            }
            return found
        }
        if requested.rootDocumentId != nil { return requested }
        return try Document.filter(Column("root_document_id") == rootId && Column("deleted_at") == nil)
            .order(Column("version_index").desc, Column("id").desc).fetchOne(db) ?? root
    }

    /// A file under `root`, refusing anything that resolves outside it.
    func safeFile(_ relative: String?, root: URL) throws -> URL {
        guard let relative, !relative.isEmpty else { throw APIError.notFound() }
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.hasPrefix("/"), !components.contains(where: { $0 == ".." || $0.isEmpty }) else { throw APIError.notFound() }
        let url = root.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        guard url.path.hasPrefix(rootPath + "/"), FileManager.default.fileExists(atPath: url.path) else { throw APIError.notFound() }
        return url
    }

    func fileResponse(_ url: URL, contentType: String, disposition: String?, filename: String?, context: APIRequestContext) async throws -> Response {
        let size = ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue
        let body = try await FileIO().loadFile(path: url.path, context: context)
        var headers: HTTPFields = [:]
        headers[.contentType] = contentType
        if let size { headers[.contentLength] = String(size) }
        if let disposition, let filename { headers[.contentDisposition] = ContentDisposition.header(disposition, filename: filename) }
        headers[.cacheControl] = "no-cache"
        return Response(status: .ok, headers: headers, body: body)
    }

    func serveDocumentFile(_ document: Document, correspondent: String?, useArchive: Bool, disposition: String,
                           followFormatting: Bool, context: APIRequestContext) async throws -> Response {
        if useArchive {
            let url = try safeFile(document.archiveFilename, root: app.storage.archiveDir)
            let name = followFormatting ? ((document.archiveFilename ?? "") as NSString).lastPathComponent
                : Self.publicFilename(document, correspondent: correspondent, archive: true)
            return try await fileResponse(url, contentType: "application/pdf", disposition: disposition, filename: name, context: context)
        }
        let url = try safeFile(document.filename, root: app.storage.originalsDir)
        let name = followFormatting ? ((document.filename ?? "") as NSString).lastPathComponent
            : Self.publicFilename(document, correspondent: correspondent, archive: false)
        var mime = document.mimeType
        if ["application/csv", "text/csv"].contains(mime) && disposition == "inline" { mime = "text/plain" }
        if ["text/plain", "text/csv", "application/csv"].contains(mime) { mime += "; charset=utf-8" }
        return try await fileResponse(url, contentType: mime, disposition: disposition, filename: name, context: context)
    }

    func documentFile(_ request: APIRequest, disposition: String) async throws -> Response {
        let access = request.access
        try access.require(.view, Document.objectType)
        let id = try request.intParam("id")
        let (document, correspondent) = try await loadFileDocument(id, version: request.query["version"], access: access)
        let useArchive = request.query["original"] != "true" && document.hasArchiveVersion
        return try await serveDocumentFile(document, correspondent: correspondent, useArchive: useArchive, disposition: disposition,
                                           followFormatting: request.query.flag("follow_formatting"), context: request.context)
    }

    func documentThumbnail(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, Document.objectType)
        let id = try request.intParam("id")
        let (document, _) = try await loadFileDocument(id, version: request.query["version"], access: access)
        let url = app.storage.thumbnailURL(documentId: document.id ?? id)
        guard FileManager.default.fileExists(atPath: url.path) else { throw APIError.notFound() }
        return try await fileResponse(url, contentType: "image/jpeg", disposition: nil, filename: nil, context: request.context)
    }

    func documentMetadata(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, Document.objectType)
        let id = try request.intParam("id")
        let (document, _) = try await loadFileDocument(id, version: request.query["version"], access: access, includeDeleted: false)
        let fileId = document.id ?? id
        let barcodes = try await read { db in
            try DocumentBarcode.filter(Column("document_id") == fileId).order(Column("page"), Column("id")).fetchAll(db)
        }
        func size(_ url: URL?) -> JSON {
            guard let url, let value = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber else { return .null }
            return .int(value.intValue)
        }
        func entries(_ list: [MetadataEntry]?) -> JSON {
            .array((list ?? []).map { ["namespace": .string($0.namespace), "prefix": .string($0.prefix), "key": .string($0.key), "value": .string($0.value)] })
        }
        let json: JSON = .object(JSONObject([
            ("original_checksum", .string(document.checksum)),
            ("original_size", size(app.storage.originalURL(document))),
            ("original_mime_type", .string(document.mimeType)),
            ("media_filename", JSON(document.filename)),
            ("has_archive_version", .bool(document.hasArchiveVersion)),
            ("original_metadata", entries(document.originalMetadata)),
            ("archive_checksum", JSON(document.archiveChecksum)),
            ("archive_media_filename", JSON(document.archiveFilename)),
            ("original_filename", JSON(document.originalFilename)),
            ("archive_size", document.hasArchiveVersion ? size(app.storage.archiveURL(document)) : .null),
            ("archive_metadata", document.hasArchiveVersion ? entries(document.archiveMetadata) : .null),
            ("barcodes", .array(barcodes.map { ["page": .int($0.page), "value": .string($0.value), "format": .string($0.format)] })),
            ("lang", .string(document.language.map { String($0.prefix(2)) } ?? "en")),
        ]))
        return .json(json)
    }

    func documentSuggestions(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, Document.objectType)
        let id = try request.intParam("id")
        let classifier = app.classifier()
        let classification = Classification(matcher: app.matcher)
        let extractor = app.dateExtractor
        let count = settings.numberOfSuggestedDates
        let json = try await read { db -> JSON in
            guard let document = try Document.fetchOne(db, key: id), document.deletedAt == nil else { throw APIError.notFound("Document") }
            guard try self.canAccess(document, .change, access: access, in: db) else { throw APIError.forbiddenText() }
            let content = try Document.filter(Column("root_document_id") == id).order(Column("version_index").desc).fetchOne(db)?.content ?? document.content
            let predictions = classifier?.predict(content) ?? .init()
            let suggestions = try classification.suggestions(content: content, ownerId: access.isSuperuser ? nil : access.user.id,
                                                             classifierPredictions: predictions, in: db)
            let dates = count > 0 ? Array(Set(extractor.dates(filename: document.filename ?? "", content: content).prefix(count))).sorted() : []
            return .object(JSONObject([
                ("correspondents", JSON(suggestions.correspondentIds)),
                ("tags", JSON(suggestions.tagIds)),
                ("document_types", JSON(suggestions.documentTypeIds)),
                ("storage_paths", JSON(suggestions.storagePathIds)),
                ("dates", JSON(dates.map(\.iso))),
            ]))
        }
        return .json(json)
    }

    func documentHistory(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, Document.objectType)
        guard settings.auditLogEnabled else { throw APIError.badRequestText("Audit log is disabled") }
        let id = try request.intParam("id")
        let json = try await read { db -> JSON in
            guard let document = try Document.fetchOne(db, key: id), document.deletedAt == nil else { throw APIError.notFound("Document") }
            let root = try document.rootDocumentId.flatMap { try Document.fetchOne(db, key: $0) } ?? document
            guard access.has(.view, "logentry"), root.ownerId == nil || root.ownerId == access.user.id || access.isSuperuser else {
                throw APIError.forbiddenText()
            }
            let entries = try AuditLog.entries(objectType: Document.objectType, objectId: id, in: db)
            let actors = Dictionary(uniqueKeysWithValues: try User.fetchAll(db, keys: Set(entries.compactMap(\.actorId))).map { ($0.id ?? 0, $0) })
            return .array(entries.map { entry in
                var changes = JSONObject()
                for key in (entry.changes ?? [:]).keys.sorted() {
                    changes[key] = .array((entry.changes?[key] ?? []).map { JSON($0) })
                }
                let actor: JSON = entry.actorId.flatMap { actors[$0] }.map { ["id": JSON($0.id), "username": .string($0.username)] } ?? .null
                return .object(JSONObject([
                    ("id", JSON(entry.id)), ("timestamp", self.datetime(entry.timestamp)), ("action", .string(entry.action.rawValue)),
                    ("changes", .object(changes)), ("actor", actor),
                ]))
            })
        }
        return .json(json)
    }

    // MARK: - Notes

    func notesJSON(_ documentId: Int, in db: Database) throws -> JSON {
        let document = try DocumentStore.document(documentId, in: db)
        return .array(try loadDocumentRelations([document], in: db).notes[documentId] ?? [])
    }

    func getNotes(_ request: APIRequest) async throws -> Response {
        let access = request.access
        guard access.has(.view, "note"), access.has(.view, Document.objectType) else { throw APIError.permissionDenied }
        let id = try request.intParam("id")
        let json = try await read { db -> JSON in
            guard let document = try Document.fetchOne(db, key: id), document.deletedAt == nil else { throw APIError.notFound("Document") }
            guard try self.canAccess(document, .view, access: access, in: db) else { throw APIError.forbiddenText("Insufficient permissions to view notes") }
            return try self.notesJSON(id, in: db)
        }
        return .json(json)
    }

    func addNote(_ request: APIRequest) async throws -> Response {
        let access = request.access
        guard access.has(.add, "note"), access.has(.view, Document.objectType), access.has(.change, Document.objectType) else {
            throw APIError.permissionDenied
        }
        let id = try request.intParam("id")
        let data = try request.data()
        let auditEnabled = settings.auditLogEnabled
        let json = try await write { db -> JSON in
            guard var document = try Document.fetchOne(db, key: id), document.deletedAt == nil else { throw APIError.notFound("Document") }
            guard try self.canAccess(document, .view, access: access, in: db) else { throw APIError.forbiddenText("Insufficient permissions to view notes") }
            guard try self.canAccess(document, .change, access: access, in: db) else { throw APIError.forbiddenText("Insufficient permissions to create notes") }
            guard let text = data["note"]?.string, !text.isEmpty else { return ["error": "Error saving note, check logs for more detail."] }
            var note = Note(documentId: id, note: text, userId: access.user.id)
            try note.insert(db)
            if auditEnabled {
                try AuditLog.record(.update, objectType: Document.objectType, objectId: id, repr: document.title,
                                    changes: ["Note Added": ["None", String(note.id ?? 0)]], actorId: access.user.id, in: db)
            }
            document.modified = Date()
            try document.update(db)
            try SearchIndex.update(documentId: id, in: db)
            return try self.notesJSON(id, in: db)
        }
        return .json(json)
    }

    func deleteNote(_ request: APIRequest) async throws -> Response {
        let access = request.access
        guard access.has(.delete, "note"), access.has(.view, Document.objectType), access.has(.change, Document.objectType) else {
            throw APIError.permissionDenied
        }
        let id = try request.intParam("id")
        guard let raw = request.query["id"], !raw.isEmpty else { throw APIError.validation(["id": "This field is required."]) }
        guard let noteId = Int(raw) else { throw APIError.validation(["id": "A valid integer is required."]) }
        let auditEnabled = settings.auditLogEnabled
        let json = try await write { db -> JSON in
            guard var document = try Document.fetchOne(db, key: id), document.deletedAt == nil else { throw APIError.notFound("Document") }
            guard try self.canAccess(document, .view, access: access, in: db) else { throw APIError.forbiddenText("Insufficient permissions to view notes") }
            guard try self.canAccess(document, .change, access: access, in: db) else { throw APIError.forbiddenText("Insufficient permissions to delete notes") }
            guard var note = try Note.fetchOne(db, key: noteId), note.documentId == id, note.deletedAt == nil else { throw APIError.notFound("Note") }
            if auditEnabled {
                try AuditLog.record(.update, objectType: Document.objectType, objectId: id, repr: document.title,
                                    changes: ["Note Deleted": [String(noteId), "None"]], actorId: access.user.id, in: db)
            }
            note.deletedAt = Date()
            try note.update(db)
            document.modified = Date()
            try document.update(db)
            try SearchIndex.update(documentId: id, in: db)
            return try self.notesJSON(id, in: db)
        }
        return .json(json)
    }

    // MARK: - Share links of a document

    func shareLinkJSON(_ link: ShareLink, documentTitle: String) -> JSON {
        .object(JSONObject([
            ("id", JSON(link.id)), ("created", datetime(link.created)), ("expiration", datetime(link.expiration)),
            ("slug", .string(link.slug)), ("document", .int(link.documentId)), ("document_title", .string(documentTitle)),
            ("file_version", .string(link.fileVersion.rawValue)),
        ]))
    }

    func documentShareLinks(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, Document.objectType)
        let id = try request.intParam("id")
        let json = try await read { db -> JSON in
            guard let document = try Document.fetchOne(db, key: id), document.deletedAt == nil else { throw APIError.notFound("Document") }
            guard try self.canAccess(document, .change, access: access, in: db) else { throw APIError.forbiddenText("Insufficient permissions to add share link") }
            let links = try ShareLink.fetchAll(db, sql: """
                SELECT * FROM share_links WHERE document_id = ? AND deleted_at IS NULL AND (expiration IS NULL OR expiration >= ?)
                ORDER BY created DESC
                """, arguments: [id, FolioDateFormat.database.string(from: Date())])
            return .array(links.map { self.shareLinkJSON($0, documentTitle: document.title) })
        }
        return .json(json)
    }

    // MARK: - Selection data

    func selectionData(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, Document.objectType)
        let data = try request.data()
        let json = try await read { db -> JSON in
            let ids = try self.resolveSelection(data, access: access, in: db)
            let found = try self.fetchDocuments(ids, in: db)
            guard found.count == Set(ids).count else { throw APIError.forbiddenText() }
            for document in found where try !self.canAccess(document, .view, access: access, in: db) {
                throw APIError.forbiddenText()
            }
            return try self.selectionDataJSON(documentIds: "SELECT id FROM documents WHERE id IN \(Self.idSet(ids))", in: db)
        }
        return .json(json)
    }

    /// `documents`, or `all` with optional `filters` and `excluded_documents` (Paperless `DocumentSelectionMixin`).
    func resolveSelection(_ data: RequestData, access: AccessContext, in db: Database) throws -> [Int] {
        if try data.optionalBool("all") == true {
            let filters = data["filters"]?.object ?? JSONObject()
            var items: [(name: String, value: String)] = []
            for (key, value) in filters {
                if let list = value.array { items += list.compactMap { $0.string }.map { (key, $0) } } else if let text = value.string { items.append((key, text)) }
            }
            let query = QueryItems(items: items)
            let predicate = try documentPredicate(query, access: access, in: db)
            var ids = try Int.fetchAll(db, SQLRequest<Int>(literal: "SELECT d.id FROM documents d WHERE \(predicate) ORDER BY d.id"))
            let excluded = Set(try data.idList("excluded_documents") ?? [])
            ids.removeAll { excluded.contains($0) }
            return ids
        }
        if let excluded = try data.idList("excluded_documents"), !excluded.isEmpty {
            throw APIError.nonField("excluded_documents is only supported when all is true.")
        }
        guard let documents = data["documents"] else { throw APIError.nonField("documents is required unless all is true.") }
        guard let items = documents.array else { throw APIError.field("documents", "documents must be a list") }
        guard items.allSatisfy({ $0.strictInt != nil }) else { throw APIError.field("documents", "documents must be a list of integers") }
        let ids = items.compactMap(\.strictInt)
        let count = try Document.filter(keys: ids).fetchCount(db)
        guard count == ids.count, Set(ids).count == ids.count else {
            throw APIError.field("documents", "Some documents in documents don't exist or were specified twice.")
        }
        return ids
    }
}
