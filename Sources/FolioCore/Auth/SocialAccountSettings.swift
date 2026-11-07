import Foundation

/// django-allauth social login settings as Paperless-ngx configures them
/// (`PAPERLESS_SOCIALACCOUNT_PROVIDERS`, `PAPERLESS_APPS`, `PAPERLESS_SOCIAL_*`).
///
/// FolioZero supports allauth's `openid_connect` provider. Its apps are active only
/// when `APPS` lists `allauth.socialaccount.providers.openid_connect`, as in Paperless-ngx.
public struct SocialAccountSettings: Sendable {
    public static let openIDConnectApp = "allauth.socialaccount.providers.openid_connect"

    /// Active OpenID Connect apps, in configuration order.
    public var providers: [OIDCProviderConfig] = []
    /// `SOCIAL_AUTO_SIGNUP` (allauth `SOCIALACCOUNT_AUTO_SIGNUP`), off by default in Paperless-ngx.
    public var autoSignup = false
    /// `SOCIALACCOUNT_ALLOW_SIGNUPS`.
    public var allowSignups = true
    /// `SOCIAL_ACCOUNT_DEFAULT_GROUPS`: groups for users who sign up through a provider.
    public var defaultGroups: [String] = []
    /// `ACCOUNT_DEFAULT_GROUPS`: groups for users who complete a signup form.
    public var accountDefaultGroups: [String] = []
    public var syncGroups = false
    public var syncGroupsClaim = "groups"
    public var syncSuperuserGroup: String?
    public var syncStaffGroup: String?
    /// `SOCIAL_ACCOUNT_MFA_TRUSTED_AMR`: ID token `amr` values that replace the local second factor.
    public var mfaTrustedAMR = ["mfa"]
    public var disableRegularLogin = false
    public var redirectLoginToSSO = false
    /// `ACCOUNT_DEFAULT_HTTP_PROTOCOL`: the scheme of callback URLs.
    public var defaultHTTPProtocol = "https"
    /// `LOGOUT_REDIRECT_URL`.
    public var logoutRedirectURL: String?
    /// Problems found while reading the settings, for the startup log.
    public var warnings: [String] = []

    public init() {}

