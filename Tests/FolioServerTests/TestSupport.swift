import CoreGraphics
import CoreText
import Foundation
import FolioParsing
import GRDB
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import FolioCore
@testable import FolioServer

/// A temporary directory removed when the value is deinitialised.
final class TempDir: @unchecked Sendable {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("foliozero-server-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

/// Writes a one-page PDF with real (selectable) text.
func makeTextPDF(_ text: String, at url: URL) {
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    context.beginPDFPage(nil)
    let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
    let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
    let framesetter = CTFramesetterCreateWithAttributedString(attributed)
    let path = CGPath(rect: box.insetBy(dx: 50, dy: 50), transform: nil)
    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
    CTFrameDraw(frame, context)
    context.endPDFPage()
    context.closePDF()
}

/// Writes a PDF with one text page per entry of `pages`.
func makeMultiPagePDF(_ pages: [String], at url: URL) {
    var box = CGRect(x: 0, y: 0, width: 595, height: 842)
    let context = CGContext(url as CFURL, mediaBox: &box, nil)!
    for text in pages {
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let attributed = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font])
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)
        let path = CGPath(rect: box.insetBy(dx: 50, dy: 50), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil), context)
        context.endPDFPage()
    }
    context.closePDF()
}

extension TestClientProtocol {
    /// Uploads a file through post_document and returns the new document id once consumed.
    func upload(_ file: URL, as user: TestUser, env: TestEnvironment, title: String? = nil) async throws -> Int {
        var form = MultipartBody()
        form.file("document", filename: file.lastPathComponent, contentType: "application/pdf", contents: try Data(contentsOf: file))
        if let title { form.field("title", title) }
        let (body, headers) = form.finished()
        let response = try await call(.post, "/api/documents/post_document/", as: user, headers: headers, body: body)
        let taskId = try #require(response.json.string)
        await env.queue.waitUntilIdle()
        let task = try await get("/api/tasks/?task_id=\(taskId)", as: user).json.results.first
        return try #require(task?["related_document_ids"]?[0]?.int)
    }
}

/// A FolioApp on a temporary home with an HTTP server in front of it.
final class TestEnvironment: Sendable {
    let dir: TempDir
    let app: FolioApp
    let queue: TaskQueue

    init(overrides: [String: String] = [:], remoteOCRTransport: any RemoteOCRTransport = URLSessionRemoteOCRTransport.shared) throws {
        dir = TempDir()
        var values = ["TIME_ZONE": "UTC", "CONSUMER_DISABLE": "true"]
        values.merge(overrides) { _, new in new }
        let settings = try SettingsLoader.load(home: dir.url.path, environment: [:], overrides: values)
        app = try FolioApp.open(settings: settings, remoteOCRTransport: remoteOCRTransport)
        queue = TaskQueue(database: app.database, workers: 1, logger: app.logger)
    }

    func run<T: Sendable>(_ setup: TestingSetup = .router, _ test: @Sendable (any TestClientProtocol) async throws -> T) async throws -> T {
        try await FolioHTTPServer(app: app, queue: queue).makeApplication().test(setup, test)
    }

    /// A user with an API token. Passwords are slow to hash, so only set one when needed.
    @discardableResult
    func user(_ name: String, superuser: Bool = false, staff: Bool = false, password: String? = nil, permissions: [String] = []) throws -> TestUser {
        try app.database.write { db in
            var user = try UserStore.createUser(username: name, password: password, isSuperuser: superuser, isStaff: staff, in: db)
            if staff { user.isStaff = true; try user.update(db) }
            for codename in permissions {
                try db.execute(sql: "INSERT INTO user_permissions(user_id, codename) VALUES (?, ?)", arguments: [user.id!, codename])
            }
            let token = try UserStore.token(for: user.id!, in: db)
            return TestUser(id: user.id!, name: name, token: token)
        }
    }

    /// Every view/add/change/delete permission for the given models.
    static func permissions(_ models: [String]) -> [String] {
        models.flatMap { model in ["view", "add", "change", "delete"].map { "\($0)_\(model)" } }
    }

