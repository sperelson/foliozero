import Foundation
import GRDB

/// OAuth 2 for Gmail and Outlook mail accounts (Paperless-ngx `paperless_mail/oauth.py`).
///
/// Builds the consent URLs, exchanges the callback code for tokens and refreshes expired
/// access tokens. Error messages never contain a token or a client secret.
public struct MailOAuth: Sendable {
    public enum Provider: String, Sendable, CaseIterable {
        case gmail, outlook
    }

    /// Sends one HTTP request. Tests replace it; the default uses an ephemeral `URLSession`.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// A token endpoint answer.
    public struct Token: Sendable, Equatable {
        public var accessToken: String
        /// Gmail sends one only with the first grant; Outlook sends a new one on every refresh.
        public var refreshToken: String?
        public var expiresIn: Int?

        public init(accessToken: String, refreshToken: String?, expiresIn: Int?) {
            self.accessToken = accessToken; self.refreshToken = refreshToken; self.expiresIn = expiresIn
        }
    }

    // The endpoints of httpx-oauth's GoogleOAuth2 and MicrosoftGraphOAuth2 (tenant "common").
    static let gmailAuthorizeEndpoint = "https://accounts.google.com/o/oauth2/v2/auth"
    static let gmailTokenEndpoint = "https://oauth2.googleapis.com/token"
    static let outlookAuthorizeEndpoint = "https://login.microsoftonline.com/common/oauth2/v2.0/authorize"
    static let outlookTokenEndpoint = "https://login.microsoftonline.com/common/oauth2/v2.0/token"

    /// Where the callback sends the browser (Paperless-ngx `oauth_redirect_url` without DEBUG).
    public static let redirectPath = "/mail"

    /// `OAUTH_CALLBACK_BASE_URL`, else `URL`.
    public let callbackBaseURL: String?
    let gmailClientId: String?
    let gmailClientSecret: String?
    let outlookClientId: String?
    let outlookClientSecret: String?
    let transport: Transport

    public init(settings: Settings, transport: Transport? = nil) {
        func value(_ key: String) -> String? {
            guard let raw = settings.raw[key]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
            return raw
        }
        callbackBaseURL = value("OAUTH_CALLBACK_BASE_URL") ?? settings.url
        gmailClientId = value("GMAIL_OAUTH_CLIENT_ID")
        gmailClientSecret = value("GMAIL_OAUTH_CLIENT_SECRET")
        outlookClientId = value("OUTLOOK_OAUTH_CLIENT_ID")
        outlookClientSecret = value("OUTLOOK_OAUTH_CLIENT_SECRET")
        self.transport = transport ?? Self.urlSessionTransport
    }

    /// Paperless-ngx `GMAIL_OAUTH_ENABLED` and `OUTLOOK_OAUTH_ENABLED`: a callback base URL,
    /// a client id and a client secret.
    public func isEnabled(_ provider: Provider) -> Bool {
        callbackBaseURL != nil && credentials(provider) != nil
    }

    public var isAnyEnabled: Bool { Provider.allCases.contains(where: isEnabled) }

    /// `<base>/api/oauth/callback/`, the redirect URI to register with Google and Microsoft.
    public var callbackURL: String? {
        guard var base = callbackBaseURL else { return nil }
        while base.hasSuffix("/") { base.removeLast() }
        return base + "/api/oauth/callback/"
    }

    /// A new state value, like Python's `secrets.token_urlsafe(32)`.
    public static func makeState() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    /// The provider's consent page, with the parameters httpx-oauth sends. Nil when not configured.
    public func authorizationURL(_ provider: Provider, state: String) -> String? {
        guard isEnabled(provider), let (clientId, _) = credentials(provider), let callbackURL else { return nil }
        var params: [(String, String)] = [
            ("response_type", "code"), ("client_id", clientId), ("redirect_uri", callbackURL), ("state", state),
        ]
        switch provider {
        case .gmail:
            params += [("scope", "https://mail.google.com/"), ("prompt", "consent"), ("access_type", "offline")]
            return Self.gmailAuthorizeEndpoint + "?" + Self.formEncode(params)
        case .outlook:
            params += [("scope", "offline_access https://outlook.office.com/IMAP.AccessAsUser.All"), ("response_mode", "query")]
            return Self.outlookAuthorizeEndpoint + "?" + Self.formEncode(params)
        }
    }

    /// Exchanges the code from the callback for tokens.
    public func exchange(code: String, provider: Provider) async throws -> Token {
        guard let callbackURL else { throw MailOAuthError.notConfigured(provider) }
        return try await tokenRequest(provider, [("grant_type", "authorization_code"), ("code", code), ("redirect_uri", callbackURL)])
    }

    /// A new access token from a refresh token.
    public func refresh(refreshToken: String, provider: Provider) async throws -> Token {
        try await tokenRequest(provider, [("grant_type", "refresh_token"), ("refresh_token", refreshToken)])
    }

