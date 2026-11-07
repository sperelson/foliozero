import Foundation
import FolioCore
import FolioParsing
import GRDB
import Hummingbird
import PDFKit

/// Page edits, merging and splitting (Paperless-ngx `bulk_edit.py` rotate, merge, split,
/// delete_pages, edit_pdf, remove_password, merge_as_versions).
extension API {
    enum PDFOperation: Sendable {
        case rotate(degrees: Int)
        case merge(metadataDocumentId: Int?, deleteOriginals: Bool, archiveFallback: Bool)
        case split(pages: [[Int]], deleteOriginals: Bool)
        case deletePages(pages: [Int])
        case editPDF(operations: [EditOperation], deleteOriginal: Bool, updateDocument: Bool, includeMetadata: Bool)
        case removePassword(password: String, updateDocument: Bool, deleteOriginal: Bool, includeMetadata: Bool)
        case mergeAsVersions(rootId: Int, label: String?)

        var label: String {
            switch self {
            case .rotate: "document rotation"
            case .merge: "document merge"
            case .split: "document split"
            case .deletePages: "page deletion"
            case .editPDF: "PDF edit"
            case .removePassword: "password removal"
            case .mergeAsVersions: "document merge as versions"
            }
        }

        /// Methods that change the original document need ownership (Paperless `_has_document_permissions`).
        var needsOwnership: Bool {
            switch self {
            case .rotate, .deletePages, .editPDF, .removePassword, .mergeAsVersions: true
            case .merge(_, let delete, _), .split(_, let delete): delete
            }
        }

        var createsDocuments: Bool {
            switch self {
            case .merge, .split: true
            case .editPDF(_, _, let update, _), .removePassword(_, let update, _, _): !update
            default: false
            }
        }

        var deletesDocuments: Bool {
            switch self {
            case .mergeAsVersions: true
            case .merge(_, let delete, _), .split(_, let delete): delete
            case .editPDF(_, let delete, let update, _), .removePassword(_, let update, let delete, _): delete && !update
            default: false
            }
        }
    }

    struct EditOperation: Sendable {
        var page: Int
        var rotate: Int
        var doc: Int
    }

    static let sourceModes: Set<String> = ["latest_version", "explicit_selection"]

    // MARK: - Endpoints

    func rotateDocuments(_ request: APIRequest) async throws -> Response {
        let data = try request.data()
        guard let raw = data["degrees"], !raw.isNull else { throw APIError.field("degrees", APIError.requiredField) }
        guard let degrees = raw.int else { throw APIError.field("degrees", "A valid integer is required.") }
        guard degrees % 90 == 0 else { throw APIError.field("degrees", "degrees must be a multiple of 90") }
        return try await runPDFOperation(request, data: data, operation: .rotate(degrees: degrees), allowAll: true)
    }

    func mergeDocuments(_ request: APIRequest) async throws -> Response {
        let data = try request.data()
        let operation = PDFOperation.merge(metadataDocumentId: try data.optionalInt("metadata_document_id"),
                                           deleteOriginals: try data.optionalBool("delete_originals") ?? false,
                                           archiveFallback: try data.optionalBool("archive_fallback") ?? false)
        return try await runPDFOperation(request, data: data, operation: operation, allowAll: false)
    }

    func editPDFDocuments(_ request: APIRequest) async throws -> Response {
        let data = try request.data()
        let operations = try parseEditOperations(data["operations"], field: "operations")
        let operation = PDFOperation.editPDF(operations: operations, deleteOriginal: try data.optionalBool("delete_original") ?? false,
                                             updateDocument: try data.optionalBool("update_document") ?? false,
                                             includeMetadata: try data.optionalBool("include_metadata") ?? true)
        return try await runPDFOperation(request, data: data, operation: operation, allowAll: false)
    }

    func removePasswordDocuments(_ request: APIRequest) async throws -> Response {
        let data = try request.data()
        guard let password = data["password"]?.string, !password.isEmpty else { throw APIError.field("password", APIError.requiredField) }
        let operation = PDFOperation.removePassword(password: password, updateDocument: try data.optionalBool("update_document") ?? false,
                                                    deleteOriginal: try data.optionalBool("delete_original") ?? false,
                                                    includeMetadata: try data.optionalBool("include_metadata") ?? true)
        return try await runPDFOperation(request, data: data, operation: operation, allowAll: false)
    }

