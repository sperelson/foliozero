import Foundation
import FolioCore
import GRDB
import Hummingbird

// MARK: - Pagination

/// DRF `PageNumberPagination` as configured by Paperless-ngx (`StandardPagination`).
struct PageRequest: Sendable {
    var number: Int
    var size: Int
    var offset: Int { (number - 1) * size }

    static let defaultSize = 25
    static let maxSize = 100_000

    /// Page size from `page_size` (invalid values fall back to the default).
    static func size(_ query: QueryItems) -> Int {
        guard let raw = query["page_size"], let value = Int(raw), value > 0 else { return defaultSize }
        return min(value, maxSize)
    }

    /// Validates `page` against the result count. Invalid pages are 404 "Invalid page.".
    static func resolve(_ query: QueryItems, count: Int) throws -> PageRequest {
        let size = size(query)
        let pages = max(1, Int((Double(count) / Double(size)).rounded(.up)))
        let raw = query["page"] ?? "1"
        let number: Int
        if raw == "last" {
            number = pages
        } else {
            guard let parsed = Int(raw.trimmingCharacters(in: .whitespaces)) else { throw APIError.detail(.notFound, "Invalid page.") }
            number = parsed
        }
        guard number >= 1, number <= pages else { throw APIError.detail(.notFound, "Invalid page.") }
        return PageRequest(number: number, size: size)
    }
}

extension API {
    /// The paginated envelope: `count`, `next`, `previous`, (`all` before v10), `results`.
    func paginated(_ request: APIRequest, page: PageRequest, count: Int, results: [JSON], allIds: [Int]?) -> JSONObject {
        var object = JSONObject()
        object["count"] = .int(count)
        let hasNext = page.number * page.size < count
        object["next"] = hasNext ? .string(absoluteURL(request, query: request.query.replacing("page", with: String(page.number + 1)))) : .null
        if page.number > 1 {
            let previous = page.number == 2 ? request.query.replacing("page", with: nil) : request.query.replacing("page", with: String(page.number - 1))
            object["previous"] = .string(absoluteURL(request, query: previous))
        } else {
            object["previous"] = .null
        }
        if request.version < 10 {
            object["all"] = JSON(allIds ?? [])
        }
        object["results"] = .array(results)
        return object
    }
}

// MARK: - Permissions

extension AccessContext {
    /// Global (model) permission check; 403 when missing.
    func require(_ action: Permission.Action, _ model: String) throws {
        guard has(action, model) else { throw APIError.permissionDenied }
    }
}

