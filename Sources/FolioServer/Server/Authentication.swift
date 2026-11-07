import CryptoKit
import Foundation
import FolioCore
import GRDB
import HTTPTypes
import Hummingbird

extension API {
    /// Resolves the caller from Basic, Token, remote-user header or session cookie,
    /// in Django REST framework's order. Invalid explicit credentials fail with 401.
    func authenticate(_ request: Request, context: APIRequestContext, isAPI: Bool) async throws -> Authentication? {
        try await authenticate(head: request.head, isAPI: isAPI)
    }

    /// Authentication from the request head alone (also used for WebSocket upgrades).
    func authenticate(head: HTTPRequest, isAPI: Bool) async throws -> Authentication? {
        let headers = head.headerFields
        if let header = headers[.authorization] {
            let parts = header.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let scheme = parts.first.map { $0.lowercased() } ?? ""
            if scheme == "basic" {
                return try await basicAuthentication(parts.count > 1 ? String(parts[1]) : "")
            }
            if scheme == "token" {
                guard parts.count > 1 else {
                    throw APIError.detail(.unauthorized, "Invalid token header. No credentials provided.")
                }
                let key = parts[1].trimmingCharacters(in: .whitespaces)
                guard !key.contains(" ") else {
                    throw APIError.detail(.unauthorized, "Invalid token header. Token string should not contain spaces.")
                }
                let access = try await read { db -> AccessContext? in
                    guard let user = try UserStore.user(forToken: key, in: db), let id = user.id else { return nil }
                    return try AccessContext.load(userId: id, in: db)
                }
                guard let access else { throw APIError.detail(.unauthorized, "Invalid token.") }
                return Authentication(access: access, method: .token)
            }
        }

        if isAPI ? settings.enableHTTPRemoteUserAPI : settings.enableHTTPRemoteUser,
           let name = remoteUserHeaderName, let username = headers[name]?.trimmingCharacters(in: .whitespaces),
           !username.isEmpty {
            let access = try await write { db -> AccessContext? in
                let user = try UserStore.user(named: username, in: db)
                    ?? UserStore.createUser(username: username, password: nil, in: db)
                return try user.id.flatMap { try AccessContext.load(userId: $0, in: db) }
            }
            if let access { return Authentication(access: access, method: .remoteUser) }
        }

        if let key = Cookies(from: headers[values: .cookie])[sessionCookieName]?.value, !key.isEmpty {
            let result = try await write { db -> (AccessContext, Session)? in
                guard let session = try UserStore.session(key: key, in: db),
                      let access = try AccessContext.load(userId: session.userId, in: db) else { return nil }
                return (access, session)
            }
            // With auto-login, Django's middleware replaces another user's session.
            if let (access, session) = result, autoLoginUsername.map({ $0 == access.user.username }) ?? true {
                return Authentication(access: access, method: .session, session: session)
            }
        }

        // Paperless-ngx AutoLoginMiddleware: sign in the configured active user, except for token requests.
        if let username = autoLoginUsername, !(head.method == .post && (head.path ?? "").hasPrefix("/api/token/")) {
            let lifetime = TimeInterval(settings.sessionCookieAge)
            let result = try await write { db -> (AccessContext, Session)? in
                guard let user = try UserStore.user(named: username, in: db), user.isActive, let id = user.id,
                      let access = try AccessContext.load(userId: id, in: db) else { return nil }
                return (access, try UserStore.createSession(userId: id, lifetime: lifetime, in: db))
            }
            if let (access, session) = result {
                return Authentication(access: access, method: .session, session: session, isNewSession: true)
            }
        }
        return nil
    }

    /// `AUTO_LOGIN_USERNAME`: the user every request without credentials runs as. Never expose such a server.
    var autoLoginUsername: String? { Self.extraSetting("AUTO_LOGIN_USERNAME", settings: settings) }

    /// Django meta name (`HTTP_REMOTE_USER`) to the header name (`Remote-User`).
    var remoteUserHeaderName: HTTPField.Name? {
        var name = settings.httpRemoteUserHeaderName
        if name.uppercased().hasPrefix("HTTP_") { name = String(name.dropFirst(5)) }
        return HTTPField.Name(name.replacingOccurrences(of: "_", with: "-"))
    }

