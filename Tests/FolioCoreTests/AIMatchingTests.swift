import Foundation
import GRDB
import Testing
@testable import FolioCore

@Suite struct AIMatchingTests {
    @Test func sequenceMatcherAgreesWithDifflib() {
        func ratio(_ a: String, _ b: String) -> Double { SequenceMatcher.ratio(Array(a.unicodeScalars), Array(b.unicodeScalars)) }
        // Values from Python: difflib.SequenceMatcher(None, a, b).ratio()
        #expect(abs(ratio("abcd", "bcde") - 0.75) < 1e-9)
        #expect(abs(ratio("acme corp", "acme corporation") - 0.72) < 1e-9)
        #expect(abs(ratio("insurance", "insurances") - 0.9473684210526315) < 1e-9)
        #expect(abs(ratio("tide", "diet") - 0.25) < 1e-9)
        #expect(ratio("", "") == 1)
    }

    @Test func closeMatchUsesCutoffAndPrefersLargerOnTies() {
        #expect(AIMatching.closeMatch("insurances", in: ["insurance", "invoice"], cutoff: 0.8) == "insurance")
        #expect(AIMatching.closeMatch("bank", in: ["insurance", "invoice"], cutoff: 0.8) == nil)
        #expect(AIMatching.closeMatch("ab", in: ["ac", "ad"], cutoff: 0.5) == "ad")
    }

    @Test func normalizeStripsPunctuationAndCase() {
        #expect(AIMatching.normalize("  ACME, Inc. ") == "acme inc")
        #expect(AIMatching.normalize("Société Générale!") == "société générale")
    }

    @Test func matchesNamesExactlyThenFuzzilyWithoutReuse() {
        let objects = [
            AIMatching.Object(id: 1, name: "Insurance"), AIMatching.Object(id: 2, name: "Car"),
            AIMatching.Object(id: 3, name: "ACME Corp."),
        ]
        let matched = AIMatching.matchNames(["insurances", "ACME corp", "Car", "car", "Unknown", ""], to: objects)
        #expect(matched.map(\.id) == [1, 3, 2])
        #expect(AIMatching.unmatchedNames(["insurances", "ACME corp", "Unknown"], matched: matched) == ["insurances", "Unknown"])
    }

    @Test func respectsObjectPermissions() async throws {
        let (database, dir) = try makeTestDatabase()
        defer { withExtendedLifetime(dir) {} }
        let (alice, bob, team) = try await database.write { db -> (User, User, Int) in
            let alice = try makeUser("alice", in: db)
            let bob = try makeUser("bob", in: db)
            var group = Group(name: "team")
            try group.insert(db)
            try db.execute(sql: "INSERT INTO user_groups(user_id, group_id) VALUES (?, ?)", arguments: [bob.id, group.id])
            var shared = Tag(name: "Shared", ownerId: alice.id)
            var secret = Tag(name: "Secret", ownerId: alice.id)
            var groupTag = Tag(name: "Team", ownerId: alice.id)
            var common = Tag(name: "Common")
            try shared.insert(db); try secret.insert(db); try groupTag.insert(db); try common.insert(db)
            try PermissionSet(view: .init(users: [bob.id!])).apply(objectType: Tag.objectType, objectId: shared.id!, in: db)
            try PermissionSet(view: .init(groups: [group.id!])).apply(objectType: Tag.objectType, objectId: groupTag.id!, in: db)
            return (alice, bob, group.id!)
        }
        try await database.read { db in
            let all = try AIMatching.fetch(kind: .tag, context: access(alice), extra: nil, in: db).map(\.name)
            #expect(all == ["Common", "Secret", "Shared", "Team"])
            let bobs = try AIMatching.fetch(kind: .tag, context: access(bob, groups: [team]), extra: nil, in: db).map(\.name)
            #expect(bobs == ["Common", "Shared", "Team"])
            let nobody = try AIMatching.fetch(kind: .tag, context: AIMatching.nobody, extra: nil, in: db).map(\.name)
            #expect(nobody == ["Common"])

            let ids = try AIMatching.fetch(kind: .tag, context: access(alice), extra: nil, in: db).map(\.id)
            let resolved = try AIMatching.resolveIds(ids + [999], kind: .tag, context: access(bob, groups: [team]), in: db)
            #expect(resolved.map(\.name) == ["Common", "Shared", "Team"])
            let byName = try AIMatching.matchByName(["secret", "shared"], kind: .tag, context: access(bob, groups: [team]), in: db)
            #expect(byName.map(\.name) == ["Shared"])
        }
    }

    @Test func validatesCandidateMappings() {
        let output = ClassifierOutput(
            title: "Invoice", tags: ["Insurance", "Car", " "], matchedTags: ["Insurance", "Car", "Bogus"], tagIds: [1, 99, 3],
            correspondents: ["ACME"], matchedCorrespondents: ["ACME"], correspondentIds: [5],
            documentTypes: ["Invoice"], matchedDocumentTypes: ["Invoice", "Invoice"], documentTypeIds: [7, 7])
        let suggestions = ClassificationSuggestions(output: output, allowedIds: [.tag: [1, 3], .correspondent: [5], .documentType: [7]])
        // "Car" mapped to an id that was never shown stays a new name; "Bogus" was never suggested.
        #expect(suggestions.tags == TaxonomyChoice(existingIds: [1], newNames: ["Car"]))
        #expect(suggestions.correspondents == TaxonomyChoice(existingIds: [5], newNames: []))
        #expect(suggestions.documentTypes == TaxonomyChoice(existingIds: [7], newNames: []))
        #expect(suggestions.storagePaths == TaxonomyChoice())
    }

    @Test func classifierOutputDecodesLeniently() throws {
        let text = """
            Here you go:
            ```json
            {"title": "\(String(repeating: "T", count: 200))", "tags": ["a","b","c","d","e","f","g","h","i"], "tag_ids": ["4"], "dates": "2024-01-02"}
            ```
            """
        let output = try ClassifierOutput.decode(fromModelText: text)
        #expect(output.title.count == ClassifierOutput.maxTitleLength)
        #expect(output.tags.count == ClassifierOutput.maxNewNames)
        #expect(output.tagIds == [4])
        #expect(output.dates == ["2024-01-02"])
        #expect(output.correspondents.isEmpty)
        #expect(throws: AIError.self) { try ClassifierOutput.decode(fromModelText: "no json here") }
    }
}
