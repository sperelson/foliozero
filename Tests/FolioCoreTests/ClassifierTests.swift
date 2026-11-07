import Foundation
import GRDB
import Testing
@testable import FolioCore

@Suite struct ClassifierTests {
    typealias Doc = DocumentClassifier.TrainingDocument

    func corpus() -> [Doc] {
        var docs: [Doc] = []
        let bank = ["Monthly account statement FNB cheque account balance interest", "FNB statement of account transactions debit order balance"]
        let power = ["Eskom electricity invoice prepaid units kWh municipal", "City Power electricity account kWh meter reading invoice"]
        let medical = ["Discovery Health medical aid claim statement benefits", "Medical aid claim Discovery Health doctor consultation"]
        for i in 0..<12 {
            docs.append(Doc(content: bank[i % 2] + " ref \(i)", correspondentId: 1, documentTypeId: 10, storagePathId: nil, tagIds: [100]))
            docs.append(Doc(content: power[i % 2] + " ref \(i)", correspondentId: 2, documentTypeId: 11, storagePathId: nil, tagIds: [101]))
            docs.append(Doc(content: medical[i % 2] + " ref \(i)", correspondentId: 3, documentTypeId: nil, storagePathId: nil, tagIds: [100, 102]))
        }
        return docs
    }

    @Test func learnsLabels() throws {
        let classifier = try #require(DocumentClassifier.train(corpus()))
        let bank = classifier.predict("Your FNB account statement with closing balance")
        #expect(bank.correspondentIds == [1])
        #expect(bank.documentTypeIds == [10])
        #expect(bank.tagIds == [100])

        let power = classifier.predict("Eskom electricity invoice for 350 kWh")
        #expect(power.correspondentIds == [2])
        #expect(power.tagIds == [101])

        let medical = classifier.predict("Discovery Health claim for doctor consultation")
        #expect(medical.correspondentIds == [3])
        #expect(medical.documentTypeIds.isEmpty) // learned "none"
        #expect(Set(medical.tagIds) == [100, 102])
    }

    @Test func persistsAndDetectsUnchangedData() throws {
        let dir = TempDir()
        let classifier = try #require(DocumentClassifier.train(corpus()))
        try classifier.save(to: dir.file("c.json"))
        let loaded = try #require(DocumentClassifier.load(from: dir.file("c.json")))
        #expect(loaded.predict("Eskom electricity invoice") == classifier.predict("Eskom electricity invoice"))
        #expect(loaded.dataHash == DocumentClassifier.hash(corpus()))
    }

    @Test func nothingToLearn() {
        #expect(DocumentClassifier.train([]) == nil)
        #expect(DocumentClassifier.train([Doc(content: "a b c", tagIds: []), Doc(content: "d e f", tagIds: [])]) == nil)
    }

    @Test func trainingDataSkipsInboxAndNonAutoLabels() throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        try db.write { db in
            var auto = Correspondent(name: "Auto", matchingAlgorithm: .auto); try auto.insert(db)
            var manual = Correspondent(name: "Manual", matchingAlgorithm: .any); try manual.insert(db)
            var inbox = Tag(name: "Inbox", isInboxTag: true); try inbox.insert(db)
            var a = Document.fixture("a", content: "alpha"); a.correspondentId = auto.id
            var b = Document.fixture("b", content: "beta"); b.correspondentId = manual.id
            var c = Document.fixture("c", content: "gamma"); c.correspondentId = auto.id
            try DocumentStore.insert(a, in: db)
            try DocumentStore.insert(b, in: db)
            try DocumentStore.insert(c, tagIds: [inbox.id!], in: db)
            let data = try DocumentClassifier.trainingData(in: db)
            #expect(data.map(\.content) == ["alpha", "beta"])
            #expect(data.map(\.correspondentId) == [auto.id, nil])
        }
    }
}
