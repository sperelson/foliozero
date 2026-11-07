import Foundation
import FolioCore
import GRDB
import Hummingbird

/// Gmail and Outlook OAuth for mail accounts (Paperless-ngx `OauthCallbackView` and the
/// OAuth part of `UiSettingsView`).
extension API {
    /// Where the OAuth state lives: the session, else the user (token, Basic or remote-user requests).
    func mailOAuthStateKey(_ request: APIRequest) -> String {
        if let session = request.auth?.session { return "session:" + session.key }
        return "user:\(request.userId)"
    }

    /// Adds `gmail_oauth_url` and `outlook_oauth_url` for the configured providers and keeps
    /// their new state for the callback.
    func addMailOAuthURLs(to settingsObject: inout JSONObject, request: APIRequest) {
        guard mailOAuth.isAnyEnabled else { return }
        let state = MailOAuth.makeState()
        if let url = mailOAuth.authorizationURL(.gmail, state: state) { settingsObject["gmail_oauth_url"] = .string(url) }
        if let url = mailOAuth.authorizationURL(.outlook, state: state) { settingsObject["outlook_oauth_url"] = .string(url) }
        mailOAuthStates.set(mailOAuthStateKey(request), state)
    }

    /// `GET /api/oauth/callback/`: the provider sends the browser back here with a code. Creates
    /// the mail account and redirects to the mail page, which opens it for editing.
    func mailOAuthCallback(_ request: APIRequest) async throws -> Response {
        let access = request.access
        guard access.has(.add, MailAccount.objectType) else {
            throw APIError.badRequestText("You do not have permission to add mail accounts")
        }
        let invalid = APIError.badRequestText("Invalid request, see logs for more detail")
        guard let code = request.query["code"] else {
            logger.error("Invalid oauth callback request: missing code")
            throw invalid
        }
        let state = request.query["state"] ?? ""
        guard let expected = mailOAuthStates.get(mailOAuthStateKey(request)), !state.isEmpty, Self.constantTimeEqual(state, expected) else {
            logger.error("Invalid oauth callback request: state validation failed")
            throw invalid
        }

        // Gmail sends the scope back, Outlook does not.
        let provider: MailOAuth.Provider
        let scope = request.query["scope"]
        if let scope, scope.contains("google") {
            provider = .gmail
        } else if scope == nil {
            provider = .outlook
        } else {
            logger.error("Invalid oauth callback request: unrecognized scope \(String(reflecting: scope ?? ""))")
            throw invalid
        }

        let token: MailOAuth.Token
        do {
            token = try await mailOAuth.exchange(code: code, provider: provider)
        } catch {
            logger.error("Error getting access token from OAuth provider: \(error)")
            return .redirect("\(MailOAuth.redirectPath)?oauth_success=0")
        }

        let now = Date()
        let isGmail = provider == .gmail
        var config = MailAccount.Config(imapServer: isGmail ? "imap.gmail.com" : "outlook.office365.com", imapPort: 993,
                                        imapSecurity: .ssl, username: "", password: token.accessToken)
        config.isToken = true
        config.accountType = isGmail ? .gmailOAuth : .outlookOAuth
        config.refreshToken = token.refreshToken
        config.expiration = token.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
        let account = MailAccount(name: "\(isGmail ? "Gmail" : "Outlook") OAuth \(Self.pythonTimestamp(now))", ownerId: access.user.id, config: config)
        let id = try await write { db -> Int in
            var account = account
            try account.insert(db)
            return account.id!
        }
        logger.info("Mail account \(account.name) connected through OAuth")
        return .redirect("\(MailOAuth.redirectPath)?oauth_success=1&account_id=\(id)")
    }

    /// Python's `str(timezone.now())`, which Paperless-ngx puts in the new account's name.
    static func pythonTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSS'+00:00'"
        return formatter.string(from: date)
    }
}