    func mergeAsVersions(_ request: APIRequest) async throws -> Response {
        let data = try request.data()
        guard let raw = data["root_document_id"], !raw.isNull else { throw APIError.field("root_document_id", APIError.requiredField) }
        guard let rootId = raw.int else { throw APIError.field("root_document_id", "A valid integer is required.") }
        var label = data["version_label"].flatMap { $0.isNull ? nil : $0.string?.trimmingCharacters(in: .whitespaces) }
        if label?.isEmpty == true { label = nil }
        if let label, label.count > 64 { throw APIError.field("version_label", "Ensure this field has no more than 64 characters.") }
        return try await runPDFOperation(request, data: data, operation: .mergeAsVersions(rootId: rootId, label: label), allowAll: false)
    }

    /// Legacy `bulk_edit` methods for page edits (API v9 clients and older v10 ones).
    func legacyPDFOperation(_ request: APIRequest, data: RequestData, method: String, parameters: JSONObject) async throws -> Response {
        let documents = data["documents"]?.array?.compactMap(\.strictInt) ?? []
        func flag(_ key: String, default value: Bool) throws -> Bool {
            guard let raw = parameters[key] else { return value }
            guard case .bool(let b) = raw else { throw APIError.nonField("\(key) must be a boolean") }
            return b
        }
        let operation: PDFOperation
        switch method {
        case "rotate":
            guard let raw = parameters["degrees"], let degrees = raw.int, degrees % 90 == 0 else { throw APIError.nonField("invalid rotation degrees") }
            operation = .rotate(degrees: degrees)
        case "merge":
            operation = .merge(metadataDocumentId: parameters["metadata_document_id"]?.int, deleteOriginals: try flag("delete_originals", default: false),
                               archiveFallback: try flag("archive_fallback", default: false))
        case "split":
            guard documents.count <= 1 else { throw APIError.nonField("Split method only supports one document") }
            guard let raw = parameters["pages"] else { throw APIError.nonField("pages not specified") }
            guard let text = raw.stringValue else { throw APIError.nonField("invalid pages specified") }
            let pageCount = try await read { db in try documents.first.flatMap { try Document.fetchOne(db, key: $0)?.pageCount } }
            guard let pageCount, pageCount > 0 else { throw APIError.nonField("document page count is unknown") }
            var groups: [[Int]] = []
            for group in text.split(separator: ",", omittingEmptySubsequences: false) {
                let parts = group.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
                guard let first = Int(parts[0].trimmingCharacters(in: .whitespaces)),
                      let last = parts.count > 1 ? Int(parts[1].trimmingCharacters(in: .whitespaces)) : first,
                      1 <= first, first <= last, last <= pageCount else { throw APIError.nonField("invalid pages specified") }
                groups.append(Array(first...last))
            }
            operation = .split(pages: groups, deleteOriginals: try flag("delete_originals", default: false))
        case "delete_pages":
            guard documents.count <= 1 else { throw APIError.nonField("Delete pages method only supports one document") }
            guard let raw = parameters["pages"] else { throw APIError.nonField("pages not specified") }
            guard let items = raw.array else { throw APIError.nonField("pages must be a list") }
            guard items.allSatisfy({ $0.strictInt != nil }) else { throw APIError.nonField("pages must be a list of integers") }
            let pages = items.compactMap(\.strictInt)
            guard pages.allSatisfy({ $0 >= 1 }) else { throw APIError.nonField("pages must be positive integers") }
            operation = .deletePages(pages: pages)
        case "edit_pdf":
            guard documents.count <= 1 else { throw APIError.nonField("Edit PDF method only supports one document") }
            guard parameters.contains("operations") else { throw APIError.nonField("operations not specified") }
            operation = .editPDF(operations: try parseEditOperations(parameters["operations"], field: "operations"),
                                 deleteOriginal: try flag("delete_original", default: false),
                                 updateDocument: try flag("update_document", default: false),
                                 includeMetadata: try flag("include_metadata", default: true))
        default: // remove_password
            guard let raw = parameters["password"] else { throw APIError.nonField("password not specified") }
            guard let password = raw.stringValue else { throw APIError.nonField("password must be a string") }
            operation = .removePassword(password: password, updateDocument: try flag("update_document", default: false),
                                        deleteOriginal: try flag("delete_original", default: false),
                                        includeMetadata: try flag("include_metadata", default: true))
        }
        var merged = data
        if let mode = parameters["source_mode"] { merged = merged.with("source_mode", mode) }
        return try await runPDFOperation(request, data: merged, operation: operation, allowAll: method == "rotate")
    }

