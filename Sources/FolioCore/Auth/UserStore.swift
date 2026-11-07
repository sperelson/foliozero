import Foundation
import GRDB

public enum UserStoreError: Error, CustomStringConvertible, Equatable {
    case usernameTaken(String)
    case notFound(String)
    case invalidUsername

    public var description: String {
        switch self {
        case .usernameTaken(let name): "A user named \(name) already exists"
        case .notFound(let name): "No user named \(name)"
        case .invalidUsername: "Usernames may contain letters, digits and @.+-_ only"
        }
    }
}

/// Users, API tokens and browser sessions.
public enum UserStore {
    @discardableResult
    public static func createUser(
        username: String, password: String?, email: String = "", isSuperuser: Bool = false,
        isStaff: Bool? = nil, in db: Database
    ) throws -> User {
        guard !username.isEmpty, username.count <= 150,
              username.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "@.+-_".unicodeScalars.contains($0) })
        else { throw UserStoreError.invalidUsername }
        if try User.filter(Column("username").collating(.nocase) == username).fetchOne(db) != nil {
            throw UserStoreError.usernameTaken(username)
        }
        var user = User(
            username: username,
            password: password.map { PasswordHasher.hash($0) } ?? "",
            email: email,
            isSuperuser: isSuperuser,
            isStaff: isStaff ?? isSuperuser
        )
        try user.insert(db)
        return user
    }

    public static func user(named username: String, in db: Database) throws -> User? {
        try User.filter(Column("username").collating(.nocase) == username).fetchOne(db)
    }

    /// Checks credentials. Upgrades old hashes and records the login time.
    public static func authenticate(username: String, password: String, in db: Database) throws -> User? {
        guard var user = try user(named: username, in: db), user.isActive, !user.password.isEmpty else {
            // Spend comparable time so missing users are not detectable by timing.
            _ = PasswordHasher.verify(password, encoded: "pbkdf2_sha256$\(PasswordHasher.defaultIterations)$timing$AAAA")
            return nil
        }
        guard PasswordHasher.verify(password, encoded: user.password) else { return nil }
        if PasswordHasher.needsRehash(user.password) {
            user.password = PasswordHasher.hash(password)
        }
        user.lastLogin = Date()
        try user.update(db)
        return user
    }

    public static func setPassword(userId: Int, password: String, in db: Database) throws {
        try db.execute(sql: "UPDATE users SET password = ? WHERE id = ?", arguments: [PasswordHasher.hash(password), userId])
        // Changing a password ends every session of that user.
        try db.execute(sql: "DELETE FROM sessions WHERE user_id = ?", arguments: [userId])
    }

    // MARK: Tokens

    /// The user's API token, created on first use (`/api/token/`).
    public static func token(for userId: Int, in db: Database) throws -> String {
        if let existing = try AuthToken.filter(Column("user_id") == userId).fetchOne(db) {
            return existing.key
        }
        return try regenerateToken(for: userId, in: db)
    }

    @discardableResult
    public static func regenerateToken(for userId: Int, in db: Database) throws -> String {
        try db.execute(sql: "DELETE FROM auth_tokens WHERE user_id = ?", arguments: [userId])
        let token = AuthToken(key: PasswordHasher.newToken(), userId: userId)
        try token.insert(db)
        return token.key
    }

    public static func user(forToken key: String, in db: Database) throws -> User? {
        guard let token = try AuthToken.fetchOne(db, key: key) else { return nil }
        return try User.fetchOne(db, key: token.userId).flatMap { $0.isActive ? $0 : nil }
    }

    // MARK: Sessions

    public static func createSession(userId: Int, lifetime: TimeInterval, in db: Database) throws -> Session {
        let session = Session(
            key: PasswordHasher.randomString(length: 40),
            userId: userId,
            csrfToken: PasswordHasher.randomString(length: 32),
            expires: Date().addingTimeInterval(lifetime)
        )
        try session.insert(db)
        return session
    }

    public static func session(key: String, in db: Database) throws -> Session? {
        guard let session = try Session.fetchOne(db, key: key) else { return nil }
        guard session.expires > Date() else {
            try db.execute(sql: "DELETE FROM sessions WHERE key = ?", arguments: [key])
            return nil
        }
        return session
    }

    public static func deleteSession(key: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM sessions WHERE key = ?", arguments: [key])
    }

    public static func purgeExpiredSessions(in db: Database) throws {
        try db.execute(sql: "DELETE FROM sessions WHERE expires <= ?", arguments: [FolioDateFormat.database.string(from: Date())])
    }
}
