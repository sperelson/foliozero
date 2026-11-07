import Foundation
import GRDB

/// Applies matching rules of tags, correspondents, document types and storage paths
/// to a document (Paperless-ngx `documents/signals/handlers.py` set_* handlers).
public struct Classification: Sendable {
    public var matcher: Matcher

    public init(matcher: Matcher) {
        self.matcher = matcher
    }

    public struct Suggestions: Sendable, Equatable {
        public var correspondentIds: [Int] = []
        public var documentTypeIds: [Int] = []
        public var storagePathIds: [Int] = []
        public var tagIds: [Int] = []

        public init(correspondentIds: [Int] = [], documentTypeIds: [Int] = [], storagePathIds: [Int] = [], tagIds: [Int] = []) {
            self.correspondentIds = correspondentIds
            self.documentTypeIds = documentTypeIds
            self.storagePathIds = storagePathIds
            self.tagIds = tagIds
        }
    }

    /// Objects whose matching rules hit `content`, limited to objects visible to `ownerId`
    /// (no owner: all objects). `auto` objects come from `classifierPredictions`.
    public func suggestions(content: String, ownerId: Int?, classifierPredictions: Suggestions = .init(), in db: Database) throws -> Suggestions {
        func candidates<M: MatchingObject>(_ type: M.Type) throws -> [M] {
            var request = M.all()
            if let ownerId {
                request = request.filter(sql: """
                    owner_id IS NULL OR owner_id = ? OR id IN (
                        SELECT object_id FROM object_permissions WHERE object_type = ? AND (user_id = ? OR group_id IN (SELECT group_id FROM user_groups WHERE user_id = ?)))
                    """, arguments: [ownerId, M.objectType, ownerId, ownerId])
            }
            return try request.fetchAll(db)
        }
        func matching<M: MatchingObject>(_ objects: [M], predicted: [Int]) -> [Int] {
            objects.compactMap { object in
                guard let id = object.id else { return nil }
                if object.matchingAlgorithm == .auto { return predicted.contains(id) ? id : nil }
                return matcher.matches(object, content: content) ? id : nil
            }
        }
        return Suggestions(
            correspondentIds: matching(try candidates(Correspondent.self), predicted: classifierPredictions.correspondentIds),
            documentTypeIds: matching(try candidates(DocumentType.self), predicted: classifierPredictions.documentTypeIds),
            storagePathIds: matching(try candidates(StoragePath.self), predicted: classifierPredictions.storagePathIds),
            tagIds: matching(try candidates(Tag.self), predicted: classifierPredictions.tagIds)
        )
    }

    /// Applies suggestions: single-valued fields only when empty (first match wins), tags are added.
    public func apply(_ suggestions: Suggestions, to document: inout Document, tagIds: inout Set<Int>) {
        if document.correspondentId == nil { document.correspondentId = suggestions.correspondentIds.first }
        if document.documentTypeId == nil { document.documentTypeId = suggestions.documentTypeIds.first }
        if document.storagePathId == nil { document.storagePathId = suggestions.storagePathIds.first }
        tagIds.formUnion(suggestions.tagIds)
    }

    public static func inboxTagIds(in db: Database) throws -> [Int] {
        try Int.fetchAll(db, sql: "SELECT id FROM tags WHERE is_inbox_tag = 1")
    }
}
