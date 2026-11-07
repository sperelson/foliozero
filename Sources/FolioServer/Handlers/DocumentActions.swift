import Foundation
import FolioCore
import FolioParsing
import GRDB
import HTTPTypes
import Hummingbird

extension API {
    // MARK: - post_document

    /// `POST /api/documents/post_document/`: streams the multipart upload to the scratch
    /// folder, validates the fields and queues consumption. Returns the task id as a JSON string.
    func postDocument(_ request: APIRequest) async throws -> Response {
        let access = request.access
        guard access.has(.add, Document.objectType) else { throw APIError.forbiddenText("Insufficient permissions") }
        let upload = try await receiveUpload(request)
        do {
            guard let file = upload.file else { throw APIError.field("document", "No file was submitted.") }
            guard file.size > 0 else { throw APIError.field("document", "The submitted file is empty.") }
            let mimeType = (try? FileTypeDetector.mimeType(of: file.url)) ?? "application/octet-stream"
            if app.parsers.parser(for: mimeType, fileName: file.filename) == nil {
                throw APIError.field("document", "File type \(mimeType) not supported")
            }
            let data = upload.data
            let overrides = try await read { db in try self.uploadOverrides(data, access: access, in: db) }
            var consumeRequest = ConsumeRequest(file: file.url, originalFilename: file.filename,
                                                source: try data.optionalBool("from_webui") == true ? .webUI : .apiUpload,
                                                overrides: overrides, deleteSource: true)
            consumeRequest.taskId = UUID().uuidString.lowercased()
            let taskId = try await queue.enqueueConsume(consumeRequest, consumer: app.consumer(), ownerId: access.user.id)
            return .json(.string(taskId))
        } catch {
            upload.cleanup()
            throw error
        }
    }

    /// Metadata form fields of an upload, validated like Paperless-ngx `PostDocumentSerializer`.
    func uploadOverrides(_ data: RequestData, access: AccessContext, in db: Database) throws -> DocumentOverrides {
        var overrides = DocumentOverrides()
        var errors = JSONObject()
        func capture(_ block: () throws -> Void) throws {
            do { try block() } catch let error as APIError where error.status == .badRequest {
                if case .json(.object(let object)) = error.body { for (key, value) in object { errors[key] = value } }
            }
        }
        try capture {
            if let title = data["title"]?.string, !title.isEmpty { overrides.title = title }
        }
        try capture {
            if let raw = data["created"]?.string, !raw.isEmpty {
                guard let date = self.parseCreated(raw) else {
                    throw APIError.field("created", "Datetime has wrong format. Use one of these formats instead: YYYY-MM-DDThh:mm[:ss[.uuuuuu]][+HH:MM|-HH:MM|Z].")
                }
                overrides.created = date
            }
        }
        try capture { overrides.correspondentId = try data.foreignKey("correspondent", table: "correspondents", in: db) ?? nil }
        try capture { overrides.documentTypeId = try data.foreignKey("document_type", table: "document_types", in: db) ?? nil }
        try capture { overrides.storagePathId = try data.foreignKey("storage_path", table: "storage_paths", in: db) ?? nil }
        try capture {
            if let tags = try data.idList("tags") {
                for tag in tags where try Tag.fetchOne(db, key: tag) == nil {
                    throw APIError.field("tags", APIError.invalidPK(String(tag)))
                }
                overrides.tagIds = Array(Set(tags)).sorted()
            }
        }
        try capture {
            if let asn = try data.optionalInt("archive_serial_number") {
                guard asn >= 0 else { throw APIError.field("archive_serial_number", "Ensure this value is greater than or equal to 0.") }
                guard asn <= 4_294_967_295 else { throw APIError.field("archive_serial_number", "Ensure this value is less than or equal to 4294967295.") }
                overrides.archiveSerialNumber = asn
            }
        }
        try capture {
            guard let value = data["custom_fields"], !value.isNull else { return }
            let parsed: JSON
            if data.isForm {
                // Form fields carry JSON text; the last value wins, as in DRF's JSONField.
                guard let text = data.list("custom_fields")?.last?.string, !text.isEmpty else { return }
                guard let decoded = try? JSON.parse(text) else { throw APIError.field("custom_fields", "Value must be valid JSON.") }
                parsed = decoded
            } else {
                parsed = value
            }
            switch parsed {
            case .int(let id):
                guard try CustomField.fetchOne(db, key: id) != nil else {
                    throw APIError.field("custom_fields", "Some custom fields don't exist or were specified twice.")
                }
                overrides.customFields = [id: JSONValue?.none]
            case .array(let items):
                let ids = items.compactMap(\.int)
                guard ids.count == items.count else {
                    throw APIError.field("custom_fields", "Custom fields must be a list of integers or an object mapping ids to values.")
                }
                guard try CustomField.filter(keys: ids).fetchCount(db) == Set(ids).count else {
                    throw APIError.field("custom_fields", "Some custom fields don't exist or were specified twice.")
                }
                overrides.customFields = Dictionary(ids.map { ($0, JSONValue?.none) }, uniquingKeysWith: { a, _ in a })
            case .object(let object):
                var values: [Int: JSONValue?] = [:]
                for (key, value) in object {
                    guard let id = Int(key) else { throw APIError.field("custom_fields", "Custom field id must be an integer: \(key)") }
                    guard let field = try CustomField.fetchOne(db, key: id) else {
                        throw APIError.field("custom_fields", "Custom field with id \(id) does not exist")
                    }
                    if !value.isNull {
                        var scratch = CustomFieldInstance(documentId: 0, fieldId: id)
                        do { try CustomFieldValues.assign(value.jsonValue, field: field, to: &scratch) } catch let error as CustomFieldValueError {
                            throw APIError.field("custom_fields", error.description)
                        }
                    }
                    values[id] = .some(value.jsonValue)
                }
                overrides.customFields = values
            default:
                throw APIError.field("custom_fields", "Custom fields must be a list of integers or an object mapping ids to values.")
            }
        }
        if !errors.isEmpty { throw APIError.validation(.object(errors)) }
        overrides.ownerId = access.user.id
        return overrides
    }

