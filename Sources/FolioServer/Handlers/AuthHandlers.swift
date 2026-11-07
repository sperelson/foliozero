import Foundation
import FolioCore
import GRDB
import Hummingbird

extension API {
    // MARK: - Token

    /// `POST /api/token/`: username and password (form or JSON) for the user's API token.
    func obtainToken(_ request: APIRequest) async throws -> Response {
        if let wait = tokenThrottle.check(request.remoteAddress ?? "unknown") {
            var error = APIError.detail(.tooManyRequests, "Request was throttled. Expected available in \(wait) second\(wait == 1 ? "" : "s").")
            error.headers[.retryAfter] = String(wait)
            throw error
        }
        let data = try request.data()
        var errors = JSONObject()
        let username = data["username"]?.string ?? ""
        let password = data["password"]?.string ?? ""
        if username.isEmpty { errors["username"] = [data.has("username") ? "This field may not be blank." : "This field is required."] }
        if password.isEmpty { errors["password"] = [data.has("password") ? "This field may not be blank." : "This field is required."] }
        if !errors.isEmpty { throw APIError.validation(.object(errors)) }
        let code = data["code"]?.string
        let token = try await write { db -> String? in
            guard let user = try UserStore.authenticate(username: username, password: password, in: db), let id = user.id else { return nil }
            // Paperless-ngx PaperlessAuthTokenSerializer: users with two-factor authentication add `code`.
            if try MFAStore.isActive(userId: id, in: db) {
                guard let code, !code.isEmpty else { throw APIError.nonField("MFA code is required") }
                guard try MFAStore.verify(userId: id, code: code, in: db) else { throw APIError.nonField("Invalid MFA code") }
            }
            return try UserStore.token(for: id, in: db)
        }
        guard let token else { throw APIError.nonField("Unable to log in with provided credentials.") }
        return .json(["token": .string(token)])
    }

    // MARK: - Profile

    func profileJSON(_ user: User, token: String?, mfa: Bool, socialAccounts: JSON = []) -> JSON {
        [
            "email": .string(user.email),
            "password": .string(String(repeating: "*", count: max(10, user.password.count))),
            "first_name": .string(user.firstName),
            "last_name": .string(user.lastName),
            "auth_token": JSON(token),
            "social_accounts": socialAccounts,
            "has_usable_password": .bool(!user.password.isEmpty),
            "is_mfa_enabled": .bool(mfa),
        ]
    }

    func getProfile(_ request: APIRequest) async throws -> Response {
        let userId = request.userId
        let (user, token, mfa, social) = try await read { db -> (User, String?, Bool, JSON) in
            guard let user = try User.fetchOne(db, key: userId) else { throw APIError.notAuthenticated }
            let token = try AuthToken.filter(Column("user_id") == userId).fetchOne(db)?.key
            return (user, token, try MFAStore.isActive(userId: userId, in: db), try self.socialAccountsJSON(userId: userId, in: db))
        }
        return .json(profileJSON(user, token: token, mfa: mfa, socialAccounts: social))
    }

    func patchProfile(_ request: APIRequest) async throws -> Response {
        let data = try request.data()
        let userId = request.userId
        if let email = data["email"]?.string, !email.isEmpty, !Self.isValidEmail(email) {
            throw APIError.field("email", "Enter a valid email address.")
        }
        for key in ["first_name", "last_name"] {
            if let value = data[key]?.string, value.count > 150 {
                throw APIError.field(key, "Ensure this field has no more than 150 characters.")
            }
        }
        let (user, token, mfa, social) = try await write { db -> (User, String?, Bool, JSON) in
            guard var user = try User.fetchOne(db, key: userId) else { throw APIError.notAuthenticated }
            if let email = data["email"]?.string { user.email = email }
            if let first = data["first_name"]?.string { user.firstName = first }
            if let last = data["last_name"]?.string { user.lastName = last }
            try user.update(db)
            if let password = data["password"]?.string, !password.replacingOccurrences(of: "*", with: "").isEmpty {
                try UserStore.setPassword(userId: userId, password: password, in: db)
                user = try User.fetchOne(db, key: userId) ?? user
            }
            let token = try AuthToken.filter(Column("user_id") == userId).fetchOne(db)?.key
            return (user, token, try MFAStore.isActive(userId: userId, in: db), try self.socialAccountsJSON(userId: userId, in: db))
        }
        return .json(profileJSON(user, token: token, mfa: mfa, socialAccounts: social))
    }

