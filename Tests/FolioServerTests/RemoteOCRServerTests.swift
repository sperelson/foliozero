import Foundation
import FolioParsing
import GRDB
import Testing
@testable import FolioCore
@testable import FolioServer

/// Answers like Azure AI Document Intelligence. Records requests; no network is used.
final class FakeDocumentIntelligence: RemoteOCRTransport, @unchecked Sendable {
    static let endpoint = "https://test.cognitiveservices.azure.com"
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    let content: String

    init(content: String = "Text from the remote engine") {
        self.content = content
    }

    var analyzeCount: Int { lock.withLock { recorded.filter { $0.httpMethod == "POST" }.count } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        var headers = ["Content-Type": "application/json"]
        var body = Data()
        var status = 200
        if request.httpMethod == "POST" {
            status = 202
            headers["Operation-Location"] = Self.endpoint + "/documentintelligence/documentModels/prebuilt-read/analyzeResults/r-7?api-version=2024-11-30"
            headers["Retry-After"] = "0"
        } else if request.url!.path.hasSuffix("/pdf") {
            headers["Content-Type"] = "application/pdf"
            body = Data("%PDF-1.4 remote".utf8)
        } else {
            body = try JSONSerialization.data(withJSONObject: ["status": "succeeded", "analyzeResult": ["content": content]])
        }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
    }
}

@Suite struct RemoteOCRServerTests {
    static let configured = [
        "REMOTE_OCR_ENGINE": "azureai", "REMOTE_OCR_API_KEY": "env-key", "REMOTE_OCR_ENDPOINT": FakeDocumentIntelligence.endpoint,
    ]

    @Test func uiSettingsReportTheRealConfiguration() async throws {
        let plain = try TestEnvironment()
        let admin = try plain.user("admin", superuser: true)
        try await plain.run { client async throws in
            let settings = try await client.get("/api/ui_settings/", as: admin)
            #expect(settings.json["settings"]?["remote_ocr"] == ["configured": false, "mode": "always"])

            // Configured through /api/config/, as the Paperless-ngx settings page does.
            let patched = try await client.call(.patch, "/api/config/1/", as: admin, json: [
                "remote_ocr_engine": "azureai", "remote_ocr_api_key": "db-key",
                "remote_ocr_endpoint": "https://db.cognitiveservices.azure.com", "remote_ocr_mode": "workflow_only",
            ])
            #expect(patched.status == .ok)
            #expect(patched.json["remote_ocr_api_key"] == "**********")
            let after = try await client.get("/api/ui_settings/", as: admin)
            #expect(after.json["settings"]?["remote_ocr"] == ["configured": true, "mode": "workflow_only"])
        }

        let fromSettings = try TestEnvironment(overrides: Self.configured.merging(["REMOTE_OCR_MODE": "workflow_only"]) { _, n in n })
        let user = try fromSettings.user("user", permissions: ["view_uisettings"])
        try await fromSettings.run { client async throws in
            let settings = try await client.get("/api/ui_settings/", as: user)
            #expect(settings.json["settings"]?["remote_ocr"] == ["configured": true, "mode": "workflow_only"])
        }

        // An engine without key and endpoint is reported as not configured, matching parser selection.
        let incomplete = try TestEnvironment(overrides: ["REMOTE_OCR_ENGINE": "azureai"])
        let other = try incomplete.user("other", superuser: true)
        try await incomplete.run { client async throws in
            let settings = try await client.get("/api/ui_settings/", as: other)
            #expect(settings.json["settings"]?["remote_ocr"]?["configured"] == false)
        }
    }

    @Test func configurationFieldsAreValidated() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        try await env.run { client async throws in
            let config = try await client.get("/api/config/1/", as: admin)
            for key in ["remote_ocr_engine", "remote_ocr_api_key", "remote_ocr_endpoint", "remote_ocr_mode"] {
                #expect(config.json[key] == .null)
            }

            let engine = try await client.call(.patch, "/api/config/1/", as: admin, json: ["remote_ocr_engine": "googlevision"])
            #expect(engine.status == .badRequest)
            #expect(engine.json["remote_ocr_engine"] == [#""googlevision" is not a valid choice."#])
            let mode = try await client.call(.patch, "/api/config/1/", as: admin, json: ["remote_ocr_mode": "auto"])
            #expect(mode.json["remote_ocr_mode"] == [#""auto" is not a valid choice."#])
            let scheme = try await client.call(.patch, "/api/config/1/", as: admin, json: ["remote_ocr_endpoint": "ftp://example.com"])
            #expect(scheme.json["remote_ocr_endpoint"] == ["Invalid remote OCR endpoint: Invalid URL scheme or hostname., see logs for details"])

            // Internal endpoints are allowed by default.
            let local = try await client.call(.patch, "/api/config/1/", as: admin, json: ["remote_ocr_endpoint": "http://127.0.0.1:5000", "remote_ocr_mode": ""])
            #expect(local.status == .ok)
            #expect(local.json["remote_ocr_endpoint"] == "http://127.0.0.1:5000")

            // API key: stars keep the stored key, an empty string clears it.
            _ = try await client.call(.patch, "/api/config/1/", as: admin, json: ["remote_ocr_api_key": "1234567890"])
            _ = try await client.call(.patch, "/api/config/1/", as: admin, json: ["remote_ocr_api_key": .string(String(repeating: "*", count: 32))])
            #expect(env.app.remoteOCRConfig().apiKey == "1234567890")
            _ = try await client.call(.patch, "/api/config/1/", as: admin, json: ["remote_ocr_api_key": ""])
            #expect(env.app.remoteOCRConfig().apiKey == nil)
        }

