import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Network
import Testing
@testable import FolioCore
@testable import FolioServer

/// Stands in for the Google and Microsoft token endpoints and records each form it receives.
final class OAuthTokenStub: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(url: String, form: [String: String])] = []
    private var status: Int
    private var body: String

    init(status: Int = 200, body: String = #"{"access_token": "test_access_token", "refresh_token": "test_refresh_token", "expires_in": 3600}"#) {
        self.status = status
        self.body = body
    }

    var calls: [(url: String, form: [String: String])] { lock.withLock { recorded } }

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
            let (status, body) = self.lock.withLock { () -> (Int, String) in
                self.recorded.append((request.url?.absoluteString ?? "", form))
                return (self.status, self.body)
            }
            return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!)
        }
    }
}

/// An IMAP server on localhost that accepts AUTHENTICATE XOAUTH2 with one access token.
final class XOAuthIMAPServer: @unchecked Sendable {
    let listener: NWListener
    let accessToken: String
    private let queue = DispatchQueue(label: "xoauth-imap")
    private let lock = NSLock()
    private var responses: [String] = []
    var port: Int { Int(listener.port!.rawValue) }

    init(accessToken: String) throws {
        self.accessToken = accessToken
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    /// Decoded XOAUTH2 responses, in order.
    var xoauth2Responses: [String] { lock.withLock { responses } }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        send(connection, "* OK ready\r\n")
        // NWConnection runs every callback on `queue`, so the buffer is never used concurrently.
        let buffer = LineBuffer()
        @Sendable func handle(_ line: String) {
            let parts = line.split(separator: " ", maxSplits: 2).map(String.init)
            guard parts.count >= 2 else { return }
            let tag = parts[0]
            switch parts[1].uppercased() {
            case "CAPABILITY":
                send(connection, "* CAPABILITY IMAP4rev1 AUTH=XOAUTH2 SASL-IR\r\n\(tag) OK\r\n")
            case "AUTHENTICATE":
                let encoded = parts.count > 2 ? String(parts[2].split(separator: " ").last ?? "") : ""
                let decoded = Data(base64Encoded: encoded).map { String(decoding: $0, as: UTF8.self) } ?? ""
                lock.withLock { responses.append(decoded) }
                let accepted = decoded.contains("auth=Bearer \(accessToken)" + String(UnicodeScalar(UInt8(1))))
                send(connection, accepted ? "\(tag) OK\r\n" : "\(tag) NO [AUTHENTICATIONFAILED] Invalid credentials\r\n")
            case "LOGOUT":
                send(connection, "* BYE\r\n\(tag) OK\r\n")
            default:
                send(connection, "\(tag) OK\r\n")
            }
        }
        @Sendable func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, _ in
                if let data { buffer.data.append(data) }
                while let line = buffer.nextLine() { handle(line) }
                if !done { receive() }
            }
        }
        receive()
    }

    private func send(_ connection: NWConnection, _ text: String) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }

    /// Received bytes of one connection, split into CRLF lines.
    private final class LineBuffer: @unchecked Sendable {
        var data = Data()

        func nextLine() -> String? {
            guard let range = data.range(of: Data("\r\n".utf8)) else { return nil }
            let line = String(decoding: data[data.startIndex..<range.lowerBound], as: UTF8.self)
            data.removeSubrange(data.startIndex..<range.upperBound)
            return line
        }
    }
}

@Suite struct MailOAuthAPITests {
    static let configured = [
        "OAUTH_CALLBACK_BASE_URL": "http://localhost:8000",
        "GMAIL_OAUTH_CLIENT_ID": "test_gmail_client_id", "GMAIL_OAUTH_CLIENT_SECRET": "test_gmail_client_secret",
        "OUTLOOK_OAUTH_CLIENT_ID": "test_outlook_client_id", "OUTLOOK_OAUTH_CLIENT_SECRET": "test_outlook_client_secret",
    ]
    static let invalidRequest = "Invalid request, see logs for more detail"

    func run(_ env: TestEnvironment, _ stub: OAuthTokenStub, _ test: @Sendable (any TestClientProtocol) async throws -> Void) async throws {
        try await FolioHTTPServer(app: env.app, queue: env.queue, mailOAuthTransport: stub.transport).makeApplication().test(.router, test)
    }