    private func basicAuthentication(_ encoded: String) async throws -> Authentication {
        guard let data = Data(base64Encoded: encoded.trimmingCharacters(in: .whitespaces)),
              let decoded = String(data: data, encoding: .utf8), let colon = decoded.firstIndex(of: ":") else {
            throw APIError.basicFailure("Invalid basic header. Credentials not correctly base64 encoded.")
        }
        let username = String(decoded[..<colon])
        let password = String(decoded[decoded.index(after: colon)...])
        let cache = credentialCache
        let secret = settings.secretKey
        let access = try await read { db -> AccessContext? in
            guard let user = try UserStore.user(named: username, in: db), let id = user.id,
                  user.isActive, !user.password.isEmpty else {
                _ = PasswordHasher.verify(password, encoded: "pbkdf2_sha256$\(PasswordHasher.defaultIterations)$timing$AAAA")
                return nil
            }
            let cacheKey = CredentialCache.key(username: username, password: password, secret: secret)
            if !cache.matches(cacheKey, passwordHash: user.password) {
                guard PasswordHasher.verify(password, encoded: user.password) else { return nil }
                cache.store(cacheKey, passwordHash: user.password)
            }
            // Paperless-ngx PaperlessBasicAuthentication: no Basic auth for accounts with two-factor authentication.
            if try MFAStore.isActive(userId: id, in: db) { throw APIError.basicFailure("MFA required") }
            return try AccessContext.load(userId: id, in: db)
        }
        guard let access else { throw APIError.basicFailure("Invalid username/password.") }
        return Authentication(access: access, method: .basic)
    }

    /// Django's CSRF check for session-authenticated unsafe requests.
    func checkCSRF(_ request: Request, session: Session?, formToken: String? = nil) throws {
        if let origin = request.headers[.origin], !isTrustedOrigin(origin, host: request.head.authority) {
            throw APIError.detail(.forbidden, "CSRF Failed: Origin checking failed - \(origin) does not match any trusted origins.")
        }
        guard let session else { throw APIError.detail(.forbidden, "CSRF Failed: CSRF token missing.") }
        guard let header = request.headers[HTTPField.Name("X-CSRFToken")!] ?? formToken, !header.isEmpty else {
            throw APIError.detail(.forbidden, "CSRF Failed: CSRF token missing.")
        }
        guard Self.constantTimeEqual(header, session.csrfToken) else {
            throw APIError.detail(.forbidden, "CSRF Failed: CSRF token incorrect.")
        }
    }

    func isTrustedOrigin(_ origin: String, host: String?) -> Bool {
        let normalized = origin.lowercased()
        if let host = host?.lowercased(), normalized == "http://\(host)" || normalized == "https://\(host)" { return true }
        var trusted = settings.csrfTrustedOrigins
        if let url = settings.url { trusted.append(url) }
        return trusted.contains { candidate in
            let value = candidate.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if value.contains("*"), let star = value.range(of: "*") {
                // https://*.example.com
                let prefix = value[..<star.lowerBound], suffix = value[star.upperBound...]
                return normalized.hasPrefix(prefix) && normalized.hasSuffix(suffix)
            }
            return value == normalized
        }
    }

    static func constantTimeEqual(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for (p, q) in zip(x, y) { difference |= p ^ q }
        return difference == 0
    }
}

extension APIError {
    static func basicFailure(_ message: String) -> APIError {
        var error = APIError.detail(.unauthorized, message)
        error.headers[.wwwAuthenticate] = "Basic realm=\"api\""
        return error
    }
}

/// Remembers recent successful Basic logins so each request does not pay for PBKDF2.
/// Entries are keyed by a keyed hash of the credentials and expire after five minutes,
/// or as soon as the stored password hash changes.
final class CredentialCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (hash: String, expires: Date)] = [:]
    static let lifetime: TimeInterval = 300

    static func key(username: String, password: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(username.count):\(username.lowercased()):\(password)".utf8), using: key)
        return Data(mac).base64EncodedString()
    }

    func matches(_ key: String, passwordHash: String) -> Bool {
        lock.withLock {
            guard let entry = entries[key] else { return false }
            guard entry.expires > Date(), entry.hash == passwordHash else {
                entries[key] = nil
                return false
            }
            return true
        }
    }

    func store(_ key: String, passwordHash: String) {
        lock.withLock {
            if entries.count > 1000 { entries = entries.filter { $0.value.expires > Date() } }
            entries[key] = (passwordHash, Date().addingTimeInterval(Self.lifetime))
        }
    }
}
