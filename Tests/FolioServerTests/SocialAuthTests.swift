import CryptoKit
import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Security
import Testing
@testable import FolioCore
@testable import FolioServer

/// A fake OpenID Provider behind an `OIDCTransport`: discovery, JWKS, token and userinfo endpoints.
/// It signs ID tokens with a real RSA, P-256 or HMAC key. Nothing leaves the process.
final class FakeIdP: @unchecked Sendable {
    enum Key {
        case rsa(SecKey)
        case p256(P256.Signing.PrivateKey)
        case hmac(String)
    }

    enum NonceMode { case echo, omit, wrong }

    struct Config {
        var signer: Key
        var published: Key
        var idTokenClaims: [String: Any] = [:]
        var userinfo: [String: Any] = [:]
        var nonceMode = NonceMode.echo
        var includeIDToken = true
        var authMethods = ["client_secret_post", "client_secret_basic"]
    }

    struct Authorization {
        var params: [String: String]
        var code: String
    }

    struct Seen {
        var method: String
        var path: String
        var headers: [String: String]
        var body: String
    }

    static let issuer = "https://idp.example.test/realms/folio"
    nonisolated(unsafe) static let rsaKey = makeRSAKey()
    nonisolated(unsafe) static let otherRSAKey = makeRSAKey()

    let clientId = "paperless"
    let secret = "s3cret"
    let kid = "key-1"
    private let lock = NSLock()
    private var config: Config
    private var codes: [String: Authorization] = [:]
    private var seen: [Seen] = []

    init(key: Key = .rsa(FakeIdP.rsaKey)) {
        config = Config(signer: key, published: key)
        config.userinfo = ["sub": "user-1", "email": "alice@example.com", "email_verified": true, "preferred_username": "alice",
                           "given_name": "Alice", "family_name": "Mokoena", "name": "Alice Mokoena"]
    }

    func configure(_ change: (inout Config) -> Void) { lock.withLock { change(&config) } }
    var requests: [Seen] { lock.withLock { seen } }

    static func makeRSAKey() -> SecKey {
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048]
        return SecKeyCreateRandomKey(attributes as CFDictionary, nil)!
    }

    // MARK: The browser's visit to the provider

    /// Approves the authorization request at `location` and returns the callback path with `code` and `state`.
    func authorize(_ location: String) throws -> (callback: String, params: [String: String]) {
        let prefix = Self.issuer + "/protocol/openid-connect/auth?"
        guard location.hasPrefix(prefix) else { throw OIDCError.network("unexpected redirect \(location)") }
        let params = Self.formDecode(String(location.dropFirst(prefix.count)))
        guard params["client_id"] == clientId, params["response_type"] == "code", let redirect = params["redirect_uri"],
              let state = params["state"], let url = URL(string: redirect) else { throw OIDCError.network("bad authorization request") }
        let code = "code-" + UUID().uuidString
        lock.withLock { codes[code] = Authorization(params: params, code: code) }
        return (url.path + "/?code=\(code)&state=\(state)", params)
    }

    // MARK: The provider's endpoints

    var transport: OIDCTransport {
        { request in try self.handle(request) }
    }

    func handle(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let url = request.url!
        let body = request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""
        lock.withLock { seen.append(Seen(method: request.httpMethod ?? "GET", path: url.path, headers: request.allHTTPHeaderFields ?? [:], body: body)) }
        let base = "/realms/folio"
        switch url.path {
        case base + "/.well-known/openid-configuration":
            return reply([
                "issuer": Self.issuer,
                "authorization_endpoint": Self.issuer + "/protocol/openid-connect/auth",
                "token_endpoint": Self.issuer + "/protocol/openid-connect/token",
                "userinfo_endpoint": Self.issuer + "/protocol/openid-connect/userinfo",
                "jwks_uri": Self.issuer + "/protocol/openid-connect/certs",
                "token_endpoint_auth_methods_supported": lock.withLock { config.authMethods },
            ], url: url)
        case base + "/protocol/openid-connect/certs":
            return reply(["keys": lock.withLock { Self.jwks(config.published, kid: kid) }], url: url)
        case base + "/protocol/openid-connect/token":
            return token(request, body: body, url: url)
        case base + "/protocol/openid-connect/userinfo":
            guard request.value(forHTTPHeaderField: "Authorization")?.hasPrefix("Bearer at-") == true else {
                return reply(["error": "invalid_token"], status: 401, url: url)
            }
            return reply(lock.withLock { config.userinfo }, url: url)
        default:
            return reply(["error": "not found"], status: 404, url: url)
        }
    }

    private func token(_ request: URLRequest, body: String, url: URL) -> (Data, HTTPURLResponse) {
        let form = Self.formDecode(body)
        var client = (form["client_id"], form["client_secret"])
        if let basic = request.value(forHTTPHeaderField: "Authorization"), basic.hasPrefix("Basic "),
           let decoded = Data(base64Encoded: String(basic.dropFirst(6))).map({ String(decoding: $0, as: UTF8.self) }) {
            let parts = decoded.split(separator: ":", maxSplits: 1).map(String.init)
            client = (parts.first, parts.count > 1 ? parts[1] : nil)
        }
        guard client.0 == clientId, client.1 == secret else { return reply(["error": "invalid_client"], status: 401, url: url) }
        guard form["grant_type"] == "authorization_code", let code = form["code"],
              let authorization = lock.withLock({ codes.removeValue(forKey: code) }) else {
            return reply(["error": "invalid_grant"], status: 400, url: url)
        }
        guard form["redirect_uri"] == authorization.params["redirect_uri"] else {
            return reply(["error": "invalid_grant", "error_description": "redirect_uri"], status: 400, url: url)
        }
        if let challenge = authorization.params["code_challenge"] {
            let verifier = form["code_verifier"] ?? ""
            guard OIDCClient.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) == challenge else {
                return reply(["error": "invalid_grant", "error_description": "PKCE"], status: 400, url: url)
            }
        }
        let config = lock.withLock { self.config }
        var claims: [String: Any] = ["iss": Self.issuer, "aud": clientId, "sub": config.userinfo["sub"] ?? "user-1",
                                     "exp": Int(Date().timeIntervalSince1970) + 300, "iat": Int(Date().timeIntervalSince1970)]
        switch config.nonceMode {
        case .echo: claims["nonce"] = authorization.params["nonce"]
        case .wrong: claims["nonce"] = "not-the-nonce"
        case .omit: break
        }
        claims.merge(config.idTokenClaims) { _, new in new }
        var response: [String: Any] = ["access_token": "at-" + code, "token_type": "Bearer", "expires_in": 300]
        if config.includeIDToken { response["id_token"] = sign(claims, with: config.signer) }
        return reply(response, url: url)
    }

    // MARK: Signing

    func sign(_ claims: [String: Any], with key: Key, alg overriddenAlg: String? = nil) -> String {
        let alg: String = switch key {
        case .rsa: "RS256"
        case .p256: "ES256"
        case .hmac: "HS256"
        }
        let header: [String: Any] = ["alg": overriddenAlg ?? alg, "kid": kid, "typ": "JWT"]
        let head = OIDCClient.base64URL(try! JSONSerialization.data(withJSONObject: header))
        let payload = OIDCClient.base64URL(try! JSONSerialization.data(withJSONObject: claims))
        let input = Data("\(head).\(payload)".utf8)
        let signature: Data = switch key {
        case .rsa(let key): SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, input as CFData, nil)! as Data
        case .p256(let key): try! key.signature(for: input).rawRepresentation
        case .hmac(let secret): Data(HMAC<SHA256>.authenticationCode(for: input, using: SymmetricKey(data: Data(secret.utf8))))
        }
        return "\(head).\(payload).\(OIDCClient.base64URL(signature))"
    }

    static func jwks(_ key: Key, kid: String) -> [[String: Any]] {
        switch key {
        case .rsa(let privateKey):
            let der = SecKeyCopyExternalRepresentation(SecKeyCopyPublicKey(privateKey)!, nil)! as Data
            let (n, e) = rsaComponents(der)
            return [["kty": "RSA", "kid": kid, "use": "sig", "alg": "RS256", "n": OIDCClient.base64URL(n), "e": OIDCClient.base64URL(e)]]
        case .p256(let privateKey):
            let point = privateKey.publicKey.x963Representation
            return [["kty": "EC", "crv": "P-256", "kid": kid, "use": "sig",
                     "x": OIDCClient.base64URL(point[1..<33]), "y": OIDCClient.base64URL(point[33..<65])]]
        case .hmac:
            return []
        }
    }

    /// Modulus and exponent of a PKCS #1 `RSAPublicKey`.
    static func rsaComponents(_ der: Data) -> (Data, Data) {
        let bytes = [UInt8](der)
        var index = 0
        func length() -> Int {
            let first = bytes[index]; index += 1
            guard first & 0x80 != 0 else { return Int(first) }
            var value = 0
            for _ in 0..<Int(first & 0x7f) { value = value << 8 | Int(bytes[index]); index += 1 }
            return value
        }
        index += 1; _ = length()
        index += 1; let nLength = length(); var n = Data(bytes[index..<index + nLength]); index += nLength
        index += 1; let eLength = length(); let e = Data(bytes[index..<index + eLength])
        if n.first == 0 { n = n.dropFirst() }
        return (n, e)
    }

    // MARK: Helpers

    func reply(_ object: Any, status: Int = 200, url: URL) -> (Data, HTTPURLResponse) {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return (data, HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    static func formDecode(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in text.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1).map {
                String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0)
            }
            result[parts[0]] = parts.count > 1 ? parts[1] : ""
        }
        return result
    }

    /// `PAPERLESS_SOCIALACCOUNT_PROVIDERS` for this provider, as the Paperless-ngx docs write it.
    func providersJSON(settings extra: String = "", provider providerExtra: String = "") -> String {
        """
        {"openid_connect": {\(providerExtra)"APPS": [{"provider_id": "keycloak", "name": "Keycloak", "client_id": "\(clientId)", "secret": "\(secret)", \
        "settings": {"server_url": "\(Self.issuer)"\(extra)}}]}}
        """
    }
}

