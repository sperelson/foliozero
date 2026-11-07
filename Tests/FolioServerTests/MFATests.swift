import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import FolioCore
@testable import FolioServer

@Suite struct MFATests {
    @Test func totpSetupLoginAndDeactivation() async throws {
        let env = try TestEnvironment()
        let user = try env.user("mfa", password: "pw-mfa")
        let other = try env.user("other")
        try await env.run { client async throws in
            let setup = try await client.get("/api/profile/totp/", as: user)
            let secret = try #require(setup.json["secret"]?.string)
            #expect(setup.json["url"]?.string?.hasPrefix("otpauth://totp/") == true)
            #expect(setup.json["qr_svg"]?.string?.contains("<svg") == true)

            let wrong = try await client.call(.post, "/api/profile/totp/", as: user, json: ["secret": .string(secret), "code": "000000"])
            #expect(wrong.json == ["success": false, "recovery_codes": .null])
            let code = try #require(TOTP.code(secret: secret))
            let activated = try await client.call(.post, "/api/profile/totp/", as: user, json: ["secret": .string(secret), "code": .string(code)])
            #expect(activated.json["success"] == true)
            let recovery = activated.json["recovery_codes"]?.array?.compactMap(\.string) ?? []
            #expect(recovery.count == 10)
            #expect(try await client.get("/api/profile/", as: user).json["is_mfa_enabled"] == true)

            // Basic auth is refused; /api/token/ needs a code.
            var basic: HTTPFields = [:]
            basic[.authorization] = "Basic " + Data("mfa:pw-mfa".utf8).base64EncodedString()
            let refused = try await client.call(.get, "/api/profile/", headers: basic)
            #expect(refused.status == .unauthorized)
            #expect(refused.json["detail"] == "MFA required")
            let noCode = try await client.call(.post, "/api/token/", json: ["username": "mfa", "password": "pw-mfa"])
            #expect(noCode.json["non_field_errors"] == ["MFA code is required"])
            let withCode = try await client.call(.post, "/api/token/", json: ["username": "mfa", "password": "pw-mfa", "code": .string(recovery[0])])
            #expect(withCode.json["token"]?.string == user.token)

            // The HTML login asks for the code after the password.
            var form: HTTPFields = [:]
            form[.contentType] = "application/x-www-form-urlencoded"
            let first = try await client.call(.post, "/accounts/login/", headers: form, body: ByteBuffer(string: "login=mfa&password=pw-mfa&next=%2Fdocuments"))
            #expect(first.status == .ok)
            #expect(first.headers[values: .setCookie].isEmpty)
            let token = try #require(first.text.range(of: "name=\"mfa_token\" value=\"").map { String(first.text[$0.upperBound...].prefix(40)) })
            let badCode = try await client.call(.post, "/accounts/login/", headers: form, body: ByteBuffer(string: "mfa_token=\(token)&code=123456"))
            #expect(badCode.status == .badRequest)
            let signedIn = try await client.call(.post, "/accounts/login/", headers: form, body: ByteBuffer(string: "mfa_token=\(token)&code=\(recovery[1])"))
            #expect(signedIn.status == .found)
            #expect(signedIn.headers[.location] == "/documents")
            #expect(signedIn.headers[values: .setCookie].contains { $0.hasPrefix("sessionid=") })
            let reused = try await client.call(.post, "/accounts/login/", headers: form, body: ByteBuffer(string: "mfa_token=\(token)&code=\(recovery[2])"))
            #expect(reused.headers[values: .setCookie].isEmpty)

            #expect(try await client.call(.post, "/api/users/\(user.id)/deactivate_totp/", as: other).status == .forbidden)
            #expect(try await client.call(.delete, "/api/profile/totp/", as: user).json == true)
            let again = try await client.call(.delete, "/api/profile/totp/", as: user)
            #expect(again.status == .notFound)
            #expect(again.text == "TOTP not found")
            #expect(try await client.call(.get, "/api/profile/", headers: basic).status == .ok)
        }
    }
}

@Suite struct AIEndpointTests {
    @Test func aiEndpointsWhenDisabled() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let reader = try env.user("reader", permissions: ["view_document"])
        let id = try env.document("Owned", owner: admin.id)
        let shared = try env.document("Shared")
        try await env.run { client async throws in
            #expect(try await client.get("/api/documents/\(id)/ai_suggestions/", as: reader).status == .forbidden)
            let disabled = try await client.get("/api/documents/\(id)/ai_suggestions/", as: admin)
            #expect(disabled.status == .badRequest)
            #expect(disabled.text == "AI is required for this feature")
            #expect(try await client.get("/api/documents/999/ai_suggestions/", as: admin).status == .notFound)
            let chat = try await client.call(.post, "/api/documents/chat/", as: admin, json: ["q": "What is due?", "document_id": .int(shared)])
            #expect(chat.text == "AI is required for this feature")
            #expect(try await client.get("/api/documents/\(shared)/similar/", as: admin).status == .badRequest)
            #expect(try await client.get("/api/ui_settings/", as: admin).json["settings"]?["ai_enabled"] == false)
            #expect(try await client.get("/api/status/", as: admin).json["tasks"]?["llmindex_status"] == "DISABLED")
        }
    }
}
