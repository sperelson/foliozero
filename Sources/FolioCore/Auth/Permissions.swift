import Foundation
import GRDB

/// Global permission codenames, as Django builds them: `<action>_<model>`.
public enum Permission {
    public enum Action: String, CaseIterable, Sendable { case add, change, delete, view }

    /// Models with global permissions, by Django model name (usage.md "Global permissions").
    public static let models = [
        "applicationconfiguration", "correspondent", "customfield", "document", "documenttype", "group",
        "mailaccount", "mailrule", "note", "paperlesstask", "savedview", "sharelink", "storagepath",
        "tag", "uisettings", "user", "workflow", "processedmail", "logentry", "sharelinkbundle",
    ]

    /// Custom permissions declared on Paperless-ngx's ApplicationConfiguration model.
    public static let viewGlobalStatistics = "view_global_statistics"
    public static let viewSystemMonitoring = "view_system_monitoring"

    public static func codename(_ action: Action, _ model: String) -> String {
        "\(action.rawValue)_\(model)"
    }

    public static var all: [String] {
        models.flatMap { model in Action.allCases.map { codename($0, model) } } + [viewGlobalStatistics, viewSystemMonitoring]
    }
}

/// The authenticated user plus what they may do. Built once per request.
public struct AccessContext: Sendable {
    public var user: User
    public var groupIds: [Int]
    public var permissions: Set<String>

    public var userId: Int { user.id ?? -1 }
    public var isSuperuser: Bool { user.isSuperuser }

    public init(user: User, groupIds: [Int], permissions: Set<String>) {
        self.user = user
        self.groupIds = groupIds
        self.permissions = permissions
    }

    /// A superuser context for internal and CLI work.
    public static func system() -> AccessContext {
        AccessContext(user: User(id: nil, username: "system", isSuperuser: true), groupIds: [], permissions: [])
    }

    public static func load(userId: Int, in db: Database) throws -> AccessContext? {
        guard let user = try User.fetchOne(db, key: userId), user.isActive else { return nil }
        let groups = try Int.fetchAll(db, sql: "SELECT group_id FROM user_groups WHERE user_id = ?", arguments: [userId])
        let own = try String.fetchAll(db, sql: "SELECT codename FROM user_permissions WHERE user_id = ?", arguments: [userId])
        let inherited = try String.fetchAll(db, sql: """
            SELECT codename FROM group_permissions WHERE group_id IN (SELECT group_id FROM user_groups WHERE user_id = ?)
            """, arguments: [userId])
        return AccessContext(user: user, groupIds: groups, permissions: Set(own + inherited))
    }

    /// Global permission check. Superusers have every permission.
    public func has(_ codename: String) -> Bool {
        isSuperuser || permissions.contains(codename)
    }

    public func has(_ action: Permission.Action, _ model: String) -> Bool {
        has(Permission.codename(action, model))
    }

    /// SQL predicate: objects of `objectType` in `table alias` this user may view.
    /// Objects without an owner are visible to everyone (Paperless-ngx behaviour).
    public func visibilityPredicate(objectType: String, alias: String) -> SQL {
        if isSuperuser { return "1" }
        let groups = groupIds.isEmpty ? "NULL" : groupIds.map(String.init).joined(separator: ",")
        return """
            (\(sql: alias).owner_id IS NULL OR \(sql: alias).owner_id = \(userId) OR EXISTS (
                SELECT 1 FROM object_permissions op
                WHERE op.object_type = \(objectType) AND op.object_id = \(sql: alias).id
                  AND (op.user_id = \(userId) OR op.group_id IN (\(sql: groups)))
            ))
            """
    }

    /// Object-level check for one object.
    public func can(_ kind: ObjectPermission.Kind, objectType: String, objectId: Int, ownerId: Int?, in db: Database) throws -> Bool {
        if isSuperuser || ownerId == nil || ownerId == userId { return true }
        let kinds = kind == .view ? ["view", "change"] : ["change"]
        var arguments: StatementArguments = [objectType, objectId, userId]
        var groupClause = ""
        if !groupIds.isEmpty {
            groupClause = " OR group_id IN (\(Array(repeating: "?", count: groupIds.count).joined(separator: ",")))"
            arguments += StatementArguments(groupIds)
        }
        arguments += StatementArguments(kinds)
        let count = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM object_permissions
            WHERE object_type = ? AND object_id = ? AND (user_id = ?\(groupClause))
              AND permission IN (\(Array(repeating: "?", count: kinds.count).joined(separator: ",")))
            """, arguments: arguments) ?? 0
        return count > 0
    }

    /// Only owners (and superusers) may change permissions or create share links.
    public func isOwner(ownerId: Int?) -> Bool {
        isSuperuser || ownerId == nil || ownerId == userId
    }
}

/// The `set_permissions` structure of the Paperless-ngx API.
public struct PermissionSet: Codable, Sendable, Equatable {
    public struct Principals: Codable, Sendable, Equatable {
        public var users: [Int]
        public var groups: [Int]
        public init(users: [Int] = [], groups: [Int] = []) { self.users = users; self.groups = groups }
    }

    public var view: Principals
    public var change: Principals

    public init(view: Principals = .init(), change: Principals = .init()) {
        self.view = view
        self.change = change
    }

    public static func load(objectType: String, objectId: Int, in db: Database) throws -> PermissionSet {
        let rows = try ObjectPermission
            .filter(Column("object_type") == objectType && Column("object_id") == objectId)
            .fetchAll(db)
        var result = PermissionSet()
        for row in rows {
            switch (row.permission, row.userId, row.groupId) {
            case (.view, let user?, _): result.view.users.append(user)
            case (.view, _, let group?): result.view.groups.append(group)
            case (.change, let user?, _): result.change.users.append(user)
            case (.change, _, let group?): result.change.groups.append(group)
            default: break
            }
        }
        return result
    }

    /// Replace (or with `merge`, extend) the object's permissions.
    public func apply(objectType: String, objectId: Int, merge: Bool = false, in db: Database) throws {
        if !merge {
            try db.execute(sql: "DELETE FROM object_permissions WHERE object_type = ? AND object_id = ?", arguments: [objectType, objectId])
        }
        let existing = merge ? try PermissionSet.load(objectType: objectType, objectId: objectId, in: db) : PermissionSet()
        func insert(_ kind: ObjectPermission.Kind, users: [Int], groups: [Int], skipping: Principals) throws {
            for user in Set(users) where !skipping.users.contains(user) {
                var record = ObjectPermission(objectType: objectType, objectId: objectId, permission: kind, userId: user)
                try record.insert(db)
            }
            for group in Set(groups) where !skipping.groups.contains(group) {
                var record = ObjectPermission(objectType: objectType, objectId: objectId, permission: kind, groupId: group)
                try record.insert(db)
            }
        }
        try insert(.view, users: view.users, groups: view.groups, skipping: existing.view)
        try insert(.change, users: change.users, groups: change.groups, skipping: existing.change)
    }

    public static func removeAll(objectType: String, objectId: Int, in db: Database) throws {
        try db.execute(sql: "DELETE FROM object_permissions WHERE object_type = ? AND object_id = ?", arguments: [objectType, objectId])
    }
}
