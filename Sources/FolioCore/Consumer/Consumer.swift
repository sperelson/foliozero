import Foundation
import FolioParsing
import GRDB
import Logging
import UniformTypeIdentifiers

/// Where a document came from (Paperless-ngx `DocumentSource`, same values).
public enum DocumentSource: Int, Sendable, Codable {
    case consumeFolder = 1
    case apiUpload = 2
    case mailFetch = 3
    case webUI = 4

    public var triggerSource: TaskRecord.TriggerSource {
        switch self {
        case .consumeFolder: .folderConsume
        case .apiUpload: .apiUpload
        case .mailFetch: .emailConsume
        case .webUI: .webUI
        }
    }
}

/// Metadata supplied with a file that takes precedence over detection.
public struct DocumentOverrides: Sendable, Codable, Equatable {
    public var title: String?
    public var correspondentId: Int?
    public var documentTypeId: Int?
    public var storagePathId: Int?
    public var tagIds: [Int] = []
    public var created: CalendarDate?
    public var archiveSerialNumber: Int?
    public var ownerId: Int?
    public var permissions: PermissionSet?
    /// Field id to value; `nil` adds the field without a value.
    public var customFields: [Int: JSONValue?] = [:]

    public init(title: String? = nil, correspondentId: Int? = nil, documentTypeId: Int? = nil, storagePathId: Int? = nil,
                tagIds: [Int] = [], created: CalendarDate? = nil, archiveSerialNumber: Int? = nil, ownerId: Int? = nil,
                permissions: PermissionSet? = nil, customFields: [Int: JSONValue?] = [:]) {
        self.title = title; self.correspondentId = correspondentId; self.documentTypeId = documentTypeId
        self.storagePathId = storagePathId; self.tagIds = tagIds; self.created = created
        self.archiveSerialNumber = archiveSerialNumber; self.ownerId = ownerId; self.permissions = permissions
        self.customFields = customFields
    }
}

public struct ConsumeRequest: Sendable {
    /// The file to consume. With `deleteSource`, it is removed after success.
    public var file: URL
    /// Name shown to users and used for the default title.
    public var originalFilename: String
    public var source: DocumentSource
    public var overrides: DocumentOverrides
    public var deleteSource: Bool
    public var taskId: String?
    public var mailRuleId: Int?
    /// Store the file as a new version of this (root) document instead of a new document.
    public var versionOf: Int?
    public var versionLabel: String?

    public init(file: URL, originalFilename: String? = nil, source: DocumentSource, overrides: DocumentOverrides = .init(),
                deleteSource: Bool = false, taskId: String? = nil, mailRuleId: Int? = nil, versionOf: Int? = nil, versionLabel: String? = nil) {
        self.versionOf = versionOf
        self.versionLabel = versionLabel
        self.file = file
        self.originalFilename = originalFilename ?? file.lastPathComponent
        self.source = source
        self.overrides = overrides
        self.deleteSource = deleteSource
        self.taskId = taskId
        self.mailRuleId = mailRuleId
    }
}

public enum ConsumeError: Error, CustomStringConvertible, Equatable {
    case fileNotFound(String)
    case unsupportedType(String, String)
    case duplicate(fileName: String, existingId: Int, inTrash: Bool)
    case preConsumeScriptFailed(Int32, String)
    case parseFailed(String, String)
    case asnInUse(Int)
    case stoppedByWorkflow(String)

    public var description: String {
        switch self {
        case .fileNotFound(let path): "File not found: \(path)"
        case let .unsupportedType(name, mime): "\(name): unsupported file type \(mime)"
        case let .duplicate(name, id, trash):
            "\(name): Not consuming \(name): It is a duplicate of document #\(id)" + (trash ? " (in the trash)" : "")
        case let .preConsumeScriptFailed(code, output): "Pre-consume script failed with exit code \(code): \(output)"
        case let .parseFailed(name, why): "\(name): Error while parsing: \(why)"
        case .asnInUse(let asn): "Archive serial number \(asn) is already in use"
        case .stoppedByWorkflow(let name): "\(name): a workflow moved the document to the trash; consumption stopped"
        }
    }
}

/// Consumption ended on purpose without a new document (for example the first
/// half of a double-sided scan was staged). Task records report it as a success.
public struct ConsumeStopped: Error, CustomStringConvertible, Equatable {
    public var message: String
    public var description: String { message }
}