    // MARK: - Bulk edit

    static let bulkMethods: Set<String> = [
        "set_correspondent", "set_document_type", "set_storage_path", "add_tag", "remove_tag", "modify_tags",
        "modify_custom_fields", "delete", "reprocess", "redo_ocr", "set_permissions",
    ]
    static let pdfBulkMethods: Set<String> = ["rotate", "merge", "split", "delete_pages", "edit_pdf", "remove_password"]

    func bulkEdit(_ request: APIRequest) async throws -> Response {
        let data = try request.data()
        guard let method = data["method"]?.string else { throw APIError.field("method", APIError.requiredField) }
        guard Self.bulkMethods.contains(method) || Self.pdfBulkMethods.contains(method) else {
            throw APIError.field("method", "\"\(method)\" is not a valid choice.")
        }
        if let parameters = data["parameters"], parameters.object == nil {
            throw APIError.field("parameters", "Expected a dictionary of items but got type \"\(parameters.typeName)\".")
        }
        if Self.pdfBulkMethods.contains(method) {
            logger.warning("Deprecated bulk_edit method '\(method)' requested; use the /api/documents/\(method)/ endpoint instead")
            return try await legacyPDFOperation(request, data: data, method: method, parameters: data["parameters"]?.object ?? JSONObject())
        }
        return try await performBulkEdit(request, data: data, method: method == "redo_ocr" ? "reprocess" : method,
                                         parameters: data["parameters"]?.object ?? JSONObject())
    }

    /// `/api/documents/delete/` and `/api/documents/reprocess/` (API v10 document operations).
    func documentOperation(_ request: APIRequest, method: String) async throws -> Response {
        let data = try request.data()
        var parameters = JSONObject()
        // `ReprocessDocumentsSerializer.remote_ocr`, a BooleanField defaulting to false.
        if method == "reprocess" { parameters["remote_ocr"] = .bool(try data.optionalBool("remote_ocr") ?? false) }
        return try await performBulkEdit(request, data: data, method: method, parameters: parameters)
    }

    func unsupportedOperation(_ request: APIRequest, _ name: String) async throws -> Response {
        throw APIError.detail(.badRequest, "The document operation \"\(name)\" is not supported yet.")
    }

    private struct BulkOutcome: Sendable {
        var rename: [Int] = []
        var reprocess: [Int] = []
        var remoteOCR = false
        var deleted: [Int] = []
    }

