import Foundation
import Logging

/// Remote OCR engines (Paperless-ngx `RemoteOCREngine`, `PAPERLESS_REMOTE_OCR_ENGINE`).
public enum RemoteOCREngineKind: String, Sendable, CaseIterable {
    /// Azure AI Document Intelligence, `prebuilt-read` model.
    case azureAI = "azureai"
}

/// The remote engine settings one parse run uses (Paperless-ngx `RemoteEngineConfig`).
public struct RemoteOCREngineConfig: Sendable, Equatable {
    /// `REMOTE_OCR_ENGINE`. Only `azureai` is known; other values leave remote OCR off.
    public var engine: String?
    /// `REMOTE_OCR_API_KEY`.
    public var apiKey: String?
    /// `REMOTE_OCR_ENDPOINT`, e.g. `https://<resource>.cognitiveservices.azure.com`.
    public var endpoint: String?
    /// `REMOTE_OCR_ALLOW_INTERNAL_ENDPOINTS`. When false, endpoints on internal addresses are refused.
    public var allowInternalEndpoints: Bool

    public init(engine: String? = nil, apiKey: String? = nil, endpoint: String? = nil, allowInternalEndpoints: Bool = true) {
        self.engine = engine
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.allowInternalEndpoints = allowInternalEndpoints
    }

    /// The engine, when the name is known.
    public var engineKind: RemoteOCREngineKind? { engine.flatMap(RemoteOCREngineKind.init(rawValue:)) }

    /// True when the engine is known and has everything it needs (Paperless-ngx `engine_is_valid`).
    /// Azure AI needs an API key and an endpoint.
    public var engineIsValid: Bool {
        switch engineKind {
        case .azureAI?: apiKey != nil && endpoint != nil
        case nil: false
        }
    }
}

/// Sends one HTTP request for the remote OCR client. Tests inject a stub; the
/// default is `URLSessionRemoteOCRTransport`.
public protocol RemoteOCRTransport: Sendable {
    /// Returns the body and response. Non-2xx answers are returned, not thrown.
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// URLSession transport: ephemeral, no cookies, no cache, and no redirects, so a
/// request (and its API key) cannot be bounced to another host.
public struct URLSessionRemoteOCRTransport: RemoteOCRTransport {
    public static let shared = URLSessionRemoteOCRTransport()

    let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteOCRError.invalidResponse("not an HTTP response")
        }
        return (data, http)
    }
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest) async -> URLRequest? {
        nil
    }
}

/// Answers whether a host name or address is internal (loopback, private, link-local).
/// FolioCore passes its `NetworkPolicy.isInternal`.
public typealias RemoteOCRHostCheck = @Sendable (String) -> Bool

public enum RemoteOCRError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The endpoint is not an http(s) URL with a host.
    case invalidEndpoint(String)
    /// The host is internal and `REMOTE_OCR_ALLOW_INTERNAL_ENDPOINTS` is false.
    case blockedEndpoint(String)
    /// The service answered with a non-2xx status.
    case rejected(status: Int, message: String)
    /// The analysis ended with status `failed` or `canceled`.
    case analysisFailed(String)
    case invalidResponse(String)
    case unreachable(String)
    case timedOut

    public var description: String {
        switch self {
        case .invalidEndpoint(let endpoint): "Invalid URL scheme or hostname: \(endpoint)"
        case .blockedEndpoint(let host): "Connection blocked: \(host) resolves to a non-public address"
        case let .rejected(status, message): "HTTP \(status)\(message.isEmpty ? "" : ": \(message)")"
        case .analysisFailed(let message): "Analysis failed: \(message)"
        case .invalidResponse(let message): "Invalid response: \(message)"
        case .unreachable(let message): "Service unreachable: \(message)"
        case .timedOut: "Timed out"
        }
    }
}

/// Azure AI Document Intelligence REST client, wire-compatible with the
/// `azure-ai-documentintelligence` 1.0 SDK calls Paperless-ngx makes:
///
/// 1. `POST {endpoint}/documentintelligence/documentModels/prebuilt-read:analyze`
///    `?api-version=2024-11-30&outputContentFormat=text&output=pdf` with
///    `{"base64Source": "..."}` and the `Ocp-Apim-Subscription-Key` header.
///    The service answers 202 with an `Operation-Location` header.
/// 2. `GET` the `Operation-Location` URL until `status` is `succeeded`, `failed` or
///    `canceled`, waiting `Retry-After` (or `pollInterval`) between requests.
///    The text is `analyzeResult.content`.
/// 3. `GET .../documentModels/prebuilt-read/analyzeResults/{resultId}/pdf` for the
///    searchable PDF.
///
/// Every request URL, including the polled one, is checked against the host
/// policy, and redirects are never followed.
public struct AzureDocumentIntelligenceClient: Sendable {
    public static let apiVersion = "2024-11-30"
    public static let modelId = "prebuilt-read"
    public static let keyHeader = "Ocp-Apim-Subscription-Key"

