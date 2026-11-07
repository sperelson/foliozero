import Foundation
import FolioCore
import GRDB
import HTTPTypes
import Hummingbird

/// A sign-in sent to an identity provider, waiting for its callback.
struct PendingSocialLogin: Sendable {
    var providerId: String
    /// allauth `process`: `login`, `connect` or `redirect`.
    var process: String
    var next: String?
    var nonce: String
    var codeVerifier: String?
    /// The browser-binding cookie value set when the sign-in started.
    var browserKey: String
    /// The signed-in user who asked to connect an account.
    var userId: Int?
    var redirectURI: String
}

/// A new social user who still has to fill in the signup form.
struct PendingSocialSignup: Sendable {
    var providerId: String
    var profile: SocialProfile
    var next: String?
}

/// A Django message shown once by the frontend.
struct FlashMessage: Sendable, Equatable {
    var level: String
    var message: String
}

/// OpenID Connect sign-in in the shape of django-allauth's `openid_connect` provider, with
/// Paperless-ngx's adapter rules: auto signup, signup closing, default groups, group sync and
/// the two-factor stage that a trusted `amr` claim skips.
extension API {
    var socialStateCookieName: String { "\(settings.cookiePrefix)socialaccount_state" }

    static func socialLoginPath(_ providerId: String) -> String { "/accounts/oidc/\(providerId)/login/" }

    /// allauth `get_callback_url`: the request's host, with `ACCOUNT_DEFAULT_HTTP_PROTOCOL` (https by default).
    func socialCallbackURL(_ request: APIRequest, providerId: String) -> String {
        let scheme = social.defaultHTTPProtocol == "https" ? "https" : "http"
        let host = request.host ?? settings.url.flatMap { URL(string: $0) }.flatMap { url in url.host.map { $0 + (url.port.map { ":\($0)" } ?? "") } } ?? "localhost"
        return "\(scheme)://\(host)\(Self.socialLoginPath(providerId))callback/"
    }

    // MARK: - Sign-in page

    /// The provider buttons below the sign-in form (Paperless-ngx `account/login.html`).
    func socialLoginButtons(_ request: APIRequest) -> String {
        let visible = social.providers.filter { !$0.hidden }
        guard !visible.isEmpty else { return "" }
        let next = Self.safeRedirect(request.query["next"])
        let csrf = request.auth?.session.map { "<input type=\"hidden\" name=\"csrfmiddlewaretoken\" value=\"\(Self.htmlEscape($0.csrfToken))\">" } ?? ""
        var html = social.disableRegularLogin ? "" : "<p class=\"mt-3\">or sign in via</p>\n"
        html += "<ul class=\"m-0 p-0\">\n"
        for (index, provider) in visible.enumerated() {
            var action = Self.socialLoginPath(provider.id)
            if let next { action += "?" + OIDCClient.formEncode([("next", next)]) }
            html += """
                <li class="d-grid mt-3"><form id="social-login" class="d-grid" method="POST" action="\(Self.htmlEscape(action))">\(csrf)
                <button type="submit" class="btn btn-secondary">\(Self.htmlEscape(provider.name))</button></form></li>

                """
            if index == 0, social.redirectLoginToSSO, request.query["loggedout"] != "1" {
                html += """
                    <script type="text/javascript">
                    const form = document.getElementById('social-login');
                    if (form) { form.submit(); }
                    </script>

                    """
            }
        }
        return html + "</ul>"
    }

    // MARK: - Starting the sign-in

    func socialProvider(_ request: APIRequest) throws -> OIDCProviderConfig {
        guard let id = request.params["provider_id"], let provider = social.provider(id: id) else { throw APIError.notFound() }
        return provider
    }

    /// `GET /accounts/oidc/<id>/login/`: allauth asks before it leaves the site (`SOCIALACCOUNT_LOGIN_ON_GET` is off).
    func socialLoginConfirmPage(_ request: APIRequest) async throws -> Response {
        let provider = try socialProvider(request)
        let encoded = request.query.encoded
        let action = request.path + (encoded.isEmpty ? "" : "?" + encoded)
        var content = """
            <p>You are about to connect a new third-party account from \(Self.htmlEscape(provider.name)).</p>
            <div class="d-grid mt-3"><button class="btn btn-lg btn-primary" type="submit">Continue</button></div>
            """
        if social.redirectLoginToSSO {
            content += "\n<script type=\"text/javascript\">const form = document.getElementById('form-account'); if (form) { form.submit(); }</script>"
        }
        return accountPage(request, title: "social account sign in", action: action, content: content)
    }

