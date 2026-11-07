import Foundation
import GRDB
import Testing
@testable import FolioCore

/// Stands in for the Google and Microsoft token endpoints and records each request.
final class TokenEndpointStub: @unchecked Sendable {
    struct Call {
        var url: String
        var method: String
        var headers: [String: String]
        var form: [String: String]
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    private var status: Int
    private var body: String

    init(status: Int = 200, body: String) {
        self.status = status
        self.body = body
    }

    var calls: [Call] { lock.withLock { recorded } }

    func answer(status: Int, body: String) {
        lock.withLock { self.status = status; self.body = body }
    }

    var transport: MailOAuth.Transport {
        { request in
            let form = Dictionary(uniqueKeysWithValues: String(decoding: request.httpBody ?? Data(), as: UTF8.self)
                .split(separator: "&").map { pair -> (String, String) in
                    let parts = pair.split(separator: "=", maxSplits: 1).map {
                        $0.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
                    }
                    return (parts[0], parts.count > 1 ? parts[1] : "")
                })
            let call = Call(url: request.url?.absoluteString ?? "", method: request.httpMethod ?? "",
                            headers: request.allHTTPHeaderFields ?? [:], form: form)
            let (status, body) = self.lock.withLock { () -> (Int, String) in
                self.recorded.append(call)
                return (self.status, self.body)
            }
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json"])!
            return (Data(body.utf8), response)
        }
    }
}

@Suite struct MailOAuthTests {
    static let configured = [
        "OAUTH_CALLBACK_BASE_URL": "http://localhost:8000",
        "GMAIL_OAUTH_CLIENT_ID": "test_gmail_client_id", "GMAIL_OAUTH_CLIENT_SECRET": "test_gmail_client_secret",
        "OUTLOOK_OAUTH_CLIENT_ID": "test_outlook_client_id", "OUTLOOK_OAUTH_CLIENT_SECRET": "test_outlook_client_secret",
    ]

    func settings(_ dir: TempDir, environment: [String: String] = [:], overrides: [String: String] = [:]) throws -> Settings {
        try SettingsLoader.load(home: dir.url.path, environment: environment, overrides: overrides.merging(["TIME_ZONE": "UTC"]) { a, _ in a })
    }

    // MARK: Settings and URLs

    @Test func enabledOnlyWithCallbackBaseAndCredentials() throws {
        let dir = TempDir()
        #expect(!MailOAuth(settings: try settings(dir)).isAnyEnabled)
        // A client id without its secret is not enough.
        #expect(!MailOAuth(settings: try settings(dir, overrides: ["URL": "http://x.example", "GMAIL_OAUTH_CLIENT_ID": "id"])).isAnyEnabled)
        // Credentials without OAUTH_CALLBACK_BASE_URL or URL are not enough.
        #expect(!MailOAuth(settings: try settings(dir, overrides: ["GMAIL_OAUTH_CLIENT_ID": "id", "GMAIL_OAUTH_CLIENT_SECRET": "s"])).isAnyEnabled)

        let gmailOnly = MailOAuth(settings: try settings(dir, overrides: ["URL": "https://paperless.example.com", "GMAIL_OAUTH_CLIENT_ID": "id", "GMAIL_OAUTH_CLIENT_SECRET": "s"]))
        #expect(gmailOnly.isEnabled(.gmail))
        #expect(!gmailOnly.isEnabled(.outlook))
        #expect(gmailOnly.authorizationURL(.outlook, state: "x") == nil)
        #expect(gmailOnly.callbackURL == "https://paperless.example.com/api/oauth/callback/")

        // PAPERLESS_ names work; FOLIOZERO_ names and OAUTH_CALLBACK_BASE_URL win.
        let environment = [
            "PAPERLESS_URL": "https://paperless.example.com", "PAPERLESS_OAUTH_CALLBACK_BASE_URL": "https://old.example.com",
            "FOLIOZERO_OAUTH_CALLBACK_BASE_URL": "https://mail.example.com/",
            "PAPERLESS_OUTLOOK_OAUTH_CLIENT_ID": "outlook-id", "PAPERLESS_OUTLOOK_OAUTH_CLIENT_SECRET": "outlook-secret",
        ]
        let fromEnvironment = MailOAuth(settings: try settings(dir, environment: environment))
        #expect(fromEnvironment.isEnabled(.outlook))
        #expect(fromEnvironment.callbackURL == "https://mail.example.com/api/oauth/callback/")
    }