    public struct Analysis: Sendable, Equatable {
        /// The result id from the `Operation-Location` URL (the SDK's `operation_id`).
        public var resultId: String
        /// `analyzeResult.content`, plain text.
        public var content: String
        /// The searchable PDF.
        public var pdf: Data
    }

    public let endpoint: String
    let apiKey: String
    let transport: any RemoteOCRTransport
    let allowInternalEndpoints: Bool
    let isInternalHost: RemoteOCRHostCheck
    /// Wait between status requests when the service sends no `Retry-After`.
    public var pollInterval: Duration
    /// Timeout of one HTTP request.
    public var requestTimeout: TimeInterval
    /// Limit for the whole analysis: upload, polling and PDF download.
    public var timeout: TimeInterval

    static let logger = Logger(label: "foliozero.parsing.remote")

    public init(
        endpoint: String,
        apiKey: String,
        transport: any RemoteOCRTransport = URLSessionRemoteOCRTransport.shared,
        allowInternalEndpoints: Bool = true,
        isInternalHost: @escaping RemoteOCRHostCheck = { _ in false },
        pollInterval: Duration = .seconds(1),
        requestTimeout: TimeInterval = 300,
        timeout: TimeInterval = 1800
    ) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.transport = transport
        self.allowInternalEndpoints = allowInternalEndpoints
        self.isInternalHost = isInternalHost
        self.pollInterval = pollInterval
        self.requestTimeout = requestTimeout
        self.timeout = timeout
    }

    // MARK: URLs

    /// `{endpoint}/documentintelligence`, after the endpoint checks.
    public func serviceBase() throws -> URL {
        let trimmed = endpoint.trimmingCharacters(in: .whitespaces)
        guard let components = URLComponents(string: trimmed), components.url != nil else {
            throw RemoteOCRError.invalidEndpoint(trimmed)
        }
        try check(components, original: trimmed)
        var base = components
        var path = base.path
        while path.hasSuffix("/") { path.removeLast() }
        base.path = path + "/documentintelligence"
        base.query = nil
        base.fragment = nil
        guard let url = base.url else { throw RemoteOCRError.invalidEndpoint(trimmed) }
        return url
    }

    /// Scheme must be http(s) with a host; internal hosts only when allowed.
    func check(_ components: URLComponents, original: String) throws {
        guard let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty else {
            throw RemoteOCRError.invalidEndpoint(original)
        }
        if !allowInternalEndpoints, isInternalHost(host) {
            throw RemoteOCRError.blockedEndpoint(host)
        }
    }

    func check(_ url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw RemoteOCRError.invalidEndpoint(url.absoluteString)
        }
        try check(components, original: url.absoluteString)
    }

    public func analyzeURL() throws -> URL {
        try url(try serviceBase(), path: "/documentModels/\(Self.modelId):analyze", query: [
            URLQueryItem(name: "api-version", value: Self.apiVersion),
            URLQueryItem(name: "outputContentFormat", value: "text"),
            URLQueryItem(name: "output", value: "pdf"),
        ])
    }

    public func pdfURL(resultId: String) throws -> URL {
        let escaped = resultId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))) ?? resultId
        return try url(try serviceBase(), path: "/documentModels/\(Self.modelId)/analyzeResults/\(escaped)/pdf",
                       query: [URLQueryItem(name: "api-version", value: Self.apiVersion)])
    }

    func url(_ base: URL, path: String, query: [URLQueryItem]) throws -> URL {
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw RemoteOCRError.invalidEndpoint(endpoint)
        }
        components.percentEncodedPath = components.percentEncodedPath + path
        components.queryItems = query
        guard let url = components.url else { throw RemoteOCRError.invalidEndpoint(endpoint) }
        return url
    }

    /// The last path segment of an `Operation-Location` URL (the SDK's `_parse_operation_id`).
    public static func resultId(fromOperationLocation location: URL) -> String? {
        let last = location.lastPathComponent
        return last.isEmpty || last == "/" ? nil : last
    }

    // MARK: Analysis

    /// Runs the analysis of `document` and downloads the searchable PDF.
    public func analyze(document: Data) async throws -> Analysis {
        let analyzeURL = try analyzeURL()
        let deadline = ContinuousClock.now + .milliseconds(Int64(timeout * 1000))

        var start = URLRequest(url: analyzeURL)
        start.httpMethod = "POST"
        start.setValue("application/json", forHTTPHeaderField: "Content-Type")
        start.setValue("application/json", forHTTPHeaderField: "Accept")
        start.httpBody = Data(#"{"base64Source":""#.utf8) + document.base64EncodedData() + Data(#""}"#.utf8)
        let (startBody, startResponse) = try await send(start, deadline: deadline)
        guard let location = startResponse.value(forHTTPHeaderField: "Operation-Location"),
              let operationURL = URL(string: location) else {
            throw RemoteOCRError.invalidResponse("the analyze request returned no Operation-Location header" + Self.snippet(startBody))
        }
        guard let resultId = Self.resultId(fromOperationLocation: operationURL) else {
            throw RemoteOCRError.invalidResponse("cannot read the result id from \(location)")
        }

        var wait = Self.retryAfter(startResponse) ?? pollInterval
        var content: String?
        while content == nil {
            let remaining = deadline - ContinuousClock.now
            guard remaining > .zero else { throw RemoteOCRError.timedOut }
            try await Task.sleep(for: min(wait, remaining))
            var poll = URLRequest(url: operationURL)
            poll.httpMethod = "GET"
            poll.setValue("application/json", forHTTPHeaderField: "Accept")
            let (body, response) = try await send(poll, deadline: deadline)
            let status: OperationStatus
            do {
                status = try JSONDecoder().decode(OperationStatus.self, from: body)
            } catch {
                throw RemoteOCRError.invalidResponse("cannot decode the analysis status" + Self.snippet(body))
            }
            switch status.status?.lowercased() {
            case "succeeded":
                content = status.analyzeResult?.content ?? ""
            case "failed", "canceled":
                throw RemoteOCRError.analysisFailed(status.error?.summary ?? status.status ?? "failed")
            default:
                wait = Self.retryAfter(response) ?? pollInterval
            }
        }

        var download = URLRequest(url: try pdfURL(resultId: resultId))
        download.httpMethod = "GET"
        download.setValue("application/pdf", forHTTPHeaderField: "Accept")
        let (pdf, _) = try await send(download, deadline: deadline)
        return Analysis(resultId: resultId, content: content ?? "", pdf: pdf)
    }

    /// Checks the URL, adds the key, enforces the deadline and maps non-2xx answers.
    func send(_ request: URLRequest, deadline: ContinuousClock.Instant) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else { throw RemoteOCRError.invalidEndpoint(endpoint) }
        try check(url)
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { throw RemoteOCRError.timedOut }
        let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
        var request = request
        request.timeoutInterval = max(0.001, min(requestTimeout, seconds))
        request.setValue(apiKey, forHTTPHeaderField: Self.keyHeader)
        request.setValue("FolioZero", forHTTPHeaderField: "User-Agent")
        let transport = self.transport
        let sendable = request
        let (data, response): (Data, HTTPURLResponse)
        do {
            (data, response) = try await Self.within(remaining) { try await transport.send(sendable) }
        } catch {
            throw Self.map(error)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw RemoteOCRError.rejected(status: response.statusCode, message: Self.serviceMessage(data))
        }
        return (data, response)
    }

    static func within<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw RemoteOCRError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw RemoteOCRError.timedOut }
            return result
        }
    }

    static func map(_ error: Error) -> Error {
        if error is RemoteOCRError || error is CancellationError { return error }
        if let error = error as? URLError {
            switch error.code {
            case .timedOut: return RemoteOCRError.timedOut
            case .cancelled: return CancellationError()
            default: return RemoteOCRError.unreachable(error.localizedDescription)
            }
        }
        return RemoteOCRError.unreachable("\(error)")
    }

    /// `retry-after-ms`, `x-ms-retry-after-ms` or `Retry-After` (seconds), as azure-core reads them.
    static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
        for name in ["retry-after-ms", "x-ms-retry-after-ms"] {
            if let raw = response.value(forHTTPHeaderField: name), let ms = Double(raw.trimmingCharacters(in: .whitespaces)), ms >= 0 {
                return .milliseconds(Int64(ms))
            }
        }
        if let raw = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(raw.trimmingCharacters(in: .whitespaces)), seconds >= 0 {
            return .milliseconds(Int64(seconds * 1000))
        }
        return nil
    }

    /// The service's `{"error": {"code", "message"}}`, or the start of the body.
    static func serviceMessage(_ body: Data) -> String {
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body), let summary = envelope.error?.summary {
            return summary
        }
        let text = String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    static func snippet(_ body: Data) -> String {
        let message = serviceMessage(body)
        return message.isEmpty ? "" : " (\(message))"
    }

    struct OperationStatus: Decodable {
        var status: String?
        var analyzeResult: AnalyzeResult?
        var error: ServiceError?

        struct AnalyzeResult: Decodable {
            var content: String?
        }
    }

    struct ErrorEnvelope: Decodable {
        var error: ServiceError?
    }

    struct ServiceError: Decodable {
        var code: String?
        var message: String?
        var innererror: Inner?

        struct Inner: Decodable {
            var code: String?
            var message: String?
        }

        var summary: String? {
            let parts = [code, message, innererror?.message].compactMap { $0 }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: ": ")
        }
    }
}
