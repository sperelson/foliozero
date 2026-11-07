import Foundation
import FolioCore
import GRDB
import Hummingbird
import MultipartKit

/// Document versions and URL capture.
extension API {
    /// `POST /api/documents/{id}/update_version/`: multipart `document` (and optional `version_label`)
    /// stored as the next version of the root document. Returns the task id.
    func updateVersion(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.change, Document.objectType)
        let id = try request.intParam("id")
        let rootId = try await read { db -> Int in
            guard let document = try Document.fetchOne(db, key: id), document.deletedAt == nil else { throw APIError.notFound("Document") }
            guard try self.canAccess(document, .change, access: access, in: db) else { throw APIError.forbiddenText() }
            return document.rootDocumentId ?? id
        }
        let upload = try await receiveUpload(request)
        do {
            guard let file = upload.file else { throw APIError.field("document", "No file was submitted.") }
            let label = upload.data["version_label"]?.string.flatMap { $0.isEmpty ? nil : String($0.prefix(64)) }
            var consume = ConsumeRequest(file: file.url, originalFilename: file.filename, source: .apiUpload,
                                         overrides: DocumentOverrides(ownerId: access.user.id), deleteSource: true,
                                         versionOf: rootId, versionLabel: label)
            consume.taskId = UUID().uuidString.lowercased()
            let taskId = try await queue.enqueueConsume(consume, consumer: app.consumer(), ownerId: access.user.id)
            return .json(.string(taskId))
        } catch {
            upload.cleanup()
            throw error
        }
    }

    /// The version of `root` named in the path, never the root itself.
    private func loadVersion(_ request: APIRequest, access: AccessContext, in db: Database) throws -> Document {
        let rootId = try request.intParam("id")
        let versionId = try request.intParam("version_id")
        guard let root = try Document.fetchOne(db, key: rootId), root.rootDocumentId == nil else { throw APIError.notFound("Document") }
        guard try access.can(.change, objectType: Document.objectType, objectId: rootId, ownerId: root.ownerId, in: db) else {
            throw APIError.forbiddenText()
        }
        guard let version = try Document.fetchOne(db, key: versionId), version.rootDocumentId == rootId else {
            throw APIError.notFound("Document")
        }
        return version
    }

    /// `PATCH /api/documents/{id}/versions/{version_id}/`: changes `version_label`.
    func updateVersionLabel(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.change, Document.objectType)
        let data = try request.data()
        guard data.has("version_label") else { throw APIError.field("version_label", APIError.requiredField) }
        let label = data["version_label"].flatMap { $0.isNull ? nil : $0.string }.flatMap { $0.isEmpty ? nil : $0 }
        if let label, label.count > 64 { throw APIError.field("version_label", "Ensure this field has no more than 64 characters.") }
        let json = try await write { db -> JSON in
            var version = try self.loadVersion(request, access: access, in: db)
            version.versionLabel = label
            try version.update(db)
            return .object(JSONObject([
                ("id", JSON(version.id)), ("added", self.datetime(version.added)), ("version_label", JSON(version.versionLabel)),
                ("checksum", .string(version.checksum)), ("is_root", false),
            ]))
        }
        return .json(json)
    }

    /// `DELETE /api/documents/{id}/versions/{version_id}/`: removes a version and its files.
    func deleteVersion(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.delete, Document.objectType)
        let version = try await write { db -> Document in
            let version = try self.loadVersion(request, access: access, in: db)
            try DocumentStore.purge(version.id ?? 0, in: db)
            try SearchIndex.update(documentId: version.rootDocumentId ?? 0, in: db)
            return version
        }
        app.storage.deleteFiles(of: version)
        return .json(["result": "OK", "current_version_id": .int(version.rootDocumentId ?? 0)])
    }

    // MARK: - URL capture

    /// FolioZero extension `POST /api/documents/post_url/`: `{"url": ..., title, tags, ...}` like post_document.
    func postURL(_ request: APIRequest) async throws -> Response {
        let access = request.access
        guard access.has(.add, Document.objectType) else { throw APIError.forbiddenText("Insufficient permissions") }
        let data = try request.data()
        guard let raw = data["url"]?.string, !raw.isEmpty else { throw APIError.field("url", APIError.requiredField) }
        guard let url = URL(string: raw), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), url.host != nil else {
            throw APIError.field("url", "Enter a valid URL.")
        }
        let overrides = try await read { db in try self.uploadOverrides(data, access: access, in: db) }
        let source: DocumentSource = try data.optionalBool("from_webui") == true ? .webUI : .apiUpload
        let app = self.app
        let taskId = try await queue.enqueue(type: .consumeFile, source: source.triggerSource,
                                             input: ["filename": raw, "source": String(source.rawValue)], ownerId: access.user.id) { _ in
            do {
                let document = try await URLCapture.consume(url: url, app: app, overrides: overrides, source: source)
                return TaskOutcome(message: "Success. New document id \(document.id ?? 0) created", documentId: document.id)
            } catch let stop as ConsumeStopped {
                return TaskOutcome(message: stop.message)
            }
        }
        return .json(.string(taskId))
    }

    // MARK: - Streaming uploads

    struct ReceivedUpload: Sendable {
        struct File: Sendable {
            var url: URL
            var filename: String
            var size: Int
        }
        var file: File?
        var data: RequestData
        var leftovers: [URL]

        func cleanup() {
            for url in leftovers + [file?.url].compactMap({ $0 }) { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Streams a multipart upload to the scratch folder. The `document` part becomes `file`;
    /// other files are removed; text fields are returned as form data.
    func receiveUpload(_ request: APIRequest) async throws -> ReceivedUpload {
        let contentType = request.contentType ?? ""
        guard contentType.lowercased().hasPrefix("multipart/form-data") else {
            throw APIError.detail(.unsupportedMediaType, "Unsupported media type \"\(contentType)\" in request.")
        }
        guard let boundary = APIRequest.boundary(from: contentType) else {
            throw APIError.detail(.badRequest, "Multipart form parse error - Invalid boundary in multipart: None")
        }
        let scratch = settings.scratchDir
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let collector = MultipartCollector(fileDirectory: scratch)
        let parser = MultipartParser(boundary: boundary)
        parser.onHeader = { name, value in collector.header(name, value) }
        parser.onBody = { buffer in collector.body(&buffer) }
        parser.onPartComplete = { collector.complete() }
        var total = 0
        do {
            for try await chunk in request.rawBody {
                total += chunk.readableBytes
                if total > maxUploadSize {
                    throw APIError.detail(.contentTooLarge, "Upload exceeds the maximum size of \(maxUploadSize) bytes.")
                }
                do { try parser.execute(chunk) } catch { throw APIError.detail(.badRequest, "Multipart form parse error") }
                if let failure = collector.failure { throw failure }
            }
        } catch {
            collector.closeFiles()
            for part in collector.parts { if let url = part.fileURL { try? FileManager.default.removeItem(at: url) } }
            throw error
        }
        var fields: [(name: String, value: String)] = []
        var file: ReceivedUpload.File?
        var leftovers: [URL] = []
        for part in collector.parts {
            if let name = part.filename, let url = part.fileURL {
                if part.name == "document", file == nil {
                    file = ReceivedUpload.File(url: url, filename: name.precomposedStringWithCanonicalMapping, size: part.size)
                } else {
                    leftovers.append(url)
                }
            } else {
                fields.append((part.name, String(decoding: part.data, as: UTF8.self)))
            }
        }
        for url in leftovers { try? FileManager.default.removeItem(at: url) }
        return ReceivedUpload(file: file, data: RequestData(json: .object(APIRequest.formObject(fields)), isForm: true), leftovers: [])
    }
}