    func parseEditOperations(_ value: JSON?, field: String) throws -> [EditOperation] {
        guard let value, !value.isNull else { throw APIError.field(field, APIError.requiredField) }
        guard let items = value.array else { throw APIError.field(field, "Expected a list of items but got type \"\(value.typeName)\".") }
        guard !items.isEmpty else { throw APIError.field(field, "This list may not be empty.") }
        var operations: [EditOperation] = []
        for item in items {
            guard let object = item.object, let page = object["page"]?.int else {
                throw APIError.validation(.object(JSONObject([(field, [["page": ["This field is required."]]])])))
            }
            guard page >= 1 else { throw APIError.validation(.object(JSONObject([(field, [["page": ["Ensure this value is greater than or equal to 1."]]])]))) }
            let rotate = object["rotate"]?.int ?? 0
            guard rotate % 90 == 0 else { throw APIError.validation(.object(JSONObject([(field, [["rotate": ["rotate must be a multiple of 90"]]])]))) }
            let doc = object["doc"]?.int ?? 0
            guard doc >= 0 else { throw APIError.validation(.object(JSONObject([(field, [["doc": ["Ensure this value is greater than or equal to 0."]]])]))) }
            operations.append(EditOperation(page: page, rotate: rotate, doc: doc))
        }
        return operations
    }

    // MARK: - Execution

    /// Validates, checks permissions and runs one operation. Errors in the file work are 400
    /// "Error performing <label>, check logs for more detail." as in Paperless-ngx.
    func runPDFOperation(_ request: APIRequest, data: RequestData, operation: PDFOperation, allowAll: Bool) async throws -> Response {
        let access = request.access
        if try data.optionalBool("all") == true, !allowAll { throw APIError.nonField("This method does not support all=true.") }
        let sourceMode = data["source_mode"]?.string ?? "latest_version"
        guard Self.sourceModes.contains(sourceMode) else { throw APIError.field("source_mode", "Invalid source_mode") }
        let fromWebUI = try data.optionalBool("from_webui") ?? false
        let ids = try await read { db -> [Int] in
            let ids = try self.resolveSelection(data, access: access, in: db)
            try self.validatePDFOperation(operation, ids: ids, in: db)
            return ids
        }
        try await read { db in try self.checkOperationPermissions(operation, ids: ids, access: access, in: db) }
        do {
            try await executePDFOperation(operation, ids: ids, sourceMode: sourceMode, access: access, fromWebUI: fromWebUI)
        } catch let error as APIError {
            throw error
        } catch {
            logger.warning("An error occurred performing \(operation.label): \(error)")
            throw APIError.badRequestText("Error performing \(operation.label), check logs for more detail.")
        }
        return .json(["result": "OK"])
    }

    private func validatePDFOperation(_ operation: PDFOperation, ids: [Int], in db: Database) throws {
        switch operation {
        case .editPDF(let operations, _, let update, _):
            guard ids.count <= 1 else { throw APIError.nonField("Edit PDF method only supports one document") }
            if operations.contains(where: { $0.doc >= operations.count }) { throw APIError.nonField("doc index is out of bounds") }
            if update, operations.contains(where: { $0.doc > 0 }) {
                throw APIError.nonField("update_document only allowed with a single output document")
            }
            if let id = ids.first, let pageCount = try Document.fetchOne(db, key: id)?.pageCount, pageCount > 0 {
                for op in operations where op.page > pageCount {
                    throw APIError.nonField("Page \(op.page) is out of bounds for document with \(pageCount) pages.")
                }
            }
        case .mergeAsVersions(let rootId, let label):
            guard ids.count >= 2 else { throw APIError.nonField("At least two documents are required.") }
            if label != nil && ids.count != 2 { throw APIError.nonField("version_label can only be used when merging one source document.") }
            guard ids.contains(rootId) else { throw APIError.nonField("root_document_id must be one of the selected documents.") }
            let documents = try fetchDocuments(ids, in: db)
            if documents.contains(where: { $0.rootDocumentId != nil }) { throw APIError.nonField("Only top-level documents can be merged as versions.") }
            let sources = ids.filter { $0 != rootId }
            if try Document.filter(sources.contains(Column("root_document_id"))).fetchCount(db) > 0 {
                throw APIError.nonField("Documents with existing versions cannot be merged into another document.")
            }
        case .split, .deletePages:
            guard ids.count <= 1 else { throw APIError.nonField("This method only supports one document") }
        default:
            break
        }
    }

