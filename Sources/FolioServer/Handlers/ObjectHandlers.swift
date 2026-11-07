import Foundation
import FolioCore
import GRDB
import Hummingbird

/// Tags, correspondents, document types and storage paths as API objects.
protocol APIMatchingObject: MatchingObject {
    /// URL segment, e.g. `tags`.
    static var endpoint: String { get }
    /// Model name in DRF 404 messages.
    static var displayName: String { get }
    /// Column of `documents` that references this object; nil for tags (many-to-many).
    static var documentColumn: String? { get }
}

extension Tag: APIMatchingObject {
    static var endpoint: String { "tags" }
    static var displayName: String { "Tag" }
    static var documentColumn: String? { nil }
}

extension Correspondent: APIMatchingObject {
    static var endpoint: String { "correspondents" }
    static var displayName: String { "Correspondent" }
    static var documentColumn: String? { "correspondent_id" }
}

extension DocumentType: APIMatchingObject {
    static var endpoint: String { "document_types" }
    static var displayName: String { "DocumentType" }
    static var documentColumn: String? { "document_type_id" }
}

extension StoragePath: APIMatchingObject {
    static var endpoint: String { "storage_paths" }
    static var displayName: String { "StoragePath" }
    static var documentColumn: String? { "storage_path_id" }
}

/// Django `slugify`.
func slugify(_ value: String) -> String {
    let ascii = value.decomposedStringWithCompatibilityMapping.unicodeScalars.filter(\.isASCII)
    var cleaned = ""
    for scalar in ascii {
        let c = Character(scalar)
        if c.isLetter || c.isNumber || c == "_" || c == "-" || c.isWhitespace { cleaned.append(c) }
    }
    cleaned = cleaned.lowercased()
    var result = ""
    var pendingDash = false
    for c in cleaned {
        if c == "-" || c.isWhitespace {
            pendingDash = true
        } else {
            if pendingDash, !result.isEmpty { result.append("-") }
            pendingDash = false
            result.append(c)
        }
    }
    if pendingDash, !result.isEmpty { result.append("-") }
    return result.trimmingCharacters(in: CharacterSet(charactersIn: "-_"))
}

extension API {
    /// Documents of `alias` that the caller may count: not trashed, not a version, visible.
    func countableDocuments(_ access: AccessContext, alias: String = "d") -> SQL {
        "\(sql: alias).deleted_at IS NULL AND \(sql: alias).root_document_id IS NULL AND \(access.visibilityPredicate(objectType: Document.objectType, alias: alias))"
    }

    func documentCountSQL<M: APIMatchingObject>(_ type: M.Type, access: AccessContext) -> SQL {
        if let column = M.documentColumn {
            return "(SELECT COUNT(*) FROM documents d WHERE d.\(sql: column) = o.id AND \(countableDocuments(access)))"
        }
        return "(SELECT COUNT(*) FROM document_tags dt JOIN documents d ON d.id = dt.document_id WHERE dt.tag_id = o.id AND \(countableDocuments(access)))"
    }

    // MARK: - Serialisation