    private func performBulkEdit(_ request: APIRequest, data: RequestData, method: String, parameters: JSONObject) async throws -> Response {
        let access = request.access
        let auditEnabled = settings.auditLogEnabled
        let outcome = try await write { db -> BulkOutcome in
            let ids = try self.resolveSelection(data, access: access, in: db)
            let params = try self.validateBulkParameters(method: method, parameters: parameters, in: db)
            try self.checkBulkPermissions(method: method, ids: ids, access: access, in: db)
            var outcome = BulkOutcome()
            let actor = access.user.id
            func snapshotTags() throws -> [Int: [Int]] {
                Dictionary(uniqueKeysWithValues: try ids.map { ($0, try DocumentStore.tagIds(of: $0, in: db)) })
            }
            switch method {
            case "set_correspondent", "set_document_type", "set_storage_path":
                let value = params.int
                for id in ids {
                    var document = try DocumentStore.document(id, in: db)
                    switch method {
                    case "set_correspondent": document.correspondentId = value
                    case "set_document_type": document.documentTypeId = value
                    default: document.storagePathId = value
                    }
                    try DocumentStore.update(document, actorId: actor, auditEnabled: auditEnabled, in: db)
                }
                outcome.rename = ids
            case "add_tag", "remove_tag", "modify_tags":
                let before = try snapshotTags()
                let add = method == "add_tag" ? [params.int!] : method == "modify_tags" ? params.add : []
                let remove = method == "remove_tag" ? [params.int!] : method == "modify_tags" ? params.remove : []
                for id in ids {
                    if !remove.isEmpty { try DocumentStore.removeTags(documentId: id, tagIds: remove, in: db) }
                    if !add.isEmpty { try DocumentStore.addTags(documentId: id, tagIds: add, in: db) }
                    try SearchIndex.update(documentId: id, in: db)
                    let after = try DocumentStore.tagIds(of: id, in: db)
                    if auditEnabled, after != before[id] {
                        try AuditLog.record(.update, objectType: Document.objectType, objectId: id, repr: "",
                                            changes: ["tags": [(before[id] ?? []).map(String.init).joined(separator: ","), after.map(String.init).joined(separator: ",")]],
                                            actorId: actor, in: db)
                    }
                }
                outcome.rename = ids
            case "modify_custom_fields":
                for id in ids {
                    for fieldId in params.remove { try CustomFieldValues.remove(fieldId: fieldId, documentId: id, in: db) }
                    for (fieldId, value) in params.fields {
                        if let value {
                            try CustomFieldValues.set(fieldId: fieldId, value: value.jsonValue, documentId: id, in: db)
                        } else {
                            try CustomFieldValues.set(fieldId: fieldId, value: nil, documentId: id, in: db)
                        }
                    }
                    try SearchIndex.update(documentId: id, in: db)
                }
                outcome.rename = ids
            case "delete":
                for id in ids { try DocumentStore.moveToTrash(id, actorId: actor, in: db) }
                outcome.deleted = ids
            case "reprocess":
                outcome.reprocess = ids
                outcome.remoteOCR = params.remoteOCR
            case "set_permissions":
                if case .some(let owner) = params.owner {
                    for id in ids {
                        var document = try DocumentStore.document(id, in: db)
                        if params.merge && owner == nil { continue }
                        if params.merge && document.ownerId != nil { continue }
                        document.ownerId = owner
                        try DocumentStore.update(document, actorId: actor, auditEnabled: auditEnabled, in: db)
                    }
                }
                try params.permissions?.apply(objectType: Document.objectType, objectIds: ids, merge: params.merge, in: db)
                outcome.rename = ids
            default:
                break
            }
            return outcome
        }
        if !outcome.rename.isEmpty { await enqueueRename(outcome.rename) }
        for id in outcome.reprocess { await enqueueReprocess(id, ownerId: access.user.id, remoteOCR: outcome.remoteOCR) }
        await publishDocumentsDeleted(outcome.deleted)
        return .json(["result": "OK"])
    }

    private struct BulkParameters: Sendable {
        var int: Int?
        var add: [Int] = []
        var remove: [Int] = []
        var fields: [(Int, JSON?)] = []
        var owner: Int??
        var permissions: PermissionSpec?
        var merge = false
        var remoteOCR = false
    }