/// Progress of a consume run, in percent, with a status message.
public typealias ConsumeProgress = @Sendable (_ percent: Int, _ message: String) -> Void

/// Turns one file into a stored, indexed document (Paperless-ngx `documents/consumer.py`).
public struct Consumer: Sendable {
    public let app: FolioApp

    /// The settings for this run: `app.settings` with the application configuration applied.
    let settings: Settings

    public init(app: FolioApp) {
        self.app = app
        self.settings = app.settings
    }

    private init(app: FolioApp, settings: Settings) {
        self.app = app
        self.settings = settings
    }

    var logger: Logger { app.logger }

    /// Paperless-ngx reads the application configuration (`/api/config/`) when each
    /// consumption starts, so a change applies to the next document without a restart.
    @discardableResult
    public func consume(_ request: ConsumeRequest, progress: ConsumeProgress = { _, _ in }) async throws -> Document {
        try await Consumer(app: app, settings: app.effectiveSettings()).run(request, progress: progress)
    }

    private func run(_ request: ConsumeRequest, progress: ConsumeProgress) async throws -> Document {
        let fm = FileManager.default
        guard fm.fileExists(atPath: request.file.path) else { throw ConsumeError.fileNotFound(request.file.path) }
        let name = request.originalFilename
        logger.info("Consuming \(name)", metadata: ["task": "\(request.taskId ?? "-")"])
        progress(0, "Consumption started")

        let workDir = try app.makeScratchDirectory(prefix: "consume")
        defer { try? fm.removeItem(at: workDir) }

        // Work on a copy, so a failure never damages the source file.
        let working = workDir.appendingPathComponent(Self.safeFileName(name))
        try fm.copyItem(at: request.file, to: working)

        try await runPreConsumeScript(source: request.file, working: working, taskId: request.taskId)

        let mimeType = try FileTypeDetector.mimeType(of: working)
        // Every type the remote OCR engine reads is also read locally, so this decides support.
        guard app.parsers.parser(for: mimeType, fileName: name, allowRemote: false) != nil else {
            throw ConsumeError.unsupportedType(name, mimeType)
        }

        // Workflows with a "Consumption Started" trigger adjust the overrides (not for new versions).
        let workflows = WorkflowEngine(app: app)
        let started = request.versionOf != nil
            ? WorkflowEngine.ConsumptionResult(overrides: request.overrides)
            : try await workflows.consumptionStarted(
                fileName: name,
                path: request.file.path,
                source: request.source,
                mailRuleId: request.mailRuleId,
                overrides: request.overrides
            )
        for message in started.messages { logger.info("\(name): \(message)") }
        if started.moveToTrash {
            if request.deleteSource { try? fm.removeItem(at: request.file) }
            throw ConsumeError.stoppedByWorkflow(name)
        }
        var request = request
        request.overrides = started.overrides

        // Workflows have run, so it is known whether this document was singled out for remote OCR.
        let remoteOCR = app.remoteOCRConfig()
        let allowRemote = started.remoteOCR || remoteOCR.remoteOCRByDefault
        guard let parser = app.parser(for: mimeType, fileName: name, allowRemote: allowRemote, remoteOCR: remoteOCR) else {
            throw ConsumeError.unsupportedType(name, mimeType)
        }
        if started.remoteOCR, !parser.usesRemoteService {
            logger.warning("\(name): Remote OCR was requested for this document but no remote parser is available for it, processing locally instead.")
        }

        // Double-sided collation: the first scan is staged, the second is merged with it.
        if request.versionOf == nil, let collated = try await collateIfNeeded(request: request, working: working, mimeType: mimeType, workDir: workDir) {
            defer { try? fm.removeItem(at: collated.deletingLastPathComponent()) }
            var next = request
            next.file = collated
            next.deleteSource = true
            if request.deleteSource { try? fm.removeItem(at: request.file) }
            return try await consume(next, progress: progress)
        }

        // Barcodes: tags, ASN, and splitting into several documents.
        var barcodes: [FoundBarcode] = []
        if request.versionOf == nil, BarcodeLogic.isNeeded(settings), Self.barcodeScannable(mimeType, settings: settings) {
            progress(5, "Reading barcodes")
            let logic = BarcodeLogic(settings: settings)
            do {
                barcodes = try await BarcodeReader.detect(
                    file: working, mimeType: mimeType, maxPages: settings.consumerBarcodeMaxPages,
                    dpi: settings.consumerBarcodeDPI, upscale: settings.consumerBarcodeUpscale, passwords: started.passwords
                ).map { FoundBarcode(page: $0.page, value: $0.value, format: $0.format) }
            } catch {
                logger.warning("\(name): barcode detection failed: \(error)")
            }
            let separators = logic.separationPages(barcodes)
            let willSplit = !separators.isEmpty && mimeType == "application/pdf"
            if logic.enableTags && (!logic.tagSplit || !willSplit) {
                let names = logic.tagNames(barcodes)
                if !names.isEmpty {
                    let ids = try await tagIds(forNames: names)
                    request.overrides.tagIds = Array(Set(request.overrides.tagIds).union(ids)).sorted()
                }
            }
            if willSplit {
                return try await split(request: request, working: working, separators: separators, workDir: workDir, progress: progress)
            }
            if let asn = logic.asn(barcodes) {
                request.overrides.archiveSerialNumber = asn
            }
        }

        progress(10, "Checking for duplicates")
        let checksum = try Checksum.sha256(of: working)
        let duplicates = try await app.database.read { db in try DocumentStore.duplicates(of: checksum, in: db) }
        if let existing = duplicates.first {
            if settings.consumerDeleteDuplicates {
                if request.deleteSource { try? fm.removeItem(at: request.file) }
                throw ConsumeError.duplicate(fileName: name, existingId: existing.id ?? 0, inTrash: existing.deletedAt != nil)
            }
            logger.warning("\(name) is a duplicate of document #\(existing.id ?? 0); consuming it anyway")
        }

        progress(20, "Parsing document")
        let outputDir = workDir.appendingPathComponent("parser", isDirectory: true)
        try fm.createDirectory(at: outputDir, withIntermediateDirectories: true)
        var options = settings.parseOptions(scratchDirectory: outputDir)
        options.pdfPasswords = started.passwords
        let result: ParseResult
        do {
            result = try await parser.parse(file: working, mimeType: mimeType, options: options)
        } catch {
            throw ConsumeError.parseFailed(name, "\(error)")
        }
        progress(70, "Storing document")

        let content = Self.cleanContent(result.text)
        let title = request.overrides.title
            ?? (Self.prefersSuggestedTitle(mimeType) ? result.suggestedTitle : nil)
            ?? Self.defaultTitle(for: name)
        // Emails carry their own date (Paperless-ngx's mail parser returns it from get_date).
        let ownDate = mimeType == "message/rfc822" ? result.metadataDate.map { CalendarDate($0, in: settings.timeZone) } : nil
        let created = request.overrides.created
            ?? ownDate
            ?? app.dateExtractor.firstDate(filename: name, content: content)
            ?? result.metadataDate.map { CalendarDate($0, in: settings.timeZone) }
            ?? Self.modificationDate(of: request.file).map { CalendarDate($0, in: settings.timeZone) }
            ?? CalendarDate.today(in: settings.timeZone)

        let archiveChecksum = try result.archiveFile.map { try Checksum.sha256(of: $0) }
        let document = Document(
            title: String(title.prefix(128)),
            content: content,
            correspondentId: request.overrides.correspondentId,
            documentTypeId: request.overrides.documentTypeId,
            storagePathId: request.overrides.storagePathId,
            ownerId: request.overrides.ownerId,
            created: created,
            mimeType: mimeType,
            checksum: checksum,
            archiveChecksum: archiveChecksum,
            originalFilename: name,
            archiveSerialNumber: request.overrides.archiveSerialNumber,
            pageCount: result.pageCount,
            language: result.language,
            originalMetadata: result.metadata
        )

        if let rootId = request.versionOf {
            let version = try await storeVersion(document: document, rootId: rootId, label: request.versionLabel, working: working, result: result)
            if request.deleteSource { try? fm.removeItem(at: request.file) }
            logger.info("Stored \(name) as version \(version.versionIndex ?? 0) of document #\(rootId)")
            progress(100, "Finished")
            return version
        }

        var stored = try await store(document: document, request: request, working: working, result: result)
        if settings.consumerStoreBarcodeValues, !barcodes.isEmpty, let id = stored.id {
            let found = barcodes
            try await app.database.write { db in
                for code in found {
                    var row = DocumentBarcode(documentId: id, page: code.page + 1, value: code.value, format: code.format)
                    try row.insert(db)
                }
                try SearchIndex.update(documentId: id, in: db)
            }
        }

        if let template = started.titleTemplate, let id = stored.id {
            stored = try await renderWorkflowTitle(template, documentId: id)
        }
        if let id = stored.id {
            let trashed = await workflows.run(.documentAdded, documentId: id, originalFile: app.storage.originalURL(stored), extraActions: started.deferredActions)
            stored = try await app.database.read { db in try DocumentStore.document(id, in: db) }
            if trashed { logger.info("Document #\(id) was moved to the trash by a workflow") }
            await updateAIIndex(documentId: id)
        }

        if request.deleteSource { try? fm.removeItem(at: request.file) }
        progress(90, "Running post-consume tasks")
        await runPostConsumeScript(stored, taskId: request.taskId)
        logger.info("Document #\(stored.id ?? 0) \"\(stored.title)\" consumed successfully")
        progress(100, "Finished")
        return stored
    }