    func generateToken(_ request: APIRequest) async throws -> Response {
        let userId = request.userId
        let token = try await write { db in try UserStore.regenerateToken(for: userId, in: db) }
        return .json(.string(token))
    }

    static func isValidEmail(_ email: String) -> Bool {
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."), !parts[1].hasPrefix("."), !parts[1].hasSuffix(".") else { return false }
        return !email.contains(" ")
    }

    // MARK: - UI settings

    func getUISettings(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, "uisettings")
        let userId = request.userId
        let (stored, appConfig) = try await read { db -> (JSON, JSON) in
            let text = try String.fetchOne(db, sql: "SELECT settings FROM ui_settings WHERE user_id = ?", arguments: [userId])
            let config = try String.fetchOne(db, sql: "SELECT config FROM app_config WHERE id = 1")
            return ((text.flatMap { try? JSON.parse($0) }) ?? .object(JSONObject()), (config.flatMap { try? JSON.parse($0) }) ?? .object(JSONObject()))
        }
        var settingsObject = stored.object ?? JSONObject()
        // FolioZero has no update check. Reporting it as switched off hides the frontend's
        // prompt and stops its `/api/remote_version/` calls, whatever the user stored before.
        settingsObject["update_checking"] = ["enabled": false, "backend_setting": "false"]
        settingsObject["trash_delay"] = .int(settings.emptyTrashDelayDays)
        settingsObject["version"] = .string(reportedVersion)
        var title = JSON(settings.appTitle)
        if let configured = appConfig["app_title"]?.string, !configured.isEmpty { title = .string(configured) }
        settingsObject["app_title"] = title
        var logo = JSON(settings.appLogo)
        if let configured = appConfig["app_logo"]?.string, !configured.isEmpty { logo = .string(configured) }
        settingsObject["app_logo"] = logo
        settingsObject["auditlog_enabled"] = .bool(settings.auditLogEnabled)
        // Whether the UI may offer remote OCR (reprocess dialog, workflow action), and in which mode.
        let remoteOCR = app.remoteOCRConfig()
        settingsObject["remote_ocr"] = ["configured": .bool(remoteOCR.isConfigured), "mode": .string(remoteOCR.mode.rawValue)]
        settingsObject["email_enabled"] = .bool(settings.emailHost != nil)
        settingsObject["ai_enabled"] = .bool(aiEnabled())
        addMailOAuthURLs(to: &settingsObject, request: request)

        let user = access.user
        var userObject = JSONObject([
            ("id", .int(user.id ?? 0)), ("username", .string(user.username)),
            ("is_staff", .bool(user.isStaff)), ("is_superuser", .bool(user.isSuperuser)),
            ("groups", JSON(access.groupIds.sorted())),
        ])
        if !user.firstName.isEmpty { userObject["first_name"] = .string(user.firstName) }
        if !user.lastName.isEmpty { userObject["last_name"] = .string(user.lastName) }

