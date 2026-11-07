import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import FolioCore
@testable import FolioServer

@Suite struct AuthTests {
    @Test func unauthenticatedRequestsGet401() async throws {
        let env = try TestEnvironment()
        try await env.run { client async throws in
            let response = try await client.get("/api/documents/", as: nil)
            #expect(response.status == .unauthorized)
            #expect(response.json["detail"] == "Authentication credentials were not provided.")
            #expect(response.headers[.wwwAuthenticate] == "Token")
            #expect(response.headers[HTTPField.Name("X-Api-Version")!] == nil)
        }
    }

    @Test func tokenAuthenticationAndVersionHeaders() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        try await env.run { client async throws in
            let response = try await client.get("/api/documents/", as: admin)
            #expect(response.status == .ok)
            #expect(response.headers[HTTPField.Name("X-Api-Version")!] == "10")
            #expect(response.headers[HTTPField.Name("X-Version")!] == "3.4.2")
            #expect(response.json["count"] == 0)

            var bad: HTTPFields = [:]
            bad[.authorization] = "Token nope"
            let invalid = try await client.call(.get, "/api/documents/", headers: bad)
            #expect(invalid.status == .unauthorized)
            #expect(invalid.json["detail"] == "Invalid token.")
        }
    }

    @Test func basicAuthentication() async throws {
        let env = try TestEnvironment()
        try env.user("alice", superuser: true, password: "s3cret!")
        try await env.run { client async throws in
            var good: HTTPFields = [:]
            good[.authorization] = "Basic " + Data("alice:s3cret!".utf8).base64EncodedString()
            #expect(try await client.call(.get, "/api/tags/", headers: good).status == .ok)
            // A second request uses the credential cache.
            #expect(try await client.call(.get, "/api/tags/", headers: good).status == .ok)

            var wrong: HTTPFields = [:]
            wrong[.authorization] = "Basic " + Data("alice:wrong".utf8).base64EncodedString()
            let response = try await client.call(.get, "/api/tags/", headers: wrong)
            #expect(response.status == .unauthorized)
            #expect(response.json["detail"] == "Invalid username/password.")
            #expect(response.headers[.wwwAuthenticate] == "Basic realm=\"api\"")
        }
    }

    @Test func obtainTokenWithFormAndJSONAndThrottle() async throws {
        let env = try TestEnvironment()
        let alice = try env.user("alice", password: "pw-alice")
        try await env.run { client async throws in
            var form: HTTPFields = [:]
            form[.contentType] = "application/x-www-form-urlencoded"
            let viaForm = try await client.call(.post, "/api/token/", headers: form, body: ByteBuffer(string: "username=alice&password=pw-alice"))
            #expect(viaForm.status == .ok)
            #expect(viaForm.json["token"]?.string == alice.token)

            let viaJSON = try await client.call(.post, "/api/token/", json: ["username": "alice", "password": "pw-alice"])
            #expect(viaJSON.json["token"]?.string == alice.token)

            let wrong = try await client.call(.post, "/api/token/", json: ["username": "alice", "password": "nope"])
            #expect(wrong.status == .badRequest)
            #expect(wrong.json["non_field_errors"] == ["Unable to log in with provided credentials."])

            let missing = try await client.call(.post, "/api/token/", json: ["username": "alice"])
            #expect(missing.json["password"] == ["This field is required."])

            // 5 per minute; four calls above, the next one passes, then throttled.
            _ = try await client.call(.post, "/api/token/", json: ["username": "x", "password": "y"])
            let throttled = try await client.call(.post, "/api/token/", json: ["username": "alice", "password": "pw-alice"])
            #expect(throttled.status == .tooManyRequests)
        }
    }

    @Test func sessionLoginRequiresCSRFForUnsafeMethods() async throws {
        let env = try TestEnvironment()
        try env.user("bob", superuser: true, password: "pw-bob")
        try await env.run { client async throws in
            let login = try await client.call(.post, "/api/auth/login/", json: ["username": "bob", "password": "pw-bob"])
            #expect(login.status == .ok)
            let cookies = login.headers[values: .setCookie]
            let session = cookies.first { $0.hasPrefix("sessionid=") }.map { String($0.split(separator: ";")[0]) }
            let csrf = cookies.first { $0.hasPrefix("csrftoken=") }.map { String($0.split(separator: ";")[0].dropFirst("csrftoken=".count)) }
            #expect(session != nil && csrf != nil)

            var headers: HTTPFields = [:]
            headers[.cookie] = "\(session!); csrftoken=\(csrf!)"
            let profile = try await client.call(.get, "/api/profile/", headers: headers)
            #expect(profile.status == .ok)
            #expect(profile.json["auth_token"]?.string != nil)

            let noToken = try await client.call(.post, "/api/tags/", json: ["name": "x"], headers: headers)
            #expect(noToken.status == .forbidden)
            #expect(noToken.json["detail"]?.string?.hasPrefix("CSRF Failed") == true)

            headers[HTTPField.Name("X-CSRFToken")!] = csrf!
            let withToken = try await client.call(.post, "/api/tags/", json: ["name": "x"], headers: headers)
            #expect(withToken.status == .created)

            // Logout ends the session.
            _ = try await client.call(.post, "/api/auth/logout/", headers: headers)
            let after = try await client.call(.get, "/api/profile/", headers: headers)
            #expect(after.status == .unauthorized)
        }
    }

    @Test func browserLoginForm() async throws {
        let env = try TestEnvironment()
        try env.user("carol", password: "pw-carol")
        try await env.run { client async throws in
            let page = try await client.get("/accounts/login/?next=/dashboard", as: nil)
            #expect(page.status == .ok)
            #expect(page.text.contains("name=\"password\""))
            var form: HTTPFields = [:]
            form[.contentType] = "application/x-www-form-urlencoded"
            let ok = try await client.call(.post, "/accounts/login/", headers: form, body: ByteBuffer(string: "login=carol&password=pw-carol&next=%2Fdashboard"))
            #expect(ok.status == .found)
            #expect(ok.headers[.location] == "/dashboard")
            let session = try #require(ok.headers[values: .setCookie].first { $0.hasPrefix("sessionid=") }.map { String($0.split(separator: ";")[0]) })
            var cookie: HTTPFields = [:]
            cookie[.cookie] = session
            let home = try await client.call(.get, "/", headers: cookie)
            #expect(home.text.contains("Signed in as carol"))
            #expect(try await client.get("/", as: nil).headers[.location] == "/accounts/login/?next=/")
            let csrf = try #require(home.text.range(of: "name=\"csrfmiddlewaretoken\" value=\"").map { home.text[$0.upperBound...].prefix(32) })
            var logoutHeaders = cookie
            logoutHeaders[.contentType] = "application/x-www-form-urlencoded"
            let forged = try await client.call(.post, "/accounts/logout/", headers: logoutHeaders, body: ByteBuffer(string: "csrfmiddlewaretoken=wrong"))
            #expect(forged.status == .forbidden)
            let logout = try await client.call(.post, "/accounts/logout/", headers: logoutHeaders, body: ByteBuffer(string: "csrfmiddlewaretoken=\(csrf)"))
            #expect(logout.headers[.location] == "/accounts/login/?loggedout=1")
            let evil = try await client.call(.post, "/accounts/login/", headers: form, body: ByteBuffer(string: "login=carol&password=pw-carol&next=%2F%2Fevil.example"))
            #expect(evil.headers[.location] == "/")
            let wrong = try await client.call(.post, "/accounts/login/", headers: form, body: ByteBuffer(string: "login=carol&password=x"))
            #expect(wrong.status == .badRequest)
        }
    }

    @Test func remoteUserHeaderWhenEnabled() async throws {
        let env = try TestEnvironment(overrides: ["ENABLE_HTTP_REMOTE_USER_API": "true"])
        try await env.run { client async throws in
            var headers: HTTPFields = [:]
            headers[HTTPField.Name("Remote-User")!] = "sso-user"
            let response = try await client.call(.get, "/api/profile/", headers: headers)
            #expect(response.status == .ok)
        }
        let disabled = try TestEnvironment()
        try await disabled.run { client async throws in
            var headers: HTTPFields = [:]
            headers[HTTPField.Name("Remote-User")!] = "sso-user"
            #expect(try await client.call(.get, "/api/profile/", headers: headers).status == .unauthorized)
        }
    }

    @Test func autoLoginSignsInTheConfiguredUser() async throws {
        let env = try TestEnvironment(overrides: ["AUTO_LOGIN_USERNAME": "kiosk"])
        try env.user("kiosk", superuser: true, password: "pw-kiosk")
        let other = try env.user("other", password: "pw-other", permissions: ["view_uisettings"])
        try await env.run { client async throws in
            // No credentials: the request runs as the auto-login user, with a new session.
            let profile = try await client.get("/api/profile/", as: nil)
            #expect(profile.status == .ok)
            let cookies = profile.headers[values: .setCookie]
            let session = try #require(cookies.first { $0.hasPrefix("sessionid=") }.map { String($0.split(separator: ";")[0]) })
            let csrf = try #require(cookies.first { $0.hasPrefix("csrftoken=") }.map { String($0.split(separator: ";")[0].dropFirst("csrftoken=".count)) })
            #expect(try await client.get("/", as: nil).status != .found)

            // The session it created is reused, and unsafe requests still need the CSRF token.
            var headers: HTTPFields = [:]
            headers[.cookie] = "\(session); csrftoken=\(csrf)"
            let again = try await client.call(.get, "/api/ui_settings/", headers: headers)
            #expect(again.json["user"]?["username"] == "kiosk")
            #expect(again.headers[values: .setCookie].contains { $0.hasPrefix("sessionid=") } == false)
            #expect(try await client.call(.post, "/api/tags/", json: ["name": "x"], headers: headers).status == .forbidden)
            headers[HTTPField.Name("X-CSRFToken")!] = csrf
            #expect(try await client.call(.post, "/api/tags/", json: ["name": "x"], headers: headers).status == .created)

            // Explicit credentials win, and token requests never auto-login.
            let explicit = try await client.get("/api/ui_settings/", as: other)
            #expect(explicit.json["user"]?["username"] == "other")
            let token = try await client.call(.post, "/api/token/", json: ["username": "nobody", "password": "x"])
            #expect(token.status == .badRequest)
        }
        // An unknown or inactive user disables the feature.
        let missing = try TestEnvironment(overrides: ["AUTO_LOGIN_USERNAME": "ghost"])
        try await missing.run { client async throws in
            #expect(try await client.get("/api/profile/", as: nil).status == .unauthorized)
        }
    }

    @Test func versionNegotiation() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        try await env.run { client async throws in
            var v9: HTTPFields = [:]
            v9[.accept] = "application/json; version=9"
            let ok = try await client.call(.get, "/api/tags/", as: admin, headers: v9)
            #expect(ok.status == .ok)
            #expect(ok.headers[.contentType] == "application/json; version=9")
            #expect(ok.json["all"] == [])

            let v10 = try await client.call(.get, "/api/tags/", as: admin)
            #expect(v10.json["all"] == nil)

            var v8: HTTPFields = [:]
            v8[.accept] = "application/json; version=8"
            let rejected = try await client.call(.get, "/api/tags/", as: admin, headers: v8)
            #expect(rejected.status == .notAcceptable)
            #expect(rejected.json["detail"] == "Invalid version in \"Accept\" header.")
        }
    }

    @Test func corsPreflightForAllowedOrigins() async throws {
        let env = try TestEnvironment(overrides: ["CORS_ALLOWED_HOSTS": "http://localhost:4200"])
        try await env.run { client async throws in
            var headers: HTTPFields = [:]
            headers[.origin] = "http://localhost:4200"
            headers[HTTPField.Name("Access-Control-Request-Method")!] = "GET"
            let preflight = try await client.call(.options, "/api/documents/", headers: headers)
            #expect(preflight.status == .ok)
            #expect(preflight.headers[HTTPField.Name("Access-Control-Allow-Origin")!] == "http://localhost:4200")

            headers[.origin] = "http://evil.example"
            let other = try await client.call(.options, "/api/documents/", headers: headers)
            #expect(other.headers[HTTPField.Name("Access-Control-Allow-Origin")!] == nil)
        }
    }

    @Test func profileUISettingsAndTokenRegeneration() async throws {
        let env = try TestEnvironment()
        let user = try env.user("dave", permissions: ["view_uisettings", "add_uisettings", "view_document"])
        try await env.run { client async throws in
            let settings = try await client.get("/api/ui_settings/", as: user)
            #expect(settings.status == .ok)
            #expect(settings.json["user"]?["username"] == "dave")
            #expect(settings.json["user"]?["is_superuser"] == false)
            #expect(settings.json["permissions"]?.array?.contains("view_document") == true)
            #expect(settings.json["settings"]?["update_checking"] == ["enabled": false, "backend_setting": "false"])

            // A stored "enabled: true" never reaches the frontend: FolioZero has no update check.
            let saved = try await client.call(.post, "/api/ui_settings/", as: user, json: ["settings": [
                "dark_mode": ["enabled": true], "update_checking": ["enabled": true, "backend_setting": "true"],
            ]])
            #expect(saved.json["success"] == true)
            let reloaded = try await client.get("/api/ui_settings/", as: user)
            #expect(reloaded.json["settings"]?["dark_mode"]?["enabled"] == true)
            #expect(reloaded.json["settings"]?["update_checking"] == ["enabled": false, "backend_setting": "false"])
            let stored = try await env.app.database.read { db in
                try String.fetchOne(db, sql: "SELECT settings FROM ui_settings WHERE user_id = ?", arguments: [user.id])
            }
            #expect(stored?.contains("update_checking") == false)

            let patched = try await client.call(.patch, "/api/profile/", as: user, json: ["first_name": "Dave", "email": "dave@example.com"])
            #expect(patched.json["first_name"] == "Dave")
            #expect(patched.json["auth_token"]?.string == user.token)
            let badEmail = try await client.call(.patch, "/api/profile/", as: user, json: ["email": "not-an-email"])
            #expect(badEmail.status == .badRequest)

            let regenerated = try await client.call(.post, "/api/profile/generate_auth_token/", as: user)
            let newToken = try #require(regenerated.json.string)
            #expect(newToken != user.token)
            #expect(try await client.get("/api/profile/", as: user).status == .unauthorized)
        }
    }

    @Test func missingGlobalPermissionIs403() async throws {
        let env = try TestEnvironment()
        let user = try env.user("noperms")
        try await env.run { client async throws in
            let response = try await client.get("/api/documents/", as: user)
            #expect(response.status == .forbidden)
            #expect(response.json["detail"] == "You do not have permission to perform this action.")
        }
    }
}
