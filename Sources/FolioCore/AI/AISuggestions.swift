import CryptoKit
import Foundation
import GRDB
import Logging

/// The body of `GET /api/documents/<id>/ai_suggestions/` (Paperless-ngx `AISuggestions`):
/// ids of existing objects the user may see, plus names to create.
public struct AISuggestionsResponse: Codable, Sendable, Equatable {
    public var title: String
    public var tags: [Int]
    public var suggestedTags: [String]
    public var correspondents: [Int]
    public var suggestedCorrespondents: [String]
    public var documentTypes: [Int]
    public var suggestedDocumentTypes: [String]
    public var storagePaths: [Int]
    public var suggestedStoragePaths: [String]
    /// `YYYY-MM-DD` strings as the model gave them.
    public var dates: [String]

    enum CodingKeys: String, CodingKey {
        case title, tags, correspondents, dates
        case suggestedTags = "suggested_tags"
        case suggestedCorrespondents = "suggested_correspondents"
        case documentTypes = "document_types"
        case suggestedDocumentTypes = "suggested_document_types"
        case storagePaths = "storage_paths"
        case suggestedStoragePaths = "suggested_storage_paths"
    }

    public init(title: String, tags: [Int] = [], suggestedTags: [String] = [], correspondents: [Int] = [],
                suggestedCorrespondents: [String] = [], documentTypes: [Int] = [], suggestedDocumentTypes: [String] = [],
                storagePaths: [Int] = [], suggestedStoragePaths: [String] = [], dates: [String] = []) {
        self.title = title; self.tags = tags; self.suggestedTags = suggestedTags
        self.correspondents = correspondents; self.suggestedCorrespondents = suggestedCorrespondents
        self.documentTypes = documentTypes; self.suggestedDocumentTypes = suggestedDocumentTypes
        self.storagePaths = storagePaths; self.suggestedStoragePaths = suggestedStoragePaths; self.dates = dates
    }
}

/// Fields the "Apply AI Suggestions" workflow action can set (Paperless-ngx `AISuggestionField`).
public enum AISuggestionField: String, Codable, Sendable, CaseIterable {
    case title, tags, correspondent
    case documentType = "document_type"
    case storagePath = "storage_path"
    case created
}

/// AI suggestions for a document (Paperless-ngx `ai_suggestions` view, `ai_classifier`,
/// `matching` and `workflows/ai.py`).
public final class AISuggestions: Sendable {
    let app: FolioApp
    let index: LLMIndex
    let runtime: AIRuntimeProvider
    let cache = SuggestionCache()
    var logger: Logging.Logger { app.logger }

    public init(app: FolioApp, index: LLMIndex, runtime: @escaping AIRuntimeProvider) {
        self.app = app
        self.index = index
        self.runtime = runtime
    }

    // MARK: - ai_suggestions

    /// Suggestions for `documentId` as `context` may see them.
    ///
    /// Checks, in Paperless-ngx order: the document exists (`documentNotFound`), the user may
    /// change it (`permissionDenied`), AI is on (`disabled`). Raw model answers are cached per
    /// document, backend, model, endpoint, output language and user; ids are resolved against
    /// the user's permissions on every call, cache hit or not.
    public func suggestions(documentId: Int, context: AccessContext) async throws -> AISuggestionsResponse {
        let (document, effectiveContent) = try await loadDocument(documentId)
        let allowed = try await app.database.read { db in
            try context.can(.change, objectType: Document.objectType, objectId: documentId, ownerId: document.ownerId, in: db)
        }
        guard allowed else { throw AIError.permissionDenied }
        let runtime = try runtime()
        guard runtime.config.enabled else { throw AIError.disabled }

        let language = try await outputLanguage(config: runtime.config, userId: context.user.id)
        let key = SuggestionCache.Key(
            documentId: documentId,
            backend: [runtime.config.cacheIdentity, language, "user=\(context.user.id.map(String.init) ?? "none")"]
                .compactMap { $0 }.joined(separator: ":"),
            version: Self.version(of: document, content: effectiveContent))

        let raw: ClassificationSuggestions
        if let cached = cache.get(key) {
            raw = cached
        } else {
            raw = try await classifier(runtime).classify(documentId: documentId, context: context, outputLanguage: language)
            cache.set(key, raw)
        }
        return try await resolve(raw, context: context)
    }

