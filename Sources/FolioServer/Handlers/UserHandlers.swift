import Foundation
import FolioCore
import GRDB
import Hummingbird

extension API {
    /// Django app label of a permission's model, for `app_label.codename` strings.
    static func appLabel(for codename: String) -> String {
        let model = codename.split(separator: "_", maxSplits: 1).last.map(String.init) ?? ""
        switch model {
        case "user", "group": return "auth"
        case "mailaccount", "mailrule", "processedmail": return "paperless_mail"
        case "applicationconfiguration", "global_statistics", "system_monitoring": return "paperless"
        case "logentry": return "auditlog"
        default: return "documents"
        }
    }

    static let validCodenames = Set(Permission.all)

    // MARK: - Users

    func userJSON(_ user: User, in db: Database) throws -> JSON {
        let id = user.id ?? 0
        let groups = try Int.fetchAll(db, sql: "SELECT group_id FROM user_groups WHERE user_id = ? ORDER BY group_id", arguments: [id])
        let own = try String.fetchAll(db, sql: "SELECT codename FROM user_permissions WHERE user_id = ? ORDER BY codename", arguments: [id])
        let inherited = try String.fetchAll(db, sql: """
            SELECT DISTINCT codename FROM group_permissions WHERE group_id IN (SELECT group_id FROM user_groups WHERE user_id = ?)
            ORDER BY codename
            """, arguments: [id])
        return .object(JSONObject([
            ("id", .int(id)),
            ("username", .string(user.username)),
            ("email", .string(user.email)),
            ("password", .string(String(repeating: "*", count: max(10, user.password.count)))),
            ("first_name", .string(user.firstName)),
            ("last_name", .string(user.lastName)),
            ("date_joined", datetime(user.dateJoined)),
            ("is_staff", .bool(user.isStaff)),
            ("is_active", .bool(user.isActive)),
            ("is_superuser", .bool(user.isSuperuser)),
            ("groups", JSON(groups)),
            ("user_permissions", JSON(own)),
            ("inherited_permissions", JSON(inherited.map { "\(Self.appLabel(for: $0)).\($0)" })),
            ("is_mfa_enabled", .bool(try MFAStore.isActive(userId: id, in: db))),
        ]))
    }

    func listUsers(_ request: APIRequest) async throws -> Response {
        try request.access.require(.view, "user")
        let query = request.query
        let body = try await read { db -> JSONObject in
            var conditions: [SQL] = ["u.username NOT IN ('consumer', 'AnonymousUser')"]
            for (name, value) in query.items where name.hasPrefix("username__") {
                if let condition = QueryFilters.charLookup("u.username", lookup: String(name.dropFirst(10)), value: value), !value.isEmpty {
                    conditions.append(condition)
                }
            }
            conditions += Self.idFilters(query, column: "u.id")
            let predicate = QueryFilters.and(conditions)
            let count = try Int.fetchOne(db, SQLRequest<Int>(literal: "SELECT COUNT(*) FROM users u WHERE \(predicate)")) ?? 0
            let page = try PageRequest.resolve(query, count: count)
            let order = QueryFilters.ordering(query["ordering"], allowed: ["username": "u.username COLLATE NOCASE", "id": "u.id"])?.joined(separator: ", ")
                ?? "u.username COLLATE NOCASE"
            let users = try User.fetchAll(db, SQLRequest<User>(literal: """
                SELECT u.* FROM users u WHERE \(predicate) ORDER BY \(sql: order) LIMIT \(page.size) OFFSET \(page.offset)
                """))
            let all = request.version < 10 ? try Int.fetchAll(db, SQLRequest<Int>(literal: "SELECT u.id FROM users u WHERE \(predicate) ORDER BY \(sql: order)")) : nil
            return self.paginated(request, page: page, count: count, results: try users.map { try self.userJSON($0, in: db) }, allIds: all)
        }
        return .json(.object(body))
    }

    func getUser(_ request: APIRequest) async throws -> Response {
        try request.access.require(.view, "user")
        let id = try request.intParam("id")
        let json = try await read { db -> JSON in
            guard let user = try User.fetchOne(db, key: id) else { throw APIError.notFound("User") }
            return try self.userJSON(user, in: db)
        }
        return .json(json)
    }