    /// Reads the settings from `Settings.raw` (prefix removed).
    public init(raw: [String: String]) {
        func value(_ key: String) -> String? {
            guard let text = raw[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return text
        }
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            guard let text = value(key) else { return fallback }
            switch text.lowercased() {
            case "true", "1", "t", "y", "yes": return true
            case "false", "0", "f", "n", "no": return false
            default:
                warnings.append("\(key)=\(text) is not a boolean; using \(fallback)")
                return fallback
            }
        }
        // Paperless-ngx `get_list_from_env`: split on commas, trim, drop empty items.
        func list(_ key: String, _ fallback: [String] = []) -> [String] {
            guard let text = value(key) else { return fallback }
            return text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        autoSignup = bool("SOCIAL_AUTO_SIGNUP", false)
        allowSignups = bool("SOCIALACCOUNT_ALLOW_SIGNUPS", true)
        defaultGroups = list("SOCIAL_ACCOUNT_DEFAULT_GROUPS")
        accountDefaultGroups = list("ACCOUNT_DEFAULT_GROUPS")
        syncGroups = bool("SOCIAL_ACCOUNT_SYNC_GROUPS", false)
        syncGroupsClaim = value("SOCIAL_ACCOUNT_SYNC_GROUPS_CLAIM") ?? "groups"
        syncSuperuserGroup = value("SOCIAL_ACCOUNT_SYNC_SUPERUSER_GROUP")
        syncStaffGroup = value("SOCIAL_ACCOUNT_SYNC_STAFF_GROUP")
        mfaTrustedAMR = list("SOCIAL_ACCOUNT_MFA_TRUSTED_AMR", ["mfa"])
        disableRegularLogin = bool("DISABLE_REGULAR_LOGIN", false)
        redirectLoginToSSO = bool("REDIRECT_LOGIN_TO_SSO", false)
        defaultHTTPProtocol = value("ACCOUNT_DEFAULT_HTTP_PROTOCOL")?.lowercased() ?? "https"
        logoutRedirectURL = value("LOGOUT_REDIRECT_URL")

        guard let text = value("SOCIALACCOUNT_PROVIDERS") else { return }
        let parsed: JSONValue
        do {
            parsed = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        } catch {
            warnings.append("SOCIALACCOUNT_PROVIDERS is not valid JSON; social login is disabled")
            return
        }
        guard case .object(let providerMap) = parsed else {
            warnings.append("SOCIALACCOUNT_PROVIDERS must be a JSON object; social login is disabled")
            return
        }
        let installed = list("APPS").contains { $0.hasPrefix(Self.openIDConnectApp) }
        for name in providerMap.keys.sorted() where name != "openid_connect" {
            warnings.append("SOCIALACCOUNT_PROVIDERS: provider \"\(name)\" is not supported; FolioZero supports openid_connect only")
        }
        guard case .object(let oidc)? = providerMap["openid_connect"] else { return }
        let apps = Self.apps(oidc)
        guard installed else {
            if !apps.isEmpty {
                warnings.append("SOCIALACCOUNT_PROVIDERS configures openid_connect, but APPS does not list \(Self.openIDConnectApp); OpenID Connect login is disabled")
            }
            return
        }
        var seen = Set<String>()
        for app in apps {
            switch OIDCProviderConfig.make(app: app, provider: oidc) {
            case .success(let config):
                guard seen.insert(config.id).inserted else {
                    warnings.append("SOCIALACCOUNT_PROVIDERS: provider_id \"\(config.id)\" appears twice; the first app is used")
                    continue
                }
                providers.append(config)
            case .failure(let message):
                warnings.append("SOCIALACCOUNT_PROVIDERS: \(message.text)")
            }
        }
    }

    /// The `APPS` list, or `APP`, or allauth's legacy `SERVERS` list (`_migrate_oidc`).
    static func apps(_ provider: [String: JSONValue]) -> [[String: JSONValue]] {
        if case .array(let servers)? = provider["SERVERS"] {
            return servers.compactMap { server -> [String: JSONValue]? in
                guard case .object(let server) = server, case .object(var app)? = server["APP"] else { return nil }
                var appSettings: [String: JSONValue] = ["server_url": server["server_url"] ?? .null]
                if let method = server["token_auth_method"] { appSettings["token_auth_method"] = method }
                app["name"] = server["name"] ?? .string("")
                app["provider_id"] = server["id"] ?? .null
                app["settings"] = .object(appSettings)
                return app
            }
        }
        if case .array(let list)? = provider["APPS"] {
            return list.compactMap { if case .object(let app) = $0 { app } else { nil } }
        }
        if case .object(let app)? = provider["APP"] { return [app] }
        return []
    }

    public func provider(id: String) -> OIDCProviderConfig? {
        providers.first { $0.id == id }
    }

    /// Whether the ID token claims an authentication method listed in `SOCIAL_ACCOUNT_MFA_TRUSTED_AMR`
    /// (Paperless-ngx `SocialAccountAuthenticateStage`).
    public func trustsAMR(idToken: JSONValue?) -> Bool {
        guard !mfaTrustedAMR.isEmpty, case .object(let claims)? = idToken, case .array(let values)? = claims["amr"],
              !values.isEmpty else { return false }
        let methods = values.compactMap { if case .string(let text) = $0 { text } else { nil } }
        guard methods.count == values.count else { return false }
        return !Set(methods).isDisjoint(with: mfaTrustedAMR)
    }
}

/// One allauth `openid_connect` app (a `SocialApp`).
public struct OIDCProviderConfig: Sendable {
    public enum VerifiedEmail: Sendable, Equatable {
        case all(Bool)
        case domains([String])
    }

    /// `provider_id`: part of the login and callback URLs, and the `provider` of linked accounts.
    public var id: String
    public var name: String
    public var clientId: String
    public var secret: String
    /// The discovery document URL (`server_url` plus `/.well-known/openid-configuration`).
    public var serverURL: String
    /// `client_secret_basic` or `client_secret_post`; nil follows the discovery document.
    public var tokenAuthMethod: String?
    public var scope: [String]
    public var authParams: [(String, String)]
    public var pkceEnabled: Bool
    public var fetchUserinfo: Bool
    public var uidField: String
    /// Hidden apps get no button on the sign-in page.
    public var hidden: Bool
    /// Sign in to the local account with the same verified email address.
    public var emailAuthentication: Bool
    public var verifiedEmail: VerifiedEmail
    public var configurationOverrides: [String: JSONValue]