    /// Cookie headers for a new browser session of `user`.
    func session(_ env: TestEnvironment, _ user: TestUser) throws -> HTTPFields {
        let session = try env.app.database.write { db in try UserStore.createSession(userId: user.id, lifetime: 3600, in: db) }
        var fields: HTTPFields = [:]
        fields[.cookie] = "sessionid=\(session.key)"
        return fields
    }

    static func state(in url: String?) -> String? {
        url.flatMap { URLComponents(string: $0)?.queryItems?.first { $0.name == "state" }?.value }
    }

    func accounts(_ env: TestEnvironment) throws -> [MailAccount] {
        try env.app.database.read { db in try MailAccount.order(Column("id")).fetchAll(db) }
    }

    // MARK: ui_settings

    @Test func uiSettingsShowOAuthURLsOnlyWhenConfigured() async throws {
        let plain = try TestEnvironment()
        let admin = try plain.user("admin", superuser: true)
        try await run(plain, OAuthTokenStub()) { client in
            let settings = try await client.get("/api/ui_settings/", as: admin).json["settings"]
            #expect(settings?["gmail_oauth_url"] == nil)
            #expect(settings?["outlook_oauth_url"] == nil)
        }

        let env = try TestEnvironment(overrides: Self.configured)
        let user = try env.user("admin", superuser: true)
        try await run(env, OAuthTokenStub()) { client in
            let settings = try await client.get("/api/ui_settings/", as: user).json["settings"]
            let gmail = try #require(settings?["gmail_oauth_url"]?.string)
            let outlook = try #require(settings?["outlook_oauth_url"]?.string)
            #expect(gmail.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth?response_type=code&client_id=test_gmail_client_id"
                + "&redirect_uri=http%3A%2F%2Flocalhost%3A8000%2Fapi%2Foauth%2Fcallback%2F&state="))
            #expect(gmail.hasSuffix("&scope=https%3A%2F%2Fmail.google.com%2F&prompt=consent&access_type=offline"))
            #expect(outlook.hasPrefix("https://login.microsoftonline.com/common/oauth2/v2.0/authorize?response_type=code&client_id=test_outlook_client_id"))
            #expect(outlook.hasSuffix("&scope=offline_access+https%3A%2F%2Foutlook.office.com%2FIMAP.AccessAsUser.All&response_mode=query"))
            // One state for both links, new on every request.
            let state = try #require(Self.state(in: gmail))
            #expect(state.count == 43)
            #expect(Self.state(in: outlook) == state)
            let again = try await client.get("/api/ui_settings/", as: user).json["settings"]?["gmail_oauth_url"]?.string
            #expect(Self.state(in: again) != state)
        }

        // Only Gmail, with the callback on PAPERLESS_URL.
        let gmailOnly = try TestEnvironment(overrides: ["URL": "https://paperless.example.com", "GMAIL_OAUTH_CLIENT_ID": "id", "GMAIL_OAUTH_CLIENT_SECRET": "secret"])
        let other = try gmailOnly.user("admin", superuser: true)
        try await run(gmailOnly, OAuthTokenStub()) { client in
            let settings = try await client.get("/api/ui_settings/", as: other).json["settings"]
            #expect(settings?["gmail_oauth_url"]?.string?.contains("redirect_uri=https%3A%2F%2Fpaperless.example.com%2Fapi%2Foauth%2Fcallback%2F") == true)
            #expect(settings?["outlook_oauth_url"] == nil)
        }
    }

    // MARK: Callback

    @Test func callbackCreatesAccountsAndRedirects() async throws {
        let env = try TestEnvironment(overrides: Self.configured)
        let alice = try env.user("alice", permissions: ["view_uisettings", "add_mailaccount", "view_mailaccount", "change_mailaccount"])
        let stub = OAuthTokenStub()
        let browser = try session(env, alice)
        try await run(env, stub) { client in
            // Gmail, from a browser session.
            let settings = try await client.call(.get, "/api/ui_settings/", headers: browser).json["settings"]
            let state = try #require(Self.state(in: settings?["gmail_oauth_url"]?.string))
            let before = Date()
            let gmail = try await client.call(.get, "/api/oauth/callback/?code=test_code&scope=https://mail.google.com/&state=\(state)", headers: browser)
            #expect(gmail.status == .found)
            let location = try #require(gmail.headers[.location])
            let gmailAccount = try #require(try accounts(env).last)
            #expect(location == "/mail?oauth_success=1&account_id=\(gmailAccount.id!)")
            // Python's str(timezone.now()), e.g. "Gmail OAuth 2026-11-07 10:22:33.123456+00:00".
            #expect(gmailAccount.name.wholeMatch(of: /Gmail OAuth \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{6}\+00:00/) != nil)
            #expect(gmailAccount.ownerId == alice.id)
            let config = gmailAccount.config
            #expect(config.imapServer == "imap.gmail.com")
            #expect(config.imapPort == 993)
            #expect(config.imapSecurity == .ssl)
            #expect(config.username == "")
            #expect(config.password == "test_access_token")
            #expect(config.isToken)
            #expect(config.accountType == .gmailOAuth)
            #expect(config.refreshToken == "test_refresh_token")
            let expiration = try #require(config.expiration)
            #expect(expiration >= before.addingTimeInterval(3599) && expiration <= Date().addingTimeInterval(3601))
            let call = try #require(stub.calls.first)
            #expect(call.url == "https://oauth2.googleapis.com/token")
            #expect(call.form == [
                "grant_type": "authorization_code", "code": "test_code", "redirect_uri": "http://localhost:8000/api/oauth/callback/",
                "client_id": "test_gmail_client_id", "client_secret": "test_gmail_client_secret",
            ])

            // The API never shows the tokens.
            let json = try await client.get("/api/mail_accounts/\(gmailAccount.id!)/", as: alice).json
            #expect(json["account_type"] == 2)
            #expect(json["is_token"] == true)
            #expect(json["password"]?.string?.allSatisfy { $0 == "*" } == true)
            #expect(json["expiration"] != .null)
            #expect(!json.serialized().contains("test_refresh_token"))

            // Outlook sends no scope. Token requests keep their state per user, apart from the session.
            let tokenSettings = try await client.get("/api/ui_settings/", as: alice).json["settings"]
            let tokenState = try #require(Self.state(in: tokenSettings?["outlook_oauth_url"]?.string))
            #expect(try await client.get("/api/oauth/callback/?code=test_code&state=\(state)", as: alice).status == .badRequest)
            let outlook = try await client.get("/api/oauth/callback/?code=test_code&state=\(tokenState)", as: alice)
            #expect(outlook.status == .found)
            let outlookAccount = try #require(try accounts(env).last)
            #expect(outlook.headers[.location] == "/mail?oauth_success=1&account_id=\(outlookAccount.id!)")
            #expect(outlookAccount.name.hasPrefix("Outlook OAuth "))
            #expect(outlookAccount.config.imapServer == "outlook.office365.com")
            #expect(outlookAccount.config.accountType == .outlookOAuth)
            #expect(stub.calls.last?.url == "https://login.microsoftonline.com/common/oauth2/v2.0/token")
            #expect(stub.calls.last?.form["client_id"] == "test_outlook_client_id")
        }
    }

    @Test func callbackRejectsBadRequests() async throws {
        let env = try TestEnvironment(overrides: Self.configured)
        let alice = try env.user("alice", permissions: ["view_uisettings", "add_mailaccount"])
        let bob = try env.user("bob", permissions: ["view_uisettings"])
        let stub = OAuthTokenStub(status: 400, body: #"{"error": "invalid_grant", "error_description": "Bad Request"}"#)
        try await run(env, stub) { client in
            let denied = try await client.get("/api/oauth/callback/?code=test_code&scope=https://mail.google.com/", as: bob)
            #expect(denied.status == .badRequest)
            #expect(denied.text == "You do not have permission to add mail accounts")

            let noCode = try await client.get("/api/oauth/callback/", as: alice)
            #expect(noCode.status == .badRequest)
            #expect(noCode.text == Self.invalidRequest)

            // No state was handed out yet.
            #expect(try await client.get("/api/oauth/callback/?code=test_code&state=anything", as: alice).text == Self.invalidRequest)

            let settings = try await client.get("/api/ui_settings/", as: alice).json["settings"]
            let state = try #require(Self.state(in: settings?["gmail_oauth_url"]?.string))
            for query in ["code=test_code&state=invalid_state", "code=test_code&state=", "code=test_code",
                          "code=test_code&scope=&state=\(state)", "code=test_code&scope=openid&state=\(state)",
                          "code=test_code&scope=https://example.com/other&state=\(state)"] {
                let response = try await client.get("/api/oauth/callback/?\(query)", as: alice)
                #expect(response.status == .badRequest, "\(query)")
                #expect(response.text == Self.invalidRequest)
            }
            #expect(stub.calls.isEmpty)

            // The provider refuses the code: back to the mail page with oauth_success=0.
            let gmail = try await client.get("/api/oauth/callback/?code=test_code&scope=https://mail.google.com/&state=\(state)", as: alice)
            #expect(gmail.status == .found)
            #expect(gmail.headers[.location] == "/mail?oauth_success=0")
            let outlook = try await client.get("/api/oauth/callback/?code=test_code&state=\(state)", as: alice)
            #expect(outlook.headers[.location] == "/mail?oauth_success=0")
            #expect(stub.calls.count == 2)

            let anonymous = try await client.get("/api/oauth/callback/?code=test_code&state=\(state)", as: nil)
            #expect(anonymous.status == .unauthorized || anonymous.status == .forbidden)
        }
        #expect(try accounts(env).isEmpty)
    }

    // MARK: Account test endpoint

    @Test func accountTestRefreshesExpiredTokensAndUsesXOAUTH2() async throws {
        let env = try TestEnvironment(overrides: Self.configured)
        let admin = try env.user("admin", superuser: true)
        let server = try XOAuthIMAPServer(accessToken: "fresh-token")
        defer { server.stop() }
        let stub = OAuthTokenStub(body: #"{"access_token": "fresh-token", "expires_in": 3599, "token_type": "Bearer"}"#)
        let port = server.port
        let accountId = try await env.app.database.write { db -> Int in
            var config = MailAccount.Config(imapServer: "127.0.0.1", imapPort: port, imapSecurity: .none, username: "me@gmail.com", password: "stale-token")
            config.isToken = true
            config.accountType = .gmailOAuth
            config.refreshToken = "refresh-1"
            config.expiration = Date().addingTimeInterval(-86_400)
            var account = MailAccount(name: "Gmail", ownerId: admin.id, config: config)
            try account.insert(db)
            return account.id!
        }
        let body: JSON = [
            "id": .int(accountId), "imap_server": "127.0.0.1", "imap_port": .int(server.port), "imap_security": 1,
            "username": "me@gmail.com", "password": "****", "is_token": true,
        ]
        let separator = String(UnicodeScalar(UInt8(1)))
        try await run(env, stub) { client in
            let tested = try await client.call(.post, "/api/mail_accounts/test/", as: admin, json: body)
            #expect(tested.status == .ok)
            #expect(tested.json["success"] == true)
            #expect(stub.calls.count == 1)
            #expect(stub.calls.first?.form["grant_type"] == "refresh_token")
            #expect(stub.calls.first?.form["refresh_token"] == "refresh-1")
            #expect(server.xoauth2Responses == ["user=me@gmail.com\(separator)auth=Bearer fresh-token\(separator)\(separator)"])
            let stored = try #require(try accounts(env).first)
            #expect(stored.config.password == "fresh-token")
            #expect(stored.config.refreshToken == "refresh-1")
            #expect(stored.config.needsTokenRefresh() == false)

            // The token is fresh now: no second refresh.
            #expect(try await client.call(.post, "/api/mail_accounts/test/", as: admin, json: body).status == .ok)
            #expect(stub.calls.count == 1)

            // A refresh that fails ends the test before any login.
            try await env.app.database.write { db in
                var account = try MailAccount.fetchOne(db, key: accountId)!
                account.config.expiration = Date().addingTimeInterval(-60)
                try account.update(db)
            }
            stub.answer(status: 400, body: #"{"error": "invalid_grant"}"#)
            let failed = try await client.call(.post, "/api/mail_accounts/test/", as: admin, json: body)
            #expect(failed.status == .badRequest)
            #expect(failed.text == "Unable to connect to server")
            #expect(server.xoauth2Responses.count == 2)

            // A new token typed into the form is used as it is.
            let typed: JSON = [
                "id": .int(accountId), "imap_server": "127.0.0.1", "imap_port": .int(server.port), "imap_security": 1,
                "username": "me@gmail.com", "password": "wrong-token", "is_token": true,
            ]
            let wrong = try await client.call(.post, "/api/mail_accounts/test/", as: admin, json: typed)
            #expect(wrong.status == .badRequest)
            #expect(server.xoauth2Responses.last?.contains("auth=Bearer wrong-token") == true)
            #expect(stub.calls.count == 2)
        }
    }
}