    /// `POST /accounts/oidc/<id>/login/`: remembers state, nonce and PKCE verifier, then redirects to the provider.
    func socialLoginStart(_ request: APIRequest) async throws -> Response {
        let provider = try socialProvider(request)
        let data = try request.data()
        func param(_ name: String) -> String? {
            if let value = data[name]?.string, !value.isEmpty { return value }
            return request.query[name]
        }
        let process = param("process").flatMap { $0.isEmpty ? nil : $0 } ?? "login"
        let next = Self.safeRedirect(param("next"))
        var scope = provider.scope
        if let extra = param("scope") { scope += extra.split(separator: ",").map(String.init) }
        var authParams = provider.authParams
        if let extra = param("auth_params") {
            for item in QueryItems(extra).items {
                authParams.removeAll { $0.0 == item.name }
                authParams.append((item.name, item.value))
            }
        }

        let discovery: OIDCDiscovery
        do {
            discovery = try await oidc.discover(provider)
        } catch {
            return socialAuthenticationError(request, provider: provider, reason: String(describing: error))
        }
        let state = PasswordHasher.randomString(length: 32)
        let nonce = PasswordHasher.randomString(length: 32)
        let pkce = provider.pkceEnabled ? OIDCClient.makePKCE() : nil
        let browserKey = request.cookieValue(socialStateCookieName).flatMap { $0.count == 32 ? $0 : nil } ?? PasswordHasher.randomString(length: 32)
        let redirectURI = socialCallbackURL(request, providerId: provider.id)
        pendingSocialLogins.set(state, PendingSocialLogin(
            providerId: provider.id, process: process, next: next, nonce: nonce, codeVerifier: pkce?.verifier,
            browserKey: browserKey, userId: request.auth?.access.userId, redirectURI: redirectURI))
        let url = OIDCClient.authorizationURL(discovery: discovery, provider: provider, redirectURI: redirectURI, scope: scope,
                                              state: state, nonce: nonce, authParams: authParams, codeChallenge: pkce?.challenge)
        var response = Response.redirect(url)
        response.setCookie(Cookie(name: socialStateCookieName, value: browserKey, maxAge: 600, path: "/", httpOnly: true, sameSite: .lax))
        return response
    }

    // MARK: - Callback

    /// `GET /accounts/oidc/<id>/login/callback/`: checks state, exchanges the code, verifies the ID token,
    /// then signs in, connects or starts a signup.
    func socialCallback(_ request: APIRequest) async throws -> Response {
        let provider = try socialProvider(request)
        guard let state = request.query["state"], !state.isEmpty, let pending = pendingSocialLogins.get(state) else {
            return socialAuthenticationError(request, provider: provider, reason: "unknown or expired state")
        }
        pendingSocialLogins.remove(state)
        guard pending.providerId == provider.id, let browserKey = request.cookieValue(socialStateCookieName),
              Self.constantTimeEqual(browserKey, pending.browserKey) else {
            return socialAuthenticationError(request, provider: provider, reason: "the state belongs to another browser")
        }
        if let error = request.query["error"] {
            if error == "access_denied" { return .redirect("/accounts/3rdparty/login/cancelled/") }
            return socialAuthenticationError(request, provider: provider, reason: "the provider returned \(error)")
        }
        guard let code = request.query["code"], !code.isEmpty else {
            return socialAuthenticationError(request, provider: provider, reason: "no authorization code")
        }

        let profile: SocialProfile
        do {
            let discovery = try await oidc.discover(provider)
            let tokens = try await oidc.exchangeCode(code, provider: provider, discovery: discovery, redirectURI: pending.redirectURI,
                                                     codeVerifier: pending.codeVerifier)
            var idToken: [String: JSONValue]?
            if case .string(let raw)? = tokens["id_token"], !raw.isEmpty {
                idToken = try await oidc.verifyIDToken(raw, provider: provider, discovery: discovery, nonce: pending.nonce)
            }
            var userinfo: [String: JSONValue]?
            if case .string(let accessToken)? = tokens["access_token"], idToken == nil || (provider.fetchUserinfo && discovery.userinfoEndpoint != nil) {
                userinfo = try await oidc.userinfo(accessToken: accessToken, discovery: discovery)
            }
            if let claimed = userinfo?["sub"]?.stringValue, let subject = idToken?["sub"]?.stringValue, claimed != subject {
                throw OIDCError.userinfo("the userinfo subject differs from the ID token subject")
            }
            profile = try SocialProfile.make(userinfo: userinfo, idToken: idToken, provider: provider)
        } catch {
            return socialAuthenticationError(request, provider: provider, reason: String(describing: error))
        }

        switch pending.process {
        case "connect":
            return try await socialConnect(request, provider: provider, profile: profile, pending: pending)
        case "redirect":
            return .redirect(pending.next ?? "/")
        default:
            return try await socialAuthenticate(request, provider: provider, profile: profile, next: pending.next)
        }
    }