    /// Raw model suggestions for `documentId`, uncached and unresolved.
    public func classify(documentId: Int, context: AccessContext, outputLanguage: String? = nil) async throws -> ClassificationSuggestions {
        let runtime = try runtime()
        guard runtime.config.enabled else { throw AIError.disabled }
        return try await classifier(runtime).classify(documentId: documentId, context: context, outputLanguage: outputLanguage)
    }

    /// Forgets cached suggestions for a document (call when it changes).
    public func invalidate(documentId: Int) {
        cache.invalidate(documentId: documentId)
    }

    /// Resolves raw suggestions for one requester (the view's `resolve_choice`): ids the model
    /// picked plus name matches, de-duplicated, then the names that matched nothing.
    public func resolve(_ raw: ClassificationSuggestions, context: AccessContext) async throws -> AISuggestionsResponse {
        try await app.database.read { db in
            func resolve(_ choice: TaxonomyChoice, _ kind: AIMatching.Kind) throws -> ([Int], [String]) {
                let matched = try AIMatching.resolveIds(choice.existingIds, kind: kind, context: context, in: db)
                    + AIMatching.matchByName(choice.newNames, kind: kind, context: context, in: db)
                var seen = Set<Int>()
                let unique = matched.filter { seen.insert($0.id).inserted }
                return (unique.map(\.id), AIMatching.unmatchedNames(choice.newNames, matched: unique))
            }
            let tags = try resolve(raw.tags, .tag)
            let correspondents = try resolve(raw.correspondents, .correspondent)
            let types = try resolve(raw.documentTypes, .documentType)
            let paths = try resolve(raw.storagePaths, .storagePath)
            return AISuggestionsResponse(
                title: raw.title, tags: tags.0, suggestedTags: tags.1,
                correspondents: correspondents.0, suggestedCorrespondents: correspondents.1,
                documentTypes: types.0, suggestedDocumentTypes: types.1,
                storagePaths: paths.0, suggestedStoragePaths: paths.1, dates: raw.dates)
        }
    }

    // MARK: - Workflow action

    /// "Apply AI Suggestions" workflow action (Paperless-ngx `apply_ai_suggestions_to_document`).
    ///
    /// Acts as the document owner (an unowned document sees only unowned objects). A field is
    /// set only when selected and either `overwrite` is true or the field is empty; tags are
    /// always added, never replaced. With `createMissing`, unmatched tags, correspondents and
    /// document types are created for the owner; storage paths never are.
    ///
    /// - Returns: names of the fields that changed (`title`, `correspondent`, `document_type`,
    ///   `storage_path`, `created`, `tags`); empty when skipped (AI off, no content, bad configuration).
    /// - Throws: transient backend errors (timeouts, unreachable, rejected), so a queued task can retry.
    @discardableResult
    public func apply(to documentId: Int, fields: Set<AISuggestionField>, createMissing: Bool, overwrite: Bool) async throws -> [String] {
        guard !fields.isEmpty else {
            logger.warning("Apply AI suggestions: no fields selected for document #\(documentId), skipping")
            return []
        }
        let runtime: AIRuntime
        do {
            runtime = try self.runtime()
        } catch {
            logger.error("Invalid AI configuration, cannot get suggestions for document #\(documentId): \(error)")
            return []
        }
        guard runtime.config.enabled else {
            logger.error("AI is not enabled, cannot apply AI suggestions for document #\(documentId)")
            return []
        }
        let (document, content) = try await loadDocument(documentId)
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            logger.warning("Document #\(documentId) has no content, skipping AI suggestions")
            return []
        }

        let owner = try await ownerContext(document.ownerId)
        let language = try await outputLanguage(config: runtime.config, userId: document.ownerId)
        let suggestions: ClassificationSuggestions
        do {
            suggestions = try await classifier(runtime).classify(documentId: documentId, context: owner, outputLanguage: language)
        } catch let error as AIError {
            switch error {
            case .invalidConfiguration, .blockedEndpoint:
                logger.error("Invalid AI configuration, cannot get suggestions for document #\(documentId): \(error)")
                return []
            default:
                throw error
            }
        }

