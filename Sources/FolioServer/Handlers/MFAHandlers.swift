import Foundation
import FolioCore
import GRDB
import Hummingbird

/// Short-lived values keyed by a string (pending TOTP secrets, half-finished logins).
final class ExpiringStore<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (value: Value, expires: Date)] = [:]
    let lifetime: TimeInterval

    init(lifetime: TimeInterval) { self.lifetime = lifetime }

    func set(_ key: String, _ value: Value) {
        lock.withLock {
            let now = Date()
            if entries.count > 1000 { entries = entries.filter { $0.value.expires > now } }
            entries[key] = (value, now.addingTimeInterval(lifetime))
        }
    }

    func get(_ key: String) -> Value? {
        lock.withLock {
            guard let entry = entries[key], entry.expires > Date() else { entries[key] = nil; return nil }
            return entry.value
        }
    }

    func remove(_ key: String) { lock.withLock { entries[key] = nil } }
}

/// A login that passed the password check and waits for the TOTP or recovery code.
struct PendingLogin: Sendable {
    var userId: Int
    var next: String?
}

/// Two-factor authentication (Paperless-ngx `TOTPView`, `deactivate_totp`, allauth MFA login stage).
extension API {
    /// `GET /api/profile/totp/`: a new secret (kept for this user until activation), its URL and QR code.
    func getTOTPSetup(_ request: APIRequest) async throws -> Response {
        let user = request.access.user
        let secret = TOTP.newSecret()
        pendingTOTPSecrets.set(String(request.userId), secret)
        let url = TOTP.url(secret: secret, username: user.username, issuer: settings.appTitle ?? "FolioZero")
        return .json(["url": .string(url), "qr_svg": JSON(TOTP.qrSVG(for: url)), "secret": .string(secret)])
    }

    /// `POST /api/profile/totp/` `{secret, code}`: activates TOTP; returns `{success, recovery_codes}`.
    func activateTOTP(_ request: APIRequest) async throws -> Response {
        let data = try request.data()
        let userId = request.userId
        let secret = data["secret"]?.string ?? ""
        let code = (data["code"]?.string ?? "").filter { !$0.isWhitespace }
        guard let pending = pendingTOTPSecrets.get(String(userId)), Self.constantTimeEqual(pending, secret) else {
            return .json(["success": false, "recovery_codes": .null])
        }
        let codes = try await write { db -> [String]? in
            do { return try MFAStore.activate(userId: userId, secret: secret, code: code, in: db) } catch is MFAStore.MFAError { return nil }
        }
        if codes != nil { pendingTOTPSecrets.remove(String(userId)) }
        return .json(["success": .bool(codes != nil), "recovery_codes": codes.map { JSON($0) } ?? .null])
    }

    /// `DELETE /api/profile/totp/`.
    func deleteTOTP(_ request: APIRequest) async throws -> Response {
        let userId = request.userId
        let removed = try await write { db -> Bool in
            guard try MFAStore.isActive(userId: userId, in: db) else { return false }
            try MFAStore.deactivate(userId: userId, in: db)
            return true
        }
        guard removed else { throw APIError(status: .notFound, body: .text("TOTP not found")) }
        return .json(true)
    }

    /// `POST /api/users/{id}/deactivate_totp/`: the user themself or a superuser.
    func deactivateUserTOTP(_ request: APIRequest) async throws -> Response {
        let access = request.access
        let id = try request.intParam("id")
        guard access.isSuperuser || access.userId == id else {
            throw APIError.forbiddenText("You do not have permission to deactivate TOTP for this user")
        }
        let removed = try await write { db -> Bool in
            guard try User.fetchOne(db, key: id) != nil else { throw APIError.notFound("User") }
            guard try MFAStore.isActive(userId: id, in: db) else { return false }
            try MFAStore.deactivate(userId: id, in: db)
            return true
        }
        guard removed else { throw APIError(status: .notFound, body: .text("TOTP not found")) }
        return .json(true)
    }

    /// The code step of the HTML login.
    func mfaPage(token: String, error: String?) -> String {
        let title = Self.htmlEscape(displayTitle)
        let alert = error.map { "<div class=\"alert alert-danger\" role=\"alert\">\(Self.htmlEscape($0))</div>" } ?? ""
        let styles = frontendDir != nil
            ? "<link href=\"/static/bootstrap.min.css\" rel=\"stylesheet\"><link href=\"/static/base.css\" rel=\"stylesheet\">"
            : "<style>body{font-family:-apple-system,system-ui,sans-serif;max-width:22rem;margin:4rem auto;padding:0 1rem}input{width:100%;padding:.5rem;box-sizing:border-box}button{margin-top:1.5rem;padding:.5rem 1rem}.alert{color:#b00020}</style>"
        return """
            <!doctype html>
            <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <meta name="robots" content="noindex,nofollow"><title>\(title) two-factor authentication</title>\(styles)</head>
            <body class="text-center"><div class="position-absolute top-50 start-50 translate-middle">
            <form class="form-accounts" method="post" action="/accounts/login/">
            <h1 class="font-weight-normal text-primary mb-4">\(title)</h1>\(alert)
            <p>Your account is protected by two-factor authentication. Please enter an authenticator code or a recovery code.</p>
            <input type="hidden" name="mfa_token" value="\(Self.htmlEscape(token))">
            <div class="form-floating"><input class="form-control" name="code" id="inputCode" placeholder="Code" autocomplete="one-time-code" inputmode="numeric" required autofocus>
            <label for="inputCode">Code</label></div>
            <div class="d-grid mt-3"><button class="btn btn-lg btn-primary" type="submit">Sign in</button></div>
            </form></div></body></html>
            """
    }
}