    /// allauth `_authenticate`: an existing account signs in; a new one signs up.
    func socialAuthenticate(_ request: APIRequest, provider: OIDCProviderConfig, profile: SocialProfile, next: String?) async throws -> Response {
        enum Lookup: Sendable { case existing(Int), new }
        let settings = social
        let lookup = try await write { db -> Lookup in
            if let account = try SocialAccountStore.account(provider: provider.id, uid: profile.uid, in: db) {
                // allauth `social_account_updated`: new claims, then Paperless-ngx's group sync.
                _ = try SocialAccountStore.update(account, extraData: profile.extraData, in: db)
                try SocialAccountStore.syncFromProvider(userId: account.userId, extraData: profile.extraData, settings: settings, in: db)
                return .existing(account.userId)
            }
            if provider.emailAuthentication, profile.emailVerified, let email = profile.email,
               let user = try SocialAccountStore.users(withEmail: email, in: db).first, let id = user.id {
                // allauth `wipe_password`: FolioZero keeps no verified addresses, so the local password goes.
                // Django ends the user's other sessions when the password hash changes.
                if !user.password.isEmpty {
                    try db.execute(sql: "UPDATE users SET password = '' WHERE id = ?", arguments: [id])
                    try db.execute(sql: "DELETE FROM sessions WHERE user_id = ?", arguments: [id])
                }
                return .existing(id)
            }
            return .new
        }
        switch lookup {
        case .existing(let userId):
            return try await finishSocialLogin(request, userId: userId, next: next, extraData: profile.extraData)
        case .new:
            return try await socialSignupOrForm(request, provider: provider, profile: profile, next: next)
        }
    }

    /// allauth `process_signup`: auto signup when allowed and the email address is free, else the signup form.
    func socialSignupOrForm(_ request: APIRequest, provider: OIDCProviderConfig, profile: SocialProfile, next: String?) async throws -> Response {
        guard social.allowSignups else { return signupClosedPage(request) }
        if social.autoSignup {
            let settings = social
            let user = try await write { db -> User? in
                if let email = profile.email, try !SocialAccountStore.users(withEmail: email, in: db).isEmpty { return nil }
                // allauth `clean_username`, then `populate_username` for a missing, invalid or taken name.
                var username = profile.username ?? ""
                let usable = try SocialAccountStore.isValidUsername(username) && !SocialAccountStore.isUsernameTaken(username, in: db)
                if !usable {
                    username = try SocialAccountStore.uniqueUsername(from: [profile.firstName, profile.lastName, profile.email, "user"], in: db)
                }
                return try SocialAccountStore.signUp(username: username, email: profile.email ?? "", provider: provider.id, profile: profile,
                                                     fromForm: false, settings: settings, in: db)
            }
            if let user, let id = user.id {
                logger.info("Social signup of `\(user.username)` through `\(provider.id)`")
                return try await finishSocialLogin(request, userId: id, next: next, extraData: profile.extraData)
            }
        }
        let token = PasswordHasher.randomString(length: 40)
        pendingSocialSignups.set(token, PendingSocialSignup(providerId: provider.id, profile: profile, next: next))
        return socialSignupForm(request, token: token, provider: provider, username: profile.username ?? "", email: profile.email ?? "", errors: [])
    }