        let settings = app.settings
        let storage = app.storage
        let ownerId = document.ownerId
        let updated = try await app.database.write { db -> [String] in
            var document = try DocumentStore.document(documentId, in: db)
            var updated: [String] = []
            func shouldSet(_ field: AISuggestionField, isEmpty: Bool) -> Bool {
                fields.contains(field) && (overwrite || isEmpty)
            }

            if shouldSet(.title, isEmpty: document.title.isEmpty) {
                let title = suggestions.title.trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    document.title = String(title.prefix(128))
                    updated.append("title")
                }
            }
            if shouldSet(.correspondent, isEmpty: document.correspondentId == nil),
               let id = try Self.resolveObject(suggestions.correspondents, kind: .correspondent, owner: owner, ownerId: ownerId, createMissing: createMissing, in: db) {
                document.correspondentId = id
                updated.append("correspondent")
            }
            if shouldSet(.documentType, isEmpty: document.documentTypeId == nil),
               let id = try Self.resolveObject(suggestions.documentTypes, kind: .documentType, owner: owner, ownerId: ownerId, createMissing: createMissing, in: db) {
                document.documentTypeId = id
                updated.append("document_type")
            }
            if shouldSet(.storagePath, isEmpty: document.storagePathId == nil),
               let id = try Self.resolveObject(suggestions.storagePaths, kind: .storagePath, owner: owner, ownerId: ownerId, createMissing: false, in: db) {
                document.storagePathId = id
                updated.append("storage_path")
            }
            if shouldSet(.created, isEmpty: false), let date = Self.firstDate(suggestions.dates) {
                document.created = date
                updated.append("created")
            }
            var tagIds: [Int] = []
            if fields.contains(.tags) {
                tagIds = try Self.resolveTags(suggestions.tags, owner: owner, ownerId: ownerId, createMissing: createMissing, in: db)
                if !tagIds.isEmpty { updated.append("tags") }
            }
            guard !updated.isEmpty else { return [] }
            if !tagIds.isEmpty {
                try DocumentStore.addTags(documentId: documentId, tagIds: tagIds, in: db)
            }
            if document.filename != nil {
                document = try storage.applyNaming(to: document, in: db)
            }
            try DocumentStore.update(document, auditEnabled: settings.auditLogEnabled, in: db)
            return updated
        }

        logger.info("Applied AI suggestions \(updated.isEmpty ? "(none)" : updated.joined(separator: ", ")) to document #\(documentId)")
        if !updated.isEmpty {
            invalidate(documentId: documentId)
            if runtime.config.llmIndexEnabled {
                do { try await index.indexDocument(documentId) } catch {
                    logger.warning("Could not update the LLM index for document #\(documentId): \(error)")
                }
            }
        }
        return updated
    }

    /// The best match, or with `createMissing` a new object named after the first unmatched
    /// suggestion (Paperless-ngx `resolve_object`). Storage paths are never created.
    static func resolveObject(_ choice: TaxonomyChoice, kind: AIMatching.Kind, owner: AccessContext, ownerId: Int?, createMissing: Bool, in db: Database) throws -> Int? {
        let matched = try AIMatching.resolveIds(choice.existingIds, kind: kind, context: owner, in: db)
            + AIMatching.matchByName(choice.newNames, kind: kind, context: owner, in: db)
        if let first = matched.first { return first.id }
        guard createMissing, kind != .storagePath,
              let name = AIMatching.unmatchedNames(choice.newNames, matched: matched).first else { return nil }
        return try getOrCreate(name: String(name.prefix(128)), kind: kind, ownerId: ownerId, in: db)
    }

    /// Matched tags plus, with `createMissing`, one new tag per unmatched name (`resolve_tags`).
    static func resolveTags(_ choice: TaxonomyChoice, owner: AccessContext, ownerId: Int?, createMissing: Bool, in db: Database) throws -> [Int] {
        let matched = try AIMatching.resolveIds(choice.existingIds, kind: .tag, context: owner, in: db)
            + AIMatching.matchByName(choice.newNames, kind: .tag, context: owner, in: db)
        var ids = matched.map(\.id)
        if createMissing {
            for name in AIMatching.unmatchedNames(choice.newNames, matched: matched) {
                ids.append(try getOrCreate(name: String(name.prefix(128)), kind: .tag, ownerId: ownerId, in: db))
            }
        }
        var seen = Set<Int>()
        return ids.filter { seen.insert($0).inserted }
    }

    /// Django `get_or_create(name=..., owner=...)`.
    static func getOrCreate(name: String, kind: AIMatching.Kind, ownerId: Int?, in db: Database) throws -> Int {
        if let existing = try Int.fetchOne(db, sql: "SELECT id FROM \(kind.table) WHERE name = ? AND owner_id IS ?", arguments: [name, ownerId]) {
            return existing
        }
        switch kind {
        case .tag:
            var tag = Tag(name: name, ownerId: ownerId)
            try tag.insert(db)
            return tag.id!
        case .correspondent:
            var correspondent = Correspondent(name: name, ownerId: ownerId)
            try correspondent.insert(db)
            return correspondent.id!
        case .documentType:
            var type = DocumentType(name: name, ownerId: ownerId)
            try type.insert(db)
            return type.id!
        case .storagePath:
            throw AIError.invalidRequest("storage paths are never created from AI suggestions")
        }
    }

    /// First suggestion that parses as `YYYY-MM-DD` (`resolve_date`).
    static func firstDate(_ dates: [String]) -> CalendarDate? {
        for value in dates {
            let parts = value.trimmingCharacters(in: .whitespaces).split(separator: "-")
            guard parts.count == 3, parts[0].count == 4, let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
                  (1...12).contains(month), (1...31).contains(day) else { continue }
            var components = DateComponents()
            components.year = year; components.month = month; components.day = day
            guard components.isValidDate(in: Calendar(identifier: .gregorian)) else { continue }
            return CalendarDate(year: year, month: month, day: day)
        }
        return nil
    }

    // MARK: - Helpers

    func classifier(_ runtime: AIRuntime) -> AIClassifier {
        AIClassifier(database: app.database, index: index, runtime: runtime, logger: logger)
    }

    /// The document and its effective content (newest version's content when it has versions).
    func loadDocument(_ documentId: Int) async throws -> (Document, String) {
        let loaded = try await app.database.read { db -> (Document, String)? in
            guard let document = try Document.fetchOne(db, key: documentId) else { return nil }
            let latest = try String.fetchOne(db, sql: """
                SELECT content FROM documents WHERE root_document_id = ? AND deleted_at IS NULL
                ORDER BY version_index DESC LIMIT 1
                """, arguments: [documentId])
            return (document, latest ?? document.content)
        }
        guard let loaded else { throw AIError.documentNotFound(documentId) }
        return loaded
    }

    /// The owner's access, or a context that sees only unowned objects.
    func ownerContext(_ ownerId: Int?) async throws -> AccessContext {
        guard let ownerId else { return AIMatching.nobody }
        return try await app.database.read { db in try AccessContext.load(userId: ownerId, in: db) } ?? AIMatching.nobody
    }

    /// `AI_LLM_OUTPUT_LANGUAGE`, else the user's UI language (`get_llm_output_language`).
    func outputLanguage(config: AIConfig, userId: Int?) async throws -> String? {
        if let language = config.outputLanguage { return language }
        guard let userId else { return nil }
        return try await AIChat.uiLanguage(userId: userId, database: app.database)
    }

    /// Cache version: changes whenever the document's text or metadata changes.
    static func version(of document: Document, content: String) -> String {
        var hasher = SHA256()
        hasher.update(data: Data(FolioDateFormat.database.string(from: document.modified).utf8))
        hasher.update(data: Data("\(document.title.utf8.count):".utf8))
        hasher.update(data: Data(document.title.utf8))
        hasher.update(data: Data(content.utf8))
        return hasher.finalize().prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}