/// `set_permissions` as sent by clients. A missing action or key leaves those grants untouched.
struct PermissionSpec: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        var users: [Int]?
        var groups: [Int]?
    }
    var view: Entry?
    var change: Entry?

    /// Parses and validates the structure; user and group ids must exist.
    static func parse(_ value: JSON?, field: String = "set_permissions", in db: Database) throws -> PermissionSpec? {
        guard let value, !value.isNull else { return nil }
        guard let object = value.object else {
            throw APIError.validation(.object(JSONObject([(field, ["non_field_errors": [.string("Invalid data. Expected a dictionary, but got \(typeName(value)).")]] as JSON)])))
        }
        let unknown = object.keys.filter { $0 != "view" && $0 != "change" }
        if !unknown.isEmpty {
            var errors = JSONObject()
            for key in unknown.sorted() { errors[key] = "Unknown permission action." }
            throw APIError.validation(.object(JSONObject([(field, .object(errors))])))
        }
        var spec = PermissionSpec()
        for action in ["view", "change"] {
            guard let entryValue = object[action] else { continue }
            var entry = Entry()
            let entryObject = entryValue.object ?? JSONObject()
            for kind in ["users", "groups"] {
                guard let list = entryObject[kind], !list.isNull else { continue }
                guard let items = list.array, items.allSatisfy({ $0.int != nil }) else {
                    throw APIError.validation(.object(JSONObject([(field, .object(JSONObject([(action, .object(JSONObject([(kind, ["A valid integer is required."])])))])))])))
                }
                let ids = items.compactMap(\.int)
                let table = kind == "users" ? "users" : "groups"
                let found = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE id IN (\(ids.map(String.init).joined(separator: ",").ifEmpty("NULL")))") ?? 0
                if found != ids.count {
                    throw APIError.field(field, "Some \(kind) in don't exist or were specified twice.")
                }
                if kind == "users" { entry.users = ids } else { entry.groups = ids }
            }
            if action == "view" { spec.view = entry } else { spec.change = entry }
        }
        return spec
    }

    private static func typeName(_ value: JSON) -> String {
        switch value {
        case .array: "list"
        case .string: "str"
        case .int: "int"
        case .double: "float"
        case .bool: "bool"
        default: "NoneType"
        }
    }

    /// Paperless-ngx `set_permissions_for_objects`: per action, replace (or with `merge`, extend)
    /// the direct grants. Granting change also grants view.
    func apply(objectType: String, objectIds: [Int], merge: Bool, in db: Database) throws {
        for objectId in objectIds {
            for (kind, entry) in [(ObjectPermission.Kind.view, view), (.change, change)] {
                guard let entry else { continue }
                for (column, ids) in [("user_id", entry.users), ("group_id", entry.groups)] {
                    guard let ids else { continue }
                    if !merge {
                        let keep = ids.isEmpty ? "NULL" : ids.map(String.init).joined(separator: ",")
                        try db.execute(sql: """
                            DELETE FROM object_permissions WHERE object_type = ? AND object_id = ? AND permission = ?
                            AND \(column) IS NOT NULL AND \(column) NOT IN (\(keep))
                            """, arguments: [objectType, objectId, kind.rawValue])
                    }
                    let kinds: [ObjectPermission.Kind] = kind == .change ? [.change, .view] : [.view]
                    for grant in kinds {
                        for id in Set(ids) {
                            let exists = try Int.fetchOne(db, sql: """
                                SELECT COUNT(*) FROM object_permissions WHERE object_type = ? AND object_id = ? AND permission = ? AND \(column) = ?
                                """, arguments: [objectType, objectId, grant.rawValue, id]) ?? 0
                            guard exists == 0 else { continue }
                            var record = ObjectPermission(objectType: objectType, objectId: objectId, permission: grant,
                                                          userId: column == "user_id" ? id : nil, groupId: column == "group_id" ? id : nil)
                            try record.insert(db)
                        }
                    }
                }
            }
        }
    }
}

extension String {
    func ifEmpty(_ replacement: String) -> String { isEmpty ? replacement : self }
}

extension API {
    /// An id set as one bound JSON parameter, so large selections stay under SQLite's variable limit.
    static func idSet(_ ids: [Int]) -> SQL {
        "(SELECT value FROM json_each(\("[" + ids.map(String.init).joined(separator: ",") + "]")))"
    }

    /// `Document.fetchAll(keys:)` in chunks.
    func fetchDocuments(_ ids: [Int], in db: Database) throws -> [Document] {
        var result: [Document] = []
        for start in stride(from: 0, to: ids.count, by: 10_000) {
            result += try Document.fetchAll(db, keys: Array(ids[start..<min(start + 10_000, ids.count)]))
        }
        return result
    }
}

/// What the serializers need about the caller.
struct SerializeContext: Sendable {
    var access: AccessContext
    var fullPerms: Bool
    var version: Int

    init(_ request: APIRequest, fullPerms: Bool? = nil) {
        access = request.access
        self.fullPerms = fullPerms ?? request.query.flag("full_perms")
        version = request.version
    }
}

/// Object permission grants for a batch of objects, loaded in one query.
struct GrantTable: Sendable {
    var grants: [Int: PermissionSet] = [:]

    static func load(objectType: String, ids: [Int], in db: Database) throws -> GrantTable {
        var table = GrantTable()
        guard !ids.isEmpty else { return table }
        for id in ids { table.grants[id] = PermissionSet() }
        let rows = try Row.fetchAll(db, sql: """
            SELECT object_id, permission, user_id, group_id FROM object_permissions
            WHERE object_type = ? AND object_id IN (\(ids.map(String.init).joined(separator: ",")))
            ORDER BY user_id, group_id
            """, arguments: [objectType])
        for row in rows {
            let id: Int = row["object_id"]
            let permission: String = row["permission"]
            var set = table.grants[id] ?? PermissionSet()
            if let user = row["user_id"] as Int? {
                if permission == "view" { set.view.users.append(user) } else { set.change.users.append(user) }
            } else if let group = row["group_id"] as Int? {
                if permission == "view" { set.view.groups.append(group) } else { set.change.groups.append(group) }
            }
            table.grants[id] = set
        }
        return table
    }