    func createUser(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.add, "user")
        let data = try request.data()
        if !access.isSuperuser {
            if try data.optionalBool("is_superuser") == true { throw APIError.forbiddenText("Superuser status can only be granted by a superuser") }
            if try data.optionalBool("is_staff") == true { throw APIError.forbiddenText("Staff status can only be granted by a superuser") }
        }
        let username = try data.requiredString("username", maxLength: 150)
        let json = try await write { db -> JSON in
            if try UserStore.user(named: username, in: db) != nil {
                throw APIError.field("username", "A user with that username already exists.")
            }
            var user: User
            do {
                user = try UserStore.createUser(username: username, password: nil, isSuperuser: try data.optionalBool("is_superuser") ?? false,
                                                isStaff: try data.optionalBool("is_staff") ?? false, in: db)
            } catch let error as UserStoreError {
                throw APIError.field("username", error.description)
            }
            try self.applyUserFields(&user, data: data, isNew: true, in: db)
            return try self.userJSON(user, in: db)
        }
        return .json(json, status: .created)
    }

    func updateUser(_ request: APIRequest, partial: Bool) async throws -> Response {
        let access = request.access
        try access.require(.change, "user")
        let id = try request.intParam("id")
        let data = try request.data()
        let json = try await write { db -> JSON in
            guard var user = try User.fetchOne(db, key: id) else { throw APIError.notFound("User") }
            if !access.isSuperuser {
                if user.isSuperuser { throw APIError.forbiddenText("Superusers can only be modified by other superusers") }
                if let requested = try data.optionalBool("is_superuser"), requested != user.isSuperuser {
                    throw APIError.forbiddenText("Superuser status can only be changed by a superuser")
                }
                if let requested = try data.optionalBool("is_staff"), requested != user.isStaff {
                    throw APIError.forbiddenText("Staff status can only be changed by a superuser")
                }
            }
            if !partial, !data.has("username") { throw APIError.field("username", APIError.requiredField) }
            if let username = data["username"]?.string {
                let trimmed = username.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { throw APIError.field("username", "This field may not be blank.") }
                if let other = try UserStore.user(named: trimmed, in: db), other.id != id {
                    throw APIError.field("username", "A user with that username already exists.")
                }
                user.username = trimmed
            }
            if let flag = try data.optionalBool("is_superuser") { user.isSuperuser = flag }
            if let flag = try data.optionalBool("is_staff") { user.isStaff = flag }
            try self.applyUserFields(&user, data: data, isNew: false, in: db)
            return try self.userJSON(user, in: db)
        }
        return .json(json)
    }

    private func applyUserFields(_ user: inout User, data: RequestData, isNew: Bool, in db: Database) throws {
        guard let id = user.id else { return }
        if let email = data["email"]?.string {
            if !email.isEmpty && !Self.isValidEmail(email) { throw APIError.field("email", "Enter a valid email address.") }
            user.email = email
        }
        if let first = data["first_name"]?.string { user.firstName = first }
        if let last = data["last_name"]?.string { user.lastName = last }
        if let active = try data.optionalBool("is_active") { user.isActive = active }
        try user.update(db)
        if let password = data["password"]?.string, !password.replacingOccurrences(of: "*", with: "").isEmpty {
            try UserStore.setPassword(userId: id, password: password, in: db)
            user = try User.fetchOne(db, key: id) ?? user
        }
        if let groups = try data.idList("groups") {
            for group in groups where try Group.fetchOne(db, key: group) == nil {
                throw APIError.field("groups", APIError.invalidPK(String(group)))
            }
            try db.execute(sql: "DELETE FROM user_groups WHERE user_id = ?", arguments: [id])
            for group in Set(groups) {
                try db.execute(sql: "INSERT INTO user_groups(user_id, group_id) VALUES (?, ?)", arguments: [id, group])
            }
        }
        if let permissions = try codenames(data, key: "user_permissions") {
            try db.execute(sql: "DELETE FROM user_permissions WHERE user_id = ?", arguments: [id])
            for codename in permissions {
                try db.execute(sql: "INSERT INTO user_permissions(user_id, codename) VALUES (?, ?)", arguments: [id, codename])
            }
        }
        if !user.isActive {
            try db.execute(sql: "DELETE FROM sessions WHERE user_id = ?", arguments: [id])
        }
    }

    private func codenames(_ data: RequestData, key: String) throws -> [String]? {
        guard let items = data.list(key) else { return nil }
        var result: [String] = []
        for item in items where !item.isNull {
            guard let raw = item.string else { throw APIError.field(key, "Invalid value.") }
            let codename = raw.split(separator: ".").last.map(String.init) ?? raw
            guard Self.validCodenames.contains(codename) else {
                throw APIError.field(key, "Object with codename=\(raw) does not exist.")
            }
            result.append(codename)
        }
        return Array(Set(result)).sorted()
    }

    func deleteUser(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.delete, "user")
        let id = try request.intParam("id")
        try await write { db in
            guard let user = try User.fetchOne(db, key: id) else { throw APIError.notFound("User") }
            if !access.isSuperuser && user.isSuperuser {
                throw APIError.forbiddenText("Superusers can only be deleted by other superusers")
            }
            _ = try User.deleteOne(db, key: id)
        }
        return .noContent()
    }

    // MARK: - Groups

    func groupJSON(_ group: Group, in db: Database) throws -> JSON {
        let permissions = try String.fetchAll(db, sql: "SELECT codename FROM group_permissions WHERE group_id = ? ORDER BY codename", arguments: [group.id])
        return .object(JSONObject([("id", JSON(group.id)), ("name", .string(group.name)), ("permissions", JSON(permissions))]))
    }

    func listGroups(_ request: APIRequest) async throws -> Response {
        try request.access.require(.view, "group")
        let query = request.query
        let body = try await read { db -> JSONObject in
            var conditions: [SQL] = []
            for (name, value) in query.items where name.hasPrefix("name__") {
                if let condition = QueryFilters.charLookup("g.name", lookup: String(name.dropFirst(6)), value: value), !value.isEmpty {
                    conditions.append(condition)
                }
            }
            conditions += Self.idFilters(query, column: "g.id")
            let predicate = QueryFilters.and(conditions)
            let count = try Int.fetchOne(db, SQLRequest<Int>(literal: "SELECT COUNT(*) FROM groups g WHERE \(predicate)")) ?? 0
            let page = try PageRequest.resolve(query, count: count)
            let order = QueryFilters.ordering(query["ordering"], allowed: ["name": "g.name COLLATE NOCASE", "id": "g.id"])?.joined(separator: ", ")
                ?? "g.name COLLATE NOCASE"
            let groups = try Group.fetchAll(db, SQLRequest<Group>(literal: """
                SELECT g.* FROM groups g WHERE \(predicate) ORDER BY \(sql: order) LIMIT \(page.size) OFFSET \(page.offset)
                """))
            let all = request.version < 10 ? try Int.fetchAll(db, SQLRequest<Int>(literal: "SELECT g.id FROM groups g WHERE \(predicate) ORDER BY \(sql: order)")) : nil
            return self.paginated(request, page: page, count: count, results: try groups.map { try self.groupJSON($0, in: db) }, allIds: all)
        }
        return .json(.object(body))
    }

    func getGroup(_ request: APIRequest) async throws -> Response {
        try request.access.require(.view, "group")
        let id = try request.intParam("id")
        let json = try await read { db -> JSON in
            guard let group = try Group.fetchOne(db, key: id) else { throw APIError.notFound("Group") }
            return try self.groupJSON(group, in: db)
        }
        return .json(json)
    }

    func createGroup(_ request: APIRequest) async throws -> Response {
        try request.access.require(.add, "group")
        let data = try request.data()
        let name = try data.requiredString("name", maxLength: 150)
        let permissions = try codenames(data, key: "permissions")
        if permissions == nil { throw APIError.field("permissions", APIError.requiredField) }
        let json = try await write { db -> JSON in
            if try Group.filter(sql: "name = ? COLLATE NOCASE", arguments: [name]).fetchOne(db) != nil {
                throw APIError.field("name", "group with this name already exists.")
            }
            var group = Group(name: name)
            try group.insert(db)
            try self.setGroupPermissions(group.id!, permissions ?? [], in: db)
            return try self.groupJSON(group, in: db)
        }
        return .json(json, status: .created)
    }

    func updateGroup(_ request: APIRequest) async throws -> Response {
        try request.access.require(.change, "group")
        let id = try request.intParam("id")
        let data = try request.data()
        let permissions = try codenames(data, key: "permissions")
        let json = try await write { db -> JSON in
            guard var group = try Group.fetchOne(db, key: id) else { throw APIError.notFound("Group") }
            if data.has("name") {
                let name = try data.requiredString("name", maxLength: 150)
                if try Group.filter(sql: "name = ? COLLATE NOCASE AND id != ?", arguments: [name, id]).fetchOne(db) != nil {
                    throw APIError.field("name", "group with this name already exists.")
                }
                group.name = name
                try group.update(db)
            }
            if let permissions { try self.setGroupPermissions(id, permissions, in: db) }
            return try self.groupJSON(group, in: db)
        }
        return .json(json)
    }

    private func setGroupPermissions(_ id: Int, _ codenames: [String], in db: Database) throws {
        try db.execute(sql: "DELETE FROM group_permissions WHERE group_id = ?", arguments: [id])
        for codename in codenames {
            try db.execute(sql: "INSERT INTO group_permissions(group_id, codename) VALUES (?, ?)", arguments: [id, codename])
        }
    }

    func deleteGroup(_ request: APIRequest) async throws -> Response {
        try request.access.require(.delete, "group")
        let id = try request.intParam("id")
        try await write { db in
            guard try Group.deleteOne(db, key: id) else { throw APIError.notFound("Group") }
        }
        return .noContent()
    }

    /// `id`, `id__in` filters shared by object endpoints.
    static func idFilters(_ query: QueryItems, column: String) -> [SQL] {
        var conditions: [SQL] = []
        if let raw = query["id"], !raw.isEmpty {
            conditions.append(Int(raw).map { "\(sql: column) = \($0)" } ?? "0")
        }
        if let raw = query["id__in"], !raw.isEmpty {
            conditions.append(QueryFilters.intList(raw).map { "\(sql: column) IN \($0)" } ?? "0")
        }
        return conditions
    }
}
