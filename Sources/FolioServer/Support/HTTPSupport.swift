import Foundation
import FolioCore
import HTTPTypes
import Hummingbird
import MultipartKit

// MARK: - Query string

/// Ordered, multi-valued query parameters.
struct QueryItems: Sendable {
    var items: [(name: String, value: String)]

    init(_ query: String?) {
        items = []
        guard let query, !query.isEmpty else { return }
        for pair in query.split(separator: "&", omittingEmptySubsequences: true) {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = Self.decode(parts[0])
            let value = parts.count > 1 ? Self.decode(parts[1]) : ""
            items.append((name, value))
        }
    }

    init(items: [(name: String, value: String)]) {
        self.items = items
    }

    static func decode(_ text: Substring) -> String {
        let plusDecoded = text.replacingOccurrences(of: "+", with: " ")
        return plusDecoded.removingPercentEncoding ?? plusDecoded
    }

    static func encode(_ text: String) -> String {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+?#")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }

    /// Last value, like Django's `QueryDict.get`.
    subscript(name: String) -> String? {
        items.last { $0.name == name }?.value
    }

    func all(_ name: String) -> [String] {
        items.filter { $0.name == name }.map(\.value)
    }

    func contains(_ name: String) -> Bool {
        items.contains { $0.name == name }
    }

    /// `true`/`1` (any case) as Paperless `get_boolean`.
    func flag(_ name: String) -> Bool {
        guard let value = self[name]?.lowercased() else { return false }
        return ["true", "1", "yes", "y", "on", "t"].contains(value)
    }

    func int(_ name: String) -> Int? {
        self[name].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    var encoded: String {
        items.map { "\(Self.encode($0.name))=\(Self.encode($0.value))" }.joined(separator: "&")
    }

    /// A copy with `name` set to `value` (or removed when nil), sorted by name like
    /// DRF's `replace_query_param`.
    func replacing(_ name: String, with value: String?) -> QueryItems {
        var copy = items.filter { $0.name != name }
        if let value { copy.append((name, value)) }
        let sorted = copy.enumerated().sorted { ($0.element.name, $0.offset) < ($1.element.name, $1.offset) }.map(\.element)
        return QueryItems(items: sorted)
    }
}

// MARK: - Request

enum AuthMethod: String, Sendable {
    case basic, token, session, remoteUser
}

struct Authentication: Sendable {
    var access: AccessContext
    var method: AuthMethod
    var session: Session?
    /// True when `AUTO_LOGIN_USERNAME` created `session` for this request; the response sets its cookies.
    var isNewSession = false
}

/// An uploaded file written to a scratch folder.
struct UploadedFile: Sendable {
    var fieldName: String
    var filename: String
    var url: URL
    var size: Int
}

/// Parsed request body: fields as a JSON value, plus uploaded files.
struct RequestData: Sendable {
    var json: JSON
    var files: [UploadedFile] = []
    /// Form bodies carry strings only; JSON bodies carry typed values.
    var isForm: Bool = false

    var object: JSONObject { json.object ?? JSONObject() }

    subscript(key: String) -> JSON? { json.object?[key] }

    func has(_ key: String) -> Bool { json.object?.contains(key) ?? false }

    /// All values for a key. Form fields repeat; JSON bodies give arrays.
    func list(_ key: String) -> [JSON]? {
        guard let value = self[key] else { return nil }
        if case .array(let items) = value { return items }
        return [value]
    }
}

/// A request after routing and authentication.
struct APIRequest: Sendable {
    let head: HTTPRequest
    let rawBody: RequestBody
    let context: APIRequestContext
    /// Path without the query string.
    let path: String
    var params: [String: String]
    let query: QueryItems
    var auth: Authentication?
    var version: Int
    /// Collected body for routes that do not stream.
    var body: ByteBuffer?

    var method: HTTPRequest.Method { head.method }

    func header(_ name: String) -> String? {
        guard let field = HTTPField.Name(name) else { return nil }
        return head.headerFields[field]
    }

    /// The authenticated user. Only call on routes that require authentication.
    var access: AccessContext { auth!.access }
    var userId: Int { access.userId }

    var remoteAddress: String? { context.remoteAddress }

    /// Host and port the client used (HTTP/1 `Host` becomes the authority).
    var host: String? { head.authority ?? header("Host") }

    func intParam(_ name: String) throws -> Int {
        guard let raw = params[name], let value = Int(raw) else { throw APIError.notFound() }
        return value
    }

    var contentType: String? { header("Content-Type") }

    /// Parses a collected body (JSON, form-urlencoded, or multipart without files).
    func data() throws -> RequestData {
        guard let body, body.readableBytes > 0 else { return RequestData(json: .object(JSONObject())) }
        let bytes = Data(body.readableBytesView)
        let type = (contentType ?? "application/json").lowercased()
        if type.hasPrefix("application/x-www-form-urlencoded") {
            let text = String(decoding: bytes, as: UTF8.self)
            return RequestData(json: .object(Self.formObject(QueryItems(text).items)), isForm: true)
        }
        if type.hasPrefix("multipart/form-data") {
            guard let boundary = Self.boundary(from: contentType ?? "") else {
                throw APIError.detail(.badRequest, "Multipart form parse error - Invalid boundary in multipart: None")
            }
            var fields: [(name: String, value: String)] = []
            let parser = MultipartParser(boundary: boundary)
            let collector = MultipartCollector()
            parser.onHeader = { name, value in collector.header(name, value) }
            parser.onBody = { buffer in collector.body(&buffer) }
            parser.onPartComplete = { collector.complete() }
            do {
                try parser.execute(body)
            } catch {
                throw APIError.detail(.badRequest, "Multipart form parse error")
            }
            for part in collector.parts where part.filename == nil {
                fields.append((part.name, String(decoding: part.data, as: UTF8.self)))
            }
            return RequestData(json: .object(Self.formObject(fields)), isForm: true)
        }
        do {
            return RequestData(json: try JSON.parse(bytes))
        } catch {
            throw APIError.detail(.badRequest, "JSON parse error - \(error)")
        }
    }

    /// Repeated keys become arrays.
    static func formObject(_ items: [(name: String, value: String)]) -> JSONObject {
        var object = JSONObject()
        for (name, value) in items {
            switch object[name] {
            case nil: object[name] = .string(value)
            case .array(var values)?:
                values.append(.string(value))
                object[name] = .array(values)
            case let existing?:
                object[name] = .array([existing, .string(value)])
            }
        }
        return object
    }

    static func boundary(from contentType: String) -> String? {
        for part in contentType.split(separator: ";") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("boundary=") {
                var value = String(trimmed.dropFirst("boundary=".count))
                if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}

// MARK: - Multipart

/// Collects multipart parts in memory (small forms) or streams file parts to disk.
final class MultipartCollector {
    struct Part {
        var name: String
        var filename: String?
        var data = Data()
        var fileURL: URL?
        var size = 0
    }

    private(set) var parts: [Part] = []
    private var headers: [(String, String)] = []
    private var current: Part?
    private var handle: FileHandle?
    private let fileDirectory: URL?
    private(set) var failure: Error?

    init(fileDirectory: URL? = nil) {
        self.fileDirectory = fileDirectory
    }

    func header(_ name: String, _ value: String) {
        headers.append((name, value))
    }

    private func beginPartIfNeeded() {
        guard current == nil else { return }
        var name = ""
        var filename: String?
        for (header, value) in headers where header.lowercased() == "content-disposition" {
            let parameters = Self.dispositionParameters(value)
            name = parameters["name"] ?? ""
            filename = parameters["filename*"].flatMap(Self.decodeExtended) ?? parameters["filename"]
        }
        var part = Part(name: name, filename: filename)
        if filename != nil, let fileDirectory {
            let url = fileDirectory.appendingPathComponent(UUID().uuidString)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try? FileHandle(forWritingTo: url)
            part.fileURL = url
            if handle == nil { failure = APIError.detail(.internalServerError, "Cannot store the upload") }
        }
        current = part
    }

    func body(_ buffer: inout ByteBuffer) {
        beginPartIfNeeded()
        guard var part = current else { return }
        let bytes = buffer.readableBytesView
        part.size += bytes.count
        if let handle {
            do { try handle.write(contentsOf: bytes) } catch { failure = error }
        } else {
            part.data.append(contentsOf: bytes)
        }
        buffer.moveReaderIndex(forwardBy: bytes.count)
        current = part
    }

    func complete() {
        beginPartIfNeeded()
        try? handle?.close()
        handle = nil
        if let part = current { parts.append(part) }
        current = nil
        headers = []
    }

    func closeFiles() {
        try? handle?.close()
        handle = nil
    }

    static func dispositionParameters(_ value: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = value.startIndex
        // Split on ';' outside quotes.
        var pieces: [String] = []
        var currentPiece = ""
        var inQuotes = false
        while index < value.endIndex {
            let c = value[index]
            if c == "\"" { inQuotes.toggle() }
            if c == ";" && !inQuotes {
                pieces.append(currentPiece)
                currentPiece = ""
            } else {
                currentPiece.append(c)
            }
            index = value.index(after: index)
        }
        pieces.append(currentPiece)
        for piece in pieces.dropFirst() {
            let trimmed = piece.trimmingCharacters(in: .whitespaces)
            guard let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            var val = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if val.hasPrefix("\""), val.hasSuffix("\""), val.count >= 2 {
                val = String(val.dropFirst().dropLast()).replacingOccurrences(of: "\\\"", with: "\"")
            }
            result[key] = val
        }
        return result
    }

    /// RFC 5987 `UTF-8''name%20here`.
    static func decodeExtended(_ value: String) -> String? {
        let parts = value.components(separatedBy: "''")
        guard parts.count == 2 else { return nil }
        return parts[1].removingPercentEncoding
    }
}

// MARK: - Responses

extension Response {
    static func json(_ value: JSON, status: HTTPResponse.Status = .ok, version: Int? = nil) -> Response {
        var buffer = ByteBuffer()
        buffer.writeString(value.serialized())
        var headers: HTTPFields = [:]
        headers[.contentType] = version.map { "application/json; version=\($0)" } ?? "application/json"
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: buffer))
    }

    static func text(_ text: String, status: HTTPResponse.Status = .ok, contentType: String = "text/html; charset=utf-8") -> Response {
        var buffer = ByteBuffer()
        buffer.writeString(text)
        var headers: HTTPFields = [:]
        headers[.contentType] = contentType
        return Response(status: status, headers: headers, body: ResponseBody(byteBuffer: buffer))
    }

    static func noContent() -> Response {
        Response(status: .noContent)
    }

    static func redirect(_ location: String, status: HTTPResponse.Status = .found) -> Response {
        var headers: HTTPFields = [:]
        headers[.location] = location
        return Response(status: status, headers: headers)
    }
}

extension APIError {
    func response(version: Int?) -> Response {
        var response: Response
        switch body {
        case .json(let json): response = .json(json, status: status, version: version)
        case .text(let text): response = .text(text, status: status)
        }
        for field in headers { response.headers.append(field) }
        return response
    }
}

// MARK: - Content-Disposition

enum ContentDisposition {
    /// Paperless-ngx `serve_file`: ASCII fallback plus RFC 5987 UTF-8 name.
    static func header(_ disposition: String, filename: String) -> String {
        let ascii = filename.replacingOccurrences(of: ",", with: "_")
            .decomposedStringWithCompatibilityMapping
            .unicodeScalars.filter { $0.isASCII }
            .map(String.init).joined()
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "\"", with: "_")
        let encoded = pythonQuote(filename)
        return "\(disposition); filename=\"\(ascii)\"; filename*=utf-8''\(encoded)"
    }

    /// `urllib.parse.quote` with the default safe character `/`.
    static func pythonQuote(_ text: String) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~/")
        allowed.remove(charactersIn: "")
        return text.addingPercentEncoding(withAllowedCharacters: allowed) ?? text
    }
}