    private func validateBulkParameters(method: String, parameters: JSONObject, in db: Database) throws -> BulkParameters {
        var result = BulkParameters()
        func exists(_ table: String, _ id: Int) throws -> Bool {
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE id = ?", arguments: [id]) ?? 0 > 0
        }
        func idList(_ key: String, table: String, label: String) throws -> [Int] {
            guard let value = parameters[key] else { throw APIError.nonField("\(key) not specified") }
            guard let items = value.array else { throw APIError.nonField("\(key) must be a list") }
            guard items.allSatisfy({ $0.strictInt != nil }) else { throw APIError.nonField("\(key) must be a list of integers") }
            let ids = items.compactMap(\.strictInt)
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE id IN (\(ids.map(String.init).joined(separator: ",").ifEmpty("NULL")))") ?? 0
            guard count == ids.count, Set(ids).count == ids.count else {
                throw APIError.nonField("Some \(label) in \(key) don't exist or were specified twice.")
            }
            return ids
        }
        switch method {
        case "set_correspondent", "set_document_type", "set_storage_path":
            let (key, table, label) = method == "set_correspondent" ? ("correspondent", "correspondents", "Correspondent")
                : method == "set_document_type" ? ("document_type", "document_types", "Document type") : ("storage_path", "storage_paths", "Storage path")
            guard let value = parameters[key] else {
                throw APIError.nonField(method == "set_storage_path" ? "storage path not specified" : "\(key) not specified")
            }
            if !value.isNull {
                guard let id = value.int, try exists(table, id) else { throw APIError.nonField("\(label) does not exist") }
                result.int = id
            }
        case "add_tag", "remove_tag":
            guard let value = parameters["tag"] else { throw APIError.nonField("tag not specified") }
            guard let id = value.int, try exists("tags", id) else { throw APIError.nonField("Tag does not exist") }
            result.int = id
        case "modify_tags":
            result.add = try idList("add_tags", table: "tags", label: "tags")
            result.remove = try idList("remove_tags", table: "tags", label: "tags")
        case "modify_custom_fields":
            guard let add = parameters["add_custom_fields"] else { throw APIError.nonField("add_custom_fields not specified") }
            if let object = add.object {
                for (key, value) in object {
                    guard let id = Int(key), let field = try CustomField.fetchOne(db, key: id) else {
                        throw APIError.nonField("Some custom fields in add_custom_fields don't exist or were specified twice.")
                    }
                    if !value.isNull {
                        var scratch = CustomFieldInstance(documentId: 0, fieldId: id)
                        do { try CustomFieldValues.assign(value.jsonValue, field: field, to: &scratch) } catch let error as CustomFieldValueError {
                            throw APIError.validation(["add_custom_fields": .object(JSONObject([(key, ["value": [.string(error.description)]] as JSON)]))])
                        }
                    }
                    result.fields.append((id, value))
                }
            } else {
                result.fields = try idList("add_custom_fields", table: "custom_fields", label: "custom fields").map { ($0, nil) }
            }
            if let remove = parameters["remove_custom_fields"], let object = remove.object {
                result.remove = object.keys.compactMap { Int($0) }
            } else {
                result.remove = try idList("remove_custom_fields", table: "custom_fields", label: "custom fields")
            }
        case "set_permissions":
            guard parameters.contains("set_permissions") else { throw APIError.nonField("set_permissions not specified") }
            result.permissions = try PermissionSpec.parse(parameters["set_permissions"], in: db)
            if let owner = parameters["owner"] {
                if owner.isNull {
                    result.owner = .some(nil)
                } else {
                    guard let id = owner.int, try exists("users", id) else { throw APIError.nonField("Specified owner cannot be found") }
                    result.owner = .some(id)
                }
            }
            result.merge = parameters["merge"]?.bool ?? false
        case "reprocess":
            // Paperless-ngx `_validate_parameters_reprocess`: a JSON boolean, default false.
            if let value = parameters["remote_ocr"] {
                guard case .bool(let flag) = value else { throw APIError.nonField("remote_ocr must be a boolean") }
                result.remoteOCR = flag
            }
        default:
            break
        }
        return result
    }