    /// Paperless-ngx `refresh_account_oauth_token`: refreshes the access token, keeps a new
    /// refresh token when the provider sends one, and saves the account. Returns the saved account.
    public func refreshAccessToken(of account: MailAccount, in database: FolioDatabase, now: Date = Date()) async throws -> MailAccount {
        guard let refreshToken = account.config.refreshToken, !refreshToken.isEmpty else { throw MailOAuthError.noRefreshToken }
        guard let provider = account.config.accountType.oauthProvider else { throw MailOAuthError.notOAuthAccount }
        let token = try await refresh(refreshToken: refreshToken, provider: provider)
        var refreshed = account
        refreshed.config.password = token.accessToken
        if let newRefreshToken = token.refreshToken { refreshed.config.refreshToken = newRefreshToken }
        refreshed.config.expiration = token.expiresIn.map { now.addingTimeInterval(TimeInterval($0)) }
        guard let id = account.id else { return refreshed }
        let fresh = refreshed
        return try await database.write { db -> MailAccount in
            guard var stored = try MailAccount.fetchOne(db, key: id) else { return fresh }
            stored.config.password = fresh.config.password
            stored.config.refreshToken = fresh.config.refreshToken
            stored.config.expiration = fresh.config.expiration
            try stored.update(db)
            return stored
        }
    }

    // MARK: Token endpoint

    private func credentials(_ provider: Provider) -> (id: String, secret: String)? {
        switch provider {
        case .gmail: gmailClientId.flatMap { id in gmailClientSecret.map { (id, $0) } }
        case .outlook: outlookClientId.flatMap { id in outlookClientSecret.map { (id, $0) } }
        }
    }

    /// POSTs a form with the client credentials in the body (`client_secret_post`).
    private func tokenRequest(_ provider: Provider, _ fields: [(String, String)]) async throws -> Token {
        guard let (clientId, clientSecret) = credentials(provider) else { throw MailOAuthError.notConfigured(provider) }
        let endpoint = provider == .gmail ? Self.gmailTokenEndpoint : Self.outlookTokenEndpoint
        var request = URLRequest(url: URL(string: endpoint)!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.formEncode(fields + [("client_id", clientId), ("client_secret", clientSecret)]).utf8)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch {
            throw MailOAuthError.requestFailed("\(provider) token endpoint unreachable: \(error.localizedDescription)")
        }
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            // OAuth 2 errors carry `error` and `error_description`, never a token.
            let code = (object?["error"] as? String).map { " (\($0))" } ?? ""
            let detail = (object?["error_description"] as? String).map { ": " + String($0.prefix(200)) } ?? ""
            throw MailOAuthError.requestFailed("\(provider) token endpoint answered HTTP \(http.statusCode)\(code)\(detail)")
        }
        guard let object else { throw MailOAuthError.requestFailed("\(provider) token endpoint sent invalid JSON content") }
        guard let accessToken = object["access_token"] as? String, !accessToken.isEmpty else {
            throw MailOAuthError.requestFailed("\(provider) token endpoint sent no access token")
        }
        let expiresIn = (object["expires_in"] as? NSNumber)?.intValue ?? (object["expires_in"] as? String).flatMap { Int($0) }
        return Token(accessToken: accessToken, refreshToken: object["refresh_token"] as? String, expiresIn: expiresIn)
    }

    /// Python's `urlencode`: `quote_plus` on names and values.
    static func formEncode(_ pairs: [(String, String)]) -> String {
        pairs.map { "\(formEscape($0.0))=\(formEscape($0.1))" }.joined(separator: "&")
    }

    private static let formAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~ ")

    static func formEscape(_ text: String) -> String {
        (text.addingPercentEncoding(withAllowedCharacters: formAllowed) ?? text).replacingOccurrences(of: " ", with: "+")
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    public static let urlSessionTransport: Transport = { request in try await session.data(for: request) }
}

public enum MailOAuthError: Error, CustomStringConvertible, Equatable {
    case notConfigured(MailOAuth.Provider)
    case notOAuthAccount
    case noRefreshToken
    case requestFailed(String)

    public var description: String {
        switch self {
        case .notConfigured(let provider): "OAuth for \(provider) is not configured"
        case .notOAuthAccount: "The account does not use OAuth"
        case .noRefreshToken: "The account has no refresh token to use"
        case .requestFailed(let detail): detail
        }
    }
}

extension MailAccount.AccountType {
    /// The OAuth provider of Gmail and Outlook accounts; nil for plain IMAP.
    public var oauthProvider: MailOAuth.Provider? {
        switch self {
        case .imap: nil
        case .gmailOAuth: .gmail
        case .outlookOAuth: .outlook
        }
    }
}

extension MailAccount.Config {
    /// Token accounts whose access token has expired (Paperless-ngx checks this before logging in).
    public func needsTokenRefresh(now: Date = Date()) -> Bool {
        guard isToken, let expiration else { return false }
        return expiration < now
    }
}

extension IMAPClient {
    /// Paperless-ngx `mailbox_login`: XOAUTH2 for token accounts, LOGIN otherwise.
    public func login(account config: MailAccount.Config) async throws {
        if config.isToken {
            try await authenticateXOAUTH2(username: config.username, accessToken: config.password)
        } else {
            try await login(username: config.username, password: config.password)
        }
    }
}