    /// allauth `do_connect`: links the provider account to the signed-in user.
    func socialConnect(_ request: APIRequest, provider: OIDCProviderConfig, profile: SocialProfile, pending: PendingSocialLogin) async throws -> Response {
        guard let auth = request.auth, let initiator = pending.userId, auth.access.userId == initiator else {
            return .redirect("/accounts/login/?next=/")
        }
        enum Outcome: Sendable { case added, updated, other }
        let settings = social
        let outcome = try await write { db -> Outcome in
            if let account = try SocialAccountStore.account(provider: provider.id, uid: profile.uid, in: db) {
                _ = try SocialAccountStore.update(account, extraData: profile.extraData, in: db)
                try SocialAccountStore.syncFromProvider(userId: account.userId, extraData: profile.extraData, settings: settings, in: db)
                return account.userId == initiator ? .updated : .other
            }
            if provider.emailAuthentication, profile.emailVerified, let email = profile.email,
               let owner = try SocialAccountStore.users(withEmail: email, in: db).first, owner.id != initiator {
                return .other
            }
            try SocialAccountStore.connect(userId: initiator, provider: provider.id, profile: profile, in: db)
            return .added
        }
        let message: FlashMessage = switch outcome {
        case .added, .updated: FlashMessage(level: "info", message: "The third-party account has been connected.")
        case .other: FlashMessage(level: "error", message: "The third-party account is already connected to a different account.")
        }
        if let key = auth.session?.key { flashMessages.set(key, (flashMessages.get(key) ?? []) + [message]) }
        return .redirect(pending.next ?? "/")
    }

    /// allauth `perform_login`: inactive accounts stop here; accounts with TOTP get the code step
    /// unless the ID token's `amr` claim is trusted (Paperless-ngx `SocialAccountAuthenticateStage`).
    func finishSocialLogin(_ request: APIRequest, userId: Int, next: String?, extraData: JSONValue) async throws -> Response {
        let (user, mfa) = try await read { db -> (User?, Bool) in
            (try User.fetchOne(db, key: userId), try MFAStore.isActive(userId: userId, in: db))
        }
        guard let user, user.isActive else { return accountInactivePage(request) }
        // allauth signs out whoever was signed in before the new sign-in.
        if let old = request.auth?.session {
            try await write { db in try UserStore.deleteSession(key: old.key, in: db) }
        }
        var idToken: JSONValue?
        if case .object(let data) = extraData { idToken = data["id_token"] }
        if mfa, !social.trustsAMR(idToken: idToken) {
            let token = PasswordHasher.randomString(length: 40)
            pendingLogins.set(token, PendingLogin(userId: userId, next: next))
            return .text(mfaPage(token: token, error: nil))
        }
        let lifetime = TimeInterval(settings.sessionCookieAge)
        let session = try await write { db -> Session in
            try db.execute(sql: "UPDATE users SET last_login = ? WHERE id = ?", arguments: [FolioDateFormat.database.string(from: Date()), userId])
            return try UserStore.createSession(userId: userId, lifetime: lifetime, in: db)
        }
        return sessionResponse(.redirect(next ?? "/"), session: session)
    }

    // MARK: - Signup form

    /// `GET /accounts/3rdparty/signup/`: nothing pending here, so back to the sign-in page.
    func socialSignupPage(_ request: APIRequest) async throws -> Response {
        .redirect("/accounts/login/")
    }