    func permissions(_ id: Int) -> PermissionSet { grants[id] ?? PermissionSet() }

    func userCanChange(_ id: Int, ownerId: Int?, access: AccessContext) -> Bool {
        if ownerId == nil || ownerId == access.userId || access.isSuperuser { return true }
        let change = permissions(id).change
        return change.users.contains(access.userId) || !Set(change.groups).isDisjoint(with: access.groupIds)
    }

    func isShared(_ id: Int) -> Bool {
        let set = permissions(id)
        return !(set.view.users.isEmpty && set.view.groups.isEmpty && set.change.users.isEmpty && set.change.groups.isEmpty)
    }

    static func json(_ set: PermissionSet) -> JSON {
        [
            "view": ["users": JSON(set.view.users.sorted()), "groups": JSON(set.view.groups.sorted())],
            "change": ["users": JSON(set.change.users.sorted()), "groups": JSON(set.change.groups.sorted())],
        ]
    }

    /// `owner`, then `permissions` (full_perms) or `user_can_change` (+ `is_shared_by_requester`).
    func addOwnedFields(to object: inout JSONObject, id: Int, ownerId: Int?, context: SerializeContext, sharedFlag: Bool = false) {
        object["owner"] = JSON(ownerId)
        if context.fullPerms {
            object["permissions"] = GrantTable.json(permissions(id))
        } else {
            object["user_can_change"] = .bool(userCanChange(id, ownerId: ownerId, access: context.access))
            if sharedFlag {
                object["is_shared_by_requester"] = .bool(ownerId == context.access.userId && isShared(id))
            }
        }
    }
}

// MARK: - Body field helpers

extension RequestData {
    /// An optional foreign key: absent, null, or an existing id in `table`.
    func foreignKey(_ key: String, table: String, in db: Database) throws -> Int?? {
        guard let value = self[key] else { return .none }
        if value.isNull || value.string == "" { return .some(nil) }
        guard let id = value.int else {
            throw APIError.field(key, "Incorrect type. Expected pk value, received \(value.typeName).")
        }
        guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE id = ?", arguments: [id]) ?? 0 > 0 else {
            throw APIError.field(key, APIError.invalidPK(String(id)))
        }
        return .some(id)
    }

    func string(_ key: String) -> String? { self[key]?.string }

    func requiredString(_ key: String, maxLength: Int? = nil, allowBlank: Bool = false) throws -> String {
        guard let value = self[key], !value.isNull else { throw APIError.field(key, APIError.requiredField) }
        guard let text = value.string else { throw APIError.field(key, "Not a valid string.") }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty && !allowBlank { throw APIError.field(key, "This field may not be blank.") }
        if let maxLength, trimmed.count > maxLength {
            throw APIError.field(key, "Ensure this field has no more than \(maxLength) characters.")
        }
        return trimmed
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard let value = self[key], !value.isNull else { return nil }
        guard let flag = value.bool else { throw APIError.field(key, "Must be a valid boolean.") }
        return flag
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard let value = self[key], !value.isNull, value.string != "" else { return nil }
        guard let n = value.int else { throw APIError.field(key, "A valid integer is required.") }
        return n
    }

    /// A list of ids (JSON array, or repeated form fields).
    func idList(_ key: String) throws -> [Int]? {
        guard let items = list(key) else { return nil }
        if items.count == 1, items[0].isNull { return [] }
        var ids: [Int] = []
        for item in items {
            guard let id = item.int else {
                throw APIError.field(key, "Incorrect type. Expected pk value, received \(item.typeName).")
            }
            ids.append(id)
        }
        return ids
    }
}

extension JSON {
    var typeName: String {
        switch self {
        case .string: "str"
        case .int: "int"
        case .double: "float"
        case .bool: "bool"
        case .null: "NoneType"
        case .array: "list"
        case .object: "dict"
        }
    }
}