    public init(id: String, name: String, clientId: String, secret: String, serverURL: String, tokenAuthMethod: String? = nil,
                scope: [String] = ["openid", "profile", "email"], authParams: [(String, String)] = [], pkceEnabled: Bool = false,
                fetchUserinfo: Bool = true, uidField: String = "sub", hidden: Bool = false, emailAuthentication: Bool = false,
                verifiedEmail: VerifiedEmail = .all(false), configurationOverrides: [String: JSONValue] = [:]) {
        self.id = id; self.name = name; self.clientId = clientId; self.secret = secret
        self.serverURL = Self.wellKnownURL(serverURL); self.tokenAuthMethod = tokenAuthMethod; self.scope = scope
        self.authParams = authParams; self.pkceEnabled = pkceEnabled; self.fetchUserinfo = fetchUserinfo
        self.uidField = uidField; self.hidden = hidden; self.emailAuthentication = emailAuthentication
        self.verifiedEmail = verifiedEmail; self.configurationOverrides = configurationOverrides
    }

    /// allauth `wk_server_url`: append the well-known path unless the URL already has one.
    public static func wellKnownURL(_ url: String) -> String {
        url.contains("/.well-known/") ? url : url + "/.well-known/openid-configuration"
    }

    /// Whether `email` counts as verified by the provider (allauth `is_email_verified`).
    public func isEmailVerified(_ email: String) -> Bool {
        switch verifiedEmail {
        case .all(let value): return value
        case .domains(let domains):
            let domain = email.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map { $0.lowercased() } ?? ""
            return domains.contains { $0.lowercased() == domain }
        }
    }

    struct Problem: Error { var text: String }

    /// Builds an app from its JSON. App `settings` win over the provider-wide keys (`SCOPE`, `AUTH_PARAMS`, ...).
    static func make(app: [String: JSONValue], provider: [String: JSONValue]) -> Result<OIDCProviderConfig, Problem> {
        func string(_ value: JSONValue?) -> String? {
            if case .string(let text)? = value { return text }
            return nil
        }
        let settings: [String: JSONValue] = if case .object(let object)? = app["settings"] { object } else { [:] }
        guard let id = string(app["provider_id"]), !id.isEmpty else {
            return .failure(Problem(text: "an openid_connect app has no provider_id; it is ignored"))
        }
        guard !id.contains("/"), id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) == id else {
            return .failure(Problem(text: "provider_id \"\(id)\" cannot be used in a URL; the app is ignored"))
        }
        guard let server = string(settings["server_url"]), !server.isEmpty else {
            return .failure(Problem(text: "app \"\(id)\" has no settings.server_url; it is ignored"))
        }
        guard let clientId = string(app["client_id"]), !clientId.isEmpty else {
            return .failure(Problem(text: "app \"\(id)\" has no client_id; it is ignored"))
        }
        func stringList(_ value: JSONValue?) -> [String]? {
            guard case .array(let items)? = value else { return nil }
            return items.compactMap { string($0) }
        }
        func pairs(_ value: JSONValue?) -> [(String, String)]? {
            guard case .object(let object)? = value else { return nil }
            return object.keys.sorted().compactMap { key in object[key]?.stringValue.map { (key, $0) } }
        }
        func flag(_ value: JSONValue?) -> Bool? {
            if case .bool(let flag)? = value { return flag }
            return value?.boolValue
        }
        let verified: VerifiedEmail
        switch settings["verified_email"] ?? provider["VERIFIED_EMAIL"] {
        case .array(let items)?: verified = .domains(items.compactMap { string($0) })
        case let other?: verified = .all(flag(other) ?? false)
        case nil: verified = .all(false)
        }
        let overrides: [String: JSONValue] = if case .object(let object)? = settings["openid_configuration_overrides"] { object } else { [:] }
        var config = OIDCProviderConfig(
            id: id,
            name: string(app["name"]) ?? "",
            clientId: clientId,
            secret: string(app["secret"]) ?? "",
            serverURL: server,
            tokenAuthMethod: string(settings["token_auth_method"]).flatMap { $0.isEmpty ? nil : $0 },
            scope: stringList(settings["scope"]) ?? stringList(provider["SCOPE"]) ?? ["openid", "profile", "email"],
            authParams: pairs(settings["auth_params"]) ?? pairs(provider["AUTH_PARAMS"]) ?? [],
            pkceEnabled: flag(settings["oauth_pkce_enabled"]) ?? flag(provider["OAUTH_PKCE_ENABLED"]) ?? false,
            fetchUserinfo: flag(settings["fetch_userinfo"]) ?? true,
            uidField: string(settings["uid_field"]) ?? "sub",
            hidden: flag(settings["hidden"]) ?? false,
            emailAuthentication: flag(settings["email_authentication"]) ?? flag(provider["EMAIL_AUTHENTICATION"]) ?? false,
            verifiedEmail: verified,
            configurationOverrides: overrides
        )
        if config.name.isEmpty { config.name = "OpenID Connect" }
        return .success(config)
    }
}