        let strict = try TestEnvironment(overrides: ["REMOTE_OCR_ALLOW_INTERNAL_ENDPOINTS": "false"])
        let other = try strict.user("admin", superuser: true)
        try await strict.run { client async throws in
            let blocked = try await client.call(.patch, "/api/config/1/", as: other, json: ["remote_ocr_endpoint": "http://127.0.0.1:5000"])
            #expect(blocked.status == .badRequest)
            #expect(blocked.json["remote_ocr_endpoint"]?[0]?.string?.contains("non-public address") == true)
        }
    }

    @Test func reprocessCanAskForRemoteOCR() async throws {
        let engine = FakeDocumentIntelligence(content: "Reprocessed by the remote engine")
        let env = try TestEnvironment(overrides: Self.configured.merging(["REMOTE_OCR_MODE": "workflow_only"]) { _, n in n }, remoteOCRTransport: engine)
        let admin = try env.user("admin", superuser: true)
        let id = try env.document("Scan")
        try await env.run { client async throws in
            let invalid = try await client.call(.post, "/api/documents/bulk_edit/", as: admin, json: [
                "documents": [.int(id)], "method": "reprocess", "parameters": ["remote_ocr": "yes"],
            ])
            #expect(invalid.status == .badRequest)
            #expect(invalid.json["non_field_errors"] == ["remote_ocr must be a boolean"])

            let notAsked = try await client.call(.post, "/api/documents/reprocess/", as: admin, json: ["documents": [.int(id)]])
            #expect(notAsked.json["result"] == "OK")
            await env.queue.waitUntilIdle()
            #expect(engine.analyzeCount == 0)

            let asked = try await client.call(.post, "/api/documents/reprocess/", as: admin, json: ["documents": [.int(id)], "remote_ocr": true])
            #expect(asked.json["result"] == "OK")
            await env.queue.waitUntilIdle()
            #expect(engine.analyzeCount == 1)
            #expect(try await client.get("/api/documents/\(id)/", as: admin).json["content"] == "Reprocessed by the remote engine")

            let bulk = try await client.call(.post, "/api/documents/bulk_edit/", as: admin, json: [
                "documents": [.int(id)], "method": "reprocess", "parameters": ["remote_ocr": true],
            ])
            #expect(bulk.json["result"] == "OK")
            await env.queue.waitUntilIdle()
            #expect(engine.analyzeCount == 2)
        }
    }

    @Test func remoteOCRActionsNeedAConsumptionTrigger() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        try await env.run { client async throws in
            let invalid = try await client.call(.post, "/api/workflows/", as: admin, json: [
                "name": "Remote on add", "triggers": [["type": 2, "filter_filename": "*.pdf"]], "actions": [["type": 7]],
            ])
            #expect(invalid.status == .badRequest)
            #expect(invalid.json["non_field_errors"] == ["Remote OCR actions require a consumption started trigger"])
            #expect(try await env.app.database.read { db in try Workflow.fetchCount(db) } == 0)

            let created = try await client.call(.post, "/api/workflows/", as: admin, json: [
                "name": "Remote for scans", "triggers": [["type": 1, "filter_filename": "*scan*"]], "actions": [["type": 7]],
            ])
            #expect(created.status == .created)
            #expect(created.json["actions"]?[0]?["type"] == 7)
            let workflowId = try #require(created.json["id"]?.int)

            // Swapping the trigger for a non-consumption one is refused too.
            let changed = try await client.call(.patch, "/api/workflows/\(workflowId)/", as: admin, json: [
                "triggers": [["type": 3]],
            ])
            #expect(changed.status == .badRequest)
            #expect(changed.json["non_field_errors"] == ["Remote OCR actions require a consumption started trigger"])
        }
    }
}
