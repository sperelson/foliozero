import Foundation
import GRDB

/// Resolves model answers to tags, correspondents, document types and storage paths the
/// user may see (Paperless-ngx `paperless_ai.matching`).
///
/// Visibility follows `AccessContext.visibilityPredicate`: unowned objects, the user's own,
/// and objects shared with the user or one of their groups. A context with no user id
/// (`AIMatching.nobody`) sees only unowned objects, as a Paperless-ngx workflow without a user.
public enum AIMatching {
    /// Paperless-ngx `MATCH_THRESHOLD` for fuzzy name matching (`difflib.get_close_matches` cutoff).
    public static let matchThreshold = 0.8

    /// A context that sees only unowned objects and documents.
    public static var nobody: AccessContext {
        AccessContext(user: User(id: nil, username: "", isSuperuser: false), groupIds: [], permissions: [])
    }

    /// One taxonomy object: id and name.
    public struct Object: Sendable, Equatable, Hashable {
        public var id: Int
        public var name: String
    }

    /// The four taxonomies the AI suggests.
    public enum Kind: String, Sendable, CaseIterable {
        case tag, correspondent, documentType, storagePath

        var table: String {
            switch self {
            case .tag: Tag.databaseTableName
            case .correspondent: Correspondent.databaseTableName
            case .documentType: DocumentType.databaseTableName
            case .storagePath: StoragePath.databaseTableName
            }
        }

        var objectType: String {
            switch self {
            case .tag: Tag.objectType
            case .correspondent: Correspondent.objectType
            case .documentType: DocumentType.objectType
            case .storagePath: StoragePath.objectType
            }
        }
    }

    // MARK: Lookups

    /// Objects among `ids` the user may see, ordered by name (`_resolve_visible_ids`).
    /// Unknown, deleted or invisible ids are dropped.
    public static func resolveIds(_ ids: [Int], kind: Kind, context: AccessContext, in db: Database) throws -> [Object] {
        guard !ids.isEmpty else { return [] }
        return try fetch(kind: kind, context: context, extra: "o.id IN \(ids)", in: db)
    }

    /// Objects matching `names` among those the user may see (`_match_by_name`).
    public static func matchByName(_ names: [String], kind: Kind, context: AccessContext, in db: Database) throws -> [Object] {
        guard !names.isEmpty else { return [] }
        let visible = try fetch(kind: kind, context: context, extra: nil, in: db)
        return matchNames(names, to: visible)
    }

    static func fetch(kind: Kind, context: AccessContext, extra: SQL?, in db: Database) throws -> [Object] {
        var sql: SQL = """
            SELECT o.id, o.name FROM \(sql: kind.table) o
            WHERE \(context.visibilityPredicate(objectType: kind.objectType, alias: "o"))
            """
        if let extra { sql += " AND \(extra)" }
        sql += " ORDER BY o.name, o.id"
        return try Row.fetchAll(db, SQLRequest<Row>(literal: sql)).map { Object(id: $0["id"], name: $0["name"]) }
    }

    // MARK: Name matching

    /// Lower case, punctuation removed, trimmed (Paperless-ngx `_normalize`).
    public static func normalize(_ text: String) -> String {
        Matcher.stripPunctuation(text.lowercased()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Matches each name to at most one object, exactly first and fuzzily as a fallback.
    /// A matched object leaves the pool, so two names never resolve to the same object
    /// (`_match_names_to_queryset`).
    public static func matchNames(_ names: [String], to objects: [Object]) -> [Object] {
        var pool = objects
        var poolNames = objects.map { normalize($0.name) }
        var results: [Object] = []
        for name in names where !name.isEmpty {
            let target = normalize(name)
            let index: Int
            if let exact = poolNames.firstIndex(of: target) {
                index = exact
            } else if let close = closeMatch(target, in: poolNames, cutoff: matchThreshold), let found = poolNames.firstIndex(of: close) {
                index = found
            } else {
                continue
            }
            poolNames.remove(at: index)
            results.append(pool.remove(at: index))
        }
        return results
    }

    /// Names whose normalised form matches none of `matched` (`extract_unmatched_names`).
    public static func unmatchedNames(_ names: [String], matched: [Object]) -> [String] {
        let matchedNames = Set(matched.map { normalize($0.name) })
        return names.filter { !matchedNames.contains(normalize($0)) }
    }

    /// `difflib.get_close_matches(word, possibilities, n=1, cutoff)`.
    static func closeMatch(_ word: String, in possibilities: [String], cutoff: Double) -> String? {
        let target = Array(word.unicodeScalars)
        var best: (score: Double, text: String, scalars: [Unicode.Scalar])?
        for candidate in possibilities {
            let scalars = Array(candidate.unicodeScalars)
            let score = SequenceMatcher.ratio(scalars, target)
            guard score >= cutoff else { continue }
            if let current = best {
                // heapq.nlargest on (score, text): ties go to the larger string.
                let larger = current.scalars.lexicographicallyPrecedes(scalars) { $0.value < $1.value }
                if score > current.score || (score == current.score && larger) {
                    best = (score, candidate, scalars)
                }
            } else {
                best = (score, candidate, scalars)
            }
        }
        return best?.text
    }
}

/// Python `difflib.SequenceMatcher(None, a, b).ratio()` without junk heuristics
/// (autojunk only applies to sequences of 200 or more elements).
enum SequenceMatcher {
    static func ratio<T: Hashable>(_ a: [T], _ b: [T]) -> Double {
        let total = a.count + b.count
        guard total > 0 else { return 1 }
        return 2.0 * Double(matchingCharacters(a, b)) / Double(total)
    }

    /// Sum of the sizes of `get_matching_blocks()`.
    static func matchingCharacters<T: Hashable>(_ a: [T], _ b: [T]) -> Int {
        var positions: [T: [Int]] = [:]
        for (index, element) in b.enumerated() { positions[element, default: []].append(index) }
        if b.count >= 200 {
            // difflib autojunk: drop elements that make up more than 1% of b.
            let limit = b.count / 100 + 1
            positions = positions.filter { $0.value.count <= limit }
        }
        var total = 0
        var queue = [(0, a.count, 0, b.count)]
        while let (alo, ahi, blo, bhi) = queue.popLast() {
            let (i, j, k) = longestMatch(a, positions, alo, ahi, blo, bhi)
            guard k > 0 else { continue }
            total += k
            if alo < i, blo < j { queue.append((alo, i, blo, j)) }
            if i + k < ahi, j + k < bhi { queue.append((i + k, ahi, j + k, bhi)) }
        }
        return total
    }

    /// `find_longest_match` without junk: the earliest longest common block.
    static func longestMatch<T: Hashable>(_ a: [T], _ positions: [T: [Int]], _ alo: Int, _ ahi: Int, _ blo: Int, _ bhi: Int) -> (Int, Int, Int) {
        var bestI = alo, bestJ = blo, bestSize = 0
        var lengths: [Int: Int] = [:]
        for i in alo..<ahi {
            var newLengths: [Int: Int] = [:]
            for j in positions[a[i]] ?? [] {
                if j < blo { continue }
                if j >= bhi { break }
                let k = (lengths[j - 1] ?? 0) + 1
                newLengths[j] = k
                if k > bestSize {
                    bestI = i - k + 1
                    bestJ = j - k + 1
                    bestSize = k
                }
            }
            lengths = newLengths
        }
        return (bestI, bestJ, bestSize)
    }
}
