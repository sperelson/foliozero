import Foundation
import GRDB

/// A local user's link to an identity provider account (allauth `SocialAccount`).
public struct SocialAccount: IdentifiedRecord, Hashable {
    public static let databaseTableName = "social_accounts"
    public var id: Int?
    public var userId: Int
    /// The app's `provider_id` (allauth `sub_id`), e.g. `keycloak`.
    public var provider: String
    public var uid: String
    /// JSON text: `{"userinfo": {...}, "id_token": {...}}` as allauth 65.11+ stores it.
    public var extraData: String
    public var dateJoined: Date
    public var lastLogin: Date

    public init(id: Int? = nil, userId: Int, provider: String, uid: String, extraData: String = "{}",
                dateJoined: Date = Date(), lastLogin: Date = Date()) {
        self.id = id; self.userId = userId; self.provider = provider; self.uid = uid
        self.extraData = extraData; self.dateJoined = dateJoined; self.lastLogin = lastLogin
    }

    public var extraDataJSON: JSONValue {
        (try? JSONDecoder().decode(JSONValue.self, from: Data(extraData.utf8))) ?? .object([:])
    }
}

/// What a provider says about the person signing in (allauth `sociallogin_from_response`).
public struct SocialProfile: Sendable, Equatable {
    public var uid: String
    public var extraData: JSONValue
    public var email: String?
    public var emailVerified: Bool
    public var username: String?
    public var firstName: String
    public var lastName: String

    public init(uid: String, extraData: JSONValue, email: String? = nil, emailVerified: Bool = false,
                username: String? = nil, firstName: String = "", lastName: String = "") {
        self.uid = uid; self.extraData = extraData; self.email = email; self.emailVerified = emailVerified
        self.username = username; self.firstName = firstName; self.lastName = lastName
    }

    public enum ProfileError: Error, CustomStringConvertible {
        case missingUID(String)

        public var description: String {
            switch self {
            case .missingUID(let field): "the provider sent no usable \"\(field)\" claim"
            }
        }
    }

    /// allauth `OpenIDConnectProvider`: userinfo claims win over ID token claims.
    public static func make(userinfo: [String: JSONValue]?, idToken: [String: JSONValue]?, provider: OIDCProviderConfig) throws -> SocialProfile {
        var extra: [String: JSONValue] = [:]
        if let userinfo { extra["userinfo"] = .object(userinfo) }
        if let idToken { extra["id_token"] = .object(idToken) }
        let data = SocialAccountStore.pickUserData(.object(extra))
        guard let uidValue = data[provider.uidField], let uid = uidValue.stringValue, !uid.isEmpty, uid.count <= 191 else {
            throw ProfileError.missingUID(provider.uidField)
        }
        func text(_ key: String) -> String? {
            if case .string(let value)? = data[key] { return value }
            return nil
        }
        let email = text("email").flatMap { SocialAccountStore.isValidEmail($0) ? $0 : nil }
        var verified = false
        switch data["email_verified"] {
        case .bool(let flag)?: verified = flag
        case .string(let flag)?: verified = flag.lowercased() == "true"
        default: break
        }
        if let email, provider.isEmailVerified(email) { verified = true }
        let name = text("name") ?? ""
        let parts = name.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let first = text("given_name").flatMap { $0.isEmpty ? nil : $0 } ?? parts.first ?? ""
        let last = text("family_name").flatMap { $0.isEmpty ? nil : $0 } ?? (parts.count > 1 ? parts[1] : "")
        return SocialProfile(uid: uid, extraData: .object(extra), email: email, emailVerified: verified,
                             username: text("preferred_username"), firstName: String(first.prefix(150)), lastName: String(last.prefix(150)))
    }
}

