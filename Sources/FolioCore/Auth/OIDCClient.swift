import CryptoKit
import Foundation
import Security

/// Sends one HTTP request. Tests replace it with a fake identity provider.
public typealias OIDCTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

public enum OIDCError: Error, CustomStringConvertible, Equatable {
    case network(String)
    case discovery(String)
    case tokenRequest(String)
    case invalidIDToken(String)
    case userinfo(String)

    public var description: String {
        switch self {
        case .network(let why): "request failed: \(why)"
        case .discovery(let why): "discovery failed: \(why)"
        case .tokenRequest(let why): "token request failed: \(why)"
        case .invalidIDToken(let why): "invalid ID token: \(why)"
        case .userinfo(let why): "userinfo request failed: \(why)"
        }
    }
}

/// The parts of an OpenID Provider's discovery document FolioZero uses.
public struct OIDCDiscovery: Sendable {
    public var issuer: String
    public var authorizationEndpoint: String
    public var tokenEndpoint: String
    public var userinfoEndpoint: String?
    public var jwksURI: String?
    public var tokenEndpointAuthMethods: [String]
}

/// The authorization code flow of allauth's `openid_connect` provider, with ID token signature checks.
///
/// Requests never carry secrets in URLs, and error messages never quote tokens.
public final class OIDCClient: Sendable {
    let transport: OIDCTransport
    let timeout: TimeInterval
    private let state = Locked()

    private final class Locked: @unchecked Sendable {
        let lock = NSLock()
        var discovery: [String: (OIDCDiscovery, Date)] = [:]
        var usedTokenIds: [String: Date] = [:]
    }

    public init(transport: OIDCTransport? = nil, timeout: TimeInterval = 10) {
        self.transport = transport ?? Self.liveTransport
        self.timeout = timeout
    }