    /// Paperless-ngx `_has_document_permissions`.
    private func checkBulkPermissions(method: String, ids: [Int], access: AccessContext, in db: Database) throws {
        if access.isSuperuser { return }
        guard access.has(.change, Document.objectType) else { throw APIError.forbiddenText() }
        let documents = try fetchDocuments(ids, in: db)
        var ownsAll = true
        for document in documents {
            let root = try document.rootDocumentId.flatMap { try Document.fetchOne(db, key: $0) } ?? document
            guard try access.can(.change, objectType: Document.objectType, objectId: document.id ?? 0, ownerId: document.ownerId, in: db) else {
                throw APIError.forbiddenText()
            }
            if !access.isOwner(ownerId: root.ownerId) { ownsAll = false }
        }
        if ["set_permissions", "delete"].contains(method) && !ownsAll { throw APIError.forbiddenText() }
        if method == "delete" && !access.has(.delete, Document.objectType) { throw APIError.forbiddenText() }
    }

    // MARK: - Reprocess

    func enqueueReprocess(_ documentId: Int, ownerId: Int?, remoteOCR: Bool = false) async {
        let app = self.app
        _ = try? await queue.enqueue(type: .reprocessDocument, source: .manual, input: ["document_id": String(documentId)], ownerId: ownerId) { _ in
            try await DocumentMaintenance.reprocess(app: app, documentId: documentId, remoteOCR: remoteOCR)
            return TaskOutcome(message: "Reprocessed document \(documentId)", documentId: documentId)
        }
    }

    // MARK: - Trash

    func trashPredicate(_ access: AccessContext) -> SQL {
        let owned: SQL = access.isSuperuser ? "1" : "(COALESCE(r.owner_id, d.owner_id) IS NULL OR COALESCE(r.owner_id, d.owner_id) = \(access.userId))"
        return """
            d.deleted_at IS NOT NULL
            AND NOT (d.root_document_id IS NOT NULL AND EXISTS (SELECT 1 FROM documents p WHERE p.id = d.root_document_id AND p.deleted_at IS NOT NULL))
            AND \(owned)
            """
    }