    /// Paperless-ngx `text_color`: luminance with channels divided by 256.
    static func textColor(_ color: String) -> String {
        let hex = color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return "#000000" }
        let r = Double((value >> 16) & 0xFF) / 256, g = Double((value >> 8) & 0xFF) / 256, b = Double(value & 0xFF) / 256
        let luminance = (0.299 * r * r + 0.587 * g * g + 0.114 * b * b).squareRoot()
        return luminance < 0.53 ? "#ffffff" : "#000000"
    }

    struct TagTree {
        var children: [Int: [(Tag, Int)]] = [:]
    }

    func matchingJSON<M: APIMatchingObject>(
        _ object: M, documentCount: Int, lastCorrespondence: CalendarDate?? = nil,
        grants: GrantTable, context: SerializeContext, tree: TagTree? = nil, depth: Int = 0
    ) -> JSON {
        let id = object.id ?? 0
        var json = JSONObject()
        json["id"] = .int(id)
        json["slug"] = .string(slugify(object.name))
        json["name"] = .string(object.name)
        if let tag = object as? Tag {
            json["color"] = .string(tag.color)
            json["text_color"] = .string(Self.textColor(tag.color))
        }
        if let path = object as? StoragePath {
            json["path"] = .string(path.path)
        }
        json["match"] = .string(object.match)
        json["matching_algorithm"] = .int(object.matchingAlgorithm.rawValue)
        json["is_insensitive"] = .bool(object.isInsensitive)
        if let tag = object as? Tag {
            json["is_inbox_tag"] = .bool(tag.isInboxTag)
        }
        json["document_count"] = .int(documentCount)
        if let lastCorrespondence {
            json["last_correspondence"] = date(lastCorrespondence)
        }
        grants.addOwnedFields(to: &json, id: id, ownerId: object.ownerId, context: context)
        if let tag = object as? Tag {
            json["parent"] = JSON(tag.parentId)
            let children = (depth < Tag.maxNestingDepth ? tree?.children[id] : nil) ?? []
            json["children"] = .array(children.map { child, count in
                matchingJSON(child, documentCount: count, grants: grants, context: context, tree: tree, depth: depth + 1)
            })
        }
        return .object(json)
    }

    /// Every tag the caller may see, with document counts, grouped by parent.
    func visibleTagTree(_ access: AccessContext, orderBy: String, in db: Database) throws -> (TagTree, [Int]) {
        let rows = try Row.fetchAll(db, SQLRequest<Row>(literal: """
            SELECT o.*, \(documentCountSQL(Tag.self, access: access)) AS document_count FROM tags o
            WHERE \(access.visibilityPredicate(objectType: Tag.objectType, alias: "o")) ORDER BY \(sql: orderBy)
            """))
        var tree = TagTree()
        var ids: [Int] = []
        for row in rows {
            let tag = try Tag(row: row)
            ids.append(tag.id ?? 0)
            if let parent = tag.parentId { tree.children[parent, default: []].append((tag, row["document_count"])) }
        }
        return (tree, ids)
    }

    // MARK: - Filters

    func objectPredicate<M: APIMatchingObject>(_ type: M.Type, query: QueryItems, access: AccessContext) throws -> SQL {
        var conditions: [SQL] = [access.visibilityPredicate(objectType: M.objectType, alias: "o")]
        conditions += try Self.strictIdFilters(query, column: "o.id")
        for (name, value) in query.items where !value.isEmpty {
            let parts = name.components(separatedBy: "__")
            guard parts.count == 2, QueryFilters.charLookups.contains(parts[1]) else { continue }
            if parts[0] == "name" || (parts[0] == "path" && M.self == StoragePath.self) {
                conditions.append(QueryFilters.charLookup("o.\(parts[0])", lookup: parts[1], value: value)!)
            }
        }
        if M.self == Tag.self, let raw = query["is_root"], let flag = QueryFilters.bool(raw) {
            conditions.append(flag ? "o.parent_id IS NULL" : "o.parent_id IS NOT NULL")
        }
        return QueryFilters.and(conditions)
    }

    static func strictIdFilters(_ query: QueryItems, column: String) throws -> [SQL] {
        var conditions: [SQL] = []
        if let raw = query["id"], !raw.isEmpty {
            guard let id = Int(raw) else { throw APIError.field("id", "Enter a number.") }
            conditions.append("\(sql: column) = \(id)")
        }
        if let raw = query["id__in"], !raw.isEmpty {
            guard let ids = QueryFilters.intList(raw) else { throw APIError.field("id__in", "Enter a number.") }
            conditions.append("\(sql: column) IN \(ids)")
        }
        return conditions
    }

    func objectOrdering<M: APIMatchingObject>(_ type: M.Type, _ param: String?) -> String {
        var allowed = [
            "name": "o.name COLLATE NOCASE", "matching_algorithm": "o.matching_algorithm", "match": "o.match COLLATE NOCASE",
            "document_count": "document_count", "id": "o.id",
        ]
        if M.self == Tag.self { allowed["color"] = "o.color" }
        if M.self == StoragePath.self { allowed["path"] = "o.path COLLATE NOCASE" }
        if M.self == Correspondent.self { allowed["last_correspondence"] = "last_correspondence" }
        return QueryFilters.ordering(param, allowed: allowed)?.joined(separator: ", ") ?? "o.name COLLATE NOCASE"
    }

    // MARK: - Handlers

    func listObjects<M: APIMatchingObject>(_ type: M.Type, _ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, M.objectType)
        let query = request.query
        let context = SerializeContext(request)
        let withLast = M.self == Correspondent.self
            && ((query["last_correspondence"].map { !$0.isEmpty } ?? false) || query["ordering"]?.contains("last_correspondence") == true)
        let body = try await read { db -> JSONObject in
            let predicate = try self.objectPredicate(M.self, query: query, access: access)
            let count = try Int.fetchOne(db, SQLRequest<Int>(literal: "SELECT COUNT(*) FROM \(sql: M.databaseTableName) o WHERE \(predicate)")) ?? 0
            let page = try PageRequest.resolve(query, count: count)
            let order = self.objectOrdering(M.self, query["ordering"])
            let lastSQL: SQL = withLast && M.self == Correspondent.self
                ? ", (SELECT MAX(d.created) FROM documents d WHERE d.correspondent_id = o.id AND \(self.countableDocuments(access))) AS last_correspondence"
                : ""
            let rows = try Row.fetchAll(db, SQLRequest<Row>(literal: """
                SELECT o.*, \(self.documentCountSQL(M.self, access: access)) AS document_count \(lastSQL)
                FROM \(sql: M.databaseTableName) o WHERE \(predicate)
                ORDER BY \(sql: order), o.id LIMIT \(page.size) OFFSET \(page.offset)
                """))
            let objects = try rows.map { try M(row: $0) }
            let grants = try GrantTable.load(objectType: M.objectType, ids: objects.compactMap(\.id), in: db)
            var tree: TagTree?
            if M.self == Tag.self {
                tree = try self.visibleTagTree(access, orderBy: order, in: db).0
            }
            // Children may come from outside the page: load their grants too.
            var childGrants = grants
            if let tree {
                let childIds = tree.children.values.flatMap { $0.compactMap { $0.0.id } }
                let extra = try GrantTable.load(objectType: M.objectType, ids: childIds, in: db)
                childGrants.grants.merge(extra.grants) { a, _ in a }
            }
            let results = zip(objects, rows).map { object, row in
                self.matchingJSON(object, documentCount: row["document_count"],
                                  lastCorrespondence: withLast ? .some(row["last_correspondence"] as CalendarDate?) : nil,
                                  grants: childGrants, context: context, tree: tree)
            }
            var all: [Int]?
            if request.version < 10 {
                all = try Int.fetchAll(db, SQLRequest<Int>(literal: """
                    SELECT o.id FROM \(sql: M.databaseTableName) o WHERE \(predicate) ORDER BY \(sql: order.replacingOccurrences(of: "document_count", with: "o.id").replacingOccurrences(of: "last_correspondence", with: "o.id")), o.id
                    """))
                if M.self == Tag.self, let tree, !tree.children.isEmpty {
                    let descendants = Set(tree.children.values.flatMap { $0.compactMap { $0.0.id } })
                    all = (all ?? []) + descendants.subtracting(all ?? []).sorted()
                }
            }
            var envelope = self.paginated(request, page: page, count: count, results: results, allIds: all)
            if M.self == Tag.self {
                let filtered = try Int.fetchAll(db, SQLRequest<Int>(literal: "SELECT o.id FROM tags o WHERE \(predicate)"))
                var display = Set(filtered)
                var frontier = filtered
                while let next = frontier.popLast() {
                    for (child, _) in tree?.children[next] ?? [] where display.insert(child.id ?? 0).inserted { frontier.append(child.id ?? 0) }
                }
                envelope["display_count"] = .int(display.count)
            }
            return envelope
        }
        return .json(.object(body))
    }

    /// Loads a visible object or fails with 404.
    func loadObject<M: APIMatchingObject>(_ type: M.Type, id: Int, access: AccessContext, in db: Database) throws -> M {
        guard let object = try M.fetchOne(db, key: id),
              try access.can(.view, objectType: M.objectType, objectId: id, ownerId: object.ownerId, in: db) else {
            throw APIError.notFound(M.displayName)
        }
        return object
    }

    func objectResponse<M: APIMatchingObject>(_ type: M.Type, id: Int, context: SerializeContext, status: HTTPResponse.Status = .ok,
                                              in db: Database) throws -> JSON {
        let access = context.access
        let row = try Row.fetchOne(db, SQLRequest<Row>(literal: """
            SELECT o.*, \(documentCountSQL(M.self, access: access)) AS document_count,
                (SELECT MAX(d.created) FROM documents d WHERE \(sql: M.documentColumn == "correspondent_id" ? "d.correspondent_id = o.id" : "0") AND \(countableDocuments(access))) AS last_correspondence
            FROM \(sql: M.databaseTableName) o WHERE o.id = \(id)
            """))
        guard let row else { throw APIError.notFound(M.displayName) }
        let object = try M(row: row)
        var grants = try GrantTable.load(objectType: M.objectType, ids: [id], in: db)
        var tree: TagTree?
        if M.self == Tag.self {
            tree = try visibleTagTree(access, orderBy: "o.name COLLATE NOCASE", in: db).0
            let childIds = tree!.children.values.flatMap { $0.compactMap { $0.0.id } }
            grants.grants.merge(try GrantTable.load(objectType: M.objectType, ids: childIds, in: db).grants) { a, _ in a }
        }
        let last: CalendarDate?? = M.self == Correspondent.self ? .some(row["last_correspondence"] as CalendarDate?) : nil
        return matchingJSON(object, documentCount: row["document_count"], lastCorrespondence: last, grants: grants, context: context, tree: tree)
    }

    func getObject<M: APIMatchingObject>(_ type: M.Type, _ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, M.objectType)
        let id = try request.intParam("id")
        let context = SerializeContext(request)
        let json = try await read { db -> JSON in
            _ = try self.loadObject(M.self, id: id, access: access, in: db)
            return try self.objectResponse(M.self, id: id, context: context, in: db)
        }
        return .json(json)
    }

    /// Validates and applies the writable fields of a matching object.
    private func applyMatchingFields<M: APIMatchingObject>(_ object: inout M, data: RequestData, isCreate: Bool, in db: Database) throws {
        if isCreate || data.has("name") {
            object.name = try data.requiredString("name", maxLength: 128)
        }
        if let match = data["match"] {
            guard let text = match.isNull ? "" : match.string else { throw APIError.field("match", "Not a valid string.") }
            object.match = text
        }
        if let raw = data["matching_algorithm"] {
            guard let value = raw.int, let algorithm = MatchingAlgorithm(rawValue: value) else {
                throw APIError.field("matching_algorithm", "\"\(raw.string ?? raw.serialized())\" is not a valid choice.")
            }
            object.matchingAlgorithm = algorithm
        }
        if let insensitive = try data.optionalBool("is_insensitive") { object.isInsensitive = insensitive }
        if object.matchingAlgorithm == .regex, data.has("match") || data.has("matching_algorithm") {
            if (try? NSRegularExpression(pattern: object.match)) == nil {
                throw APIError.field("match", "Invalid regular expression, see log for details.")
            }
        }
        if var tag = object as? Tag {
            if let color = data["color"] {
                guard let text = color.string, text.range(of: "^#[0-9a-fA-F]{6}", options: .regularExpression) != nil else {
                    throw APIError.field("color", "Invalid color.")
                }
                tag.color = text
            }
            if let inbox = try data.optionalBool("is_inbox_tag") { tag.isInboxTag = inbox }
            object = tag as! M
        }
        if var storagePath = object as? StoragePath {
            if isCreate || data.has("path") {
                let path = try data.requiredString("path", allowBlank: false)
                storagePath.path = try validateStoragePathTemplate(path)
            }
            object = storagePath as! M
        }
    }

    /// Paperless-ngx accepts `{correspondent}` style and Jinja templates; both must render.
    func validateStoragePathTemplate(_ path: String) throws -> String {
        let converted = Self.convertLegacyFormat(path)
        let namer = FileNamer(format: nil, timeZone: settings.timeZone)
        let document = Document(id: 1, title: "Test", created: CalendarDate.today(in: settings.timeZone), mimeType: "application/pdf", checksum: "0")
        guard namer.render(converted, context: NamingContext(document: document)) != nil else {
            throw APIError.field("path", "Invalid variable detected.")
        }
        return converted
    }

    /// `{created_year}/{title}` to `{{ created_year }}/{{ title }}`.
    static func convertLegacyFormat(_ format: String) -> String {
        guard !format.contains("{{"), !format.contains("{%") else { return format }
        guard let regex = try? NSRegularExpression(pattern: "\\{([^{}]+)\\}") else { return format }
        let range = NSRange(format.startIndex..., in: format)
        return regex.stringByReplacingMatches(in: format, range: range, withTemplate: "{{ $1 }}")
    }

    private func checkUniqueName<M: APIMatchingObject>(_ object: M, in db: Database) throws {
        let ownerClause: SQL = object.ownerId.map { "owner_id = \($0)" } ?? "owner_id IS NULL"
        let exists = try Int.fetchOne(db, SQLRequest<Int>(literal: """
            SELECT COUNT(*) FROM \(sql: M.databaseTableName) WHERE name = \(object.name) AND \(ownerClause) AND id IS NOT \(object.id)
            """)) ?? 0
        if exists > 0 { throw APIError.field("error", "Object violates owner / name unique constraint") }
    }

    private func ownerValue(_ data: RequestData, in db: Database) throws -> Int?? {
        guard data.has("owner") else { return .none }
        return try data.foreignKey("owner", table: "users", in: db)
    }

    func createObject<M: APIMatchingObject>(_ type: M.Type, _ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.add, M.objectType)
        let data = try request.data()
        let context = SerializeContext(request)
        let json = try await write { db -> JSON in
            var object: M
            switch M.self {
            case is Tag.Type: object = Tag(name: "") as! M
            case is Correspondent.Type: object = Correspondent(name: "") as! M
            case is DocumentType.Type: object = DocumentType(name: "") as! M
            default: object = StoragePath(name: "", path: "") as! M
            }
            try self.applyMatchingFields(&object, data: data, isCreate: true, in: db)
            switch try self.ownerValue(data, in: db) {
            case .some(let owner): object.ownerId = owner
            case .none: object.ownerId = access.user.id
            }
            let spec = try PermissionSpec.parse(data["set_permissions"], in: db)
            try self.checkUniqueName(object, in: db)
            var parentId: Int?? = .none
            if M.self == Tag.self, data.has("parent") {
                parentId = try data.foreignKey("parent", table: "tags", in: db)
            }
            try object.insert(db)
            let id = object.id!
            if case .some(let parent) = parentId, parent != nil {
                do {
                    try DocumentStore.setParent(tagId: id, parentId: parent, in: db)
                } catch let error as DocumentStoreError {
                    throw APIError.field("parent", error.description)
                }
            }
            try spec?.apply(objectType: M.objectType, objectIds: [id], merge: false, in: db)
            return try self.objectResponse(M.self, id: id, context: context, in: db)
        }
        return .json(json, status: .created)
    }

    func updateObject<M: APIMatchingObject>(_ type: M.Type, _ request: APIRequest, partial: Bool) async throws -> Response {
        let access = request.access
        try access.require(.change, M.objectType)
        let id = try request.intParam("id")
        let data = try request.data()
        let context = SerializeContext(request)
        let (json, renameDocuments) = try await write { db -> (JSON, [Int]) in
            var object = try self.loadObject(M.self, id: id, access: access, in: db)
            guard try access.can(.change, objectType: M.objectType, objectId: id, ownerId: object.ownerId, in: db) else {
                throw APIError.permissionDenied
            }
            let before = object
            try self.applyMatchingFields(&object, data: data, isCreate: !partial, in: db)
            let newOwner = try self.ownerValue(data, in: db)
            let spec = try PermissionSpec.parse(data["set_permissions"], in: db)
            if (newOwner != nil && newOwner! != before.ownerId) || spec != nil {
                guard access.isOwner(ownerId: before.ownerId) else { throw APIError.insufficientPermissions }
            }
            if case .some(let owner) = newOwner { object.ownerId = owner }
            if data.has("name") || newOwner != nil { try self.checkUniqueName(object, in: db) }
            try object.update(db)
            if M.self == Tag.self, data.has("parent") {
                let parent = try data.foreignKey("parent", table: "tags", in: db) ?? nil
                do {
                    try DocumentStore.setParent(tagId: id, parentId: parent, in: db)
                } catch let error as DocumentStoreError {
                    throw APIError.field("parent", error.description)
                }
            }
            try spec?.apply(objectType: M.objectType, objectIds: [id], merge: false, in: db)
            // Names are part of the search index.
            let affected = try self.documentsReferencing(M.self, id: id, in: db)
            if before.name != object.name {
                for documentId in affected { try SearchIndex.update(documentId: documentId, in: db) }
            }
            var rename: [Int] = []
            if let path = object as? StoragePath, let old = before as? StoragePath, path.path != old.path { rename = affected }
            return (try self.objectResponse(M.self, id: id, context: context, in: db), rename)
        }
        if !renameDocuments.isEmpty { await enqueueRename(renameDocuments) }
        return .json(json)
    }

    func documentsReferencing<M: APIMatchingObject>(_ type: M.Type, id: Int, in db: Database) throws -> [Int] {
        if let column = M.documentColumn {
            return try Int.fetchAll(db, sql: "SELECT id FROM documents WHERE \(column) = ?", arguments: [id])
        }
        return try Int.fetchAll(db, sql: "SELECT document_id FROM document_tags WHERE tag_id = ?", arguments: [id])
    }

    func deleteObject<M: APIMatchingObject>(_ type: M.Type, _ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.delete, M.objectType)
        let id = try request.intParam("id")
        let renameDocuments = try await write { db -> [Int] in
            let object = try self.loadObject(M.self, id: id, access: access, in: db)
            var ids = [id]
            var owners = [object.ownerId]
            if M.self == Tag.self {
                let descendants = try DocumentStore.descendants(of: id, in: db)
                ids += descendants
                owners += try descendants.map { try Tag.fetchOne(db, key: $0)?.ownerId }
            }
            guard owners.allSatisfy({ access.isOwner(ownerId: $0) }) else { throw APIError.permissionDenied }
            var affected = Set<Int>()
            for objectId in ids { affected.formUnion(try self.documentsReferencing(M.self, id: objectId, in: db)) }
            for objectId in ids.reversed() {
                _ = try M.deleteOne(db, key: objectId)
                try PermissionSet.removeAll(objectType: M.objectType, objectId: objectId, in: db)
            }
            for documentId in affected { try SearchIndex.update(documentId: documentId, in: db) }
            return M.self == StoragePath.self ? Array(affected) : []
        }
        if !renameDocuments.isEmpty { await enqueueRename(renameDocuments) }
        return .noContent()
    }

    /// Paperless `bulk_update_documents`: moves files of documents whose naming inputs changed,
    /// then runs "Document Updated" workflows for each of them.
    func enqueueRename(_ documentIds: [Int]) async {
        let app = self.app
        _ = try? await queue.enqueue(type: .bulkUpdate, source: .system, input: ["documents": documentIds.map(String.init).joined(separator: ",")]) { _ in
            var updated = 0
            for id in documentIds {
                let exists = try await app.database.write { db -> Bool in
                    guard var document = try Document.fetchOne(db, key: id) else { return false }
                    let named = try app.storage.applyNaming(to: document, in: db)
                    if named.filename != document.filename || named.archiveFilename != document.archiveFilename {
                        document.filename = named.filename
                        document.archiveFilename = named.archiveFilename
                        try document.update(db)
                    }
                    return document.deletedAt == nil
                }
                if exists {
                    await WorkflowEngine(app: app).documentUpdated(id)
                    updated += 1
                }
            }
            return TaskOutcome(message: "Updated \(updated) documents")
        }
    }

    // MARK: - Storage path test

    func testStoragePath(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, Document.objectType)
        let data = try request.data()
        var errors = JSONObject()
        let path = data["path"]?.string ?? ""
        if path.isEmpty { errors["path"] = [data.has("path") ? "This field may not be blank." : "This field is required."] }
        guard let documentValue = data["document"], !documentValue.isNull else {
            errors["document"] = ["This field is required."]
            throw APIError.validation(.object(errors))
        }
        if !errors.isEmpty { throw APIError.validation(.object(errors)) }
        guard let documentId = documentValue.int else {
            throw APIError.field("document", "Incorrect type. Expected pk value, received \(documentValue.typeName).")
        }
        let timeZone = settings.timeZone
        let result = try await read { db -> String? in
            guard let document = try Document.fetchOne(db, key: documentId), document.deletedAt == nil,
                  try access.can(.view, objectType: Document.objectType, objectId: documentId, ownerId: document.ownerId, in: db) else {
                throw APIError.field("document", APIError.invalidPK(String(documentId)))
            }
            var context = try NamingContext.load(for: document, in: db)
            let template = Self.convertLegacyFormat(path)
            context.storagePath = StoragePath(name: "test", path: template)
            let namer = FileNamer(format: nil, timeZone: timeZone)
            guard let rendered = namer.render(template, context: context) else { return nil }
            return rendered + document.fileExtension
        }
        return .json(JSON(result))
    }
}