    /// URLSession without cookies or caches.
    public static let liveTransport: OIDCTransport = { request in
        let (data, response) = try await liveSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw OIDCError.network("not an HTTP response") }
        return (data, http)
    }

    private static let liveSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    // MARK: Requests

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        guard let scheme = request.url?.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw OIDCError.network("only http and https URLs are allowed")
        }
        do {
            return try await transport(request)
        } catch let error as OIDCError {
            throw error
        } catch {
            throw OIDCError.network((error as? URLError)?.localizedDescription ?? String(describing: type(of: error)))
        }
    }

    func getJSON(_ url: String, headers: [String: String] = [:], error: (String) -> OIDCError) async throws -> [String: JSONValue] {
        guard let target = URL(string: url) else { throw error("invalid URL") }
        var request = URLRequest(url: target, timeoutInterval: timeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else { throw error("HTTP \(response.statusCode)") }
        guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw error("the response is not a JSON object")
        }
        return object
    }

    // MARK: Discovery

    /// The provider's discovery document with `openid_configuration_overrides` applied. Cached for five minutes.
    public func discover(_ provider: OIDCProviderConfig) async throws -> OIDCDiscovery {
        let cacheKey = provider.id + "\n" + provider.serverURL
        if let cached = state.lock.withLock({ state.discovery[cacheKey] }), cached.1 > Date() { return cached.0 }
        var document = try await getJSON(provider.serverURL) { OIDCError.discovery($0) }
        document.merge(provider.configurationOverrides) { _, override in override }
        func string(_ key: String) -> String? {
            if case .string(let text)? = document[key], !text.isEmpty { return text }
            return nil
        }
        guard let issuer = string("issuer"), let authorization = string("authorization_endpoint"), let token = string("token_endpoint") else {
            throw OIDCError.discovery("issuer, authorization_endpoint or token_endpoint is missing")
        }
        var methods: [String] = []
        if case .array(let items)? = document["token_endpoint_auth_methods_supported"] {
            methods = items.compactMap { if case .string(let text) = $0 { text } else { nil } }
        }
        let discovery = OIDCDiscovery(issuer: issuer, authorizationEndpoint: authorization, tokenEndpoint: token,
                                      userinfoEndpoint: string("userinfo_endpoint"), jwksURI: string("jwks_uri"),
                                      tokenEndpointAuthMethods: methods)
        state.lock.withLock { state.discovery[cacheKey] = (discovery, Date().addingTimeInterval(300)) }
        return discovery
    }

    /// allauth `basic_auth`: the configured method, else Basic only when the provider lists it but not `client_secret_post`.
    public static func usesBasicAuth(_ provider: OIDCProviderConfig, _ discovery: OIDCDiscovery) -> Bool {
        if let method = provider.tokenAuthMethod { return method == "client_secret_basic" }
        let methods = discovery.tokenEndpointAuthMethods
        return !methods.contains("client_secret_post") && methods.contains("client_secret_basic")
    }

    // MARK: Authorization request

    /// A PKCE pair as allauth makes it: a 128-character verifier and its S256 challenge.
    public static func makePKCE() -> (verifier: String, challenge: String) {
        let verifier = PasswordHasher.randomString(length: 128)
        let challenge = base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        return (verifier, challenge)
    }

    /// The provider's authorization URL (allauth `OAuth2Client.get_redirect_url`, plus a nonce).
    public static func authorizationURL(discovery: OIDCDiscovery, provider: OIDCProviderConfig, redirectURI: String, scope: [String],
                                        state: String, nonce: String, authParams: [(String, String)], codeChallenge: String?) -> String {
        var seen = Set<String>()
        let scopes = scope.filter { seen.insert($0).inserted }
        var params: [(String, String)] = [
            ("client_id", provider.clientId), ("redirect_uri", redirectURI), ("scope", scopes.joined(separator: " ")),
            ("response_type", "code"), ("state", state),
        ]
        for (name, value) in authParams {
            params.removeAll { $0.0 == name }
            params.append((name, value))
        }
        if let codeChallenge {
            params.append(("code_challenge", codeChallenge))
            params.append(("code_challenge_method", "S256"))
        }
        if !params.contains(where: { $0.0 == "nonce" }) { params.append(("nonce", nonce)) }
        let separator = discovery.authorizationEndpoint.contains("?") ? "&" : "?"
        return discovery.authorizationEndpoint + separator + formEncode(params)
    }

    // MARK: Token request

    /// Exchanges the authorization code (allauth `OAuth2Client.get_access_token`).
    public func exchangeCode(_ code: String, provider: OIDCProviderConfig, discovery: OIDCDiscovery, redirectURI: String,
                             codeVerifier: String?) async throws -> [String: JSONValue] {
        guard let url = URL(string: discovery.tokenEndpoint) else { throw OIDCError.tokenRequest("invalid token endpoint") }
        var params: [(String, String)] = [("redirect_uri", redirectURI), ("grant_type", "authorization_code"), ("code", code)]
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        if Self.usesBasicAuth(provider, discovery) {
            let credentials = Data("\(provider.clientId):\(provider.secret)".utf8).base64EncodedString()
            request.setValue("Basic \(credentials)", forHTTPHeaderField: "Authorization")
        } else {
            params.append(("client_id", provider.clientId))
            params.append(("client_secret", provider.secret))
        }
        params.removeAll { $0.1.isEmpty }
        if let codeVerifier { params.append(("code_verifier", codeVerifier)) }
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(Self.formEncode(params).utf8)
        let (data, response) = try await send(request)
        var object: [String: JSONValue]?
        if response.statusCode == 200 || response.statusCode == 201 {
            let type = (response.value(forHTTPHeaderField: "Content-Type") ?? "").split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) }
            if type == "application/json" || data.starts(with: Data("{\"".utf8)) {
                if case .object(let parsed)? = try? JSONDecoder().decode(JSONValue.self, from: data) { object = parsed }
            } else {
                var pairs: [String: JSONValue] = [:]
                for item in String(decoding: data, as: UTF8.self).split(separator: "&") {
                    let kv = item.split(separator: "=", maxSplits: 1).map { String($0).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String($0) }
                    if kv.count == 2 { pairs[kv[0]] = .string(kv[1]) }
                }
                object = pairs
            }
        }
        guard let object, case .string(let accessToken)? = object["access_token"], !accessToken.isEmpty else {
            throw OIDCError.tokenRequest("HTTP \(response.statusCode)\(Self.oauthError(data).map { ": " + $0 } ?? "")")
        }
        return object
    }

    /// `error` and `error_description` of an OAuth error response, never the whole body.
    static func oauthError(_ data: Data) -> String? {
        guard case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .string(let error)? = object["error"] else { return nil }
        var text = error
        if case .string(let description)? = object["error_description"] { text += " (\(description.prefix(200)))" }
        return text
    }

    // MARK: Userinfo

    public func userinfo(accessToken: String, discovery: OIDCDiscovery) async throws -> [String: JSONValue] {
        guard let endpoint = discovery.userinfoEndpoint else { throw OIDCError.userinfo("the provider has no userinfo_endpoint") }
        return try await getJSON(endpoint, headers: ["Authorization": "Bearer \(accessToken)"]) { OIDCError.userinfo($0) }
    }

    // MARK: ID token

    /// Checks the ID token's signature (JWKS, or the client secret for HS*), issuer, audience, expiry and nonce.
    public func verifyIDToken(_ token: String, provider: OIDCProviderConfig, discovery: OIDCDiscovery, nonce: String?,
                              now: Date = Date()) async throws -> [String: JSONValue] {
        let jwt = try JWT(token)
        let alg = jwt.algorithm
        if alg.hasPrefix("HS") {
            guard !provider.secret.isEmpty else { throw OIDCError.invalidIDToken("\(alg) needs a client secret") }
            guard try jwt.verify(hmacSecret: Data(provider.secret.utf8)) else { throw OIDCError.invalidIDToken("bad signature") }
        } else {
            guard let jwksURI = discovery.jwksURI else { throw OIDCError.invalidIDToken("the provider has no jwks_uri") }
            let jwks = try await getJSON(jwksURI) { OIDCError.invalidIDToken("cannot load the signing keys: \($0)") }
            guard case .array(let keys)? = jwks["keys"] else { throw OIDCError.invalidIDToken("the JWKS has no keys") }
            let candidates = keys.compactMap { key -> [String: JSONValue]? in
                guard case .object(let jwk) = key else { return nil }
                if let kid = jwt.keyId, let keyId = jwk["kid"]?.stringValue, keyId != kid { return nil }
                if jwk["use"]?.stringValue == "enc" { return nil }
                if let keyAlg = jwk["alg"]?.stringValue, keyAlg != alg { return nil }
                return jwk
            }
            guard !candidates.isEmpty else { throw OIDCError.invalidIDToken("no signing key matches kid \(jwt.keyId ?? "(none)")") }
            guard try candidates.contains(where: { try jwt.verify(jwk: $0) }) else { throw OIDCError.invalidIDToken("bad signature") }
        }
        try validateClaims(jwt.claims, provider: provider, discovery: discovery, nonce: nonce, now: now)
        return jwt.claims
    }

    func validateClaims(_ claims: [String: JSONValue], provider: OIDCProviderConfig, discovery: OIDCDiscovery, nonce: String?, now: Date) throws {
        guard claims["iss"]?.stringValue == discovery.issuer else { throw OIDCError.invalidIDToken("wrong issuer") }
        let audiences: [String] = switch claims["aud"] {
        case .string(let audience)?: [audience]
        case .array(let items)?: items.compactMap { if case .string(let text) = $0 { text } else { nil } }
        default: []
        }
        guard audiences.contains(provider.clientId) else { throw OIDCError.invalidIDToken("wrong audience") }
        let time = now.timeIntervalSince1970
        guard let exp = claims["exp"]?.doubleValue else { throw OIDCError.invalidIDToken("no expiry") }
        guard time < exp else { throw OIDCError.invalidIDToken("expired") }
        if let nbf = claims["nbf"] {
            guard let value = nbf.doubleValue, time + 30 >= value else { throw OIDCError.invalidIDToken("not yet valid") }
        }
        if let iat = claims["iat"] {
            guard let value = iat.doubleValue, time + 30 >= value else { throw OIDCError.invalidIDToken("issued in the future") }
        }
        // The nonce is FolioZero's addition: allauth sends none. A provider that returns one must return ours.
        if let nonce, let returned = claims["nonce"], returned.stringValue != nonce {
            throw OIDCError.invalidIDToken("wrong nonce")
        }
        // allauth `verify_jti`: each token identifier once until it expires.
        if let jti = claims["jti"]?.stringValue {
            let key = "\(discovery.issuer)\n\(jti)"
            let replayed = state.lock.withLock { () -> Bool in
                let current = Date()
                if state.usedTokenIds.count > 5000 { state.usedTokenIds = state.usedTokenIds.filter { $0.value > current } }
                if let until = state.usedTokenIds[key], until > current { return true }
                state.usedTokenIds[key] = Date(timeIntervalSince1970: exp)
                return false
            }
            if replayed { throw OIDCError.invalidIDToken("token already used") }
        }
    }

    // MARK: Encoding

    /// `application/x-www-form-urlencoded` as Python's `urlencode` writes it (spaces become `+`).
    public static func formEncode(_ params: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~ ")
        func encode(_ text: String) -> String {
            (text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text).replacingOccurrences(of: " ", with: "+")
        }
        return params.map { encode($0.0) + "=" + encode($0.1) }.joined(separator: "&")
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func base64URLDecode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        return Data(base64Encoded: base64)
    }
}