        let permissions = access.isSuperuser ? Permission.all : access.permissions.sorted()
        return .json([
            "user": .object(userObject),
            "settings": .object(settingsObject),
            "permissions": JSON(permissions),
        ])
    }

    func postUISettings(_ request: APIRequest) async throws -> Response {
        try request.access.require(.add, "uisettings")
        let data = try request.data()
        var value = data["settings"] ?? .object(JSONObject())
        if !value.isNull, value.object == nil {
            throw APIError.field("settings", "Expected a dictionary of items but got type \"\(value.typeName)\".")
        }
        // The server owns `update_checking` (always off), so it is never stored.
        if var object = value.object, object["update_checking"] != nil {
            object["update_checking"] = nil
            value = .object(object)
        }
        let text = value.isNull ? "{}" : value.serialized()
        let userId = request.userId
        try await write { db in
            try db.execute(sql: """
                INSERT INTO ui_settings(user_id, settings) VALUES (?, ?)
                ON CONFLICT(user_id) DO UPDATE SET settings = excluded.settings
                """, arguments: [userId, text])
        }
        return .json(["success": true])
    }

    /// Stored UI settings of a user (saved view visibility for API v9).
    func storedUISettings(userId: Int, in db: Database) throws -> JSONObject {
        let text = try String.fetchOne(db, sql: "SELECT settings FROM ui_settings WHERE user_id = ?", arguments: [userId])
        return text.flatMap { try? JSON.parse($0) }?.object ?? JSONObject()
    }

    // MARK: - Browser login

    /// `/`: FolioZero has no web UI yet; show who is signed in, or go to the login page.
    func homePage(_ request: APIRequest) async throws -> Response {
        if frontendDir != nil { return try await frontendIndex(request) }
        guard let auth = request.auth else { return .redirect("/accounts/login/?next=/") }
        let title = Self.htmlEscape(displayTitle)
        let html = """
            <!doctype html>
            <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(title)</title>
            <style>body{font-family:-apple-system,system-ui,sans-serif;max-width:32rem;margin:4rem auto;padding:0 1rem}</style></head>
            <body><h1>\(title)</h1><p>Signed in as \(Self.htmlEscape(auth.access.user.username)).</p>
            <p><a href="/api/">REST API</a></p>
            <form method="post" action="/accounts/logout/">
            <input type="hidden" name="csrfmiddlewaretoken" value="\(Self.htmlEscape(auth.session?.csrfToken ?? ""))">
            <button type="submit">Sign out</button></form></body></html>
            """
        return .text(html)
    }

    func loginPage(_ request: APIRequest, error: String? = nil) async throws -> Response {
        if frontendDir != nil { return .text(styledLoginPage(request, error: error), status: error == nil ? .ok : .badRequest) }
        let next = Self.safeRedirect(request.query["next"]) ?? "/"
        let escapedNext = Self.htmlEscape(next)
        let message = error.map { "<p class=\"error\">\(Self.htmlEscape($0))</p>" } ?? ""
        let title = Self.htmlEscape(displayTitle)
        // PAPERLESS_DISABLE_REGULAR_LOGIN hides the password form; the provider buttons stay.
        let form = social.disableRegularLogin ? "" : """
            <form method="post" action="/accounts/login/">
            <input type="hidden" name="next" value="\(escapedNext)">
            <label>Username <input name="login" autocomplete="username" required autofocus></label>
            <label>Password <input name="password" type="password" autocomplete="current-password" required></label>
            <button type="submit">Sign in</button></form>
            """
        let html = """
            <!doctype html>
            <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
            <title>\(title) sign in</title>
            <style>body{font-family:-apple-system,system-ui,sans-serif;max-width:22rem;margin:4rem auto;padding:0 1rem}
            label{display:block;margin-top:1rem}input{width:100%;padding:.5rem;box-sizing:border-box}
            button{margin-top:1.5rem;padding:.5rem 1rem}.error{color:#b00020}ul{list-style:none}</style></head>
            <body><h1>\(title)</h1>\(message)
            \(form)
            \(socialLoginButtons(request))</body></html>
            """
        return .text(html, status: error == nil ? .ok : .badRequest)
    }

    func login(_ request: APIRequest) async throws -> Response {
        let data = try request.data()
        let wantsJSON = !data.isForm
        if let wait = tokenThrottle.check("login:" + (request.remoteAddress ?? "unknown")) {
            throw APIError.detail(.tooManyRequests, "Request was throttled. Expected available in \(wait) seconds.")
        }
        let lifetime = TimeInterval(settings.sessionCookieAge)

        // Second step of the HTML login: the authenticator or recovery code.
        if let token = data["mfa_token"]?.string, !token.isEmpty {
            guard let pending = pendingLogins.get(token) else {
                return try await loginPage(request, error: "Your sign-in attempt expired. Please sign in again.")
            }
            let code = data["code"]?.string ?? ""
            let result = try await write { db -> (User, Session)? in
                guard try MFAStore.verify(userId: pending.userId, code: code, in: db), let user = try User.fetchOne(db, key: pending.userId),
                      user.isActive else { return nil }
                return (user, try UserStore.createSession(userId: pending.userId, lifetime: lifetime, in: db))
            }
            guard let (_, session) = result else {
                return .text(mfaPage(token: token, error: "Incorrect code."), status: .badRequest)
            }
            pendingLogins.remove(token)
            return sessionResponse(.redirect(pending.next ?? "/"), session: session)
        }

        // Paperless-ngx `CustomAccountAdapter.pre_authenticate`. Tokens, Basic auth and /api/token/ keep working.
        if social.disableRegularLogin {
            if wantsJSON { throw APIError.nonField("Regular login is disabled") }
            return try await loginPage(request, error: "Regular login is disabled")
        }
        let username = data["login"]?.string ?? data["username"]?.string ?? ""
        let password = data["password"]?.string ?? ""
        let code = data["code"]?.string
        enum Outcome: Sendable { case failed, needsCode(Int), invalidCode, signedIn(User, Session) }
        let outcome = try await write { db -> Outcome in
            guard !username.isEmpty, !password.isEmpty,
                  let user = try UserStore.authenticate(username: username, password: password, in: db), let id = user.id else { return .failed }
            if try MFAStore.isActive(userId: id, in: db) {
                guard wantsJSON, let code else { return .needsCode(id) }
                guard try MFAStore.verify(userId: id, code: code, in: db) else { return .invalidCode }
            }
            return .signedIn(user, try UserStore.createSession(userId: id, lifetime: lifetime, in: db))
        }
        switch outcome {
        case .failed:
            if wantsJSON { throw APIError.nonField("The username and/or password you specified are not correct.") }
            return try await loginPage(request, error: "The username and/or password you specified are not correct.")
        case .needsCode(let userId):
            if wantsJSON { throw APIError.nonField("MFA code is required") }
            let token = PasswordHasher.randomString(length: 40)
            pendingLogins.set(token, PendingLogin(userId: userId, next: Self.safeRedirect(data["next"]?.string)))
            return .text(mfaPage(token: token, error: nil))
        case .invalidCode:
            throw APIError.nonField("Invalid MFA code")
        case .signedIn(let user, let session):
            if wantsJSON {
                return sessionResponse(.json(["id": JSON(user.id), "username": .string(user.username), "csrf_token": .string(session.csrfToken)]), session: session)
            }
            return sessionResponse(.redirect(Self.safeRedirect(data["next"]?.string) ?? "/"), session: session)
        }
    }

    /// Adds the session and CSRF cookies.
    func sessionResponse(_ response: Response, session: Session) -> Response {
        var response = response
        response.setCookie(Cookie(name: sessionCookieName, value: session.key, maxAge: settings.sessionCookieAge, path: "/", httpOnly: true, sameSite: .lax))
        response.setCookie(Cookie(name: csrfCookieName, value: session.csrfToken, maxAge: settings.sessionCookieAge, path: "/", httpOnly: false, sameSite: .lax))
        return response
    }

    func logout(_ request: APIRequest) async throws -> Response {
        if let cookieHeader = request.header("Cookie") {
            let cookies = Cookies(from: [cookieHeader])
            if let key = cookies[sessionCookieName]?.value, !key.isEmpty {
                try await write { db in try UserStore.deleteSession(key: key, in: db) }
            }
        }
        let isAPI = request.path.hasPrefix("/api/")
        // Paperless-ngx LOGOUT_REDIRECT_URL; `loggedout=1` keeps REDIRECT_LOGIN_TO_SSO from signing straight back in.
        let afterLogout = Self.safeRedirect(request.query["next"]) ?? social.logoutRedirectURL ?? "/accounts/login/?loggedout=1"
        var response: Response = isAPI ? .json(["detail": "Logged out."]) : .redirect(afterLogout)
        response.setCookie(Cookie(name: sessionCookieName, value: "", maxAge: 0, path: "/", httpOnly: true, sameSite: .lax))
        response.setCookie(Cookie(name: csrfCookieName, value: "", maxAge: 0, path: "/", httpOnly: false, sameSite: .lax))
        return response
    }

    /// Only same-site absolute paths, never `//host` or schemes.
    static func safeRedirect(_ target: String?) -> String? {
        guard let target, target.hasPrefix("/"), !target.hasPrefix("//"), !target.contains("\\"),
              !target.contains("\r"), !target.contains("\n") else { return nil }
        return target
    }

    static func htmlEscape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#x27;")
    }
}
