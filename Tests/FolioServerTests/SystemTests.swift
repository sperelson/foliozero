import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import FolioCore
@testable import FolioServer

@Suite struct SystemTests {
    @Test func tasksAreScopedToTheirOwners() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let perms = TestEnvironment.permissions(TestEnvironment.regularModels)
        let alice = try env.user("alice", permissions: perms)
        let bob = try env.user("bob", permissions: perms)
        try await env.app.database.write { db in
            var mine = TaskRecord(taskType: .consumeFile, triggerSource: .apiUpload, status: .failure, inputData: ["filename": "a.pdf"], ownerId: alice.id)
            mine.resultMessage = "a.pdf: Not consuming a.pdf: It is a duplicate of document #3"
            mine.resultData = ["duplicate_of": "3"]
            try mine.insert(db)
            var system = TaskRecord(taskType: .trainClassifier, triggerSource: .scheduled, status: .success)
            system.resultMessage = "Trained"
            try system.insert(db)
            var theirs = TaskRecord(taskType: .consumeFile, triggerSource: .folderConsume, status: .pending, ownerId: bob.id)
            try theirs.insert(db)
        }
        try await env.run { client async throws in
            let forAlice = try await client.get("/api/tasks/", as: alice)
            #expect(forAlice.json["count"] == 2)
            let failed = forAlice.json.results.first { $0["task_type"] == "consume_file" }
            #expect(failed?["result_data"]?["duplicate_of"] == 3)
            #expect(failed?["status_display"] == "Failure")
            #expect(failed?["trigger_source_display"] == "API Upload")
            #expect(try await client.get("/api/tasks/", as: admin).json["count"] == 3)

            let filtered = try await client.get("/api/tasks/?status=failure", as: admin)
            #expect(filtered.json["count"] == 1)
            let active = try await client.get("/api/tasks/active/", as: admin)
            #expect(active.json.array?.count == 1)
            let summary = try await client.get("/api/tasks/summary/", as: admin)
            #expect(summary.json.array?.first { $0["task_type"] == "consume_file" }?["total_count"] == 2)
            let counts = try await client.get("/api/tasks/status_counts/?status=success", as: admin)
            #expect(counts.json["all"] == 3)
            #expect(counts.json["needs_attention"] == 1)
            #expect(counts.json["in_progress"] == 1)

            var v9: HTTPFields = [:]
            v9[.accept] = "application/json; version=9"
            let legacy = try await client.call(.get, "/api/tasks/?task_name=consume_file", as: alice, headers: v9)
            #expect(legacy.json[0]?["status"] == "FAILURE")
            #expect(legacy.json[0]?["result"]?.string?.contains("duplicate") == true)

            let bothSet = try await client.call(.post, "/api/tasks/acknowledge/", as: admin, json: ["all": true, "tasks": [1]])
            #expect(bothSet.status == .badRequest)
            let all = try await client.call(.post, "/api/tasks/acknowledge/", as: admin, json: ["all": true])
            #expect(all.json["result"] == 3)

            #expect(try await client.call(.post, "/api/tasks/run/", as: alice, json: ["task_type": "index_optimize"]).status == .forbidden)
            let run = try await client.call(.post, "/api/tasks/run/", as: admin, json: ["task_type": "index_optimize"])
            #expect(run.json["task_id"]?.string != nil)
            await env.queue.waitUntilIdle()
        }
    }

    @Test func statisticsStatusVersionAndConfig() async throws {
        let env = try TestEnvironment(overrides: ["APP_TITLE": "My Archive"])
        let admin = try env.user("admin", superuser: true)
        let user = try env.user("user", permissions: ["view_document", "view_uisettings"])
        let inbox = try env.tag("Inbox", inbox: true)
        try env.document("One", content: "abc", tags: [inbox], asn: 5)
        try env.document("Two", content: "defg")
        try await env.run { client async throws in
            let stats = try await client.get("/api/statistics/", as: admin)
            #expect(stats.json["documents_total"] == 2)
            #expect(stats.json["documents_inbox"] == 1)
            #expect(stats.json["inbox_tags"] == [.int(inbox)])
            #expect(stats.json["character_count"] == 7)
            #expect(stats.json["current_asn"] == 5)
            #expect(stats.json["document_file_type_counts"]?[0]?["mime_type_count"] == 2)

            let status = try await client.get("/api/status/", as: admin)
            #expect(status.json["database"]?["type"] == "sqlite")
            #expect(status.json["database"]?["status"] == "OK")
            #expect(try await client.get("/api/status/", as: user).status == .forbidden)

            let remote = try await client.get("/api/remote_version/", as: user)
            #expect(remote.json == ["version": "3.4.2", "update_available": false])

            let settings = try await client.get("/api/ui_settings/", as: user)
            #expect(settings.json["settings"]?["app_title"] == "My Archive")

            let config = try await client.get("/api/config/", as: admin)
            #expect(config.json[0]?["id"] == 1)
            let updated = try await client.call(.patch, "/api/config/1/", as: admin, json: ["app_title": "Renamed", "llm_api_key": "secret-key"])
            #expect(updated.json["app_title"] == "Renamed")
            #expect(updated.json["llm_api_key"] == "**********")
            let kept = try await client.call(.patch, "/api/config/1/", as: admin, json: ["llm_api_key": "**********"])
            #expect(kept.json["llm_api_key"] == "**********")
            let stored = try await env.app.database.read { db in try String.fetchOne(db, sql: "SELECT config FROM app_config WHERE id = 1") }
            #expect(stored?.contains("secret-key") == true)
            #expect(try await client.get("/api/ui_settings/", as: user).json["settings"]?["app_title"] == "Renamed")
            #expect(try await client.call(.patch, "/api/config/1/", as: user, json: ["app_title": "x"]).status == .forbidden)
        }
    }

    @Test func configValidatesChoicesAndMinimums() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        try await env.run { client async throws in
            func patch(_ body: JSON) async throws -> TestResponse {
                try await client.call(.patch, "/api/config/1/", as: admin, json: body)
            }
            #expect(try await patch(["mode": "skip"]).json == ["mode": ["\"skip\" is not a valid choice."]])
            #expect(try await patch(["output_type": "pdfx"]).json["output_type"] == ["\"pdfx\" is not a valid choice."])
            #expect(try await patch(["archive_file_generation": "sometimes"]).status == .badRequest)
            #expect(try await patch(["unpaper_clean": "scrub"]).status == .badRequest)
            #expect(try await patch(["color_conversion_strategy": "Sepia"]).status == .badRequest)
            #expect(try await patch(["pages": 0]).json == ["pages": ["Ensure this value is greater than or equal to 1."]])
            #expect(try await patch(["barcode_upscale": 0.5]).json["barcode_upscale"] == ["Ensure this value is greater than or equal to 1.0."])
            #expect(try await patch(["rotate_pages_threshold": -1]).json["rotate_pages_threshold"] == ["Ensure this value is greater than or equal to 0.0."])
            #expect(try await patch(["image_dpi": "lots"]).json["image_dpi"] == ["A valid integer is required."])
            #expect(try await patch(["barcode_upscale": "big"]).json["barcode_upscale"] == ["A valid number is required."])
            #expect(try await patch(["deskew": "maybe"]).json["deskew"] == ["Must be a valid boolean."])
            // Valid values, null and the empty choice are accepted.
            let ok = try await patch(["mode": "off", "output_type": "pdfa-2", "pages": 2, "barcode_upscale": 1.5,
                                      "deskew": true, "image_dpi": .null, "archive_file_generation": ""])
            #expect(ok.status == .ok)
            #expect(ok.json["mode"] == "off")
            #expect(ok.json["pages"] == 2)
            #expect(env.app.effectiveSettings().ocrMode == .off)
            #expect(env.app.effectiveSettings().ocrPages == 2)
        }
    }

    @Test func signInPagesUseTheStoredAppTitle() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        try await env.run { client async throws in
            #expect(try await client.get("/accounts/login/", as: nil).text.contains("<title>FolioZero"))
            #expect(try await client.call(.patch, "/api/config/1/", as: admin, json: ["app_title": "Family Archive"]).status == .ok)
            let page = try await client.get("/accounts/login/", as: nil).text
            #expect(page.contains("Family Archive"))
        }
    }

    @Test func logsAreAdminOnly() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let user = try env.user("user", permissions: ["view_document"])
        let log = env.app.settings.loggingDir.appendingPathComponent("foliozero.log")
        try FileManager.default.createDirectory(at: env.app.settings.loggingDir, withIntermediateDirectories: true)
        try "line one\nline two\nline three\n".write(to: log, atomically: false, encoding: .utf8)
        try await env.run { client async throws in
            #expect(try await client.get("/api/logs/", as: admin).json == ["paperless"])
            #expect(try await client.get("/api/logs/paperless/?limit=2", as: admin).json == ["line two", "line three"])
            #expect(try await client.get("/api/logs/mail/", as: admin).status == .notFound)
            #expect(try await client.get("/api/logs/../secret/", as: admin).status == .notFound)
            #expect(try await client.get("/api/logs/", as: user).status == .forbidden)
        }
    }

    @Test func liveServerOverRealSockets() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        try await env.run(.live) { client async throws in
            let index = try await client.get("/api/", as: admin)
            #expect(index.status == .ok)
            #expect(index.headers[HTTPField.Name("X-Version")!] == "3.4.2")

            var form = MultipartBody()
            form.file("document", filename: "note.txt", contentType: "text/plain", contents: Data(String(repeating: "Meeting notes from 3 May 2022. ", count: 4000).utf8))
            let (body, headers) = form.finished()
            let upload = try await client.call(.post, "/api/documents/post_document/", as: admin, headers: headers, body: body)
            #expect(upload.status == .ok)
            await env.queue.waitUntilIdle()
            let documents = try await client.get("/api/documents/", as: admin)
            #expect(documents.json["count"] == 1)
            #expect(documents.json.results.first?["created"] == "2022-05-03")
            let id = try #require(documents.json.results.first?["id"]?.int)
            let file = try await client.get("/api/documents/\(id)/download/", as: admin)
            #expect(file.body.readableBytes == 4000 * 31)
            #expect(file.headers[.contentType] == "text/plain; charset=utf-8")
        }
    }

    @Test func globalSearchAndAutocomplete() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        _ = try env.tag("Insurance")
        try env.document("Insurance policy", content: "household insurance renewal")
        try await env.run { client async throws in
            let short = try await client.get("/api/search/?query=in", as: admin)
            #expect(short.status == .badRequest)
            let result = try await client.get("/api/search/?query=insurance", as: admin)
            #expect(Set(result.json["documents"]?[0]?.object?.keys ?? []) == ["id", "title", "created"])
            #expect(result.json["tags"]?[0]?["name"] == "Insurance")
            #expect(result.json["total"] == 2)
            let words = try await client.get("/api/search/autocomplete/?term=hous", as: admin)
            #expect(words.json.array?.isEmpty == false)
            #expect(try await client.get("/api/search/autocomplete/", as: admin).status == .badRequest)
        }
    }
}
