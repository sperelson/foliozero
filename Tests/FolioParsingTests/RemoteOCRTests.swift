import Foundation
import PDFKit
import Testing
import UniformTypeIdentifiers
@testable import FolioParsing

/// Records requests and answers them from a closure. No network is used.
final class StubRemoteOCRTransport: RemoteOCRTransport, @unchecked Sendable {
    struct Reply {
        var status = 200
        var headers: [String: String] = [:]
        var body = Data()
    }

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: @Sendable (URLRequest, [URLRequest]) async throws -> Reply

    init(_ handler: @escaping @Sendable (URLRequest, [URLRequest]) async throws -> Reply) {
        self.handler = handler
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let previous = lock.withLock { () -> [URLRequest] in
            defer { recorded.append(request) }
            return recorded
        }
        let reply = try await handler(request, previous)
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (reply.body, response)
    }

    static let endpoint = "https://test.cognitiveservices.azure.com"
    static let operationLocation = endpoint + "/documentintelligence/documentModels/prebuilt-read/analyzeResults/op-123?api-version=2024-11-30"

    /// Azure Document Intelligence: 202 with `Operation-Location`, `running` for
    /// `runningPolls` status requests, then `succeeded`, then the PDF.
    static func azure(content: String = "Remote OCR text", pdf: Data = Data("%PDF-1.4 FAKE".utf8), runningPolls: Int = 0,
                      location: String = operationLocation) -> StubRemoteOCRTransport {
        StubRemoteOCRTransport { request, previous in
            if request.httpMethod == "POST" {
                return Reply(status: 202, headers: ["Operation-Location": location, "Retry-After": "0"])
            }
            if request.url!.path.hasSuffix("/pdf") {
                return Reply(headers: ["Content-Type": "application/pdf"], body: pdf)
            }
            let polls = previous.filter { $0.httpMethod == "GET" && !$0.url!.path.hasSuffix("/pdf") }.count
            if polls < runningPolls {
                return Reply(headers: ["Content-Type": "application/json", "Retry-After": "0"], body: Data(#"{"status":"running"}"#.utf8))
            }
            let result = try JSONSerialization.data(withJSONObject: [
                "status": "succeeded",
                "analyzeResult": ["apiVersion": "2024-11-30", "modelId": "prebuilt-read", "content": content],
            ])
            return Reply(headers: ["Content-Type": "application/json"], body: result)
        }
    }
}

@Suite struct RemoteOCRTests {
    static let configured = RemoteOCREngineConfig(engine: "azureai", apiKey: "test-key", endpoint: StubRemoteOCRTransport.endpoint)

    func parser(_ transport: StubRemoteOCRTransport, config: RemoteOCREngineConfig = configured,
                isInternalHost: @escaping RemoteOCRHostCheck = { _ in false }) -> RemoteOCRParser {
        var parser = RemoteOCRParser(config: config, transport: transport, isInternalHost: isInternalHost)
        parser.pollInterval = .zero
        return parser
    }

    /// A real one-page PDF, standing in for the searchable PDF Azure returns.
    func remotePDF(in dir: URL) throws -> Data {
        let url = dir.appendingPathComponent("remote-archive.pdf")
        try FixtureFactory.bornDigitalPDF(pages: [["REMOTE ARCHIVE PAGE"]], to: url)
        return try Data(contentsOf: url)
    }

    func png(in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent("scan.png")
        try FixtureFactory.writeImage(FixtureFactory.textImage(width: 600, height: 800, fontSize: 32), type: .png, to: url)
        return url
    }

    static func message(_ error: any Error) -> String {
        if case ParserError.remoteOCRFailed(let message) = error { return message }
        return "unexpected error: \(error)"
    }

    // MARK: Configuration and selection

    @Test func engineValidity() {
        #expect(Self.configured.engineIsValid)
        #expect(!RemoteOCREngineConfig().engineIsValid)
        #expect(!RemoteOCREngineConfig(engine: "googlevision", apiKey: "k", endpoint: "https://x").engineIsValid)
        #expect(!RemoteOCREngineConfig(engine: "azureai", endpoint: "https://x").engineIsValid)
        #expect(!RemoteOCREngineConfig(engine: "azureai", apiKey: "k").engineIsValid)
    }

    @Test func scoreAndRegistrySelection() {
        let remote = parser(.azure())
        for mime in ["application/pdf", "image/png", "image/jpeg", "image/tiff", "image/bmp", "image/gif", "image/webp"] {
            #expect(remote.score(mimeType: mime, fileName: "doc") == 20)
        }
        #expect(Set(remote.supportedMIMETypes.keys).count == 7)
        #expect(remote.score(mimeType: "text/plain", fileName: "doc.txt") == 0)
        #expect(remote.usesRemoteService)
        let unconfigured = parser(.azure(), config: RemoteOCREngineConfig(engine: "azureai", apiKey: "k"))
        #expect(unconfigured.score(mimeType: "application/pdf", fileName: "doc.pdf") == 0)

        var registry = StandardParsers.makeRegistry()
        #expect(!registry.parsers.contains { $0.usesRemoteService })
        registry.register(remote)
        #expect(registry.parser(for: "application/pdf", fileName: "doc.pdf")?.name == "remote")
        #expect(registry.parser(for: "image/png", fileName: "doc.png", allowRemote: true)?.name == "remote")
        // Not allowed: the local parsers handle it and nothing leaves the Mac.
        #expect(registry.parser(for: "application/pdf", fileName: "doc.pdf", allowRemote: false)?.name == "pdf")
        #expect(registry.parser(for: "image/heic", fileName: "doc.heic")?.name == "image")
        #expect(registry.parser(for: "text/plain", fileName: "doc.txt")?.name == "text")
    }

    @Test func archiveDecisionMatchesPaperless() {
        let long = String(repeating: "word ", count: 20)
        #expect(RemoteOCRParser.isBornDigital(text: long, isTagged: false))
        #expect(!RemoteOCRParser.isBornDigital(text: "short text", isTagged: false))
        #expect(RemoteOCRParser.isBornDigital(text: "short text", isTagged: true))
        #expect(!RemoteOCRParser.isBornDigital(text: "", isTagged: true))
        #expect(!RemoteOCRParser.isBornDigital(text: nil, isTagged: true))

        let pdf = "application/pdf"
        #expect(!RemoteOCRParser.shouldProduceArchive(mimeType: pdf, archiveMode: .auto, pdfText: long, isTaggedPDF: false))
        #expect(RemoteOCRParser.shouldProduceArchive(mimeType: pdf, archiveMode: .auto, pdfText: "", isTaggedPDF: false))
        #expect(RemoteOCRParser.shouldProduceArchive(mimeType: pdf, archiveMode: .always, pdfText: long, isTaggedPDF: true))
        #expect(!RemoteOCRParser.shouldProduceArchive(mimeType: pdf, archiveMode: .never, pdfText: nil, isTaggedPDF: false))
        #expect(RemoteOCRParser.shouldProduceArchive(mimeType: "image/png", archiveMode: .auto, pdfText: nil, isTaggedPDF: false))
        #expect(!RemoteOCRParser.shouldProduceArchive(mimeType: "image/png", archiveMode: .never, pdfText: nil, isTaggedPDF: false))
    }

    // MARK: Wire format

    @Test func requestShapeAndPolling() async throws {
        let transport = StubRemoteOCRTransport.azure(content: "Line one\nLine two", pdf: Data("%PDF-1.7 result".utf8), runningPolls: 2)
        // A trailing slash on the endpoint does not double the slash in the path.
        let client = AzureDocumentIntelligenceClient(endpoint: StubRemoteOCRTransport.endpoint + "/", apiKey: "secret-key",
                                                     transport: transport, pollInterval: .zero)
        let document = Data("%PDF-1.4 scanned bytes".utf8)
        let analysis = try await client.analyze(document: document)

        #expect(analysis == .init(resultId: "op-123", content: "Line one\nLine two", pdf: Data("%PDF-1.7 result".utf8)))
        let requests = transport.requests
        #expect(requests.count == 5) // analyze, running, running, succeeded, pdf

        let start = requests[0]
        #expect(start.httpMethod == "POST")
        #expect(start.url?.absoluteString == "https://test.cognitiveservices.azure.com/documentintelligence/documentModels/prebuilt-read:analyze?api-version=2024-11-30&outputContentFormat=text&output=pdf")
        #expect(start.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "secret-key")
        #expect(start.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(start.value(forHTTPHeaderField: "Accept") == "application/json")
        let body = try #require(start.httpBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        #expect(body.keys.sorted() == ["base64Source"])
        #expect(body["base64Source"].flatMap { Data(base64Encoded: $0) } == document)

        for poll in requests[1...3] {
            #expect(poll.httpMethod == "GET")
            #expect(poll.url?.absoluteString == StubRemoteOCRTransport.operationLocation)
            #expect(poll.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "secret-key")
        }

        let download = requests[4]
        #expect(download.httpMethod == "GET")
        #expect(download.url?.absoluteString == "https://test.cognitiveservices.azure.com/documentintelligence/documentModels/prebuilt-read/analyzeResults/op-123/pdf?api-version=2024-11-30")
        #expect(download.value(forHTTPHeaderField: "Accept") == "application/pdf")
        #expect(download.value(forHTTPHeaderField: "Ocp-Apim-Subscription-Key") == "secret-key")
    }

    @Test func retryAfterHeaders() {
        func response(_ headers: [String: String]) -> HTTPURLResponse {
            HTTPURLResponse(url: URL(string: "https://x")!, statusCode: 202, httpVersion: nil, headerFields: headers)!
        }
        #expect(AzureDocumentIntelligenceClient.retryAfter(response(["Retry-After": "2"])) == .seconds(2))
        #expect(AzureDocumentIntelligenceClient.retryAfter(response(["retry-after-ms": "150", "Retry-After": "9"])) == .milliseconds(150))
        #expect(AzureDocumentIntelligenceClient.retryAfter(response([:])) == nil)
        #expect(AzureDocumentIntelligenceClient.resultId(fromOperationLocation: URL(string: StubRemoteOCRTransport.operationLocation)!) == "op-123")
    }

    // MARK: Which files go to the engine

    @Test func imageGoesToTheEngine() async throws {
        let dir = try FixtureFactory.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let pdf = try remotePDF(in: dir)
        let transport = StubRemoteOCRTransport.azure(content: "FOLIOZERO INVOICE 4711 from the cloud", pdf: pdf)
        let result = try await parser(transport).parse(file: try png(in: dir), mimeType: "image/png", options: FixtureFactory.options(dir))

        #expect(result.text == "FOLIOZERO INVOICE 4711 from the cloud")
        let archive = try #require(result.archiveFile)
        #expect(try Data(contentsOf: archive) == pdf)
        #expect(FileManager.default.fileExists(atPath: result.thumbnailFile.path))
        #expect(result.pageCount == 1)
        #expect(result.metadata.contains { $0.key == "pixelWidth" && $0.value == "600" })
        #expect(transport.requests.map { $0.httpMethod ?? "" } == ["POST", "GET", "GET"])
    }

    @Test func bornDigitalPDFStaysLocal() async throws {
        let dir = try FixtureFactory.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("report.pdf")
        try FixtureFactory.bornDigitalPDF(pages: [["Quarterly report for the second quarter of 2026", "Revenue grew by twelve percent"]], to: file)
        let transport = StubRemoteOCRTransport.azure()
        let result = try await parser(transport).parse(file: file, mimeType: "application/pdf", options: FixtureFactory.options(dir))

        #expect(transport.requests.isEmpty)
        #expect(result.text.contains("Revenue grew by twelve percent"))
        #expect(result.archiveFile == nil)
        #expect(result.pageCount == 1)
        #expect(result.suggestedTitle == "Quarterly Report")
    }

    @Test func scannedPDFGoesToTheEngine() async throws {
        let dir = try FixtureFactory.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("scan.pdf")
        try FixtureFactory.scannedPDF(images: [FixtureFactory.textImage(width: 600, height: 800, fontSize: 32)], to: file)
        let pdf = try remotePDF(in: dir)
        let transport = StubRemoteOCRTransport.azure(content: "Scanned text", pdf: pdf)
        let result = try await parser(transport).parse(file: file, mimeType: "application/pdf", options: FixtureFactory.options(dir))

        #expect(transport.requests.count == 3)
        #expect(result.text == "Scanned text")
        #expect(try result.archiveFile.map { try Data(contentsOf: $0) } == pdf)
        #expect(result.pageCount == 1)
    }

    @Test func archiveModesDecideWhatIsSent() async throws {
        let dir = try FixtureFactory.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let born = dir.appendingPathComponent("born.pdf")
        try FixtureFactory.bornDigitalPDF(pages: [["A born-digital document with more than fifty characters of text"]], to: born)

        // always: even a born-digital PDF is sent, and the engine's PDF is the archive.
        let always = StubRemoteOCRTransport.azure(content: "From the engine")
        let sent = try await parser(always).parse(file: born, mimeType: "application/pdf", options: FixtureFactory.options(dir, archiveMode: .always))
        #expect(always.requests.count == 3)
        #expect(sent.text == "From the engine")
        #expect(sent.archiveFile != nil)

        // never: a PDF keeps its own text and is not sent.
        let never = StubRemoteOCRTransport.azure()
        let kept = try await parser(never).parse(file: born, mimeType: "application/pdf", options: FixtureFactory.options(dir, archiveMode: .never))
        #expect(never.requests.isEmpty)
        #expect(kept.text.contains("born-digital document"))
        #expect(kept.archiveFile == nil)

        // Images have no local text, so they are sent even with `never`; no archive is kept.
        let image = StubRemoteOCRTransport.azure(content: "Image text")
        let fromImage = try await parser(image).parse(file: try png(in: dir), mimeType: "image/png", options: FixtureFactory.options(dir, archiveMode: .never))
        #expect(image.requests.count == 3)
        #expect(fromImage.text == "Image text")
        #expect(fromImage.archiveFile == nil)
    }

    @Test func unconfiguredOrLockedFilesAreNotSent() async throws {
        let dir = try FixtureFactory.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transport = StubRemoteOCRTransport.azure()
        let unconfigured = parser(transport, config: RemoteOCREngineConfig(engine: "azureai"))
        let empty = try await unconfigured.parse(file: try png(in: dir), mimeType: "image/png", options: FixtureFactory.options(dir))
        #expect(empty.text.isEmpty)
        #expect(empty.archiveFile == nil)

        let locked = dir.appendingPathComponent("locked.pdf")
        try FixtureFactory.bornDigitalPDF(pages: [["Secret"]], to: locked, userPassword: "pw")
        let result = try await parser(transport).parse(file: locked, mimeType: "application/pdf", options: FixtureFactory.options(dir))
        #expect(result.text.isEmpty)
        #expect(transport.requests.isEmpty)
    }

    // MARK: Errors and timeouts

    @Test func serviceErrorsFailTheParse() async throws {
        let dir = try FixtureFactory.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try png(in: dir)
        let options = FixtureFactory.options(dir)

        let rejected = StubRemoteOCRTransport { _, _ in
            .init(status: 401, body: Data(#"{"error":{"code":"401","message":"Access denied due to invalid subscription key."}}"#.utf8))
        }
        let unauthorized = await #expect(throws: ParserError.self) { try await parser(rejected).parse(file: file, mimeType: "image/png", options: options) }
        #expect(Self.message(unauthorized!) == "Azure AI Vision parsing failed: HTTP 401: 401: Access denied due to invalid subscription key.")
        #expect(rejected.requests.count == 1)

        let failing = StubRemoteOCRTransport { request, _ in
            if request.httpMethod == "POST" { return .init(status: 202, headers: ["Operation-Location": StubRemoteOCRTransport.operationLocation]) }
            return .init(body: Data(#"{"status":"failed","error":{"code":"InvalidRequest","message":"Invalid request.","innererror":{"code":"InvalidContent","message":"The file is corrupted or format is unsupported."}}}"#.utf8))
        }
        let failed = await #expect(throws: ParserError.self) { try await parser(failing).parse(file: file, mimeType: "image/png", options: options) }
        #expect(Self.message(failed!).hasPrefix("Azure AI Vision parsing failed: Analysis failed: InvalidRequest: Invalid request.: The file is corrupted"))
        #expect(!failing.requests.contains { $0.url!.path.hasSuffix("/pdf") })

        let noLocation = StubRemoteOCRTransport { _, _ in .init(status: 202) }
        let missing = await #expect(throws: ParserError.self) { try await parser(noLocation).parse(file: file, mimeType: "image/png", options: options) }
        #expect(Self.message(missing!).contains("Operation-Location"))
    }

    @Test func timeoutsFailTheParse() async throws {
        let dir = try FixtureFactory.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try png(in: dir)
        let options = FixtureFactory.options(dir)

        let urlTimeout = StubRemoteOCRTransport { _, _ in throw URLError(.timedOut) }
        let timedOut = await #expect(throws: ParserError.self) { try await parser(urlTimeout).parse(file: file, mimeType: "image/png", options: options) }
        #expect(Self.message(timedOut!) == "Azure AI Vision parsing failed: Timed out")

        // The analysis never finishes: the overall limit ends the polling.
        let endless = StubRemoteOCRTransport { request, _ in
            if request.httpMethod == "POST" { return .init(status: 202, headers: ["Operation-Location": StubRemoteOCRTransport.operationLocation]) }
            return .init(body: Data(#"{"status":"running"}"#.utf8))
        }
        var polling = parser(endless)
        polling.pollInterval = .milliseconds(10)
        polling.timeout = 0.3
        let clock = ContinuousClock()
        let started = clock.now
        let stopped = await #expect(throws: ParserError.self) { try await polling.parse(file: file, mimeType: "image/png", options: options) }
        #expect(Self.message(stopped!) == "Azure AI Vision parsing failed: Timed out")
        #expect(clock.now - started < .seconds(10))
        #expect(endless.requests.first?.httpMethod == "POST")
        #expect(!endless.requests.contains { $0.url!.path.hasSuffix("/pdf") })

        // A request that hangs is cut off by the same limit.
        let hanging = StubRemoteOCRTransport { _, _ in
            try await Task.sleep(for: .seconds(30))
            return .init()
        }
        var hangingParser = parser(hanging)
        hangingParser.timeout = 0.2
        let hung = await #expect(throws: ParserError.self) { try await hangingParser.parse(file: file, mimeType: "image/png", options: options) }
        #expect(Self.message(hung!) == "Azure AI Vision parsing failed: Timed out")
    }

    @Test func endpointChecks() async throws {
        let dir = try FixtureFactory.makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = try png(in: dir)
        let options = FixtureFactory.options(dir)

        // Internal endpoints are refused before anything is sent when they are not allowed.
        var internalConfig = RemoteOCREngineConfig(engine: "azureai", apiKey: "k", endpoint: "http://10.0.0.5:5000", allowInternalEndpoints: false)
        let blocked = StubRemoteOCRTransport.azure()
        let refused = await #expect(throws: ParserError.self) {
            try await parser(blocked, config: internalConfig, isInternalHost: { $0 == "10.0.0.5" }).parse(file: file, mimeType: "image/png", options: options)
        }
        #expect(Self.message(refused!) == "Invalid remote OCR endpoint: Connection blocked: 10.0.0.5 resolves to a non-public address")
        #expect(blocked.requests.isEmpty)

        // Allowed by default (REMOTE_OCR_ALLOW_INTERNAL_ENDPOINTS=true).
        internalConfig.allowInternalEndpoints = true
        let allowed = StubRemoteOCRTransport.azure(location: "http://10.0.0.5:5000/documentintelligence/documentModels/prebuilt-read/analyzeResults/op-9")
        _ = try await parser(allowed, config: internalConfig, isInternalHost: { $0 == "10.0.0.5" }).parse(file: file, mimeType: "image/png", options: options)
        #expect(allowed.requests.last?.url?.absoluteString == "http://10.0.0.5:5000/documentintelligence/documentModels/prebuilt-read/analyzeResults/op-9/pdf?api-version=2024-11-30")

        let badScheme = StubRemoteOCRTransport.azure()
        let invalid = await #expect(throws: ParserError.self) {
            try await parser(badScheme, config: RemoteOCREngineConfig(engine: "azureai", apiKey: "k", endpoint: "ftp://example.com")).parse(file: file, mimeType: "image/png", options: options)
        }
        #expect(Self.message(invalid!).hasPrefix("Invalid remote OCR endpoint: Invalid URL scheme or hostname"))
        #expect(badScheme.requests.isEmpty)

        // Every request is checked: a status URL on an internal host is not polled.
        let config = RemoteOCREngineConfig(engine: "azureai", apiKey: "k", endpoint: StubRemoteOCRTransport.endpoint, allowInternalEndpoints: false)
        let redirected = StubRemoteOCRTransport.azure(location: "http://169.254.169.254/documentintelligence/documentModels/prebuilt-read/analyzeResults/op-1")
        let stopped = await #expect(throws: ParserError.self) {
            try await parser(redirected, config: config, isInternalHost: { $0 == "169.254.169.254" }).parse(file: file, mimeType: "image/png", options: options)
        }
        #expect(Self.message(stopped!) == "Azure AI Vision parsing failed: Connection blocked: 169.254.169.254 resolves to a non-public address")
        #expect(redirected.requests.count == 1)
    }
}