    /// `POST /accounts/3rdparty/signup/`: allauth's social `SignupForm` (username, optional email).
    func socialSignup(_ request: APIRequest) async throws -> Response {
        let data = try request.data()
        guard let token = data["signup_token"]?.string, let pending = pendingSocialSignups.get(token),
              let provider = social.provider(id: pending.providerId) else {
            return .redirect("/accounts/login/")
        }
        guard social.allowSignups else { return signupClosedPage(request) }
        let username = (data["username"]?.string ?? "").trimmingCharacters(in: .whitespaces)
        let email = (data["email"]?.string ?? "").trimmingCharacters(in: .whitespaces)
        let settings = social
        enum Outcome: Sendable { case invalid([String]), created(User) }
        let outcome = try await write { db -> Outcome in
            var errors: [String] = []
            if username.isEmpty {
                errors.append("This field is required.")
            } else if !SocialAccountStore.isValidUsername(username) {
                errors.append("Enter a valid username. This value may contain only letters, numbers, and @/./+/-/_ characters.")
            } else if try SocialAccountStore.isUsernameTaken(username, in: db) {
                errors.append("This username is already taken. Please choose another.")
            }
            if !email.isEmpty {
                if !SocialAccountStore.isValidEmail(email) {
                    errors.append("Enter a valid email address.")
                } else if try !SocialAccountStore.users(withEmail: email, in: db).isEmpty {
                    errors.append("An account already exists with this email address. Please sign in to that account first, then connect your \(provider.name) account.")
                }
            }
            if try SocialAccountStore.account(provider: provider.id, uid: pending.profile.uid, in: db) != nil {
                errors.append("The third-party account is already connected to a different account.")
            }
            guard errors.isEmpty else { return .invalid(errors) }
            return .created(try SocialAccountStore.signUp(username: username, email: email, provider: provider.id, profile: pending.profile,
                                                          fromForm: true, settings: settings, in: db))
        }
        switch outcome {
        case .invalid(let errors):
            return socialSignupForm(request, token: token, provider: provider, username: username, email: email, errors: errors)
        case .created(let user):
            pendingSocialSignups.remove(token)
            logger.info("Social signup of `\(user.username)` through `\(provider.id)`")
            return try await finishSocialLogin(request, userId: user.id!, next: pending.next, extraData: pending.profile.extraData)
        }
    }

    func socialSignupForm(_ request: APIRequest, token: String, provider: OIDCProviderConfig, username: String, email: String, errors: [String]) -> Response {
        let alert = errors.isEmpty ? "" : "<div class=\"alert alert-danger\" role=\"alert\">\(errors.map(Self.htmlEscape).joined(separator: " "))</div>\n"
        let content = """
            <p>You are about to use your \(Self.htmlEscape(provider.name)) account to login. As a final step, please complete the following form:</p>
            \(alert)<input type="hidden" name="signup_token" value="\(Self.htmlEscape(token))">
            <div class="form-floating form-stacked-top">
            <input type="text" name="username" id="inputUsername" placeholder="Username" class="form-control" autocorrect="off" autocapitalize="none" required autofocus value="\(Self.htmlEscape(username))">
            <label for="inputUsername">Username</label>
            </div>
            <div class="form-floating form-stacked-bottom">
            <input type="email" name="email" id="inputEmail" placeholder="Email (optional)" class="form-control" autocorrect="off" autocapitalize="none" value="\(Self.htmlEscape(email))">
            <label for="inputEmail">Email (optional)</label>
            </div>
            <div class="d-grid mt-3"><button class="btn btn-lg btn-primary" type="submit">Sign up</button></div>
            """
        return accountPage(request, title: "social account sign up", action: "/accounts/3rdparty/signup/", content: content)
    }

    // MARK: - Result pages

    /// Paperless-ngx `socialaccount/authentication_error.html`. The reason goes to the log only.
    func socialAuthenticationError(_ request: APIRequest, provider: OIDCProviderConfig?, reason: String) -> Response {
        logger.warning("Social authentication error for provider `\(provider?.id ?? "unknown")`: \(reason)")
        return accountPage(request, title: "social account sign in", action: nil, content: """
            <p>An error occurred while attempting to login via your social network account. Back to the <a href="/accounts/login/">login page</a></p>
            """)
    }

    func socialLoginErrorPage(_ request: APIRequest) async throws -> Response {
        socialAuthenticationError(request, provider: nil, reason: "error page requested")
    }

    /// allauth `socialaccount/login_cancelled.html`.
    func socialLoginCancelledPage(_ request: APIRequest) async throws -> Response {
        accountPage(request, title: "login cancelled", action: nil, content: """
            <h4>Login Cancelled</h4>
            <p>You decided to cancel logging in to our site using one of your existing accounts. If this was a mistake, please proceed to <a href="/accounts/login/">sign in</a>.</p>
            """)
    }

    /// allauth `account/signup_closed.html`.
    func signupClosedPage(_ request: APIRequest) -> Response {
        accountPage(request, title: "sign up closed", action: nil, content: """
            <h4>Sign Up Closed</h4>
            <p>We are sorry, but the sign up is currently closed.</p>
            """)
    }