    func listTrash(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, Document.objectType)
        let query = request.query
        let context = SerializeContext(request)
        let options = DocumentSerializeOptions(request)
        let body = try await read { db -> JSONObject in
            let predicate = self.trashPredicate(access)
            let from: SQL = "documents d LEFT JOIN documents r ON r.id = d.root_document_id"
            let count = try Int.fetchOne(db, SQLRequest<Int>(literal: "SELECT COUNT(*) FROM \(from) WHERE \(predicate)")) ?? 0
            let page = try PageRequest.resolve(query, count: count)
            let documents = try Document.fetchAll(db, SQLRequest<Document>(literal: """
                SELECT d.* FROM \(from) WHERE \(predicate) ORDER BY d.created DESC, d.id DESC LIMIT \(page.size) OFFSET \(page.offset)
                """))
            let all = request.version < 10 ? try Int.fetchAll(db, SQLRequest<Int>(literal: "SELECT d.id FROM \(from) WHERE \(predicate) ORDER BY d.created DESC, d.id DESC")) : nil
            return self.paginated(request, page: page, count: count,
                                  results: try self.documentsJSON(documents, context: context, options: options, in: db), allIds: all)
        }
        return .json(.object(body))
    }

    func trashAction(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.delete, Document.objectType)
        let data = try request.data()
        guard let action = data["action"]?.string else { throw APIError.field("action", APIError.requiredField) }
        guard action == "restore" || action == "empty" else { throw APIError.field("action", "\"\(action)\" is not a valid choice.") }
        let requested = try data.idList("documents")
        let ids = try await write { db -> [Int] in
            let ids: [Int]
            if let requested {
                let deleted = try Int.fetchOne(db, SQLRequest<Int>(literal: "SELECT COUNT(*) FROM documents WHERE id IN \(requested) AND deleted_at IS NOT NULL")) ?? 0
                guard deleted == Set(requested).count else {
                    throw APIError.field("documents", "Some documents in the list have not yet been deleted.")
                }
                ids = requested
            } else {
                ids = try Int.fetchAll(db, SQLRequest<Int>(literal: """
                    SELECT d.id FROM documents d LEFT JOIN documents r ON r.id = d.root_document_id WHERE \(self.trashPredicate(access))
                    """))
            }
            for document in try self.fetchDocuments(ids, in: db) {
                let root = try document.rootDocumentId.flatMap { try Document.fetchOne(db, key: $0) } ?? document
                guard access.isOwner(ownerId: root.ownerId) else { throw APIError.forbiddenText() }
            }
            if action == "restore" {
                for document in try self.fetchDocuments(ids, in: db) {
                    if let root = document.rootDocumentId, try Document.fetchOne(db, key: root)?.deletedAt != nil {
                        throw APIError.field("documents", "Restore the root document instead of one of its versions.")
                    }
                    try DocumentStore.restoreFromTrash(document.id ?? 0, in: db)
                }
            }
            return ids
        }
        if action == "empty", !ids.isEmpty {
            try await Maintenance.emptyTrash(app: app, ids: ids)
        }
        return .json(["result": "OK", "doc_ids": requested.map { JSON($0) } ?? JSON(ids)])
    }

    // MARK: - Share links

    func shareLinksPredicate(_ access: AccessContext) -> SQL {
        "o.deleted_at IS NULL AND \(access.visibilityPredicate(objectType: ShareLink.objectType, alias: "o"))"
    }

    func listShareLinks(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, ShareLink.objectType)
        let query = request.query
        let timeZone = settings.timeZone
        let body = try await read { db -> JSONObject in
            var conditions = [self.shareLinksPredicate(access)]
            for (name, value) in query.items where !value.isEmpty {
                for field in ["created", "expiration"] where name.hasPrefix(field + "__") {
                    let lookup = String(name.dropFirst(field.count + 2))
                    guard let date = QueryFilters.parseDateTime(value, timeZone: timeZone) else {
                        throw APIError.field(name, "Enter a valid date/time.")
                    }
                    let op = ["gt": ">", "gte": ">=", "lt": "<", "lte": "<=", "date__gt": ">=", "date__gte": ">=", "date__lt": "<", "date__lte": "<"][lookup]
                    guard let op else { continue }
                    var bound = date
                    if lookup == "date__gt" || lookup == "date__lte" { bound = CalendarDate(date, in: timeZone).adding(days: 1).startDate(in: timeZone) }
                    conditions.append("o.\(sql: field) \(sql: op) \(QueryFilters.timestamp(bound))")
                }
            }
            let predicate = QueryFilters.and(conditions)
            let from: SQL = "share_links o JOIN documents d ON d.id = o.document_id"
            let count = try Int.fetchOne(db, SQLRequest<Int>(literal: "SELECT COUNT(*) FROM \(from) WHERE \(predicate)")) ?? 0
            let page = try PageRequest.resolve(query, count: count)
            let order = QueryFilters.ordering(query["ordering"], allowed: [
                "created": "o.created", "expiration": "o.expiration", "document__title": "d.title COLLATE NOCASE",
            ])?.joined(separator: ", ") ?? "o.id"
            let rows = try Row.fetchAll(db, SQLRequest<Row>(literal: """
                SELECT o.*, d.title AS document_title FROM \(from) WHERE \(predicate) ORDER BY \(sql: order), o.id
                LIMIT \(page.size) OFFSET \(page.offset)
                """))
            let results = try rows.map { self.shareLinkJSON(try ShareLink(row: $0), documentTitle: $0["document_title"]) }
            let all = request.version < 10 ? try Int.fetchAll(db, SQLRequest<Int>(literal: "SELECT o.id FROM \(from) WHERE \(predicate) ORDER BY o.id")) : nil
            return self.paginated(request, page: page, count: count, results: results, allIds: all)
        }
        return .json(.object(body))
    }

    private func loadShareLink(_ id: Int, access: AccessContext, in db: Database) throws -> (ShareLink, String) {
        guard let link = try ShareLink.fetchOne(db, key: id), link.deletedAt == nil,
              try access.can(.view, objectType: ShareLink.objectType, objectId: id, ownerId: link.ownerId, in: db) else {
            throw APIError.notFound("ShareLink")
        }
        let title = try Document.fetchOne(db, key: link.documentId)?.title ?? ""
        return (link, title)
    }

    func getShareLink(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, ShareLink.objectType)
        let id = try request.intParam("id")
        let (link, title) = try await read { db in try self.loadShareLink(id, access: access, in: db) }
        return .json(shareLinkJSON(link, documentTitle: title))
    }

    func createShareLink(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.add, ShareLink.objectType)
        let data = try request.data()
        guard let documentValue = data["document"], !documentValue.isNull else { throw APIError.field("document", APIError.requiredField) }
        guard let documentId = documentValue.int else {
            throw APIError.field("document", "Incorrect type. Expected pk value, received \(documentValue.typeName).")
        }
        var parsedExpiration: Date?
        if let raw = data["expiration"], !raw.isNull, let text = raw.string, !text.isEmpty {
            guard let date = QueryFilters.parseDateTime(text, timeZone: settings.timeZone) else {
                throw APIError.field("expiration", "Datetime has wrong format. Use one of these formats instead: YYYY-MM-DDThh:mm[:ss[.uuuuuu]][+HH:MM|-HH:MM|Z].")
            }
            parsedExpiration = date
        }
        var parsedVersion = ShareLink.FileVersion.archive
        if let raw = data["file_version"]?.string {
            guard let parsed = ShareLink.FileVersion(rawValue: raw) else { throw APIError.field("file_version", "\"\(raw)\" is not a valid choice.") }
            parsedVersion = parsed
        }
        let expiration = parsedExpiration, version = parsedVersion
        let (link, title) = try await write { db -> (ShareLink, String) in
            guard let document = try Document.fetchOne(db, key: documentId), document.deletedAt == nil else {
                throw APIError.field("document", APIError.invalidPK(String(documentId)))
            }
            guard access.has(.view, Document.objectType), try self.canAccess(document, .view, access: access, in: db) else {
                throw APIError.insufficientPermissions
            }
            var link = ShareLink(slug: PasswordHasher.randomString(length: 50), documentId: documentId, expiration: expiration,
                                 fileVersion: version, ownerId: access.user.id)
            try link.insert(db)
            return (link, document.title)
        }
        return .json(shareLinkJSON(link, documentTitle: title), status: .created)
    }

    func deleteShareLink(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.delete, ShareLink.objectType)
        let id = try request.intParam("id")
        try await write { db in
            let (link, _) = try self.loadShareLink(id, access: access, in: db)
            guard access.isOwner(ownerId: link.ownerId) else { throw APIError.permissionDenied }
            _ = try ShareLink.deleteOne(db, key: id)
        }
        return .noContent()
    }

    /// Public `GET /share/<slug>`: the shared file, or a redirect to the login page.
    func serveShareLink(_ request: APIRequest) async throws -> Response {
        let slug = request.params["slug"] ?? ""
        guard !slug.isEmpty, slug.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            return .redirect("/accounts/login/?sharelink_notfound=1")
        }
        let found = try await read { db -> (ShareLink, Document, String?)? in
            guard let link = try ShareLink.filter(Column("slug") == slug).fetchOne(db), link.deletedAt == nil,
                  let document = try Document.fetchOne(db, key: link.documentId), document.deletedAt == nil else { return nil }
            let correspondent = try document.correspondentId.flatMap { try Correspondent.fetchOne(db, key: $0)?.name }
            return (link, document, correspondent)
        }
        guard let (link, document, correspondent) = found else { return try await serveShareLinkBundle(slug: slug, context: request.context) }
        if let expiration = link.expiration, expiration < Date() { return .redirect("/accounts/login/?sharelink_expired=1") }
        do {
            return try await serveDocumentFile(document, correspondent: correspondent,
                                               useArchive: link.fileVersion == .archive && document.hasArchiveVersion,
                                               disposition: "inline", followFormatting: false, context: request.context)
        } catch let error as APIError where error.status == .notFound {
            return .redirect("/accounts/login/?sharelink_notfound=1")
        }
    }

    // MARK: - Bulk edit objects

    func bulkEditObjects(_ request: APIRequest) async throws -> Response {
        let access = request.access
        let data = try request.data()
        guard let objectType = data["object_type"]?.string else { throw APIError.field("object_type", APIError.requiredField) }
        let tables = ["tags": ("tags", Tag.objectType), "correspondents": ("correspondents", Correspondent.objectType),
                      "document_types": ("document_types", DocumentType.objectType), "storage_paths": ("storage_paths", StoragePath.objectType)]
        guard let (table, model) = tables[objectType] else { throw APIError.field("object_type", "\"\(objectType)\" is not a valid choice.") }
        guard let operation = data["operation"]?.string else { throw APIError.field("operation", APIError.requiredField) }
        guard operation == "set_permissions" || operation == "delete" else { throw APIError.field("operation", "\"\(operation)\" is not a valid choice.") }
        let applyToAll = try data.optionalBool("all") ?? false
        let merge = try data.optionalBool("merge") ?? false
        let action: Permission.Action = operation == "set_permissions" ? .change : .delete
        let renamed = try await write { db -> [Int] in
            var ids: [Int]
            if applyToAll {
                let filters = data["filters"]?.object ?? JSONObject()
                let query = QueryItems(items: filters.compactMap { key, value in value.string.map { (key, $0) } })
                var conditions: [SQL] = [access.visibilityPredicate(objectType: model, alias: "o")]
                conditions += try Self.strictIdFilters(query, column: "o.id")
                for (name, value) in query.items where name.hasPrefix("name__") && !value.isEmpty {
                    if let condition = QueryFilters.charLookup("o.name", lookup: String(name.dropFirst(6)), value: value) { conditions.append(condition) }
                }
                ids = try Int.fetchAll(db, SQLRequest<Int>(literal: "SELECT o.id FROM \(sql: table) o WHERE \(QueryFilters.and(conditions))"))
            } else {
                guard let objects = data["objects"] else { throw APIError.nonField("objects is required unless all is true.") }
                guard let items = objects.array else { throw APIError.field("objects", "Expected a list of items but got type \"\(objects.typeName)\".") }
                guard !items.isEmpty else { throw APIError.nonField("objects must not be empty") }
                guard items.allSatisfy({ $0.strictInt != nil }) else { throw APIError.field("objects", "A valid integer is required.") }
                ids = items.compactMap(\.strictInt)
                let count = try Int.fetchOne(db, SQLRequest<Int>(literal: "SELECT COUNT(*) FROM \(sql: table) WHERE id IN \(ids)")) ?? 0
                guard count == ids.count, Set(ids).count == ids.count else {
                    throw APIError.nonField("Some ids in objects don't exist or were specified twice.")
                }
            }
            if objectType == "tags" {
                var all = Set(ids)
                for id in ids { all.formUnion(try DocumentStore.descendants(of: id, in: db)) }
                ids = all.sorted()
            }
            if !access.isSuperuser {
                let owners = try Row.fetchAll(db, SQLRequest<Row>(literal: "SELECT owner_id FROM \(sql: table) WHERE id IN \(ids)")).map { $0["owner_id"] as Int? }
                guard access.has(action, model), owners.allSatisfy({ access.isOwner(ownerId: $0) }) else { throw APIError.forbiddenText() }
            }
            var affected = Set<Int>()
            if operation == "set_permissions" {
                let spec = try PermissionSpec.parse(data["permissions"], field: "permissions", in: db)
                if data.has("owner") {
                    let owner = try data.foreignKey("owner", table: "users", in: db) ?? nil
                    if !merge || owner != nil {
                        let target: SQL = merge ? "AND owner_id IS NULL" : ""
                        try db.execute(literal: "UPDATE \(sql: table) SET owner_id = \(owner) WHERE id IN \(ids) \(target)")
                    }
                }
                try spec?.apply(objectType: model, objectIds: ids, merge: merge, in: db)
            } else {
                let column = objectType == "tags" ? nil : ["correspondents": "correspondent_id", "document_types": "document_type_id", "storage_paths": "storage_path_id"][objectType]
                for id in ids {
                    if let column {
                        affected.formUnion(try Int.fetchAll(db, sql: "SELECT id FROM documents WHERE \(column) = ?", arguments: [id]))
                    } else {
                        affected.formUnion(try Int.fetchAll(db, sql: "SELECT document_id FROM document_tags WHERE tag_id = ?", arguments: [id]))
                    }
                }
                try db.execute(literal: "DELETE FROM \(sql: table) WHERE id IN \(ids)")
                for id in ids { try PermissionSet.removeAll(objectType: model, objectId: id, in: db) }
                for documentId in affected { try SearchIndex.update(documentId: documentId, in: db) }
            }
            return objectType == "storage_paths" ? Array(affected) : []
        }
        if !renamed.isEmpty { await enqueueRename(renamed) }
        return .json(["result": "OK"])
    }
}