    static let regularModels = ["document", "tag", "correspondent", "documenttype", "storagepath", "customfield", "savedview",
                                "sharelink", "note", "uisettings", "paperlesstask"]

    /// A document row with a stored original file (no parsing).
    @discardableResult
    func document(_ title: String, content: String = "", owner: Int? = nil, created: CalendarDate = CalendarDate(year: 2024, month: 3, day: 14),
                  tags: [Int] = [], correspondent: Int? = nil, asn: Int? = nil, mimeType: String = "application/pdf") throws -> Int {
        let originals = app.settings.originalsDir
        return try app.database.write { db in
            var document = Document(title: title, content: content, correspondentId: correspondent, ownerId: owner, created: created,
                                    mimeType: mimeType, checksum: UUID().uuidString.lowercased(), archiveSerialNumber: asn, pageCount: 1)
            document = try DocumentStore.insert(document, tagIds: tags, in: db)
            let id = document.id!
            let filename = String(format: "%07d.pdf", id)
            try Data("%PDF-1.4 \(title)".utf8).write(to: originals.appendingPathComponent(filename))
            document.filename = filename
            document.originalFilename = "\(title).pdf"
            try document.update(db)
            return id
        }
    }

    func tag(_ name: String, owner: Int? = nil, parent: Int? = nil, inbox: Bool = false) throws -> Int {
        try app.database.write { db in
            var tag = Tag(name: name, isInboxTag: inbox, parentId: parent, ownerId: owner)
            try tag.insert(db)
            return tag.id!
        }
    }

    func correspondent(_ name: String, owner: Int? = nil) throws -> Int {
        try app.database.write { db in
            var object = Correspondent(name: name, ownerId: owner)
            try object.insert(db)
            return object.id!
        }
    }
}

struct TestUser: Sendable {
    var id: Int
    var name: String
    var token: String

    var headers: HTTPFields {
        var fields: HTTPFields = [:]
        fields[.authorization] = "Token \(token)"
        return fields
    }
}

extension TestClientProtocol {
    @discardableResult
    func call(_ method: HTTPRequest.Method, _ uri: String, as user: TestUser? = nil, json: JSON? = nil,
              headers: HTTPFields = [:], body: ByteBuffer? = nil) async throws -> TestResponse {
        var fields = user?.headers ?? [:]
        for field in headers { fields.append(field) }
        var payload = body
        if let json {
            fields[.contentType] = "application/json"
            payload = ByteBuffer(string: json.serialized())
        }
        return try await execute(uri: uri, method: method, headers: fields, body: payload)
    }

    func get(_ uri: String, as user: TestUser?) async throws -> TestResponse {
        try await call(.get, uri, as: user)
    }
}

extension TestResponse {
    var json: JSON {
        (try? JSON.parse(Data(body.readableBytesView))) ?? .null
    }

    var text: String { String(buffer: body) }
}

/// A multipart/form-data body.
struct MultipartBody {
    let boundary = "----FolioZeroTest\(UUID().uuidString.prefix(8))"
    var data = Data()

    mutating func field(_ name: String, _ value: String) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
    }

    mutating func file(_ name: String, filename: String, contentType: String, contents: Data) {
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\nContent-Type: \(contentType)\r\n\r\n".utf8))
        data.append(contents)
        data.append(Data("\r\n".utf8))
    }

    func finished() -> (ByteBuffer, HTTPFields) {
        var body = data
        body.append(Data("--\(boundary)--\r\n".utf8))
        var headers: HTTPFields = [:]
        headers[.contentType] = "multipart/form-data; boundary=\(boundary)"
        return (ByteBuffer(bytes: body), headers)
    }
}

extension JSON {
    /// Convenience for tests: `json["results"]?[0]?["id"]`.
    subscript(index: Int) -> JSON? {
        guard let array, index >= 0, index < array.count else { return nil }
        return array[index]
    }

    var ids: [Int] { (array ?? []).compactMap { $0["id"]?.int } }
    var results: [JSON] { self["results"]?.array ?? [] }
}

extension Array where Element == JSON {
    var ids: [Int] { compactMap { $0["id"]?.int } }
}