    private func checkOperationPermissions(_ operation: PDFOperation, ids: [Int], access: AccessContext, in db: Database) throws {
        if access.isSuperuser { return }
        guard access.has(.change, Document.objectType) else { throw APIError.forbiddenText() }
        var ownsAll = true
        for document in try fetchDocuments(ids, in: db) {
            guard try access.can(.change, objectType: Document.objectType, objectId: document.id ?? 0, ownerId: document.ownerId, in: db) else {
                throw APIError.forbiddenText()
            }
            let root = try document.rootDocumentId.flatMap { try Document.fetchOne(db, key: $0) } ?? document
            if !access.isOwner(ownerId: root.ownerId) { ownsAll = false }
        }
        if operation.needsOwnership && !ownsAll { throw APIError.forbiddenText() }
        if operation.createsDocuments && !access.has(.add, Document.objectType) { throw APIError.forbiddenText() }
        if operation.deletesDocuments && !access.has(.delete, Document.objectType) { throw APIError.forbiddenText() }
    }

    struct SourcePair: Sendable {
        var root: Document
        var source: Document
    }

    /// Paperless-ngx `_resolve_root_and_source_doc`.
    func resolveSource(_ document: Document, mode: String, in db: Database) throws -> SourcePair {
        let root = try document.rootDocumentId.flatMap { try Document.fetchOne(db, key: $0) } ?? document
        if mode == "explicit_selection" || document.rootDocumentId != nil { return SourcePair(root: root, source: document) }
        let latest = try Document.filter(Column("root_document_id") == root.id && Column("deleted_at") == nil)
            .order(Column("version_index").desc, Column("id").desc).fetchOne(db)
        return SourcePair(root: root, source: latest ?? root)
    }

    /// Paperless-ngx `DocumentMetadataOverrides.from_document`.
    func overrides(from document: Document, in db: Database) throws -> DocumentOverrides {
        let id = document.id ?? 0
        var overrides = DocumentOverrides(title: document.title, correspondentId: document.correspondentId, documentTypeId: document.documentTypeId,
                                          storagePathId: document.storagePathId, tagIds: try DocumentStore.tagIds(of: id, in: db),
                                          created: document.created, ownerId: document.ownerId)
        let grants = try PermissionSet.load(objectType: Document.objectType, objectId: id, in: db)
        if grants != PermissionSet() { overrides.permissions = grants }
        let fields = Dictionary(uniqueKeysWithValues: try CustomField.fetchAll(db).map { ($0.id ?? 0, $0) })
        for instance in try CustomFieldInstance.filter(Column("document_id") == id && Column("deleted_at") == nil).fetchAll(db) {
            guard let field = fields[instance.fieldId] else { continue }
            let value = CustomFieldValues.value(of: instance, field: field)
            overrides.customFields[instance.fieldId] = value.isNull ? JSONValue?.none : .some(value)
        }
        return overrides
    }

    /// The original file of `document`, refusing paths outside the originals folder.
    func originalFile(_ document: Document) throws -> URL {
        try safeFile(document.filename, root: app.storage.originalsDir)
    }

