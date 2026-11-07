import CoreGraphics
import Foundation
import FolioParsing
import GRDB

/// Admin operations on stored documents (Paperless-ngx management commands
/// document_sanity_checker, document_renamer, document_retagger, document_thumbnails,
/// document_archiver, and the "reprocess" bulk action).
public enum DocumentMaintenance {
    // MARK: Sanity check

    public struct SanityMessage: Sendable, Hashable, CustomStringConvertible {
        public enum Level: String, Sendable { case info, warning, error }
        public var level: Level
        public var documentId: Int?
        public var message: String

        public var description: String {
            "[\(level.rawValue.uppercased())]" + (documentId.map { " document #\($0):" } ?? "") + " \(message)"
        }
    }

    /// Checks that every file exists and matches its checksum, and lists orphaned files.
    public static func sanityCheck(app: FolioApp, progress: ConsumeProgress = { _, _ in }) async throws -> [SanityMessage] {
        let storage = app.storage
        let documents = try await app.database.read { db in try Document.fetchAll(db) }
        var messages: [SanityMessage] = []
        var known = Set<String>()
        for (index, document) in documents.enumerated() {
            guard let id = document.id else { continue }
            if index % 25 == 0 { progress(index * 100 / max(documents.count, 1), "Checking document #\(id)") }
            let thumbnail = storage.thumbnailURL(documentId: id)
            known.insert(thumbnail.resolvingSymlinksInPath().path)
            if !FileManager.default.fileExists(atPath: thumbnail.path) {
                messages.append(.init(level: .warning, documentId: id, message: "Thumbnail missing"))
            }
            if let original = storage.originalURL(document) {
                known.insert(original.resolvingSymlinksInPath().path)
                if !FileManager.default.fileExists(atPath: original.path) {
                    messages.append(.init(level: .error, documentId: id, message: "Original file missing: \(original.path)"))
                } else if let checksum = try? Checksum.sha256(of: original), checksum != document.checksum {
                    messages.append(.init(level: .error, documentId: id, message: "Checksum mismatch of original file"))
                }
            } else {
                messages.append(.init(level: .error, documentId: id, message: "No original file name stored"))
            }
            if let archive = storage.archiveURL(document) {
                known.insert(archive.resolvingSymlinksInPath().path)
                if !FileManager.default.fileExists(atPath: archive.path) {
                    messages.append(.init(level: .error, documentId: id, message: "Archive file missing: \(archive.path)"))
                } else if let expected = document.archiveChecksum, let checksum = try? Checksum.sha256(of: archive), checksum != expected {
                    messages.append(.init(level: .error, documentId: id, message: "Checksum mismatch of archive file"))
                }
            }
            if document.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                messages.append(.init(level: .info, documentId: id, message: "Document has no content"))
            }
        }
        for root in [storage.originalsDir, storage.archiveDir, storage.thumbnailDir] {
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
            while let url = enumerator?.nextObject() as? URL {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true, url.lastPathComponent != ".DS_Store" else { continue }
                if !known.contains(url.resolvingSymlinksInPath().path) {
                    messages.append(.init(level: .warning, documentId: nil, message: "Orphaned file: \(url.path)"))
                }
            }
        }
        progress(100, "Sanity check finished")
        return messages
    }

    // MARK: Renamer

    /// Re-applies FILENAME_FORMAT and storage paths to every document. Returns how many moved.
    @discardableResult
    public static func renameAll(app: FolioApp) async throws -> Int {
        let ids = try await app.database.read { db in try Int.fetchAll(db, sql: "SELECT id FROM documents ORDER BY id") }
        var moved = 0
        for id in ids {
            let changed = try await app.database.write { [storage = app.storage] db -> Bool in
                let document = try DocumentStore.document(id, in: db)
                let renamed = try storage.applyNaming(to: document, in: db)
                guard renamed.filename != document.filename || renamed.archiveFilename != document.archiveFilename else { return false }
                try renamed.update(db)
                return true
            }
            if changed { moved += 1 }
        }
        return moved
    }

    // MARK: Retagger

    public struct RetagOptions: Sendable {
        public var correspondents = false
        public var documentTypes = false
        public var tags = false
        public var storagePaths = false
        /// Replace existing values (and, for tags, remove tags that no longer match).
        public var overwrite = false
        /// Only documents with an inbox tag.
        public var inboxOnly = false
        /// With several matches, take the first instead of skipping.
        public var useFirst = false

        public init(correspondents: Bool = false, documentTypes: Bool = false, tags: Bool = false, storagePaths: Bool = false, overwrite: Bool = false, inboxOnly: Bool = false, useFirst: Bool = false) {
            self.correspondents = correspondents; self.documentTypes = documentTypes; self.tags = tags
            self.storagePaths = storagePaths; self.overwrite = overwrite; self.inboxOnly = inboxOnly; self.useFirst = useFirst
        }
    }

    /// Re-runs matching on existing documents (document_retagger). Returns the ids of changed documents.
    public static func retag(app: FolioApp, options: RetagOptions) async throws -> [Int] {
        let classification = Classification(matcher: app.matcher)
        let classifier = app.classifier()
        let ids = try await app.database.read { db in
            try Int.fetchAll(db, sql: options.inboxOnly
                ? "SELECT DISTINCT d.id FROM documents d JOIN document_tags dt ON dt.document_id = d.id JOIN tags t ON t.id = dt.tag_id WHERE t.is_inbox_tag = 1 AND d.deleted_at IS NULL AND d.root_document_id IS NULL"
                : "SELECT id FROM documents WHERE deleted_at IS NULL AND root_document_id IS NULL ORDER BY id")
        }
        var changed: [Int] = []
        for id in ids {
            let didChange = try await app.database.write { [storage = app.storage, audit = app.settings.auditLogEnabled] db -> Bool in
                var document = try DocumentStore.document(id, in: db)
                let before = document
                let predictions = classifier?.predict(document.content) ?? .init()
                let s = try classification.suggestions(content: document.content, ownerId: document.ownerId, classifierPredictions: predictions, in: db)
                func pick(_ ids: [Int], current: Int?) -> Int? {
                    guard current == nil || options.overwrite else { return current }
                    // Several matches without --use-first: leave the document alone (Paperless-ngx behaviour).
                    if ids.count > 1 && !options.useFirst { return current }
                    return ids.first ?? (options.overwrite ? nil : current)
                }
                if options.correspondents { document.correspondentId = pick(s.correspondentIds, current: document.correspondentId) }
                if options.documentTypes { document.documentTypeId = pick(s.documentTypeIds, current: document.documentTypeId) }
                if options.storagePaths { document.storagePathId = pick(s.storagePathIds, current: document.storagePathId) }
                var tagsChanged = false
                if options.tags {
                    let current = Set(try DocumentStore.tagIds(of: id, in: db))
                    var next = current.union(s.tagIds)
                    if options.overwrite {
                        // Keep inbox tags and tags without matching rules; drop matching tags that no longer match.
                        let matchingTagIds = Set(try Int.fetchAll(db, sql: "SELECT id FROM tags WHERE matching_algorithm != 0 AND is_inbox_tag = 0"))
                        next = current.subtracting(matchingTagIds).union(s.tagIds)
                    }
                    if next != current {
                        try DocumentStore.setTags(documentId: id, tagIds: Array(next), in: db)
                        tagsChanged = true
                    }
                }
                guard document != before || tagsChanged else { return false }
                document = try storage.applyNaming(to: document, in: db)
                try DocumentStore.update(document, auditEnabled: audit, in: db)
                return true
            }
            if didChange { changed.append(id) }
        }
        return changed
    }

    // MARK: Reprocess, thumbnails, archives

    /// Parses the original again and replaces content, archive file, thumbnail and page count
    /// (Paperless-ngx `update_document_content_maybe_archive_file`). Metadata stays.
    ///
    /// The remote OCR engine is used when `REMOTE_OCR_MODE` is `always`, or when `remoteOCR`
    /// asks for it (consumption workflows do not run here).
    public static func reprocess(app: FolioApp, documentId: Int, remoteOCR: Bool = false) async throws {
        let document = try await app.database.read { db in try DocumentStore.document(documentId, in: db) }
        guard let original = app.storage.originalURL(document), FileManager.default.fileExists(atPath: original.path) else {
            throw StorageError.missingFile(app.storage.originalURL(document) ?? URL(fileURLWithPath: "/"))
        }
        let remoteConfig = app.remoteOCRConfig()
        let allowRemote = remoteOCR || remoteConfig.remoteOCRByDefault
        guard let parser = app.parser(for: document.mimeType, fileName: original.lastPathComponent, allowRemote: allowRemote, remoteOCR: remoteConfig) else {
            throw ConsumeError.unsupportedType(original.lastPathComponent, document.mimeType)
        }
        let work = try app.makeScratchDirectory(prefix: "reprocess")
        defer { try? FileManager.default.removeItem(at: work) }
        let result = try await parser.parse(file: original, mimeType: document.mimeType, options: app.effectiveSettings().parseOptions(scratchDirectory: work))
        let storage = app.storage
        let audit = app.settings.auditLogEnabled
        try await app.database.write { db in
            var updated = try DocumentStore.document(documentId, in: db)
            updated.content = Consumer.cleanContent(result.text)
            updated.pageCount = result.pageCount
            updated.originalMetadata = result.metadata
            if let archive = result.archiveFile {
                let context = try NamingContext.load(for: updated, in: db)
                let name = updated.archiveFilename ?? storage.namer.uniqueFilename(for: context, fileExtension: ".pdf", archive: true, current: nil, originalFilename: updated.filename, root: storage.archiveDir)
                _ = try storage.place(archive, at: name, root: storage.archiveDir)
                updated.archiveFilename = name
                updated.archiveChecksum = try Checksum.sha256(of: storage.archiveDir.appendingPathComponent(name))
            }
            _ = try storage.place(result.thumbnailFile, at: storage.thumbnailURL(documentId: documentId).lastPathComponent, root: storage.thumbnailDir)
            try DocumentStore.update(updated, auditEnabled: audit, in: db)
        }
    }

    /// Regenerates thumbnails (all, or the given documents) without touching anything else.
    public static func regenerateThumbnails(app: FolioApp, ids: [Int]? = nil) async throws -> Int {
        let documents = try await app.database.read { db in
            try ids.map { try Document.filter($0.contains(Column("id"))).fetchAll(db) } ?? Document.fetchAll(db)
        }
        var count = 0
        for document in documents {
            guard let id = document.id else { continue }
            let source = app.storage.archiveURL(document) ?? app.storage.originalURL(document)
            guard let source, FileManager.default.fileExists(atPath: source.path) else { continue }
            let work = try app.makeScratchDirectory(prefix: "thumb")
            defer { try? FileManager.default.removeItem(at: work) }
            let maxPixels = app.settings.thumbnailMaxPixels
            let image: CGImage?
            if source.pathExtension.lowercased() == "pdf" {
                image = ThumbnailRenderer.image(fromPDF: source, maxPixels: maxPixels)
            } else {
                image = await ThumbnailRenderer.quickLookImage(for: source, maxPixels: maxPixels)
            }
            guard let image else { continue }
            let file = try ThumbnailRenderer.write(image, to: work)
            _ = try app.storage.place(file, at: app.storage.thumbnailURL(documentId: id).lastPathComponent, root: app.storage.thumbnailDir)
            count += 1
        }
        return count
    }
}