    /// Paperless-ngx `account/account_inactive.html`.
    func accountInactivePage(_ request: APIRequest) -> Response {
        accountPage(request, title: "account inactive", action: nil, content: """
            <h4>Account inactive.</h4>
            <p>This account is inactive.</p>
            <div class="d-grid mt-3"><a class="btn btn-lg btn-primary" href="/accounts/login/">Return to login</a></div>
            """)
    }

    /// The layout of Paperless-ngx `paperless-ngx/base.html`: one centred form, frontend styles when available.
    func accountPage(_ request: APIRequest, title: String, action: String?, content: String, status: HTTPResponse.Status = .ok) -> Response {
        let appTitle = Self.htmlEscape(displayTitle)
        let styles = frontendDir != nil
            ? "<link href=\"/static/bootstrap.min.css\" rel=\"stylesheet\"><link href=\"/static/base.css\" rel=\"stylesheet\">"
            : "<style>body{font-family:-apple-system,system-ui,sans-serif;max-width:22rem;margin:4rem auto;padding:0 1rem}input{width:100%;padding:.5rem;box-sizing:border-box;margin-top:.5rem}button{margin-top:1.5rem;padding:.5rem 1rem}.alert-danger{color:#b00020}</style>"
        let csrf = request.auth?.session.map { "<input type=\"hidden\" name=\"csrfmiddlewaretoken\" value=\"\(Self.htmlEscape($0.csrfToken))\">" } ?? ""
        let open = action.map { "<form class=\"form-accounts\" id=\"form-account\" method=\"post\" action=\"\(Self.htmlEscape($0))\">\(csrf)" }
            ?? "<div class=\"form-accounts\">"
        let close = action == nil ? "</div>" : "</form>"
        return .text("""
            <!doctype html>
            <html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no">
            <meta name="robots" content="noindex,nofollow"><title>\(appTitle) \(Self.htmlEscape(title))</title>\(styles)</head>
            <body class="text-center"><div class="position-absolute top-50 start-50 translate-middle">
            \(open)
            <h1 class="font-weight-normal text-primary mb-4">\(appTitle)</h1>
            \(content)
            \(close)
            </div></body></html>
            """, status: status)
    }

    // MARK: - Profile

    /// `GET /api/profile/social_account_providers/`: a connect link per provider, sorted by name.
    func socialAccountProviders(_ request: APIRequest) async throws -> Response {
        let providers = social.providers.sorted { $0.name < $1.name }.map { provider -> JSON in
            ["name": .string(provider.name), "login_url": .string(Self.socialLoginPath(provider.id) + "?process=connect")]
        }
        return .json(.array(providers))
    }

    /// `POST /api/profile/disconnect_social_account/` `{id}`: returns the id, or 400 when it is not the caller's.
    func disconnectSocialAccount(_ request: APIRequest) async throws -> Response {
        let data = try request.data()
        let userId = request.userId
        guard let id = data["id"]?.int ?? data["id"]?.string.flatMap({ Int($0) }),
              try await write({ db in try SocialAccountStore.disconnect(id: id, userId: userId, in: db) }) else {
            throw APIError.badRequestText("Social account not found")
        }
        return .json(.int(id))
    }

    /// The profile's `social_accounts`: `{id, provider, name}` (Paperless-ngx `SocialAccountSerializer`).
    func socialAccountsJSON(userId: Int, in db: Database) throws -> JSON {
        let accounts = try SocialAccountStore.accounts(userId: userId, in: db)
        return .array(accounts.map { account in
            let name = social.provider(id: account.provider).map {
                SocialAccountStore.displayName(extraData: account.extraDataJSON, providerName: $0.name)
            } ?? "Unknown App"
            return ["id": JSON(account.id), "provider": .string(account.provider), "name": .string(name)]
        })
    }

    /// Pending Django messages of this session as the frontend's `window.DJANGO_MESSAGES` items.
    func takeFlashMessages(_ session: Session?) -> [FlashMessage] {
        guard let key = session?.key, let messages = flashMessages.get(key) else { return [] }
        flashMessages.remove(key)
        return messages
    }
}