    /// Moves a PDFOperations output to a unique scratch file the consumer may delete.
    private func stage(_ url: URL) throws -> URL {
        let target = settings.scratchDir.appendingPathComponent("pdfedit-\(UUID().uuidString).pdf")
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    private func executePDFOperation(_ operation: PDFOperation, ids: [Int], sourceMode: String, access: AccessContext, fromWebUI: Bool) async throws {
        let source: DocumentSource = fromWebUI ? .webUI : .apiUpload
        let work = try app.makeScratchDirectory(prefix: "pdfedit")
        defer { try? FileManager.default.removeItem(at: work) }
        let userId = access.user.id
        let documents = try await read { db -> [(SourcePair, DocumentOverrides)] in
            var result: [(SourcePair, DocumentOverrides)] = []
            for id in ids {
                guard let document = try Document.fetchOne(db, key: id) else { continue }
                let pair = try self.resolveSource(document, mode: sourceMode, in: db)
                result.append((pair, try self.overrides(from: pair.root, in: db)))
            }
            return result
        }

        switch operation {
        case .rotate(let degrees):
            var seen = Set<Int>()
            for (pair, overrides) in documents where seen.insert(pair.root.id ?? 0).inserted {
                guard pair.source.mimeType == "application/pdf" else {
                    logger.warning("Document \(pair.root.id ?? 0) is not a PDF, skipping rotation.")
                    continue
                }
                let output = try PDFOperations.rotate(try originalFile(pair.source), degrees: degrees, outputDirectory: work)
                try await enqueueVersion(try stage(output), root: pair.root, name: "\(pair.root.id ?? 0)_rotated.pdf", overrides: overrides, source: source, userId: userId)
            }

        case .deletePages(let pages):
            guard let (pair, overrides) = documents.first else { return }
            let output = try PDFOperations.deletePages(try originalFile(pair.source), pages: pages, outputDirectory: work)
            try await enqueueVersion(try stage(output), root: pair.root, name: "\(pair.root.id ?? 0)_pages_deleted.pdf", overrides: overrides, source: source, userId: userId)

        case .merge(let metadataId, let deleteOriginals, let archiveFallback):
            var files: [URL] = []
            var merged: [Int] = []
            var handoffASN: Int?
            for (pair, _) in documents {
                let id = pair.root.id ?? 0
                if pair.source.mimeType == "application/pdf" {
                    files.append(try originalFile(pair.source))
                } else if archiveFallback, pair.source.hasArchiveVersion {
                    files.append(try safeFile(pair.source.archiveFilename, root: app.storage.archiveDir))
                } else {
                    logger.warning("Document \(id) is not a PDF, it will not be included in the merge")
                    continue
                }
                merged.append(pair.source.id ?? id)
                if handoffASN == nil { handoffASN = pair.root.archiveSerialNumber }
            }
            guard !merged.isEmpty else {
                logger.warning("No documents were merged")
                return
            }
            let output = try stage(try PDFOperations.merge(files, outputDirectory: work))
            var overrides = DocumentOverrides()
            if let metadataId, let (pair, metadata) = documents.first(where: { $0.0.root.id == metadataId || $0.0.source.id == metadataId }) {
                overrides = metadata
                overrides.title = pair.root.title + " (merged)"
                if let asn = pair.root.archiveSerialNumber { handoffASN = asn }
            }
            overrides.ownerId = userId
            overrides.archiveSerialNumber = deleteOriginals ? handoffASN : nil
            let name = merged.map(String.init).joined(separator: "_").prefix(100) + "_merged.pdf"
            try await enqueueNewDocuments([(output, String(name), overrides)], source: source, userId: userId, deleteAfter: deleteOriginals ? merged : [])

        case .split(let groups, let deleteOriginals):
            guard let (pair, metadata) = documents.first else { return }
            let outputs = try PDFOperations.split(try originalFile(pair.source), pageGroups: groups, outputDirectory: work)
            let id = pair.root.id ?? 0
            var jobs: [(URL, String, DocumentOverrides)] = []
            for (index, (group, output)) in zip(groups, outputs).enumerated() {
                var overrides = metadata
                overrides.title = "\(pair.root.title) (split \(index + 1))"
                overrides.ownerId = userId
                overrides.archiveSerialNumber = nil
                jobs.append((try stage(output), "\(id)_\(group.first ?? 0)-\(group.last ?? 0).pdf", overrides))
            }
            try await enqueueNewDocuments(jobs, source: source, userId: userId, deleteAfter: deleteOriginals ? [id] : [])

        case .editPDF(let operations, let deleteOriginal, let updateDocument, let includeMetadata):
            guard let (pair, metadata) = documents.first else { return }
            let id = pair.root.id ?? 0
            let outputCount = (operations.map(\.doc).max() ?? 0) + 1
            var specs = [[PDFOperations.PageSpec]](repeating: [], count: outputCount)
            for op in operations { specs[op.doc].append(PDFOperations.PageSpec(page: op.page, rotation: op.rotate)) }
            var overrides = includeMetadata ? metadata : DocumentOverrides()
            overrides.ownerId = userId
            let file = try originalFile(pair.source)
            if updateDocument {
                let output = try PDFOperations.editPages(file, specs: specs[0], outputDirectory: work)
                try await enqueueVersion(try stage(output), root: pair.root, name: "\(id)_edited.pdf", overrides: overrides, source: source, userId: userId)
            } else {
                overrides.archiveSerialNumber = deleteOriginal && outputCount == 1 ? pair.root.archiveSerialNumber : nil
                var jobs: [(URL, String, DocumentOverrides)] = []
                for (index, pageSpecs) in specs.enumerated() {
                    let edited = work.appendingPathComponent("edit-\(index + 1)", isDirectory: true)
                    try FileManager.default.createDirectory(at: edited, withIntermediateDirectories: true)
                    let output = try PDFOperations.editPages(file, specs: pageSpecs, outputDirectory: edited)
                    jobs.append((try stage(output), "\(id)_edit_\(index + 1).pdf", overrides))
                }
                try await enqueueNewDocuments(jobs, source: source, userId: userId, deleteAfter: deleteOriginal ? [id] : [])
            }

        case .removePassword(let password, let updateDocument, let deleteOriginal, let includeMetadata):
            for (pair, metadata) in documents {
                let id = pair.root.id ?? 0
                let file = try originalFile(pair.source)
                guard PDFDocument(url: file)?.isEncrypted == true else {
                    logger.info("Skipping password removal for document \(id) because the source PDF is not encrypted")
                    continue
                }
                guard let output = try PDFOperations.removePassword(file, passwords: [password], outputDirectory: work) else {
                    throw PDFOperations.OperationError.locked(file.lastPathComponent)
                }
                var overrides = includeMetadata ? metadata : DocumentOverrides()
                overrides.ownerId = userId
                if updateDocument {
                    try await enqueueVersion(try stage(output), root: pair.root, name: "\(id)_unprotected.pdf", overrides: overrides, source: source, userId: userId)
                } else {
                    overrides.archiveSerialNumber = nil
                    try await enqueueNewDocuments([(try stage(output), "\(id)_unprotected.pdf", overrides)], source: source, userId: userId,
                                                  deleteAfter: deleteOriginal ? [id] : [])
                }
            }

        case .mergeAsVersions(let rootId, let label):
            try await performMergeAsVersions(ids: ids, rootId: rootId, label: label, actorId: userId)
        }
    }

    /// Consumes `file` as the next version of `root`.
    private func enqueueVersion(_ file: URL, root: Document, name: String, overrides: DocumentOverrides, source: DocumentSource, userId: Int?) async throws {
        var request = ConsumeRequest(file: file, originalFilename: name, source: source, overrides: overrides, deleteSource: true, versionOf: root.id)
        request.taskId = UUID().uuidString.lowercased()
        try await queue.enqueueConsume(request, consumer: app.consumer(), ownerId: userId)
    }

    /// Consumes new documents. With `deleteAfter`, the originals give up their ASNs first,
    /// go to the trash once every new document exists, and get their ASNs back on failure.
    private func enqueueNewDocuments(_ jobs: [(URL, String, DocumentOverrides)], source: DocumentSource, userId: Int?, deleteAfter: [Int]) async throws {
        guard !deleteAfter.isEmpty else {
            for (file, name, overrides) in jobs {
                var request = ConsumeRequest(file: file, originalFilename: name, source: source, overrides: overrides, deleteSource: true)
                request.taskId = UUID().uuidString.lowercased()
                try await queue.enqueueConsume(request, consumer: app.consumer(), ownerId: userId)
            }
            return
        }
        let backup = try await write { db -> [Int: Int] in
            var backup: [Int: Int] = [:]
            for document in try self.fetchDocuments(deleteAfter, in: db) {
                guard let asn = document.archiveSerialNumber, let id = document.id else { continue }
                backup[id] = asn
                try db.execute(sql: "UPDATE documents SET archive_serial_number = NULL WHERE id = ?", arguments: [id])
            }
            return backup
        }
        let app = self.app
        try await queue.enqueue(type: .consumeFile, source: source.triggerSource,
                                input: ["filename": jobs.map(\.1).joined(separator: ", "), "source": String(source.rawValue)], ownerId: userId) { progress in
            var created: [Int] = []
            do {
                for (file, name, overrides) in jobs {
                    let document = try await app.consumer().consume(
                        ConsumeRequest(file: file, originalFilename: name, source: source, overrides: overrides, deleteSource: true), progress: progress)
                    if let id = document.id { created.append(id) }
                }
                try await app.database.write { db in
                    for id in deleteAfter { try DocumentStore.moveToTrash(id, actorId: userId, in: db) }
                }
            } catch {
                for (file, _, _) in jobs { try? FileManager.default.removeItem(at: file) }
                try? await app.database.write { db in
                    for (id, asn) in backup {
                        try db.execute(sql: "UPDATE documents SET archive_serial_number = ? WHERE id = ?", arguments: [asn, id])
                    }
                }
                throw error
            }
            return TaskOutcome(message: "Success. New document id \(created.map(String.init).joined(separator: ", ")) created", documentId: created.first)
        }
    }

    /// Paperless-ngx `merge_as_versions`: the other documents become versions of the root.
    private func performMergeAsVersions(ids: [Int], rootId: Int, label: String?, actorId: Int?) async throws {
        let auditEnabled = settings.auditLogEnabled
        try await write { db in
            let sources = ids.filter { $0 != rootId }.sorted()
            var root = try DocumentStore.document(rootId, in: db)
            var nextIndex = try Int.fetchOne(db, sql: "SELECT MAX(version_index) FROM documents WHERE root_document_id = ?", arguments: [rootId]) ?? 0
            var asns: [Int] = []
            for sourceId in sources {
                var document = try DocumentStore.document(sourceId, in: db)
                nextIndex += 1
                if let asn = document.archiveSerialNumber { asns.append(asn) }
                document.rootDocumentId = rootId
                document.versionIndex = nextIndex
                document.archiveSerialNumber = nil
                if let label { document.versionLabel = label }
                try document.update(db)
                try SearchIndex.update(documentId: sourceId, in: db)
            }
            if root.archiveSerialNumber == nil, !asns.isEmpty { root.archiveSerialNumber = asns.removeFirst() }
            root.modified = Date()
            try root.update(db)
            try SearchIndex.update(documentId: rootId, in: db)
            if auditEnabled {
                try AuditLog.record(.update, objectType: Document.objectType, objectId: rootId, repr: root.title,
                                    changes: ["Merged As Versions": ["None", sources.map(String.init).joined(separator: ",")]], actorId: actorId, in: db)
            }
        }
        await enqueueRename([rootId])
        await publishDocumentsDeleted(ids.filter { $0 != rootId })
    }

    // MARK: - Bulk download

    /// `POST /api/documents/bulk_download/`: a zip of originals, archives or both.
    func bulkDownload(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, Document.objectType)
        let data = try request.data()
        let content = data["content"]?.string ?? "archive"
        guard ["archive", "originals", "both"].contains(content) else { throw APIError.field("content", "\"\(content)\" is not a valid choice.") }
        let compression = data["compression"]?.string ?? "none"
        guard ["none", "deflated", "bzip2", "lzma"].contains(compression) else {
            throw APIError.field("compression", "\"\(compression)\" is not a valid choice.")
        }
        let followFormatting = try data.optionalBool("follow_formatting") ?? false
        let entries = try await read { db -> [(Document, String?)] in
            let ids = try self.resolveSelection(data, access: access, in: db)
            var result: [(Document, String?)] = []
            for document in try self.fetchDocuments(ids, in: db) {
                guard try self.canAccess(document, .view, access: access, in: db) else { throw APIError.forbiddenText() }
                let root = try document.rootDocumentId.flatMap { try Document.fetchOne(db, key: $0) } ?? document
                var file = try self.effectiveVersion(of: root, requested: root, version: nil, in: db)
                file.title = root.title
                file.created = root.created
                file.correspondentId = root.correspondentId
                let correspondent = try root.correspondentId.flatMap { try Correspondent.fetchOne(db, key: $0)?.name }
                result.append((file, correspondent))
            }
            return result
        }
        let zipURL = settings.scratchDir.appendingPathComponent("bulk-\(UUID().uuidString)-compressed-archive")
        do {
            try BulkArchive.write(entries: entries, to: zipURL, content: content, deflate: compression != "none", followFormatting: followFormatting,
                                  storage: app.storage, api: self)
        } catch {
            try? FileManager.default.removeItem(at: zipURL)
            throw error
        }
        return try streamAndDelete(zipURL, contentType: "application/zip", disposition: ContentDisposition.header("attachment", filename: "documents.zip"))
    }