/// A signed JWT in compact form (JWS). Supports RS*, PS*, ES*, EdDSA and HS*.
public struct JWT: Sendable {
    public let header: [String: JSONValue]
    public let claims: [String: JSONValue]
    let signingInput: Data
    let signature: Data

    public var algorithm: String { header["alg"]?.stringValue ?? "" }
    public var keyId: String? { header["kid"]?.stringValue }

    public init(_ token: String) throws {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { throw OIDCError.invalidIDToken("not a signed JWT") }
        guard let headerData = OIDCClient.base64URLDecode(String(parts[0])),
              case .object(let header)? = try? JSONDecoder().decode(JSONValue.self, from: headerData),
              let payloadData = OIDCClient.base64URLDecode(String(parts[1])),
              case .object(let claims)? = try? JSONDecoder().decode(JSONValue.self, from: payloadData),
              let signature = OIDCClient.base64URLDecode(String(parts[2])) else {
            throw OIDCError.invalidIDToken("malformed JWT")
        }
        guard header["crit"] == nil else { throw OIDCError.invalidIDToken("unsupported critical header") }
        let alg = header["alg"]?.stringValue ?? ""
        guard Self.supported.contains(alg) else { throw OIDCError.invalidIDToken("unsupported algorithm \(alg.isEmpty ? "(none)" : alg)") }
        self.header = header
        self.claims = claims
        self.signingInput = Data("\(parts[0]).\(parts[1])".utf8)
        self.signature = signature
    }