extension TestResponse {
    /// A cookie value from `Set-Cookie`.
    func oidcCookie(_ name: String) -> String? {
        headers[values: .setCookie].first { $0.hasPrefix(name + "=") }.map { String($0.split(separator: ";")[0].dropFirst(name.count + 1)) }
    }
}

@Suite struct SocialAuthTests {
    static let app = "allauth.socialaccount.providers.openid_connect"

    func environment(_ idp: FakeIdP, settings: String = "", provider: String = "", _ overrides: [String: String] = [:]) throws -> TestEnvironment {
        var values = ["APPS": Self.app, "SOCIALACCOUNT_PROVIDERS": idp.providersJSON(settings: settings, provider: provider)]
        values.merge(overrides) { _, new in new }
        return try TestEnvironment(overrides: values)
    }

    func run<T: Sendable>(_ env: TestEnvironment, _ idp: FakeIdP, _ test: @Sendable (any TestClientProtocol) async throws -> T) async throws -> T {
        var server = FolioHTTPServer(app: env.app, queue: env.queue)
        server.oidcTransport = idp.transport
        return try await server.makeApplication().test(.router, test)
    }

    /// Starts a sign-in, lets the fake provider approve it and follows the callback.
    func signIn(_ client: any TestClientProtocol, _ idp: FakeIdP, next: String? = nil, process: String? = nil,
                session: String? = nil, csrf: String? = nil) async throws -> TestResponse {
        var headers: HTTPFields = [:]
        headers[.contentType] = "application/x-www-form-urlencoded"
        if let session { headers[.cookie] = "sessionid=\(session)" }
        var form: [(String, String)] = []
        if let next { form.append(("next", next)) }
        if let process { form.append(("process", process)) }
        if let csrf { form.append(("csrfmiddlewaretoken", csrf)) }
        let start = try await client.call(.post, "/accounts/oidc/keycloak/login/", headers: headers, body: ByteBuffer(string: OIDCClient.formEncode(form)))
        #expect(start.status == .found)
        let browser = try #require(start.oidcCookie("socialaccount_state"))
        let (callback, _) = try idp.authorize(try #require(start.headers[.location]))
        var callbackHeaders: HTTPFields = [:]
        callbackHeaders[.cookie] = (["socialaccount_state=\(browser)"] + (session.map { ["sessionid=\($0)"] } ?? [])).joined(separator: "; ")
        return try await client.call(.get, callback, headers: callbackHeaders)
    }

    static func sessionHeaders(_ session: String) -> HTTPFields {
        var headers: HTTPFields = [:]
        headers[.cookie] = "sessionid=\(session)"
        return headers
    }

    // MARK: - Settings

    @Test func providerSettingsFollowPaperless() throws {
        let json = """
            {"openid_connect": {"SCOPE": ["openid", "profile", "email", "groups"], "OAUTH_PKCE_ENABLED": true, "APPS": [
              {"provider_id": "keycloak", "name": "Keycloak", "client_id": "paperless", "secret": "x",
               "settings": {"server_url": "https://kc.example/realms/r/.well-known/openid-configuration", "token_auth_method": "client_secret_basic"}},
              {"provider_id": "authelia", "name": "Authelia", "client_id": "c",
               "settings": {"server_url": "https://auth.example", "scope": ["openid"], "hidden": true, "fetch_userinfo": false,
                            "oauth_pkce_enabled": false, "verified_email": ["example.com"], "email_authentication": true}},
              {"name": "No id", "client_id": "c", "settings": {"server_url": "https://x.example"}}]},
             "github": {"APPS": [{"provider_id": "github", "client_id": "g"}]}}
            """
        let settings = SocialAccountSettings(raw: [
            "APPS": "allauth.socialaccount.providers.openid_connect", "SOCIALACCOUNT_PROVIDERS": json,
            "SOCIAL_AUTO_SIGNUP": "yes", "SOCIAL_ACCOUNT_DEFAULT_GROUPS": "readers, editors,,", "ACCOUNT_DEFAULT_GROUPS": "staff",
            "SOCIAL_ACCOUNT_SYNC_GROUPS": "true", "SOCIAL_ACCOUNT_SYNC_GROUPS_CLAIM": "roles", "SOCIAL_ACCOUNT_SYNC_SUPERUSER_GROUP": "admins",
            "DISABLE_REGULAR_LOGIN": "1", "REDIRECT_LOGIN_TO_SSO": "t", "SOCIAL_ACCOUNT_MFA_TRUSTED_AMR": "",
        ])
        #expect(settings.providers.map(\.id) == ["keycloak", "authelia"])
        let keycloak = try #require(settings.provider(id: "keycloak"))
        #expect(keycloak.serverURL == "https://kc.example/realms/r/.well-known/openid-configuration")
        #expect(keycloak.scope == ["openid", "profile", "email", "groups"])
        #expect(keycloak.pkceEnabled && keycloak.fetchUserinfo && !keycloak.hidden && !keycloak.emailAuthentication)
        #expect(keycloak.tokenAuthMethod == "client_secret_basic")
        let authelia = try #require(settings.provider(id: "authelia"))
        #expect(authelia.serverURL == "https://auth.example/.well-known/openid-configuration")
        #expect(authelia.scope == ["openid"])
        #expect(!authelia.pkceEnabled && !authelia.fetchUserinfo && authelia.hidden && authelia.emailAuthentication)
        #expect(authelia.isEmailVerified("a@EXAMPLE.com") && !authelia.isEmailVerified("a@other.example"))
        #expect(settings.autoSignup && settings.allowSignups && settings.syncGroups && settings.disableRegularLogin && settings.redirectLoginToSSO)
        #expect(settings.defaultGroups == ["readers", "editors"])
        #expect(settings.accountDefaultGroups == ["staff"])
        #expect(settings.syncGroupsClaim == "roles")
        #expect(settings.syncSuperuserGroup == "admins" && settings.syncStaffGroup == nil)
        #expect(settings.mfaTrustedAMR == ["mfa"])
        #expect(settings.defaultHTTPProtocol == "https")
        #expect(settings.warnings.contains { $0.contains("\"github\"") })
        #expect(settings.warnings.contains { $0.contains("no provider_id") })

        // Paperless-ngx needs the provider app in PAPERLESS_APPS.
        let notInstalled = SocialAccountSettings(raw: ["SOCIALACCOUNT_PROVIDERS": json])
        #expect(notInstalled.providers.isEmpty)
        #expect(notInstalled.warnings.contains { $0.contains("APPS does not list") })
        let invalid = SocialAccountSettings(raw: ["APPS": Self.app, "SOCIALACCOUNT_PROVIDERS": "{not json"])
        #expect(invalid.providers.isEmpty && invalid.warnings.contains { $0.contains("not valid JSON") })

        // allauth's older SERVERS list.
        let legacy = SocialAccountSettings(raw: ["APPS": Self.app, "SOCIALACCOUNT_PROVIDERS": """
            {"openid_connect": {"SERVERS": [{"id": "kc", "name": "KC", "server_url": "https://kc.example", "token_auth_method": "client_secret_post",
             "APP": {"client_id": "id", "secret": "s"}}]}}
            """])
        #expect(legacy.providers.first?.id == "kc")
        #expect(legacy.providers.first?.tokenAuthMethod == "client_secret_post")
        #expect(legacy.providers.first?.name == "KC")

        func amr(_ value: JSON) -> JSONValue { JSON(dictionaryLiteral: ("amr", value)).jsonValue }
        #expect(settings.trustsAMR(idToken: amr(["pwd", "mfa"])))
        #expect(!settings.trustsAMR(idToken: amr(["otp"])))
        #expect(!settings.trustsAMR(idToken: amr("mfa")))
        #expect(!settings.trustsAMR(idToken: amr(["mfa", 1])))
        #expect(!settings.trustsAMR(idToken: nil))
        #expect(!SocialAccountSettings(raw: ["SOCIAL_ACCOUNT_MFA_TRUSTED_AMR": ",,"]).trustsAMR(idToken: amr(["mfa"])))
    }

    // MARK: - ID tokens

    @Test func idTokenVerification() async throws {
        let rsa = FakeIdP()
        let provider = OIDCProviderConfig(id: "kc", name: "KC", clientId: rsa.clientId, secret: rsa.secret, serverURL: FakeIdP.issuer)
        let client = OIDCClient(transport: rsa.transport)
        let discovery = try await client.discover(provider)
        #expect(discovery.issuer == FakeIdP.issuer)
        let now = Int(Date().timeIntervalSince1970)
        let good: [String: Any] = ["iss": FakeIdP.issuer, "aud": [rsa.clientId, "other"], "sub": "u1", "exp": now + 60, "iat": now, "nonce": "n1"]

        let token = rsa.sign(good, with: .rsa(FakeIdP.rsaKey))
        let claims = try await client.verifyIDToken(token, provider: provider, discovery: discovery, nonce: "n1")
        #expect(claims["sub"] == .string("u1"))
        // A token without a nonce passes (allauth sends none); a different nonce fails.
        var noNonce = good
        noNonce["nonce"] = nil
        _ = try await client.verifyIDToken(rsa.sign(noNonce, with: .rsa(FakeIdP.rsaKey)), provider: provider, discovery: discovery, nonce: "n1")

        func rejects(_ token: String, nonce: String? = "n1", _ reason: String) async {
            await #expect(throws: OIDCError.invalidIDToken(reason)) {
                try await client.verifyIDToken(token, provider: provider, discovery: discovery, nonce: nonce)
            }
        }
        await rejects(rsa.sign(good, with: .rsa(FakeIdP.otherRSAKey)), "bad signature")
        let parts = token.split(separator: ".")
        var tampered = good
        tampered["sub"] = "admin"
        let forgedPayload = OIDCClient.base64URL(try JSONSerialization.data(withJSONObject: tampered))
        await rejects("\(parts[0]).\(forgedPayload).\(parts[2])", "bad signature")
        var expired = good
        expired["exp"] = now - 3600
        await rejects(rsa.sign(expired, with: .rsa(FakeIdP.rsaKey)), "expired")
        var wrongAudience = good
        wrongAudience["aud"] = "someone-else"
        await rejects(rsa.sign(wrongAudience, with: .rsa(FakeIdP.rsaKey)), "wrong audience")
        var wrongIssuer = good
        wrongIssuer["iss"] = "https://evil.example"
        await rejects(rsa.sign(wrongIssuer, with: .rsa(FakeIdP.rsaKey)), "wrong issuer")
        await rejects(token, nonce: "n2", "wrong nonce")
        await rejects(rsa.sign(good, with: .hmac("x"), alg: "none"), "unsupported algorithm none")
        // An HS256 token signed with a guessable key is no RS256 token.
        await rejects(rsa.sign(good, with: .hmac(rsa.secret + "x")), "bad signature")
        var once = good
        once["jti"] = "token-1"
        let onceToken = rsa.sign(once, with: .rsa(FakeIdP.rsaKey))
        _ = try await client.verifyIDToken(onceToken, provider: provider, discovery: discovery, nonce: "n1")
        await rejects(onceToken, "token already used")

        // ES256 with a P-256 JWK, and HS256 with the client secret.
        let p256Key = P256.Signing.PrivateKey()
        let ec = FakeIdP(key: .p256(p256Key))
        let ecClient = OIDCClient(transport: ec.transport)
        let ecDiscovery = try await ecClient.discover(provider)
        _ = try await ecClient.verifyIDToken(ec.sign(good, with: .p256(p256Key)), provider: provider, discovery: ecDiscovery, nonce: "n1")
        await #expect(throws: OIDCError.invalidIDToken("bad signature")) {
            try await ecClient.verifyIDToken(ec.sign(good, with: .p256(P256.Signing.PrivateKey())), provider: provider, discovery: ecDiscovery, nonce: "n1")
        }
        _ = try await client.verifyIDToken(rsa.sign(good, with: .hmac(rsa.secret)), provider: provider, discovery: discovery, nonce: "n1")
    }

    // MARK: - Sign-in page

    @Test func loginPageShowsProviderButtonsAndConfirmPage() async throws {
        let idp = FakeIdP()
        let env = try environment(idp)
        try await run(env, idp) { client in
            let page = try await client.get("/accounts/login/?next=/documents", as: nil)
            #expect(page.text.contains("name=\"password\""))
            #expect(page.text.contains("or sign in via"))
            #expect(page.text.contains("action=\"/accounts/oidc/keycloak/login/?next=%2Fdocuments\""))
            #expect(page.text.contains(">Keycloak</button>"))
            #expect(!page.text.contains("form.submit()"))

            let confirm = try await client.get("/accounts/oidc/keycloak/login/?process=connect", as: nil)
            #expect(confirm.status == .ok)
            #expect(confirm.text.contains("You are about to connect a new third-party account from Keycloak."))
            #expect(confirm.text.contains("action=\"/accounts/oidc/keycloak/login/?process=connect\""))
            #expect(try await client.get("/accounts/oidc/unknown/login/", as: nil).status == .notFound)
            #expect(try await client.call(.post, "/accounts/oidc/unknown/login/").status == .notFound)
        }
        // Hidden apps get no button; without providers the page has no SSO section.
        let hidden = try environment(idp, settings: #", "hidden": true"#)
        try await run(hidden, idp) { client async throws in
            #expect(!(try await client.get("/accounts/login/", as: nil).text.contains("Keycloak")))
        }
        let plain = try TestEnvironment()
        try await plain.run { client async throws in
            #expect(!(try await client.get("/accounts/login/", as: nil).text.contains("sign in via")))
        }
    }

    @Test func disabledRegularLoginAndRedirectToSSO() async throws {
        let idp = FakeIdP()
        let env = try environment(idp, ["DISABLE_REGULAR_LOGIN": "true", "REDIRECT_LOGIN_TO_SSO": "true"])
        let user = try env.user("local", password: "pw-local")
        try await run(env, idp) { client in
            let page = try await client.get("/accounts/login/", as: nil)
            #expect(!page.text.contains("name=\"password\""))
            #expect(!page.text.contains("or sign in via"))
            #expect(page.text.contains("const form = document.getElementById('social-login');"))
            // After a logout the page waits instead of bouncing back to the provider.
            let loggedOut = try await client.get("/accounts/login/?loggedout=1", as: nil)
            #expect(loggedOut.text.contains(">Keycloak</button>"))
            #expect(!loggedOut.text.contains("form.submit()"))
            #expect(try await client.get("/accounts/oidc/keycloak/login/", as: nil).text.contains("form.submit()"))

            var form: HTTPFields = [:]
            form[.contentType] = "application/x-www-form-urlencoded"
            let refused = try await client.call(.post, "/accounts/login/", headers: form, body: ByteBuffer(string: "login=local&password=pw-local"))
            #expect(refused.status == .badRequest)
            #expect(refused.text.contains("Regular login is disabled"))
            #expect(refused.headers[values: .setCookie].isEmpty)
            let json = try await client.call(.post, "/api/auth/login/", json: ["username": "local", "password": "pw-local"])
            #expect(json.json["non_field_errors"] == ["Regular login is disabled"])
            // API credentials keep working, as the Paperless-ngx docs say.
            let token = try await client.call(.post, "/api/token/", json: ["username": "local", "password": "pw-local"])
            #expect(token.json["token"]?.string == user.token)
            #expect(try await client.get("/accounts/logout/", as: nil).headers[.location] == "/accounts/login/?loggedout=1")
        }
    }

    // MARK: - Sign-in flow

    @Test func redirectCarriesStateNonceAndPKCE() async throws {
        let idp = FakeIdP()
        let env = try environment(idp, settings: #", "oauth_pkce_enabled": true, "auth_params": {"prompt": "login"}"#,
                                  provider: #""SCOPE": ["openid", "email", "groups"], "#, ["ACCOUNT_DEFAULT_HTTP_PROTOCOL": "http"])
        try await run(env, idp) { client in
            let start = try await client.call(.post, "/accounts/oidc/keycloak/login/?next=/documents")
            #expect(start.status == .found)
            let location = try #require(start.headers[.location])
            let (callback, params) = try idp.authorize(location)
            #expect(params["scope"] == "openid email groups")
            #expect(params["prompt"] == "login")
            #expect(params["state"]?.count == 32)
            #expect(params["nonce"]?.count == 32)
            #expect(params["code_challenge_method"] == "S256")
            #expect(params["code_challenge"]?.isEmpty == false)
            let redirect = try #require(params["redirect_uri"])
            #expect(redirect.hasPrefix("http://") && redirect.hasSuffix("/accounts/oidc/keycloak/login/callback/"))
            #expect(callback.hasPrefix("/accounts/oidc/keycloak/login/callback/?code="))
            let cookie = try #require(start.headers[values: .setCookie].first { $0.hasPrefix("socialaccount_state=") })
            #expect(cookie.contains("HttpOnly") && cookie.contains("SameSite=Lax"))

            var headers: HTTPFields = [:]
            headers[.cookie] = "socialaccount_state=\(start.oidcCookie("socialaccount_state")!)"
            let done = try await client.call(.get, callback, headers: headers)
            // No auto signup by default: the signup form, and a PKCE-checked token request with client_secret_post.
            #expect(done.status == .ok)
            #expect(done.text.contains("name=\"signup_token\""))
            let tokenRequest = try #require(idp.requests.first { $0.path.hasSuffix("/token") })
            #expect(tokenRequest.body.contains("client_secret=s3cret") && tokenRequest.body.contains("code_verifier="))
            #expect(tokenRequest.headers["Authorization"] == nil)
        }
    }

    @Test func autoSignupCreatesUserAndSignsIn() async throws {
        let idp = FakeIdP()
        idp.configure { $0.authMethods = ["client_secret_basic"] }
        let env = try environment(idp, ["SOCIAL_AUTO_SIGNUP": "true"])
        try env.user("alice")
        try await run(env, idp) { client in
            let response = try await signIn(client, idp, next: "/documents")
            #expect(response.status == .found)
            #expect(response.headers[.location] == "/documents")
            let session = try #require(response.oidcCookie("sessionid"))
            // Basic client authentication when the provider only offers it (allauth `basic_auth`).
            let tokenRequest = try #require(idp.requests.first { $0.path.hasSuffix("/token") })
            #expect(tokenRequest.headers["Authorization"]?.hasPrefix("Basic ") == true)
            #expect(!tokenRequest.body.contains("client_secret"))

            // "alice" is taken, so allauth derives a name from the first name.
            let user = try #require(try await env.app.database.read { db in try User.filter(Column("email") == "alice@example.com").fetchOne(db) })
            #expect(user.username.hasPrefix("alice") && user.username != "alice")
            #expect(user.firstName == "Alice" && user.lastName == "Mokoena")
            #expect(user.password.isEmpty && !user.isSuperuser)

            let profile = try await client.call(.get, "/api/profile/", headers: Self.sessionHeaders(session))
            #expect(profile.status == .ok)
            let accounts = try #require(profile.json["social_accounts"]?.array)
            #expect(accounts.count == 1)
            #expect(accounts.first?["provider"] == "keycloak")
            #expect(accounts.first?["name"] == "alice@example.com")
            #expect(profile.json["has_usable_password"] == false)

            // The next sign-in finds the linked account and stores the new claims.
            idp.configure { $0.userinfo["email"] = "alice@new.example" }
            let again = try await signIn(client, idp)
            #expect(again.headers[.location] == "/")
            let users = try await env.app.database.read { db in try User.fetchCount(db) }
            #expect(users == 2)
            let extra = try await env.app.database.read { db in try SocialAccount.fetchOne(db)?.extraDataJSON }
            #expect(SocialAccountStore.pickUserData(extra ?? .null)["email"] == .string("alice@new.example"))
        }
    }

    @Test func signupFormWithDefaultGroups() async throws {
        let idp = FakeIdP()
        let env = try environment(idp, ["SOCIAL_ACCOUNT_DEFAULT_GROUPS": "readers", "ACCOUNT_DEFAULT_GROUPS": "staff, missing"])
        try env.user("taken")
        try await env.app.database.write { db in
            for name in ["readers", "staff"] { var group = Group(name: name); try group.insert(db) }
        }
        try await run(env, idp) { client in
            let form = try await signIn(client, idp, next: "/dashboard")
            #expect(form.text.contains("You are about to use your Keycloak account to login."))
            #expect(form.text.contains("value=\"alice\""))
            #expect(form.text.contains("value=\"alice@example.com\""))
            let token = try #require(form.text.range(of: "name=\"signup_token\" value=\"").map { String(form.text[$0.upperBound...].prefix(40)) })

            var headers: HTTPFields = [:]
            headers[.contentType] = "application/x-www-form-urlencoded"
            let taken = try await client.call(.post, "/accounts/3rdparty/signup/", headers: headers,
                                              body: ByteBuffer(string: "signup_token=\(token)&username=TAKEN&email=alice%40example.com"))
            #expect(taken.text.contains("This username is already taken."))
            let bad = try await client.call(.post, "/accounts/3rdparty/signup/", headers: headers,
                                            body: ByteBuffer(string: "signup_token=\(token)&username=al%20ice&email=nope"))
            #expect(bad.text.contains("Enter a valid username.") && bad.text.contains("Enter a valid email address."))
            let created = try await client.call(.post, "/accounts/3rdparty/signup/", headers: headers,
                                                body: ByteBuffer(string: "signup_token=\(token)&username=alice2&email="))
            #expect(created.status == .found)
            #expect(created.headers[.location] == "/dashboard")
            #expect(created.oidcCookie("sessionid") != nil)
            let reused = try await client.call(.post, "/accounts/3rdparty/signup/", headers: headers,
                                               body: ByteBuffer(string: "signup_token=\(token)&username=alice3"))
            #expect(reused.headers[.location] == "/accounts/login/")

            let (user, groups) = try await env.app.database.read { db -> (User?, [String]) in
                let user = try UserStore.user(named: "alice2", in: db)
                let groups = try String.fetchAll(db, sql: "SELECT g.name FROM groups g JOIN user_groups ug ON ug.group_id = g.id WHERE ug.user_id = ? ORDER BY g.name",
                                                 arguments: [user?.id])
                return (user, groups)
            }
            #expect(user?.email == "" && user?.firstName == "Alice" && user?.isSuperuser == false)
            // The form path adds ACCOUNT_DEFAULT_GROUPS as well as SOCIAL_ACCOUNT_DEFAULT_GROUPS.
            #expect(groups == ["readers", "staff"])
        }
    }

    @Test func firstSignupOfFreshInstallIsSuperuser() async throws {
        let idp = FakeIdP()
        let env = try environment(idp)
        try await run(env, idp) { client in
            let form = try await signIn(client, idp)
            let token = try #require(form.text.range(of: "name=\"signup_token\" value=\"").map { String(form.text[$0.upperBound...].prefix(40)) })
            var headers: HTTPFields = [:]
            headers[.contentType] = "application/x-www-form-urlencoded"
            let created = try await client.call(.post, "/accounts/3rdparty/signup/", headers: headers,
                                                body: ByteBuffer(string: "signup_token=\(token)&username=alice&email=alice%40example.com"))
            #expect(created.status == .found)
            let user = try await env.app.database.read { db in try UserStore.user(named: "alice", in: db) }
            #expect(user?.isSuperuser == true && user?.isStaff == true)
        }
    }

    @Test func emailLinkingOnlyWithEmailAuthentication() async throws {
        let idp = FakeIdP()
        // Default: an existing address blocks auto signup and shows the form; nothing is linked.
        let env = try environment(idp, ["SOCIAL_AUTO_SIGNUP": "true"])
        try await env.app.database.write { db in _ = try UserStore.createUser(username: "thandi", password: "pw", email: "Alice@Example.com", in: db) }
        try await run(env, idp) { client in
            let response = try await signIn(client, idp)
            #expect(response.status == .ok)
            #expect(response.text.contains("name=\"signup_token\""))
            let token = try #require(response.text.range(of: "name=\"signup_token\" value=\"").map { String(response.text[$0.upperBound...].prefix(40)) })
            var headers: HTTPFields = [:]
            headers[.contentType] = "application/x-www-form-urlencoded"
            let conflict = try await client.call(.post, "/accounts/3rdparty/signup/", headers: headers,
                                                 body: ByteBuffer(string: "signup_token=\(token)&username=alice&email=alice%40example.com"))
            #expect(conflict.text.contains("An account already exists with this email address. Please sign in to that account first, then connect your Keycloak account."))
            #expect(try await env.app.database.read { db in try SocialAccount.fetchCount(db) } == 0)
        }

        // `email_authentication` with a verified address signs in to the existing account and wipes its password.
        let linked = try environment(idp, settings: #", "email_authentication": true"#)
        let thandi = try await linked.app.database.write { db in try UserStore.createUser(username: "thandi", password: "pw", email: "alice@example.com", in: db) }
        try await run(linked, idp) { client in
            idp.configure { $0.userinfo["email_verified"] = false }
            let unverified = try await signIn(client, idp)
            #expect(unverified.text.contains("name=\"signup_token\""))

            idp.configure { $0.userinfo["email_verified"] = true }
            let response = try await signIn(client, idp)
            #expect(response.status == .found)
            let session = try #require(response.oidcCookie("sessionid"))
            let sessionUser = try await linked.app.database.read { db in try UserStore.session(key: session, in: db)?.userId }
            #expect(sessionUser == thandi.id)
            let user = try await linked.app.database.read { db in try User.fetchOne(db, key: thandi.id) }
            #expect(user?.password.isEmpty == true)
            // allauth does not connect the account (EMAIL_AUTHENTICATION_AUTO_CONNECT is off).
            #expect(try await linked.app.database.read { db in try SocialAccount.fetchCount(db) } == 0)
        }
    }

    @Test func groupSyncAndSuperuserFromClaims() async throws {
        let idp = FakeIdP()
        idp.configure { $0.userinfo["groups"] = ["editors", "admins", "unknown"] }
        let env = try environment(idp, ["SOCIAL_AUTO_SIGNUP": "true", "SOCIAL_ACCOUNT_SYNC_GROUPS": "true",
                                        "SOCIAL_ACCOUNT_DEFAULT_GROUPS": "readers", "SOCIAL_ACCOUNT_SYNC_SUPERUSER_GROUP": "admins"])
        try await env.app.database.write { db in
            for name in ["readers", "editors", "admins"] { var group = Group(name: name); try group.insert(db) }
        }
        @Sendable func state() async throws -> (groups: [String], superuser: Bool, staff: Bool) {
            try await env.app.database.read { db in
                let user = try #require(try UserStore.user(named: "alice", in: db))
                let groups = try String.fetchAll(db, sql: "SELECT g.name FROM groups g JOIN user_groups ug ON ug.group_id = g.id WHERE ug.user_id = ? ORDER BY g.name",
                                                 arguments: [user.id])
                return (groups, user.isSuperuser, user.isStaff)
            }
        }
        try await run(env, idp) { client in
            #expect(try await signIn(client, idp).status == .found)
            // The sync replaces the default groups, as in Paperless-ngx.
            let first = try await state()
            #expect(first.groups == ["admins", "editors"])
            #expect(first.superuser && first.staff)

            idp.configure { $0.userinfo["groups"] = nil; $0.idTokenClaims["groups"] = "editors" }
            #expect(try await signIn(client, idp).status == .found)
            let second = try await state()
            #expect(second.groups == ["editors"])
            #expect(!second.superuser && second.staff)

            idp.configure { $0.idTokenClaims["groups"] = [] as [String] }
            #expect(try await signIn(client, idp).status == .found)
            #expect(try await state().groups == [])
        }
    }

    // MARK: - Failures

    @Test func rejectsBadStateSignatureExpiryAndNonce() async throws {
        let idp = FakeIdP()
        let env = try environment(idp, ["SOCIAL_AUTO_SIGNUP": "true"])
        try await run(env, idp) { client in
            let unknown = try await client.get("/accounts/oidc/keycloak/login/callback/?code=x&state=nope", as: nil)
            #expect(unknown.text.contains("An error occurred while attempting to login via your social network account."))
            #expect(unknown.oidcCookie("sessionid") == nil)

            // The state cookie binds the callback to the browser that started the sign-in.
            let start = try await client.call(.post, "/accounts/oidc/keycloak/login/")
            let (callback, _) = try idp.authorize(try #require(start.headers[.location]))
            var stranger: HTTPFields = [:]
            stranger[.cookie] = "socialaccount_state=" + String(repeating: "x", count: 32)
            let foreign = try await client.call(.get, callback, headers: stranger)
            #expect(foreign.text.contains("An error occurred"))
            var owner: HTTPFields = [:]
            owner[.cookie] = "socialaccount_state=\(start.oidcCookie("socialaccount_state")!)"
            // Each state works once.
            #expect(try await client.call(.get, callback, headers: owner).text.contains("An error occurred"))

            idp.configure { $0.signer = .rsa(FakeIdP.otherRSAKey) }
            #expect(try await signIn(client, idp).text.contains("An error occurred"))
            idp.configure { $0.signer = $0.published; $0.idTokenClaims["exp"] = Int(Date().timeIntervalSince1970) - 3600 }
            #expect(try await signIn(client, idp).text.contains("An error occurred"))
            idp.configure { $0.idTokenClaims = [:]; $0.nonceMode = .wrong }
            #expect(try await signIn(client, idp).text.contains("An error occurred"))
            idp.configure { $0.nonceMode = .echo; $0.idTokenClaims["sub"] = "someone-else" }
            #expect(try await signIn(client, idp).text.contains("An error occurred"))
            #expect(try await env.app.database.read { db in try User.fetchCount(db) } == 0)

            // A cancelled consent screen goes to allauth's cancelled page.
            idp.configure { $0.idTokenClaims = [:] }
            let cancelStart = try await client.call(.post, "/accounts/oidc/keycloak/login/")
            let (cancelCallback, params) = try idp.authorize(try #require(cancelStart.headers[.location]))
            _ = cancelCallback
            var cancelHeaders: HTTPFields = [:]
            cancelHeaders[.cookie] = "socialaccount_state=\(cancelStart.oidcCookie("socialaccount_state")!)"
            let cancelled = try await client.call(.get, "/accounts/oidc/keycloak/login/callback/?error=access_denied&state=\(params["state"]!)", headers: cancelHeaders)
            #expect(cancelled.headers[.location] == "/accounts/3rdparty/login/cancelled/")
            #expect(try await client.get("/accounts/3rdparty/login/cancelled/", as: nil).text.contains("Login Cancelled"))

            // With a valid token the same provider signs in.
            #expect(try await signIn(client, idp).status == .found)
        }
    }

    @Test func signupsClosedAndInactiveAccounts() async throws {
        let idp = FakeIdP()
        let closed = try environment(idp, ["SOCIALACCOUNT_ALLOW_SIGNUPS": "false", "SOCIAL_AUTO_SIGNUP": "true"])
        try await run(closed, idp) { client async throws in
            #expect(try await signIn(client, idp).text.contains("We are sorry, but the sign up is currently closed."))
        }
        let env = try environment(idp, ["SOCIAL_AUTO_SIGNUP": "true"])
        try await run(env, idp) { client in
            #expect(try await signIn(client, idp).status == .found)
            try await env.app.database.write { db in try db.execute(sql: "UPDATE users SET is_active = 0") }
            let inactive = try await signIn(client, idp)
            #expect(inactive.text.contains("This account is inactive."))
            #expect(inactive.oidcCookie("sessionid") == nil)
        }
    }

    // MARK: - Two-factor authentication

    @Test func totpAfterSocialLoginUnlessAMRIsTrusted() async throws {
        let idp = FakeIdP()
        let env = try environment(idp, ["SOCIAL_AUTO_SIGNUP": "true"])
        try await run(env, idp) { client in
            #expect(try await signIn(client, idp).status == .found)
            let userId = try await env.app.database.read { db in try #require(try UserStore.user(named: "alice", in: db)?.id) }
            let secret = TOTP.newSecret()
            _ = try await env.app.database.write { db in try MFAStore.activate(userId: userId, secret: secret, code: TOTP.code(secret: secret)!, in: db) }

            let challenge = try await signIn(client, idp, next: "/documents")
            #expect(challenge.status == .ok)
            #expect(challenge.text.contains("name=\"mfa_token\""))
            #expect(challenge.oidcCookie("sessionid") == nil)
            let token = try #require(challenge.text.range(of: "name=\"mfa_token\" value=\"").map { String(challenge.text[$0.upperBound...].prefix(40)) })
            let codes = try await env.app.database.write { db in try MFAStore.regenerateRecoveryCodes(userId: userId, in: db) }
            var form: HTTPFields = [:]
            form[.contentType] = "application/x-www-form-urlencoded"
            let done = try await client.call(.post, "/accounts/login/", headers: form, body: ByteBuffer(string: "mfa_token=\(token)&code=\(codes[0])"))
            #expect(done.status == .found)
            #expect(done.headers[.location] == "/documents")
            #expect(done.oidcCookie("sessionid") != nil)

            // The provider already asked for a second factor.
            idp.configure { $0.idTokenClaims["amr"] = ["pwd", "mfa"] }
            let trusted = try await signIn(client, idp)
            #expect(trusted.status == .found)
            #expect(trusted.oidcCookie("sessionid") != nil)
            // amr in userinfo only does not count.
            idp.configure { $0.idTokenClaims = [:]; $0.userinfo["amr"] = ["mfa"] }
            #expect(try await signIn(client, idp).text.contains("name=\"mfa_token\""))
        }
        // With DISABLE_REGULAR_LOGIN the code step still completes a social sign-in.
        let strict = try environment(idp, ["SOCIAL_AUTO_SIGNUP": "true", "DISABLE_REGULAR_LOGIN": "true"])
        try await run(strict, idp) { client in
            idp.configure { $0.userinfo["amr"] = nil }
            #expect(try await signIn(client, idp).status == .found)
            let userId = try await strict.app.database.read { db in try #require(try UserStore.user(named: "alice", in: db)?.id) }
            let secret = TOTP.newSecret()
            let codes = try await strict.app.database.write { db in try MFAStore.activate(userId: userId, secret: secret, code: TOTP.code(secret: secret)!, in: db) }
            let challenge = try await signIn(client, idp)
            let token = try #require(challenge.text.range(of: "name=\"mfa_token\" value=\"").map { String(challenge.text[$0.upperBound...].prefix(40)) })
            var form: HTTPFields = [:]
            form[.contentType] = "application/x-www-form-urlencoded"
            let done = try await client.call(.post, "/accounts/login/", headers: form, body: ByteBuffer(string: "mfa_token=\(token)&code=\(codes[0])"))
            #expect(done.status == .found)
        }
    }

    // MARK: - Profile

    @Test func profileProvidersConnectAndDisconnect() async throws {
        let idp = FakeIdP()
        let env = try environment(idp)
        let local = try env.user("local", password: "pw-local")
        let other = try env.user("other")
        try await run(env, idp) { client in
            let providers = try await client.get("/api/profile/social_account_providers/", as: local)
            #expect(providers.json == [["name": "Keycloak", "login_url": "/accounts/oidc/keycloak/login/?process=connect"]])
            #expect(try await client.get("/api/profile/social_account_providers/", as: nil).status == .unauthorized)

            var form: HTTPFields = [:]
            form[.contentType] = "application/x-www-form-urlencoded"
            let login = try await client.call(.post, "/accounts/login/", headers: form, body: ByteBuffer(string: "login=local&password=pw-local"))
            let session = try #require(login.oidcCookie("sessionid"))
            let csrf = try #require(login.oidcCookie("csrftoken"))

            // The confirm page carries the CSRF token; a POST without it is refused.
            let confirm = try await client.call(.get, "/accounts/oidc/keycloak/login/?process=connect", headers: Self.sessionHeaders(session))
            #expect(confirm.text.contains("name=\"csrfmiddlewaretoken\" value=\"\(csrf)\""))
            var forged = Self.sessionHeaders(session)
            forged[.contentType] = "application/x-www-form-urlencoded"
            #expect(try await client.call(.post, "/accounts/oidc/keycloak/login/", headers: forged, body: ByteBuffer(string: "process=connect")).status == .forbidden)

            let connected = try await signIn(client, idp, process: "connect", session: session, csrf: csrf)
            #expect(connected.status == .found)
            #expect(connected.headers[.location] == "/")
            #expect(connected.oidcCookie("sessionid") == nil)
            let profile = try await client.get("/api/profile/", as: local)
            let accounts = try #require(profile.json["social_accounts"]?.array)
            #expect(accounts.count == 1)
            let accountId = try #require(accounts.first?["id"]?.int)
            #expect(accounts.first?["name"] == "alice@example.com")

            // Another user cannot take over the same provider account.
            let otherLogin = try await env.app.database.write { db in try UserStore.createSession(userId: other.id, lifetime: 600, in: db) }
            let taken = try await signIn(client, idp, process: "connect", session: otherLogin.key, csrf: otherLogin.csrfToken)
            #expect(taken.headers[.location] == "/")
            #expect(try await client.get("/api/profile/", as: other).json["social_accounts"] == [])

            // The provider account now signs in as "local".
            let social = try await signIn(client, idp)
            let socialSession = try #require(social.oidcCookie("sessionid"))
            #expect(try await env.app.database.read { db in try UserStore.session(key: socialSession, in: db)?.userId } == local.id)

            // Disconnect: only the owner's accounts.
            let notMine = try await client.call(.post, "/api/profile/disconnect_social_account/", as: other, json: ["id": .int(accountId)])
            #expect(notMine.status == .badRequest)
            #expect(notMine.text == "Social account not found")
            #expect(try await client.call(.post, "/api/profile/disconnect_social_account/", as: local, json: [:]).status == .badRequest)
            let removed = try await client.call(.post, "/api/profile/disconnect_social_account/", as: local, json: ["id": .int(accountId)])
            #expect(removed.status == .ok)
            #expect(removed.json == .int(accountId))
            #expect(try await client.get("/api/profile/", as: local).json["social_accounts"] == [])
        }
    }

    @Test func connectMessagesReachTheFrontend() throws {
        let env = try TestEnvironment()
        let api = API(app: env.app, queue: env.queue)
        let session = Session(key: "k", userId: 1, csrfToken: "c", expires: Date().addingTimeInterval(60))
        api.flashMessages.set("k", [FlashMessage(level: "info", message: "Connected </script> & done")])
        let html = api.renderIndex(language: "en-US", messages: api.takeFlashMessages(session))
        #expect(html.contains("window.DJANGO_MESSAGES = [{ level: \"info\", message: \"Connected \\u003C"))
        #expect(html.contains("script\\u003E \\u0026 done\" },]"))
        #expect(!html.contains("</script> &"))
        #expect(api.takeFlashMessages(session).isEmpty)
    }

    @Test func profileNamesFollowAllauth() {
        func name(_ extra: JSON) -> String { SocialAccountStore.displayName(extraData: extra.jsonValue, providerName: "KC") }
        #expect(name(["userinfo": ["preferred_username": "a", "email": "a@x.example"]]) == "a@x.example")
        #expect(name(["id_token": ["given_name": "Ann", "family_name": "Lee"]]) == "Ann Lee")
        #expect(name(["userinfo": ["sub": "1"]]) == "KC")
        #expect(name(["groups": ["a"], "name": "Legacy"]) == "Legacy")
    }

    // MARK: - Import

    @Test func importsSocialAccountsFromPaperlessExport() async throws {
        let dir = TempDir()
        let root = dir.url.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manifest: [[String: Any]] = [
            ["model": "auth.user", "pk": 7, "fields": ["password": "!unusable", "username": "alice", "email": "alice@example.com", "first_name": "",
                                                        "last_name": "", "is_superuser": false, "is_staff": false, "is_active": true,
                                                        "date_joined": "2024-03-14T10:00:00Z", "last_login": NSNull(), "groups": [], "user_permissions": []]],
            ["model": "socialaccount.socialaccount", "pk": 3, "fields": ["user": 7, "provider": "keycloak", "uid": "user-1",
                                                                          "last_login": "2024-03-15T10:00:00Z", "date_joined": "2024-03-14T10:00:00Z",
                                                                          "extra_data": ["userinfo": ["sub": "user-1", "email": "alice@example.com"]]]],
            ["model": "socialaccount.socialapp", "pk": 1, "fields": ["provider": "openid_connect", "name": "Keycloak", "client_id": "x"]],
        ]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: ["version": "3.4.2"]).write(to: root.appendingPathComponent("metadata.json"))

        let idp = FakeIdP()
        let env = try environment(idp)
        let report = try await PaperlessImporter.run(app: env.app, source: root, options: .init())
        #expect(report.count("social accounts") == 1)
        #expect(report.skippedCount("socialaccount.socialapp") == 1)
        let account = try await env.app.database.read { db in try SocialAccount.fetchOne(db, key: 3) }
        #expect(account?.userId == 7 && account?.provider == "keycloak" && account?.uid == "user-1")

        // The imported link signs alice in without a signup.
        try await run(env, idp) { client in
            let response = try await signIn(client, idp)
            #expect(response.status == .found)
            let session = try #require(response.oidcCookie("sessionid"))
            #expect(try await env.app.database.read { db in try UserStore.session(key: session, in: db)?.userId } == 7)
        }

        // The exporter writes the link back in Paperless-ngx's shape.
        let records = try await env.app.database.read { db -> [ManifestRecord] in
            var builder = ManifestBuilder(db: db, settings: env.app.settings, storage: env.app.storage, options: PaperlessExportOptions(), crypto: nil)
            try builder.build()
            return builder.records
        }
        let exported = try #require(records.first { $0.model == "socialaccount.socialaccount" })
        #expect(exported.fields["provider"] == .string("keycloak") && exported.fields["user"] == .int(7))
    }
}