    /// Inserts the row, classifies, moves files into media and indexes, in one transaction.
    /// Files moved before a failure are removed again.
    private func store(document: Document, request: ConsumeRequest, working: URL, result: ParseResult) async throws -> Document {
        let classification = Classification(matcher: app.matcher)
        let predictions = app.classifier()?.predict(document.content) ?? .init()
        let storage = app.storage
        let settings = self.settings
        let mover = MovedFiles()
        do {
            return try await app.database.write { db in
                var document = document
                if let asn = document.archiveSerialNumber, try !DocumentStore.isArchiveSerialNumberFree(asn, in: db) {
                    throw ConsumeError.asnInUse(asn)
                }
                var tagIds = Set(request.overrides.tagIds)
                tagIds.formUnion(try Classification.inboxTagIds(in: db))
                let suggestions = try classification.suggestions(content: document.content, ownerId: document.ownerId, classifierPredictions: predictions, in: db)
                classification.apply(suggestions, to: &document, tagIds: &tagIds)

                document = try DocumentStore.insert(document, tagIds: Array(tagIds), auditEnabled: settings.auditLogEnabled, in: db)
                let id = document.id!

                // Name and move the files now that the id is known.
                let context = try NamingContext.load(for: document, in: db)
                let originalName = storage.namer.uniqueFilename(for: context, fileExtension: Self.fileExtension(for: request.originalFilename, mimeType: document.mimeType), current: nil, root: storage.originalsDir)
                mover.add(try storage.place(working, at: originalName, root: storage.originalsDir))
                document.filename = originalName
                if let archive = result.archiveFile {
                    let archiveName = storage.namer.uniqueFilename(for: context, fileExtension: ".pdf", archive: true, current: nil, originalFilename: originalName, root: storage.archiveDir)
                    mover.add(try storage.place(archive, at: archiveName, root: storage.archiveDir))
                    document.archiveFilename = archiveName
                }
                mover.add(try storage.place(result.thumbnailFile, at: storage.thumbnailURL(documentId: id).lastPathComponent, root: storage.thumbnailDir))
                try document.update(db)

                for (fieldId, value) in request.overrides.customFields {
                    try CustomFieldValues.set(fieldId: fieldId, value: value, documentId: id, in: db)
                }
                if let permissions = request.overrides.permissions {
                    try permissions.apply(objectType: Document.objectType, objectId: id, in: db)
                }
                try SearchIndex.update(documentId: id, in: db)
                return document
            }
        } catch {
            for url in mover.urls { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    /// Barcodes are read from PDFs, and from TIFFs when CONSUMER_BARCODE_TIFF_SUPPORT is on.
    static func barcodeScannable(_ mimeType: String, settings: Settings) -> Bool {
        mimeType == "application/pdf" || (mimeType == "image/tiff" && settings.consumerBarcodeTIFFSupport)
    }

    /// Splits a PDF on barcode separator pages and consumes each part as its own document.
    private func split(request: ConsumeRequest, working: URL, separators: [Int: Bool], workDir: URL, progress: ConsumeProgress) async throws -> Document {
        guard let pageCount = PDFUtilities.open(working, passwords: [])?.document.pageCount else {
            throw ConsumeError.parseFailed(request.originalFilename, "cannot read the PDF to split it")
        }
        let plan = BarcodeLogic.splitPlan(pageCount: pageCount, separationPages: separators)
        let splitDir = workDir.appendingPathComponent("split", isDirectory: true)
        try FileManager.default.createDirectory(at: splitDir, withIntermediateDirectories: true)
        let parts = try PDFOperations.split(working, pageGroups: plan.map { $0.map { $0 + 1 } }, outputDirectory: splitDir)
        logger.info("\(request.originalFilename): barcodes split it into \(parts.count) documents")
        let stem = (request.originalFilename as NSString).deletingPathExtension
        var documents: [Document] = []
        for (index, part) in parts.enumerated() {
            var partRequest = request
            partRequest.file = part
            partRequest.originalFilename = "\(stem)_\(String(format: "%02d", index + 1)).pdf"
            partRequest.deleteSource = true
            partRequest.taskId = nil
            documents.append(try await consume(partRequest))
        }
        if request.deleteSource { try? FileManager.default.removeItem(at: request.file) }
        progress(100, "Barcode splitting complete")
        guard let first = documents.first else { throw ConsumeError.parseFailed(request.originalFilename, "splitting produced no documents") }
        return first
    }

    /// Tag ids for names from tag barcodes, creating missing tags (case-insensitive match).
    private func tagIds(forNames names: [String]) async throws -> [Int] {
        try await app.database.write { db in
            try names.map { name in
                if let existing = try Tag.filter(sql: "name = ? COLLATE NOCASE", arguments: [name]).fetchOne(db) { return existing.id! }
                var tag = Tag(name: name)
                try tag.insert(db)
                return tag.id!
            }
        }
    }

    /// `CONSUMER_ENABLE_COLLATE_DOUBLE_SIDED`: a PDF in a `double-sided` folder is either staged
    /// (odd pages) or merged with the staged scan (even pages, scanned back to front).
    /// Returns the collated file to consume, nil when collation does not apply, and throws
    /// `ConsumeStopped` after staging.
    private func collateIfNeeded(request: ConsumeRequest, working: URL, mimeType: String, workDir: URL) async throws -> URL? {
        guard settings.consumerEnableCollateDoubleSided else { return nil }
        let subdir = settings.consumerCollateDoubleSidedSubdirName
        let components = request.file.resolvingSymlinksInPath().pathComponents
        guard components.dropLast().contains(subdir) else { return nil }
        guard mimeType == "application/pdf" || (mimeType == "image/tiff" && settings.consumerCollateDoubleSidedTIFFSupport) else { return nil }

        let fm = FileManager.default
        let staging = settings.scratchDir.appendingPathComponent("double-sided-staging.pdf")
        var pdf = working
        if mimeType == "image/tiff" {
            let result = try await ImageParser().parse(file: working, mimeType: mimeType, options: settings.parseOptions(scratchDirectory: workDir.appendingPathComponent("tiff", isDirectory: true)))
            guard let archive = result.archiveFile else { throw ConsumeError.parseFailed(request.originalFilename, "cannot convert the TIFF to PDF") }
            pdf = archive
        }
        let stagingAge = (try? fm.attributesOfItem(atPath: staging.path)[.modificationDate] as? Date).map { Date().timeIntervalSince($0) }
        if let age = stagingAge, age < 30 * 60 {
            defer { try? fm.removeItem(at: staging) }
            let oddCount = PDFUtilities.open(staging, passwords: [])?.document.pageCount ?? 0
            let evenCount = PDFUtilities.open(pdf, passwords: [])?.document.pageCount ?? 0
            guard oddCount >= evenCount else {
                if request.deleteSource { try? fm.removeItem(at: request.file) }
                throw ConsumeError.parseFailed(request.originalFilename, "The scan of even pages has more pages (\(evenCount)) than the odd pages (\(oddCount)). Start again with the odd pages.")
            }
            let collated = try PDFOperations.collateDoubleSided(odd: staging, even: pdf, outputDirectory: workDir)
            // Subfolder tags were already taken from the original path by the folder watcher.
            let outDir = settings.scratchDir.appendingPathComponent("collated-\(UUID().uuidString)", isDirectory: true)
            try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
            let target = outDir.appendingPathComponent((request.originalFilename as NSString).deletingPathExtension + ".pdf")
            try fm.moveItem(at: collated, to: target)
            logger.info("\(request.originalFilename): collated \(oddCount) odd and \(evenCount) even pages")
            return target
        }
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: pdf, to: staging)
        if request.deleteSource { try? fm.removeItem(at: request.file) }
        throw ConsumeStopped(message: "Received odd numbered pages of a double-sided scan; waiting up to 30 minutes for the even pages")
    }

    /// Stores a parsed file as the next version of `rootId`. Metadata stays on the root.
    private func storeVersion(document: Document, rootId: Int, label: String?, working: URL, result: ParseResult) async throws -> Document {
        let storage = app.storage
        let mover = MovedFiles()
        do {
            return try await app.database.write { db in
                let root = try DocumentStore.document(rootId, in: db)
                guard root.rootDocumentId == nil else { throw DocumentStoreError.notFound(rootId) }
                let nextIndex = (try Int.fetchOne(db, sql: "SELECT MAX(version_index) FROM documents WHERE root_document_id = ?", arguments: [rootId]) ?? 0) + 1
                var version = document
                version.title = root.title
                version.created = root.created
                version.ownerId = root.ownerId
                version.correspondentId = nil
                version.documentTypeId = nil
                version.storagePathId = nil
                version.archiveSerialNumber = nil
                version.rootDocumentId = rootId
                version.versionIndex = nextIndex
                version.versionLabel = label
                try version.insert(db)
                let context = try NamingContext.load(for: version, in: db)
                let originalName = storage.namer.uniqueFilename(for: context, fileExtension: Self.fileExtension(for: version.originalFilename ?? "", mimeType: version.mimeType), version: nextIndex, current: nil, root: storage.originalsDir)
                mover.add(try storage.place(working, at: originalName, root: storage.originalsDir))
                version.filename = originalName
                if let archive = result.archiveFile {
                    let archiveName = storage.namer.uniqueFilename(for: context, fileExtension: ".pdf", version: nextIndex, archive: true, current: nil, root: storage.archiveDir)
                    mover.add(try storage.place(archive, at: archiveName, root: storage.archiveDir))
                    version.archiveFilename = archiveName
                }
                mover.add(try storage.place(result.thumbnailFile, at: storage.thumbnailURL(documentId: version.id!).lastPathComponent, root: storage.thumbnailDir))
                try version.update(db)
                // The root's index row carries the newest version's content.
                try SearchIndex.update(documentId: rootId, in: db)
                try AuditLog.record(.update, objectType: Document.objectType, objectId: rootId, repr: root.title,
                                    changes: ["version": [nil, String(nextIndex)]], actorId: nil, in: db)
                return version
            }
        } catch {
            for url in mover.urls { try? FileManager.default.removeItem(at: url) }
            throw error
        }
    }

    private func renderWorkflowTitle(_ template: String, documentId: Int) async throws -> Document {
        let settings = self.settings
        let storage = app.storage
        return try await app.database.write { db in
            var document = try DocumentStore.document(documentId, in: db)
            let context = try WorkflowPlaceholders.context(for: document, includeTitle: false, settings: settings, in: db)
            if let title = WorkflowPlaceholders.render(template, context: context, timeZone: settings.timeZone), !title.isEmpty {
                document.title = String(title.prefix(128))
                document = try storage.applyNaming(to: document, in: db)
                try DocumentStore.update(document, auditEnabled: false, in: db)
            }
            return document
        }
    }

    /// Adds the document to the LLM index when AI is on; failures are logged, not fatal.
    private func updateAIIndex(documentId: Int) async {
        let ai = FolioAI.shared(for: app)
        guard (try? ai.config().llmIndexEnabled) == true else { return }
        do {
            try await ai.index.indexDocument(documentId)
        } catch {
            logger.warning("LLM index update for document #\(documentId) failed: \(error)")
        }
    }

    // MARK: Scripts

    private func runPreConsumeScript(source: URL, working: URL, taskId: String?) async throws {
        guard let script = settings.preConsumeScript else { return }
        let env = [
            "DOCUMENT_SOURCE_PATH": source.path,
            "DOCUMENT_WORKING_PATH": working.path,
            "TASK_ID": taskId ?? "",
        ]
        let result = try await ProcessRunner.run(URL(fileURLWithPath: script), arguments: [], environment: env, timeout: .seconds(Int64(settings.workerTimeout)))
        log(script: script, result: result)
        guard result.succeeded else {
            throw ConsumeError.preConsumeScriptFailed(result.exitCode, result.errorString)
        }
    }

    private func runPostConsumeScript(_ document: Document, taskId: String?) async {
        guard let script = settings.postConsumeScript, let id = document.id else { return }
        let details = try? await app.database.read { db -> (String?, String?, String?, [String]) in
            (try document.documentTypeId.flatMap { try DocumentType.fetchOne(db, key: $0)?.name },
             try document.correspondentId.flatMap { try Correspondent.fetchOne(db, key: $0)?.name },
             try document.ownerId.flatMap { try User.fetchOne(db, key: $0)?.username },
             try DocumentStore.tags(of: id, in: db).map(\.name))
        }
        let base = settings.url ?? ""
        let iso = ISO8601DateFormatter()
        let env: [String: String] = [
            "DOCUMENT_ID": String(id),
            "DOCUMENT_FILE_NAME": document.filename.map { ($0 as NSString).lastPathComponent } ?? "",
            "DOCUMENT_TYPE": details?.0 ?? "",
            "DOCUMENT_CREATED": document.created.iso,
            "DOCUMENT_MODIFIED": iso.string(from: document.modified),
            "DOCUMENT_ADDED": iso.string(from: document.added),
            "DOCUMENT_SOURCE_PATH": app.storage.originalURL(document)?.path ?? "",
            "DOCUMENT_ARCHIVE_PATH": app.storage.archiveURL(document)?.path ?? "",
            "DOCUMENT_THUMBNAIL_PATH": app.storage.thumbnailURL(documentId: id).path,
            "DOCUMENT_DOWNLOAD_URL": "\(base)/api/documents/\(id)/download/",
            "DOCUMENT_THUMBNAIL_URL": "\(base)/api/documents/\(id)/thumb/",
            "DOCUMENT_OWNER": details?.2 ?? "",
            "DOCUMENT_CORRESPONDENT": details?.1 ?? "",
            "DOCUMENT_TAGS": (details?.3 ?? []).joined(separator: ","),
            "DOCUMENT_ORIGINAL_FILENAME": document.originalFilename ?? "",
            "TASK_ID": taskId ?? "",
        ]
        do {
            let result = try await ProcessRunner.run(URL(fileURLWithPath: script), arguments: [], environment: env, timeout: .seconds(Int64(settings.workerTimeout)))
            log(script: script, result: result)
        } catch {
            logger.error("Post-consume script \(script) could not run: \(error)")
        }
    }

    private func log(script: String, result: ProcessResult) {
        for line in result.outputString.split(whereSeparator: \.isNewline) { logger.info("\(script): \(line)") }
        for line in result.errorString.split(whereSeparator: \.isNewline) { logger.warning("\(script): \(line)") }
        logger.info("\(script) exited with code \(result.exitCode)\(result.timedOut ? " (timed out)" : "")")
    }

    // MARK: Helpers

    /// Removes NUL characters and surrounding whitespace.
    static func cleanContent(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value != 0 }.map(Character.init))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func defaultTitle(for fileName: String) -> String {
        ((fileName as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Web pages and emails carry better titles than their file names.
    static func prefersSuggestedTitle(_ mimeType: String) -> Bool {
        ["text/html", "application/x-webarchive", "message/rfc822", "application/x-foliozero-url-shortcut"].contains(mimeType)
    }

    static func fileExtension(for name: String, mimeType: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let detected = FileTypeDetector.defaultExtension(for: mimeType)
        // Keep the user's extension when it is a known spelling (".jpeg", ".tif"), otherwise use the detected one.
        if !ext.isEmpty, UTType(filenameExtension: ext)?.preferredMIMEType == mimeType { return "." + ext }
        return detected
    }

    static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    static func safeFileName(_ name: String) -> String {
        let base = (name as NSString).lastPathComponent
        let cleaned = FileNamer.sanitize(base)
        return cleaned.isEmpty ? "document" : cleaned
    }
}

/// Collects files moved during a transaction so they can be removed on failure.
final class MovedFiles: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [URL] = []
    func add(_ url: URL) { lock.withLock { stored.append(url) } }
    var urls: [URL] { lock.withLock { stored } }
}