    static let supported: Set<String> = ["RS256", "RS384", "RS512", "PS256", "PS384", "PS512", "ES256", "ES384", "ES512",
                                         "EdDSA", "HS256", "HS384", "HS512"]

    func verify(hmacSecret: Data) throws -> Bool {
        let key = SymmetricKey(data: hmacSecret)
        switch algorithm {
        case "HS256": return HMAC<SHA256>.isValidAuthenticationCode(signature, authenticating: signingInput, using: key)
        case "HS384": return HMAC<SHA384>.isValidAuthenticationCode(signature, authenticating: signingInput, using: key)
        case "HS512": return HMAC<SHA512>.isValidAuthenticationCode(signature, authenticating: signingInput, using: key)
        default: return false
        }
    }

    /// Verifies against one JWK. Keys of another type are no match.
    func verify(jwk: [String: JSONValue]) throws -> Bool {
        func bytes(_ name: String) -> Data? { jwk[name]?.stringValue.flatMap(OIDCClient.base64URLDecode) }
        let kty = jwk["kty"]?.stringValue
        switch algorithm {
        case "RS256", "RS384", "RS512", "PS256", "PS384", "PS512":
            guard kty == "RSA", let n = bytes("n"), let e = bytes("e") else { return false }
            let key = try Self.rsaPublicKey(modulus: n, exponent: e)
            let algorithms: [String: SecKeyAlgorithm] = [
                "RS256": .rsaSignatureMessagePKCS1v15SHA256, "RS384": .rsaSignatureMessagePKCS1v15SHA384,
                "RS512": .rsaSignatureMessagePKCS1v15SHA512, "PS256": .rsaSignatureMessagePSSSHA256,
                "PS384": .rsaSignatureMessagePSSSHA384, "PS512": .rsaSignatureMessagePSSSHA512,
            ]
            return SecKeyVerifySignature(key, algorithms[algorithm]!, signingInput as CFData, signature as CFData, nil)
        case "ES256", "ES384", "ES512":
            let curves = ["ES256": "P-256", "ES384": "P-384", "ES512": "P-521"]
            guard kty == "EC", jwk["crv"]?.stringValue == curves[algorithm], let x = bytes("x"), let y = bytes("y") else { return false }
            let point = Data([0x04]) + x + y
            do {
                switch algorithm {
                case "ES256":
                    return try P256.Signing.PublicKey(x963Representation: point)
                        .isValidSignature(P256.Signing.ECDSASignature(rawRepresentation: signature), for: signingInput)
                case "ES384":
                    return try P384.Signing.PublicKey(x963Representation: point)
                        .isValidSignature(P384.Signing.ECDSASignature(rawRepresentation: signature), for: signingInput)
                default:
                    return try P521.Signing.PublicKey(x963Representation: point)
                        .isValidSignature(P521.Signing.ECDSASignature(rawRepresentation: signature), for: signingInput)
                }
            } catch {
                return false
            }
        case "EdDSA":
            guard kty == "OKP", jwk["crv"]?.stringValue == "Ed25519", let x = bytes("x"),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: x) else { return false }
            return key.isValidSignature(signature, for: signingInput)
        default:
            return false
        }
    }

    /// An RSA public key from its modulus and exponent (PKCS #1 `RSAPublicKey` DER).
    static func rsaPublicKey(modulus: Data, exponent: Data) throws -> SecKey {
        func length(_ count: Int) -> Data {
            if count < 0x80 { return Data([UInt8(count)]) }
            var bytes: [UInt8] = []
            var value = count
            while value > 0 { bytes.insert(UInt8(value & 0xff), at: 0); value >>= 8 }
            return Data([0x80 | UInt8(bytes.count)] + bytes)
        }
        func integer(_ data: Data) -> Data {
            var bytes = Array(data.drop { $0 == 0 })
            if bytes.isEmpty { bytes = [0] }
            if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
            return Data([0x02]) + length(bytes.count) + Data(bytes)
        }
        let body = integer(modulus) + integer(exponent)
        let der = Data([0x30]) + length(body.count) + body
        let attributes: [CFString: Any] = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else {
            throw OIDCError.invalidIDToken("unusable RSA key")
        }
        return key
    }
}