/// Social accounts, group sync and signup helpers (allauth plus Paperless-ngx `paperless.adapter` and `signals`).
public enum SocialAccountStore {
    /// Schema for migration "v4-social-accounts".
    static func createTable(_ db: Database) throws {
        try db.create(table: "social_accounts") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("user_id", .integer).notNull().indexed().references("users", onDelete: .cascade)
            t.column("provider", .text).notNull()
            t.column("uid", .text).notNull()
            t.column("extra_data", .jsonText).notNull().defaults(to: "{}")
            t.column("date_joined", .datetime).notNull()
            t.column("last_login", .datetime).notNull()
            t.uniqueKey(["provider", "uid"])
        }
    }

    public static func account(provider: String, uid: String, in db: Database) throws -> SocialAccount? {
        try SocialAccount.filter(Column("provider") == provider && Column("uid") == uid).fetchOne(db)
    }

    public static func accounts(userId: Int, in db: Database) throws -> [SocialAccount] {
        try SocialAccount.filter(Column("user_id") == userId).order(Column("id")).fetchAll(db)
    }

    @discardableResult
    public static func connect(userId: Int, provider: String, profile: SocialProfile, in db: Database) throws -> SocialAccount {
        var account = SocialAccount(userId: userId, provider: provider, uid: profile.uid, extraData: json(profile.extraData))
        try account.insert(db)
        return account
    }

    /// Stores the latest claims (allauth updates `extra_data` on every login).
    public static func update(_ account: SocialAccount, extraData: JSONValue, in db: Database) throws -> SocialAccount {
        var account = account
        account.extraData = json(extraData)
        account.lastLogin = Date()
        try account.update(db)
        return account
    }

    /// Paperless-ngx `DisconnectSocialAccountView`: only the owner's accounts.
    public static func disconnect(id: Int, userId: Int, in db: Database) throws -> Bool {
        try db.execute(sql: "DELETE FROM social_accounts WHERE id = ? AND user_id = ?", arguments: [id, userId])
        return db.changesCount > 0
    }

    static func json(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    // MARK: Claims

    /// allauth `_pick_data`: the userinfo claims, else the ID token claims, else the data itself.
    public static func pickUserData(_ extraData: JSONValue) -> [String: JSONValue] {
        guard case .object(let object) = extraData else { return [:] }
        if case .object(let userinfo)? = object["userinfo"], !userinfo.isEmpty { return userinfo }
        if case .object(let idToken)? = object["id_token"], !idToken.isEmpty { return idToken }
        return object
    }

    /// allauth `ProviderAccount.to_str`: the name the profile page shows for a linked account.
    public static func displayName(extraData: JSONValue, providerName: String) -> String {
        let data = pickUserData(extraData)
        let table: [(String?, [String])] = [
            (nil, ["username", "userName", "user_name", "login", "handle"]),
            (nil, ["email", "Email", "mail", "email_address"]),
            (nil, ["name", "display_name", "displayName", "displayname", "Display_Name", "nickname"]),
            (nil, ["full_name", "fullName"]),
            ("first_name", ["first_name", "firstname", "firstName", "First_Name", "given_name", "givenName"]),
            ("last_name", ["last_name", "lastname", "lastName", "Last_Name", "family_name", "familyName", "surname"]),
        ]
        var combined: [String: String] = [:]
        for (storeAs, keys) in table {
            for key in keys {
                guard case .string(let raw)? = data[key] else { continue }
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty, storeAs == nil { return value }
                if let storeAs { combined[storeAs] = value }
            }
        }
        let full = "\(combined["first_name"] ?? "") \(combined["last_name"] ?? "")".trimmingCharacters(in: .whitespaces)
        return full.isEmpty ? providerName : full
    }

    /// The groups claim (Paperless-ngx `handle_social_account_updated`): top level, then userinfo, then the ID token.
    static func groupNames(_ extraData: JSONValue, claim: String) -> [String] {
        guard case .object(let object) = extraData else { return [] }
        func truthy(_ value: JSONValue?) -> JSONValue? {
            switch value {
            case nil, .null?, .bool(false)?: return nil
            case .string(let text)? where text.isEmpty: return nil
            case .array(let items)? where items.isEmpty: return nil
            case .object(let items)? where items.isEmpty: return nil
            default: return value
            }
        }
        func nested(_ key: String) -> JSONValue? {
            guard case .object(let inner)? = object[key] else { return nil }
            return truthy(inner[claim])
        }
        let value = truthy(object[claim]) ?? nested("userinfo") ?? nested("id_token")
        switch value {
        case .string(let name)?: return [name]
        case .array(let items)?: return items.compactMap { if case .string(let name) = $0 { name } else { nil } }
        default: return []
        }
    }

    /// Syncs groups and the superuser and staff flags from the provider's groups claim.
    /// Inactive users are left alone (Paperless-ngx `handle_social_account_updated`).
    public static func syncFromProvider(userId: Int, extraData: JSONValue, settings: SocialAccountSettings, in db: Database) throws {
        guard var user = try User.fetchOne(db, key: userId), user.isActive else { return }
        let names = groupNames(extraData, claim: settings.syncGroupsClaim)
        if settings.syncGroups {
            try db.execute(sql: "DELETE FROM user_groups WHERE user_id = ?", arguments: [userId])
            for groupId in try groupIds(names, in: db) {
                try db.execute(sql: "INSERT OR IGNORE INTO user_groups(user_id, group_id) VALUES (?, ?)", arguments: [userId, groupId])
            }
        }
        var changed = false
        if let group = settings.syncSuperuserGroup {
            let isSuperuser = names.contains(group)
            if user.isSuperuser != isSuperuser { user.isSuperuser = isSuperuser; changed = true }
        }
        if let group = settings.syncStaffGroup {
            let isStaff = names.contains(group) || user.isSuperuser
            if user.isStaff != isStaff { user.isStaff = isStaff; changed = true }
        } else if settings.syncSuperuserGroup != nil {
            let isStaff = user.isSuperuser || user.isStaff
            if user.isStaff != isStaff { user.isStaff = isStaff; changed = true }
        }
        if changed { try user.update(db) }
    }

    /// Adds the user to the named groups that exist (Django `Group.objects.filter(name__in=...)`).
    public static func addToGroups(userId: Int, names: [String], in db: Database) throws {
        for groupId in try groupIds(names, in: db) {
            try db.execute(sql: "INSERT OR IGNORE INTO user_groups(user_id, group_id) VALUES (?, ?)", arguments: [userId, groupId])
        }
    }

    /// Ids of groups whose name matches exactly (case-sensitive, as on PostgreSQL).
    static func groupIds(_ names: [String], in db: Database) throws -> [Int] {
        guard !names.isEmpty else { return [] }
        let marks = Array(repeating: "?", count: names.count).joined(separator: ", ")
        return try Int.fetchAll(db, sql: "SELECT id FROM groups WHERE name COLLATE BINARY IN (\(marks)) ORDER BY id",
                                arguments: StatementArguments(names))
    }

    // MARK: Signup

    /// Users that share the email address, oldest first (allauth `filter_users_by_email`).
    public static func users(withEmail email: String, in db: Database) throws -> [User] {
        try User.filter(sql: "email = ? COLLATE NOCASE AND email != ''", arguments: [email]).order(Column("id")).fetchAll(db)
    }

    /// Paperless-ngx `CustomAccountAdapter`: no users (besides `consumer` and `AnonymousUser`) and no documents.
    public static func isFreshInstall(in db: Database) throws -> Bool {
        let users = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users WHERE username NOT IN ('consumer', 'AnonymousUser')") ?? 0
        let documents = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM documents") ?? 0
        return users == 0 && documents == 0
    }

    /// Django's username rules: letters, digits and `@.+-_`, at most 150 characters.
    public static func isValidUsername(_ name: String) -> Bool {
        !name.isEmpty && name.count <= 150
            && name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "@.+-_".unicodeScalars.contains($0) }
    }

    public static func isUsernameTaken(_ name: String, in db: Database) throws -> Bool {
        try UserStore.user(named: name, in: db) != nil
    }

    public static func isValidEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              email.count <= 254 else { return false }
        return !email.contains(where: { $0.isWhitespace })
    }

    /// allauth `generate_unique_username`: the first usable text as a base, then a random suffix until it is free.
    public static func uniqueUsername(from texts: [String?], in db: Database) throws -> String {
        var base = "user"
        for text in texts {
            guard let text, !text.isEmpty else { continue }
            var candidate = text.decomposedStringWithCompatibilityMapping.unicodeScalars.filter(\.isASCII)
                .map(String.init).joined()
            guard !candidate.isEmpty else { continue }
            candidate = String(candidate.unicodeScalars.filter {
                CharacterSet.alphanumerics.contains($0) || $0 == "_" || CharacterSet.whitespaces.contains($0) || "@+.-".unicodeScalars.contains($0)
            }.map(Character.init)).lowercased()
            candidate = String(candidate.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
            candidate = candidate.trimmingCharacters(in: .whitespaces)
            candidate = candidate.split(whereSeparator: { $0.isWhitespace }).joined(separator: "_")
            if isValidUsername(candidate) { base = candidate; break }
        }
        let digits = Array("0123456789"), letters = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var candidates = [base]
        for length in 1..<7 {
            let suffix = String((0..<length).map { index in (index < 4 ? digits : letters).randomElement()! })
            candidates.append(String(base.prefix(150 - length)) + suffix)
        }
        for candidate in candidates where isValidUsername(candidate) {
            if try !isUsernameTaken(candidate, in: db) { return candidate }
        }
        return String(base.prefix(118)) + "_" + PasswordHasher.randomString(length: 31).lowercased()
    }

    /// Creates the local user for a social signup: no usable password, then the social default groups,
    /// then the group sync (Paperless-ngx `CustomSocialAccountAdapter.save_user`).
    ///
    /// `fromForm` mirrors allauth's signup form path, which also runs `CustomAccountAdapter.save_user`:
    /// the first user of a fresh install becomes a superuser, and `ACCOUNT_DEFAULT_GROUPS` apply.
    public static func signUp(username: String, email: String, provider: String, profile: SocialProfile, fromForm: Bool,
                              settings: SocialAccountSettings, in db: Database) throws -> User {
        let fresh = fromForm ? try isFreshInstall(in: db) : false
        var user = try UserStore.createUser(username: username, password: nil, email: email, isSuperuser: fresh, isStaff: fresh, in: db)
        user.firstName = profile.firstName
        user.lastName = profile.lastName
        try user.update(db)
        let userId = user.id!
        if fromForm { try addToGroups(userId: userId, names: settings.accountDefaultGroups, in: db) }
        try connect(userId: userId, provider: provider, profile: profile, in: db)
        try addToGroups(userId: userId, names: settings.defaultGroups, in: db)
        try syncFromProvider(userId: userId, extraData: profile.extraData, settings: settings, in: db)
        return try User.fetchOne(db, key: userId) ?? user
    }
}
