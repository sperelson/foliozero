import CoreGraphics
import Foundation
import FolioParsing
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FolioCore

/// A stand-in for Azure AI Document Intelligence. Records requests; no network is used.
final class FakeAzure: RemoteOCRTransport, @unchecked Sendable {
    static let endpoint = "https://test.cognitiveservices.azure.com"
    static let pdf = Data("%PDF-1.4 remote archive".utf8)

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    let content: String
    let status: Int

    init(content: String = "Text recognised by the remote engine", status: Int = 202) {
        self.content = content
        self.status = status
    }

    var requests: [URLRequest] { lock.withLock { recorded } }
    var analyzeCount: Int { requests.filter { $0.httpMethod == "POST" }.count }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        lock.withLock { recorded.append(request) }
        func reply(_ status: Int, _ body: Data, _ headers: [String: String] = [:]) -> (Data, HTTPURLResponse) {
            (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!)
        }
        if request.httpMethod == "POST" {
            guard status == 202 else {
                return reply(status, Data(#"{"error":{"code":"401","message":"Access denied due to invalid subscription key."}}"#.utf8))
            }
            return reply(202, Data(), [
                "Operation-Location": Self.endpoint + "/documentintelligence/documentModels/prebuilt-read/analyzeResults/r-1?api-version=2024-11-30",
                "Retry-After": "0",
            ])
        }
        if request.url!.path.hasSuffix("/pdf") { return reply(200, Self.pdf, ["Content-Type": "application/pdf"]) }
        let body = try JSONSerialization.data(withJSONObject: ["status": "succeeded", "analyzeResult": ["content": content]])
        return reply(200, body, ["Content-Type": "application/json"])
    }
}

/// A small white PNG; the fake engine supplies the text.
func writeBlankPNG(to url: URL) throws {
    let context = CGContext(data: nil, width: 200, height: 280, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 200, height: 280))
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    #expect(CGImageDestinationFinalize(destination))
}

@Suite(.serialized) struct RemoteOCRTests {
    static let configured = [
        "REMOTE_OCR_ENGINE": "azureai", "REMOTE_OCR_API_KEY": "env-key", "REMOTE_OCR_ENDPOINT": FakeAzure.endpoint,
    ]

    func makeApp(_ dir: TempDir, _ overrides: [String: String] = [:], transport: FakeAzure) throws -> FolioApp {
        let settings = try SettingsLoader.load(home: dir.url.path, environment: [:], overrides: ["TIME_ZONE": "UTC"].merging(overrides) { _, new in new })
        return try FolioApp.open(settings: settings, remoteOCRTransport: transport)
    }