/// In-memory cache of raw suggestions. Entries expire 50 minutes after their last use
/// (Paperless-ngx `CACHE_50_MINUTES`, refreshed on hits).
final class SuggestionCache: @unchecked Sendable {
    struct Key: Hashable, Sendable {
        var documentId: Int
        var backend: String
        var version: String
    }

    static let lifetime: TimeInterval = 50 * 60
    static let capacity = 1000

    private let lock = NSLock()
    private var entries: [Key: (value: ClassificationSuggestions, expires: Date)] = [:]

    func get(_ key: Key, now: Date = Date()) -> ClassificationSuggestions? {
        lock.withLock {
            guard let entry = entries[key] else { return nil }
            guard entry.expires > now else {
                entries[key] = nil
                return nil
            }
            entries[key] = (entry.value, now.addingTimeInterval(Self.lifetime))
            return entry.value
        }
    }

    func set(_ key: Key, _ value: ClassificationSuggestions, now: Date = Date()) {
        lock.withLock {
            if entries.count >= Self.capacity {
                entries = entries.filter { $0.value.expires > now }
                if entries.count >= Self.capacity, let oldest = entries.min(by: { $0.value.expires < $1.value.expires })?.key {
                    entries[oldest] = nil
                }
            }
            entries[key] = (value, now.addingTimeInterval(Self.lifetime))
        }
    }

    func invalidate(documentId: Int) {
        lock.withLock { entries = entries.filter { $0.key.documentId != documentId } }
    }

    var count: Int { lock.withLock { entries.count } }
}
