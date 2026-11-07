import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import HummingbirdWSTesting
import Testing
import HummingbirdWSClient
@testable import FolioCore
@testable import FolioServer

/// The `static` folder of a Paperless-ngx v3.4.2 release, from `FOLIOZERO_TEST_FRONTEND_DIR`.
/// `servesTheRealRelease` is skipped when it is not set.
let releaseStaticFolder = ProcessInfo.processInfo.environment["FOLIOZERO_TEST_FRONTEND_DIR"] ?? ""

@Suite struct FrontendTests {
    /// A small stand-in for a release's static folder.
    func makeFrontend(in dir: TempDir) throws -> URL {
        let root = dir.url.appendingPathComponent("static", isDirectory: true)
        let fm = FileManager.default
        for language in ["en-US", "de-DE", "fr-FR"] {
            let folder = root.appendingPathComponent("frontend/\(language)", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data("console.log('\(language)')".utf8).write(to: folder.appendingPathComponent("main.js"))
            try Data("body{}".utf8).write(to: folder.appendingPathComponent("styles.css"))
        }
        try Data("brotli-bytes".utf8).write(to: root.appendingPathComponent("frontend/en-US/main.js.br"))
        try fm.createDirectory(at: root.appendingPathComponent("paperless/img"), withIntermediateDirectories: true)
        try Data([0, 0, 1, 0]).write(to: root.appendingPathComponent("paperless/img/favicon.ico"))
        try Data(".btn{}".utf8).write(to: root.appendingPathComponent("bootstrap.min.css"))
        try "secret".write(to: dir.url.appendingPathComponent("outside.txt"), atomically: false, encoding: .utf8)
        return root
    }

    @Test func servesIndexStaticFilesAndLogin() async throws {
        let setup = TempDir()
        let root = try makeFrontend(in: setup)
        let env = try TestEnvironment(overrides: ["FRONTEND_DIR": root.path, "COOKIE_PREFIX": "pngx_"])
        let user = try env.user("reader", password: "pw-reader", permissions: ["view_uisettings", "add_uisettings"])
        try await env.run { client async throws in
            let anonymous = try await client.get("/", as: nil)
            #expect(anonymous.status == .found)
            #expect(anonymous.headers[.location] == "/accounts/login/?next=%2F")
            let deepLink = try await client.get("/documents/12/details", as: nil)
            #expect(deepLink.headers[.location]?.hasPrefix("/accounts/login/?next=%2Fdocuments%2F12%2Fdetails") == true)

            let loginPage = try await client.get("/accounts/login/?sharelink_expired=1", as: nil)
            #expect(loginPage.text.contains("/static/bootstrap.min.css"))
            #expect(loginPage.text.contains("Share link has expired."))

            var form: HTTPFields = [:]
            form[.contentType] = "application/x-www-form-urlencoded"
            let login = try await client.call(.post, "/accounts/login/", headers: form, body: ByteBuffer(string: "login=reader&password=pw-reader&next=%2Fdashboard"))
            #expect(login.headers[.location] == "/dashboard")
            let cookies = login.headers[values: .setCookie]
            let session = try #require(cookies.first { $0.hasPrefix("pngx_sessionid=") }.map { String($0.split(separator: ";")[0]) })
            #expect(cookies.contains { $0.hasPrefix("pngx_csrftoken=") && !$0.contains("HttpOnly") })

            var browser: HTTPFields = [:]
            browser[.cookie] = session
            let index = try await client.call(.get, "/dashboard", headers: browser)
            #expect(index.status == .ok)
            #expect(index.headers[.contentType] == "text/html; charset=utf-8")
            #expect(index.text.contains("<meta name=\"cookie_prefix\" content=\"pngx_\">"))
            #expect(index.text.contains("<base href=\"/\">"))
            #expect(index.text.contains("src=\"/static/frontend/en-US/main.js\""))
            #expect(index.headers[values: .setCookie].contains { $0.hasPrefix("pngx_csrftoken=") })
            // No update-check UI, and a credit line under the sidebar version.
            #expect(index.text.contains(".version-check, #update-checking, #update-checking + .row { display: none !important; }"))
            #expect(index.text.contains("::after { content: \"Powered by FolioZero \(FolioApp.version)\"; display: block; }"))

            var german = browser
            german[.acceptLanguage] = "de-CH,de;q=0.9,en;q=0.5"
            #expect(try await client.call(.get, "/", headers: german).text.contains("/static/frontend/de-DE/main.js"))
            var cookieLanguage = browser
            cookieLanguage[.cookie] = session + "; pngx_django_language=fr-fr"
            #expect(try await client.call(.get, "/", headers: cookieLanguage).text.contains("/static/frontend/fr-FR/main.js"))
            try await client.call(.post, "/api/ui_settings/", as: user, json: ["settings": ["language": "de-de"]])
            #expect(try await client.call(.get, "/", headers: cookieLanguage).text.contains("/static/frontend/de-DE/main.js"))

            // Static files: content type, precompressed variants, conditional requests, traversal.
            let plain = try await client.get("/static/frontend/en-US/main.js", as: nil)
            #expect(plain.status == .ok)
            #expect(plain.headers[.contentType] == "text/javascript; charset=utf-8")
            #expect(plain.headers[.contentEncoding] == nil)
            #expect(plain.text == "console.log('en-US')")
            var brotli: HTTPFields = [:]
            brotli[.acceptEncoding] = "gzip, deflate, br"
            let compressed = try await client.call(.get, "/static/frontend/en-US/main.js", headers: brotli)
            #expect(compressed.headers[.contentEncoding] == "br")
            #expect(compressed.text == "brotli-bytes")
            var conditional: HTTPFields = [:]
            let etag: String = try #require(plain.headers[.eTag])
            conditional[.ifNoneMatch] = etag
            #expect(try await client.call(.get, "/static/frontend/en-US/main.js", headers: conditional).status == .notModified)
            #expect(try await client.get("/static/../outside.txt", as: nil).status == .notFound)
            #expect(try await client.get("/static/frontend/en-US/missing.js", as: nil).status == .notFound)
            let icon = try await client.get("/favicon.ico", as: nil)
            #expect(icon.headers[.contentType] == "image/x-icon")

            // The PDF viewer loads its worker from /assets/ (Paperless-ngx redirects to the en-US build).
            let worker = try await client.get("/assets/js/pdf.worker.min.mjs?v=1", as: nil)
            #expect(worker.status == .found)
            #expect(worker.headers[.location] == "/static/frontend/en-US/assets/js/pdf.worker.min.mjs")

            // Reserved prefixes never fall through to the app.
            let api = try await client.get("/api/nothing/", as: user)
            #expect(api.status == .notFound)
            #expect(api.json["detail"] == "Not found.")
            #expect(try await client.call(.post, "/api/nothing/", as: user).status == .notFound)

            let logout = try await client.call(.get, "/accounts/logout/?next=/accounts/login/?next=/", headers: browser)
            #expect(logout.headers[.location] == "/accounts/login/?next=/")
        }
    }

    @Test func servesTheInstalledFrontendWithoutARestart() async throws {
        let env = try TestEnvironment()
        let user = try env.user("admin", superuser: true)
        try await env.run { client async throws in
            #expect(try await client.get("/", as: user).text.contains("main.js") == false)
            let installed = FrontendInstaller.defaultDirectory(home: env.app.settings.home)
            try FileManager.default.createDirectory(at: installed.appendingPathComponent("frontend/en-US"), withIntermediateDirectories: true)
            try Data("main".utf8).write(to: installed.appendingPathComponent("frontend/en-US/main.js"))
            #expect(try await client.get("/", as: user).text.contains("/static/frontend/en-US/main.js"))
            #expect(try await client.get("/static/frontend/en-US/main.js", as: nil).text == "main")
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: releaseStaticFolder + "/frontend/en-US/main.js")))
    func servesTheRealRelease() async throws {
        let env = try TestEnvironment(overrides: ["FRONTEND_DIR": releaseStaticFolder])
        let user = try env.user("admin", superuser: true)
        try await env.run { client async throws in
            let index = try await client.get("/", as: user)
            #expect(index.text.contains("/static/frontend/en-US/polyfills.js"))
            var gzip: HTTPFields = [:]
            gzip[.acceptEncoding] = "gzip"
            let main = try await client.call(.get, "/static/frontend/en-US/main.js", headers: gzip)
            #expect(main.status == .ok)
            #expect(main.headers[.contentEncoding] == "gzip")
            let manifest = try await client.get("/static/frontend/en-US/manifest.webmanifest", as: nil)
            #expect(manifest.headers[.contentType] == "application/manifest+json")
        }
    }