    func storeAppConfig(_ app: FolioApp, _ json: String) async throws {
        try await app.database.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO app_config(id, config) VALUES (1, ?)", arguments: [json])
        }
    }

    func addRemoteOCRWorkflow(_ app: FolioApp, filename: String) async throws {
        try await app.database.write { db in
            var workflow = Workflow(name: "Remote OCR for \(filename)")
            try workflow.insert(db)
            var config = WorkflowTriggerConfig()
            config.filterFilename = filename
            var trigger = WorkflowTrigger(workflowId: workflow.id!, type: .consumption, config: config)
            try trigger.insert(db)
            var action = WorkflowAction(workflowId: workflow.id!, type: .remoteOCR, order: 0, config: .init())
            try action.insert(db)
        }
    }

    // MARK: Settings and configuration

    @Test func settingsUsePaperlessNames() throws {
        let defaults = try SettingsLoader.load(home: "/tmp/fz-home", environment: [:])
        #expect(defaults.remoteOCREngine == nil)
        #expect(defaults.remoteOCRAPIKey == nil)
        #expect(defaults.remoteOCREndpoint == nil)
        #expect(defaults.remoteOCRMode == .always)
        #expect(defaults.remoteOCRAllowInternalEndpoints)
        #expect(!RemoteOCRConfig(settings: defaults).isConfigured)

        let env = [
            "PAPERLESS_REMOTE_OCR_ENGINE": "azureai", "PAPERLESS_REMOTE_OCR_API_KEY": "paperless-key",
            "FOLIOZERO_REMOTE_OCR_API_KEY": "folio-key", "PAPERLESS_REMOTE_OCR_ENDPOINT": "https://x.cognitiveservices.azure.com",
            "PAPERLESS_REMOTE_OCR_MODE": "workflow_only", "FOLIOZERO_REMOTE_OCR_ALLOW_INTERNAL_ENDPOINTS": "false",
        ]
        let settings = try SettingsLoader.load(home: "/tmp/fz-home", environment: env)
        #expect(settings.remoteOCREngine == "azureai")
        #expect(settings.remoteOCRAPIKey == "folio-key")
        #expect(settings.remoteOCREndpoint == "https://x.cognitiveservices.azure.com")
        #expect(settings.remoteOCRMode == .workflowOnly)
        #expect(!settings.remoteOCRAllowInternalEndpoints)
        #expect(settings.raw["REMOTE_OCR_MODE"] == "workflow_only")
        let config = RemoteOCRConfig(settings: settings)
        #expect(config.isConfigured)
        #expect(!config.remoteOCRByDefault)
        #expect(!config.engineConfig.allowInternalEndpoints)

        #expect(throws: SettingsError.self) { try SettingsLoader.load(home: "/tmp/fz-home", environment: ["PAPERLESS_REMOTE_OCR_MODE": "sometimes"]) }
        // An unknown engine is not an error, it just leaves remote OCR off.
        let unknown = try SettingsLoader.load(home: "/tmp/fz-home", environment: [:], overrides: ["REMOTE_OCR_ENGINE": "other", "REMOTE_OCR_API_KEY": "k", "REMOTE_OCR_ENDPOINT": "https://x"])
        #expect(!RemoteOCRConfig(settings: unknown).isConfigured)
    }

    @Test func applicationConfigurationTakesPrecedence() async throws {
        let dir = TempDir()
        let app = try makeApp(dir, Self.configured.merging(["REMOTE_OCR_MODE": "always"]) { _, n in n }, transport: FakeAzure())

        // Settings alone.
        var config = app.remoteOCRConfig()
        #expect(config == RemoteOCRConfig(engine: "azureai", apiKey: "env-key", endpoint: FakeAzure.endpoint, mode: .always))

        // Stored values win.
        try await storeAppConfig(app, """
            {"remote_ocr_engine": "azureai", "remote_ocr_api_key": "db-key",
             "remote_ocr_endpoint": "https://db.cognitiveservices.azure.com", "remote_ocr_mode": "workflow_only"}
            """)
        config = app.remoteOCRConfig()
        #expect(config.apiKey == "db-key")
        #expect(config.endpoint == "https://db.cognitiveservices.azure.com")
        #expect(config.mode == .workflowOnly)
        #expect(!config.remoteOCRByDefault)

        // Null and empty values fall back to the settings.
        try await storeAppConfig(app, #"{"remote_ocr_engine": null, "remote_ocr_api_key": "", "remote_ocr_endpoint": null, "remote_ocr_mode": ""}"#)
        #expect(app.remoteOCRConfig() == RemoteOCRConfig(settings: app.settings))

        // The application configuration alone is enough.
        let bareDir = TempDir()
        let bare = try makeApp(bareDir, transport: FakeAzure())
        #expect(!bare.remoteOCRConfig().isConfigured)
        try await storeAppConfig(bare, #"{"remote_ocr_engine": "azureai", "remote_ocr_api_key": "k", "remote_ocr_endpoint": "https://c.cognitiveservices.azure.com"}"#)
        #expect(bare.remoteOCRConfig().isConfigured)
        #expect(bare.remoteOCRConfig().mode == .always)
    }

    // MARK: Consumption

    @Test func alwaysModeSendsImagesAndKeepsBornDigitalPDFsLocal() async throws {
        let dir = TempDir()
        let azure = FakeAzure(content: "Invoice 4711 from the remote engine")
        let app = try makeApp(dir, Self.configured, transport: azure)

        let image = dir.file("receipt.png")
        try writeBlankPNG(to: image)
        let document = try await app.consumer().consume(ConsumeRequest(file: image, source: .consumeFolder))
        #expect(document.content == "Invoice 4711 from the remote engine")
        #expect(document.mimeType == "image/png")
        let archive = try #require(app.storage.archiveURL(document))
        #expect(try Data(contentsOf: archive) == FakeAzure.pdf)
        #expect(azure.analyzeCount == 1)
        #expect(azure.requests.first?.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "env-key")

        // A born-digital PDF needs no archive in `auto` mode, so its own text is used.
        let pdf = dir.file("letter.pdf")
        makeTextPDF("Dear customer, your account statement for March 2026 is attached to this letter.", at: pdf)
        let letter = try await app.consumer().consume(ConsumeRequest(file: pdf, source: .consumeFolder))
        #expect(letter.content.contains("account statement for March 2026"))
        #expect(letter.archiveFilename == nil)
        #expect(azure.analyzeCount == 1)
    }

    @Test func workflowOnlyModeNeedsAWorkflow() async throws {
        let dir = TempDir()
        let azure = FakeAzure(content: "Remote text for the marked scan")
        let app = try makeApp(dir, Self.configured.merging(["REMOTE_OCR_MODE": "workflow_only", "ARCHIVE_FILE_GENERATION": "always"]) { _, n in n },
                              transport: azure)

        let plain = dir.file("plain.pdf")
        makeTextPDF("A document that stays on this Mac because no workflow asks for remote OCR.", at: plain)
        let local = try await app.consumer().consume(ConsumeRequest(file: plain, source: .consumeFolder))
        #expect(local.content.contains("stays on this Mac"))
        #expect(azure.requests.isEmpty)

        try await addRemoteOCRWorkflow(app, filename: "*remote*")
        let marked = dir.file("remote-scan.pdf")
        makeTextPDF("Text layer of the marked scan, replaced by the remote engine's text.", at: marked)
        let remote = try await app.consumer().consume(ConsumeRequest(file: marked, source: .consumeFolder))
        #expect(remote.content == "Remote text for the marked scan")
        #expect(try Data(contentsOf: try #require(app.storage.archiveURL(remote))) == FakeAzure.pdf)
        #expect(azure.analyzeCount == 1)
    }

    @Test func requestedButNotConfiguredFallsBackToLocal() async throws {
        let dir = TempDir()
        let azure = FakeAzure()
        let app = try makeApp(dir, ["REMOTE_OCR_ENGINE": "azureai", "REMOTE_OCR_MODE": "workflow_only"], transport: azure)
        try await addRemoteOCRWorkflow(app, filename: "*")
        let file = dir.file("note.pdf")
        makeTextPDF("A note processed locally because the engine has no key or endpoint.", at: file)
        let document = try await app.consumer().consume(ConsumeRequest(file: file, source: .consumeFolder))
        #expect(document.content.contains("processed locally"))
        #expect(azure.requests.isEmpty)
    }

    @Test func engineErrorsFailConsumption() async throws {
        let dir = TempDir()
        let azure = FakeAzure(status: 401)
        let app = try makeApp(dir, Self.configured, transport: azure)
        let image = dir.file("scan.png")
        try writeBlankPNG(to: image)
        do {
            try await app.consumer().consume(ConsumeRequest(file: image, source: .consumeFolder))
            Issue.record("expected the parse to fail")
        } catch let error as ConsumeError {
            guard case .parseFailed(let name, let why) = error else { Issue.record("unexpected \(error)"); return }
            #expect(name == "scan.png")
            #expect(why == "Azure AI Vision parsing failed: HTTP 401: 401: Access denied due to invalid subscription key.")
        }
        #expect(try await app.database.read { db in try Document.fetchCount(db) } == 0)
        #expect(azure.analyzeCount == 1)
    }

    // MARK: URLSession transport

    /// The real transport against a local server: headers and body on the wire, and no redirects.
    @Test func urlSessionTransportOnTheWire() async throws {
        final class Port: @unchecked Sendable { var value = 0 }
        let port = Port()
        let pdf = Data("%PDF-1.4 from the wire".utf8)
        let server = try FakeHTTPServer { request in
            let base = "http://127.0.0.1:\(port.value)/documentintelligence/documentModels/prebuilt-read"
            if request.method == "POST" {
                return .custom(status: 202, headers: ["Operation-Location": base + "/analyzeResults/wire-1?api-version=2024-11-30", "Retry-After": "0"], body: Data())
            }
            if request.path.contains("/pdf") { return .custom(status: 200, headers: ["Content-Type": "application/pdf"], body: pdf) }
            return .json(#"{"status":"succeeded","analyzeResult":{"content":"Wire text"}}"#)
        }
        defer { server.stop() }
        port.value = server.port

        let client = AzureDocumentIntelligenceClient(endpoint: server.baseURL, apiKey: "wire-key", transport: URLSessionRemoteOCRTransport(),
                                                     pollInterval: .zero, requestTimeout: 5, timeout: 10)
        let analysis = try await client.analyze(document: Data("image bytes".utf8))
        #expect(analysis.content == "Wire text")
        #expect(analysis.pdf == pdf)
        let requests = server.requests
        #expect(requests.map(\.method) == ["POST", "GET", "GET"])
        #expect(requests[0].path == "/documentintelligence/documentModels/prebuilt-read:analyze?api-version=2024-11-30&outputContentFormat=text&output=pdf")
        #expect(requests[0].headers["ocp-apim-subscription-key"] == "wire-key")
        #expect(requests[0].headers["content-type"] == "application/json")
        #expect(requests[0].json?["base64Source"] == .string(Data("image bytes".utf8).base64EncodedString()))
        #expect(requests[1].path == "/documentintelligence/documentModels/prebuilt-read/analyzeResults/wire-1?api-version=2024-11-30")
        #expect(requests[2].path == "/documentintelligence/documentModels/prebuilt-read/analyzeResults/wire-1/pdf?api-version=2024-11-30")

        // A redirect is not followed, so the key never reaches another URL.
        let redirecting = try FakeHTTPServer { _ in .custom(status: 307, headers: ["Location": "http://127.0.0.1:9/steal"], body: Data()) }
        defer { redirecting.stop() }
        let bounced = AzureDocumentIntelligenceClient(endpoint: redirecting.baseURL, apiKey: "wire-key", transport: URLSessionRemoteOCRTransport(),
                                                      pollInterval: .zero, requestTimeout: 5, timeout: 10)
        await #expect(throws: RemoteOCRError.rejected(status: 307, message: "")) {
            try await bounced.analyze(document: Data("x".utf8))
        }
        #expect(redirecting.requests.count == 1)
    }

    // MARK: Reprocess

    @Test func reprocessUsesTheEngineWhenAsked() async throws {
        let dir = TempDir()
        let azure = FakeAzure(content: "Better text from the remote engine")
        let app = try makeApp(dir, Self.configured.merging(["REMOTE_OCR_MODE": "workflow_only", "ARCHIVE_FILE_GENERATION": "always"]) { _, n in n },
                              transport: azure)
        let file = dir.file("contract.pdf")
        makeTextPDF("Original text layer of the contract, long enough to count as born-digital.", at: file)
        let document = try await app.consumer().consume(ConsumeRequest(file: file, source: .consumeFolder))
        let id = try #require(document.id)
        #expect(azure.requests.isEmpty)

        try await DocumentMaintenance.reprocess(app: app, documentId: id)
        #expect(azure.requests.isEmpty)

        try await DocumentMaintenance.reprocess(app: app, documentId: id, remoteOCR: true)
        let updated = try await app.database.read { db in try DocumentStore.document(id, in: db) }
        #expect(updated.content == "Better text from the remote engine")
        #expect(try Data(contentsOf: try #require(app.storage.archiveURL(updated))) == FakeAzure.pdf)
        #expect(azure.analyzeCount == 1)
    }
}