    /// Streams a temporary file and removes it once it is open.
    func streamAndDelete(_ url: URL, contentType: String, disposition: String) throws -> Response {
        let handle = try FileHandle(forReadingFrom: url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        try? FileManager.default.removeItem(at: url)
        let box = HandleBox(handle)
        let body = ResponseBody(contentLength: size?.intValue) { writer in
            defer { box.close() }
            while let chunk = try box.handle.read(upToCount: 256 * 1024), !chunk.isEmpty {
                try await writer.write(ByteBuffer(bytes: chunk))
            }
            try await writer.finish(nil)
        }
        var headers: HTTPFields = [:]
        headers[.contentType] = contentType
        headers[.contentDisposition] = disposition
        return Response(status: .ok, headers: headers, body: body)
    }

    // MARK: - Email

    /// `POST /api/documents/email/` (and the per-document variant).
    func emailDocuments(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, Document.objectType)
        var parsed = try request.data()
        if let id = request.params["id"], let documentId = Int(id) { parsed = parsed.with("documents", [.int(documentId)]) }
        let data = parsed
        var errors = JSONObject()
        let addresses = (data["addresses"]?.string ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if !data.has("addresses") { errors["addresses"] = [.string(APIError.requiredField)] } else if let bad = addresses.first(where: { !Self.isValidEmail($0) }) {
            errors["addresses"] = [.string("Invalid email address: \(bad)")]
        }
        for key in ["subject", "message"] where (data[key]?.string ?? "").isEmpty {
            errors[key] = [.string(data.has(key) ? "This field may not be blank." : APIError.requiredField)]
        }
        if !errors.isEmpty { throw APIError.validation(.object(errors)) }
        let useArchive = try data.optionalBool("use_archive_version") ?? true
        let entries = try await read { db -> [(Document, String?)] in
            let ids = try self.resolveSelection(data, access: access, in: db)
            guard !ids.isEmpty else { throw APIError.field("documents", "At least one document is required") }
            return try self.fetchDocuments(ids, in: db).map { document in
                guard try self.canAccess(document, .view, access: access, in: db) else { throw APIError.forbiddenText() }
                return (document, try document.correspondentId.flatMap { try Correspondent.fetchOne(db, key: $0)?.name })
            }
        }
        do {
            var attachments: [OutgoingEmail.Attachment] = []
            for (document, correspondent) in entries {
                let archive = useArchive && document.hasArchiveVersion
                let file = archive ? try safeFile(document.archiveFilename, root: app.storage.archiveDir) : try originalFile(document)
                attachments.append(.init(filename: Self.publicFilename(document, correspondent: correspondent, archive: archive),
                                         contentType: archive ? "application/pdf" : document.mimeType, data: try Data(contentsOf: file)))
            }
            let client = try SMTPClient(settings: settings)
            try await client.send(OutgoingEmail(from: settings.emailFrom ?? settings.emailHostUser ?? "foliozero@localhost", to: addresses,
                                                subject: data["subject"]?.string ?? "", body: data["message"]?.string ?? "", attachments: attachments))
        } catch {
            logger.warning("An error occurred emailing documents: \(error)")
            throw APIError(status: .internalServerError, body: .text("Error emailing documents, check logs for more detail."))
        }
        return .json(["message": "Email sent"])
    }
}

/// Lets a file handle travel into a response body writer.
final class HandleBox: @unchecked Sendable {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func close() { try? handle.close() }
}