    @Test func statusWebSocketReportsConsumption() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let pdf = env.dir.file("socket.pdf")
        makeTextPDF("Sent while a socket listens", at: pdf)
        let pdfData = try Data(contentsOf: pdf)
        try await env.run(.live) { client async throws in
            var configuration = WebSocketClientConfiguration()
            configuration.additionalHeaders[.authorization] = "Token \(admin.token)"
            let collected = MessageLog()
            try await client.ws("/ws/status/", configuration: configuration) { inbound, outbound, _ in
                var form = MultipartBody()
                form.file("document", filename: "socket.pdf", contentType: "application/pdf", contents: pdfData)
                let (body, headers) = form.finished()
                let upload = try await client.call(.post, "/api/documents/post_document/", as: admin, headers: headers, body: body)
                let taskId = upload.json.string ?? ""
                var iterator = inbound.messages(maxSize: 1 << 20).makeAsyncIterator()
                while let message = try await iterator.next() {
                    guard case .text(let text) = message, let json = try? JSON.parse(text) else { continue }
                    await collected.add(json)
                    if json["data"]?["task_id"]?.string == taskId, json["data"]?["status"] == "SUCCESS" { break }
                }
                try await outbound.close(.normalClosure, reason: nil)
            }
            let messages = await collected.messages
            let statuses = messages.compactMap { $0["data"]?["status"]?.string }
            // Under load the socket may see a task only once it has finished, so check the order, not the first state.
            #expect(Set(statuses).isSubset(of: ["STARTED", "WORKING", "SUCCESS"]))
            #expect(statuses.last == "SUCCESS")
            #expect(statuses.firstIndex(of: "SUCCESS") == statuses.count - 1)
            #expect(messages.last?["type"] == "status_update")
            #expect(messages.last?["data"]?["document_id"]?.int != nil)
            #expect(messages.last?["data"]?["message"] == "finished")

            // Without credentials the upgrade is refused.
            await #expect(throws: (any Error).self) {
                try await client.ws("/ws/status/") { _, outbound, _ in try await outbound.close(.normalClosure, reason: nil) }
            }
        }
    }
}

actor MessageLog {
    var messages: [JSON] = []
    func add(_ message: JSON) { messages.append(message) }
}