    @Test func authorizationURLsMatchHttpxOAuth() throws {
        let oauth = MailOAuth(settings: try settings(TempDir(), overrides: Self.configured))
        #expect(oauth.authorizationURL(.gmail, state: "abc_-123") == "https://accounts.google.com/o/oauth2/v2/auth?response_type=code"
            + "&client_id=test_gmail_client_id&redirect_uri=http%3A%2F%2Flocalhost%3A8000%2Fapi%2Foauth%2Fcallback%2F&state=abc_-123"
            + "&scope=https%3A%2F%2Fmail.google.com%2F&prompt=consent&access_type=offline")
        #expect(oauth.authorizationURL(.outlook, state: "abc_-123") == "https://login.microsoftonline.com/common/oauth2/v2.0/authorize?response_type=code"
            + "&client_id=test_outlook_client_id&redirect_uri=http%3A%2F%2Flocalhost%3A8000%2Fapi%2Foauth%2Fcallback%2F&state=abc_-123"
            + "&scope=offline_access+https%3A%2F%2Foutlook.office.com%2FIMAP.AccessAsUser.All&response_mode=query")
    }

    @Test func stateIsLikeTokenURLSafe32() {
        let first = MailOAuth.makeState(), second = MailOAuth.makeState()
        #expect(first.count == 43)
        #expect(first != second)
        #expect(first.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") })
    }

    // MARK: Token endpoint

    @Test func exchangePostsTheCodeWithClientCredentials() async throws {
        let stub = TokenEndpointStub(body: #"{"access_token": "access-1", "refresh_token": "refresh-1", "expires_in": 3599, "token_type": "Bearer"}"#)
        let oauth = MailOAuth(settings: try settings(TempDir(), overrides: Self.configured), transport: stub.transport)
        let token = try await oauth.exchange(code: "4/0Ab code", provider: .gmail)
        #expect(token == MailOAuth.Token(accessToken: "access-1", refreshToken: "refresh-1", expiresIn: 3599))
        let call = try #require(stub.calls.first)
        #expect(call.url == "https://oauth2.googleapis.com/token")
        #expect(call.method == "POST")
        #expect(call.headers["Accept"] == "application/json")
        #expect(call.headers["Content-Type"] == "application/x-www-form-urlencoded")
        #expect(call.form == [
            "grant_type": "authorization_code", "code": "4/0Ab code", "redirect_uri": "http://localhost:8000/api/oauth/callback/",
            "client_id": "test_gmail_client_id", "client_secret": "test_gmail_client_secret",
        ])

        _ = try await oauth.refresh(refreshToken: "refresh-1", provider: .outlook)
        let refresh = try #require(stub.calls.last)
        #expect(refresh.url == "https://login.microsoftonline.com/common/oauth2/v2.0/token")
        #expect(refresh.form == [
            "grant_type": "refresh_token", "refresh_token": "refresh-1",
            "client_id": "test_outlook_client_id", "client_secret": "test_outlook_client_secret",
        ])
    }

    @Test func tokenErrorsNameTheProblemButNoSecrets() async throws {
        let stub = TokenEndpointStub(status: 400, body: #"{"error": "invalid_grant", "error_description": "Bad Request"}"#)
        let oauth = MailOAuth(settings: try settings(TempDir(), overrides: Self.configured), transport: stub.transport)
        do {
            _ = try await oauth.exchange(code: "secret-code", provider: .gmail)
            Issue.record("expected an error")
        } catch let error as MailOAuthError {
            let text = String(describing: error)
            #expect(text.contains("HTTP 400 (invalid_grant): Bad Request"))
            #expect(!text.contains("secret-code"))
            #expect(!text.contains("test_gmail_client_secret"))
        }
        stub.answer(status: 200, body: "<html>")
        await #expect(throws: MailOAuthError.requestFailed("gmail token endpoint sent invalid JSON content")) {
            try await oauth.exchange(code: "c", provider: .gmail)
        }
        stub.answer(status: 200, body: #"{"refresh_token": "r"}"#)
        await #expect(throws: MailOAuthError.requestFailed("gmail token endpoint sent no access token")) {
            try await oauth.exchange(code: "c", provider: .gmail)
        }
        let unconfigured = MailOAuth(settings: try settings(TempDir()), transport: stub.transport)
        await #expect(throws: MailOAuthError.notConfigured(.outlook)) {
            try await unconfigured.refresh(refreshToken: "r", provider: .outlook)
        }
    }

    // MARK: Refresh

    func insertAccount(_ name: String, type: MailAccount.AccountType, refreshToken: String?, server: FakeIMAPServer? = nil, in app: FolioApp) throws -> MailAccount {
        try app.database.write { db in
            var config = MailAccount.Config(imapServer: "127.0.0.1", imapPort: server?.port ?? 1, imapSecurity: .none, username: "me@example.com", password: "stale-token")
            config.isToken = true
            config.accountType = type
            config.refreshToken = refreshToken
            config.expiration = Date().addingTimeInterval(-86_400)
            var account = MailAccount(name: name, config: config)
            try account.insert(db)
            return account
        }
    }

    @Test func refreshSavesTheNewTokens() async throws {
        let dir = TempDir()
        let app = try FolioApp.open(settings: try settings(dir, overrides: Self.configured))
        let stub = TokenEndpointStub(body: #"{"access_token": "fresh-gmail", "expires_in": 3600}"#)
        let oauth = MailOAuth(settings: app.settings, transport: stub.transport)

        // Gmail sends no new refresh token: the old one stays.
        let gmail = try insertAccount("Gmail", type: .gmailOAuth, refreshToken: "gmail-refresh", in: app)
        let now = Date()
        let refreshed = try await oauth.refreshAccessToken(of: gmail, in: app.database, now: now)
        #expect(refreshed.config.password == "fresh-gmail")
        #expect(refreshed.config.refreshToken == "gmail-refresh")
        #expect(refreshed.config.expiration == now.addingTimeInterval(3600))
        let stored = try await app.database.read { db in try MailAccount.fetchOne(db, key: gmail.id!) }
        #expect(stored?.config.password == "fresh-gmail")
        #expect(stored?.config.needsTokenRefresh() == false)
        #expect(stub.calls.last?.form["refresh_token"] == "gmail-refresh")

        // Outlook rotates the refresh token.
        stub.answer(status: 200, body: #"{"access_token": "fresh-outlook", "refresh_token": "outlook-refresh-2", "expires_in": 3600}"#)
        let outlook = try insertAccount("Outlook", type: .outlookOAuth, refreshToken: "outlook-refresh-1", in: app)
        _ = try await oauth.refreshAccessToken(of: outlook, in: app.database)
        let storedOutlook = try await app.database.read { db in try MailAccount.fetchOne(db, key: outlook.id!) }
        #expect(storedOutlook?.config.password == "fresh-outlook")
        #expect(storedOutlook?.config.refreshToken == "outlook-refresh-2")
        #expect(stub.calls.last?.url == "https://login.microsoftonline.com/common/oauth2/v2.0/token")

        // Plain IMAP accounts and accounts without a refresh token are refused without a request.
        let calls = stub.calls.count
        let imap = try insertAccount("IMAP", type: .imap, refreshToken: "token", in: app)
        await #expect(throws: MailOAuthError.notOAuthAccount) { try await oauth.refreshAccessToken(of: imap, in: app.database) }
        let noRefresh = try insertAccount("No refresh", type: .gmailOAuth, refreshToken: nil, in: app)
        await #expect(throws: MailOAuthError.noRefreshToken) { try await oauth.refreshAccessToken(of: noRefresh, in: app.database) }
        #expect(stub.calls.count == calls)
    }

    @Test func mailProcessingRefreshesExpiredTokensBeforeLogin() async throws {
        let dir = TempDir()
        let app = try FolioApp.open(settings: try settings(dir, overrides: Self.configured))
        let server = try FakeIMAPServer(message: Data("raw".utf8), accessToken: "fresh-token")
        defer { server.stop() }
        let stub = TokenEndpointStub(body: #"{"access_token": "fresh-token", "expires_in": 3600}"#)
        let account = try insertAccount("Gmail", type: .gmailOAuth, refreshToken: "refresh-1", server: server, in: app)
        try await app.database.write { db in
            var rule = MailRule(name: "All", accountId: account.id!)
            try rule.insert(db)
        }
        let queue = TaskQueue(database: app.database, workers: 1, logger: app.logger)
        let processor = MailProcessor(app: app, queue: queue, parse: { _ in
            MailContent(subject: "Hello", fromAddress: "a@example.com", fromName: nil, date: Date(), attachments: [])
        }, oauth: MailOAuth(settings: app.settings, transport: stub.transport))

        let summary = await processor.process(account: account)
        #expect(summary.errors.isEmpty)
        #expect(summary.messages == 2)
        #expect(stub.calls.count == 1)
        #expect(server.xoauth2Responses == [IMAPClientTests.xoauth2String("me@example.com", "fresh-token")])
        let stored = try await app.database.read { db in try MailAccount.fetchOne(db, key: account.id!) }
        #expect(stored?.config.password == "fresh-token")

        // A failed refresh skips the account without connecting.
        let failing = try FakeIMAPServer(message: Data("raw".utf8))
        defer { failing.stop() }
        stub.answer(status: 400, body: #"{"error": "invalid_grant"}"#)
        let expired = try insertAccount("Expired", type: .gmailOAuth, refreshToken: "revoked", server: failing, in: app)
        try await app.database.write { db in
            var rule = MailRule(name: "Expired rule", accountId: expired.id!)
            try rule.insert(db)
        }
        let failed = await processor.process(account: expired)
        #expect(failed.messages == 0)
        #expect(failed.errors.count == 1)
        #expect(failed.errors.first?.hasPrefix("Failed to refresh oauth token for account Expired: gmail token endpoint answered HTTP 400 (invalid_grant)") == true)
        #expect(failing.commands.isEmpty)
    }
}
