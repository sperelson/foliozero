import Foundation
import GRDB
import Testing
@testable import FolioCore

@Suite struct SearchQueryParserTests {
    let utc = TimeZone(identifier: "UTC")!
    // Saturday 7 November 2026, 10:00 UTC
    var now: Date { Date(timeIntervalSince1970: 1_794_045_600) }
    var parser: SearchQueryParser { SearchQueryParser(timeZone: utc, now: now) }

    func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        CalendarDate(year: y, month: m, day: d).startDate(in: utc)
    }

    @Test func implicitAndAndOperators() throws {
        #expect(try parser.parse("invoice unpaid") == .and([.term("invoice", field: .default), .term("unpaid", field: .default)]))
        #expect(try parser.parse("shopname AND (product1 OR product2)") == .and([
            .term("shopname", field: .default),
            .or([.term("product1", field: .default), .term("product2", field: .default)]),
        ]))
        #expect(try parser.parse("invoice NOT draft") == .and([.term("invoice", field: .default), .not(.term("draft", field: .default))]))
        // Lowercase operators are words; a leading - is not exclusion.
        #expect(try parser.parse("cats and dogs") == .and([.term("cats", field: .default), .term("and", field: .default), .term("dogs", field: .default)]))
        #expect(try parser.parse("invoice -secret") == .and([.term("invoice", field: .default), .term("secret", field: .default)]))
    }

    @Test func phrasesAndSeparators() throws {
        #expect(try parser.parse("\"quick brown fox\"") == .phrase(["quick", "brown", "fox"], field: .default))
        #expect(try parser.parse("A-1312/B") == .phrase(["a", "1312", "b"], field: .default))
        #expect(try parser.parse("résumé") == .term("résumé", field: .default))
    }

    @Test func fields() throws {
        #expect(try parser.parse("type:invoice tag:unpaid") == .and([.term("invoice", field: .documentType), .tag("unpaid")]))
        #expect(try parser.parse("correspondent:\"acme corp\"") == .phrase(["acme", "corp"], field: .correspondent))
        #expect(try parser.parse("tag:bills,unpaid") == .and([.tag("bills"), .tag("unpaid")]))
        #expect(try parser.parse("asn:[50 to 150]") == .number(.asn, lower: 50, upper: 150))
        #expect(try parser.parse("asn:42") == .number(.asn, lower: 42, upper: 42))
        #expect(try parser.parse("checksum:9F86D081*") == .checksum("9f86d081", prefix: true))
        #expect(try parser.parse("notes.user:alice notes.note:insurance") == .and([.term("alice", field: .notesUser), .term("insurance", field: .notes)]))
        #expect(try parser.parse("custom_fields.name:\"Contract Number\" custom_fields.value:1312") == .and([
            .phrase(["contract", "number"], field: .customFieldNames), .term("1312", field: .customFieldValues),
        ]))
        #expect(try parser.parse("barcodes:wifi") == .term("wifi", field: .barcodeValues))
        // Unknown field names are text.
        #expect(try parser.parse("foo:bar") == .phrase(["foo", "bar"], field: .default))
    }

    @Test func wildcards() throws {
        #expect(try parser.parse("invoice*") == .term("invoice*", field: .default))
        #expect(try parser.parse("title:Invoice*") == .term("invoice*", field: .title))
        #expect(try parser.parse("20[12]?") == .term("20[12]?", field: .default))
        #expect(throws: SearchQueryError.self) { try parser.parse("asn:4*") }
    }

    @Test func dateKeywords() throws {
        #expect(try parser.parse("added:yesterday") == .date(.added, from: day(2026, 11, 6), to: day(2026, 11, 7)))
        #expect(try parser.parse("modified:\"previous month\"") == .date(.modified, from: day(2026, 10, 1), to: day(2026, 11, 1)))
        #expect(try parser.parse("created:2005") == .date(.created, from: day(2005, 1, 1), to: day(2006, 1, 1)))
        #expect(try parser.parse("created:2005-03-04") == .date(.created, from: day(2005, 3, 4), to: day(2005, 3, 5)))
        #expect(try parser.parse("added:january") == .date(.added, from: day(2026, 1, 1), to: day(2026, 2, 1)))
        #expect(try parser.parse("added:\"12 december 2019\"") == .date(.added, from: day(2019, 12, 12), to: day(2019, 12, 13)))
        // Previous week is Monday 26 Oct to Monday 2 Nov 2026.
        #expect(try parser.parse("added:\"previous week\"") == .date(.added, from: day(2026, 10, 26), to: day(2026, 11, 2)))
        #expect(try parser.parse("added:\"previous quarter\"") == .date(.added, from: day(2026, 7, 1), to: day(2026, 10, 1)))
    }

    @Test func dateRanges() throws {
        #expect(try parser.parse("created:[2005 to 2009]") == .date(.created, from: day(2005, 1, 1), to: day(2010, 1, 1)))
        #expect(try parser.parse("added:[-1 week to now]") == .date(.added, from: now.addingTimeInterval(-7 * 86400), to: now))
        #expect(try parser.parse("added:['-1 week' to now]") == .date(.added, from: now.addingTimeInterval(-7 * 86400), to: now))
        #expect(try parser.parse("added:[now-7d to now]") == .date(.added, from: now.addingTimeInterval(-7 * 86400), to: now))
        #expect(throws: SearchQueryError.self) { try parser.parse("added:\"-1 week\"") }
        #expect(throws: SearchQueryError.self) { try parser.parse("added:monday") }
        #expect(throws: SearchQueryError.self) { try parser.parse("added:[\"-1 week\" to now]") }
    }

    @Test func errors() {
        #expect(throws: SearchQueryError.self) { try parser.parse("(invoice") }
        #expect(throws: SearchQueryError.self) { try parser.parse("\"open") }
        #expect(throws: SearchQueryError.self) { try parser.parse("invoice AND") }
    }
}

@Suite struct SearchIndexTests {
    /// Inserts documents and indexes them. Returns their ids in order.
    func seed(_ db: FolioDatabase) throws -> [Int] {
        try db.write { db in
            var acme = Correspondent(name: "Acme Corp")
            try acme.insert(db)
            var invoiceType = DocumentType(name: "Invoice")
            try invoiceType.insert(db)
            var unpaid = Tag(name: "Unpaid")
            try unpaid.insert(db)
            var bills = Tag(name: "Bills")
            try bills.insert(db)

            var a = Document.fixture("Acme invoice March", content: "Total due R 1 312.00 for account A-1312/B. Café visit.", asn: 100, pageCount: 2)
            a.correspondentId = acme.id
            a.documentTypeId = invoiceType.id
            try a.insert(db)
            try DocumentTag(documentId: a.id!, tagId: unpaid.id!).insert(db)
            try DocumentTag(documentId: a.id!, tagId: bills.id!).insert(db)

            var b = Document.fixture("Electricity statement", content: "Your electricity usage and invoices summary. Draft.", created: CalendarDate(year: 2023, month: 6, day: 1), asn: 200)
            try b.insert(db)
            try DocumentTag(documentId: b.id!, tagId: bills.id!).insert(db)

            var c = Document.fixture("Holiday photo", content: "Beach and sun", created: CalendarDate(year: 2020, month: 1, day: 5), checksum: "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08")
            try c.insert(db)
            var note = Note(documentId: c.id!, note: "Remember the insurance claim")
            try note.insert(db)

            for id in [a.id!, b.id!, c.id!] { try SearchIndex.update(documentId: id, in: db) }
            return [a.id!, b.id!, c.id!]
        }
    }

    func ids(_ query: String, _ db: FolioDatabase) throws -> Set<Int> {
        let parsed = try SearchQueryParser(timeZone: TimeZone(identifier: "UTC")!).parse(query)
        return try db.read { db in Set(try SearchIndex.search(parsed, in: db, timeZone: TimeZone(identifier: "UTC")!).map(\.documentId)) }
    }

    @Test func textSearch() throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        let ids = try seed(db)
        #expect(try self.ids("invoice", db) == [ids[0], ids[1]]) // "invoices" stems to "invoic"
        #expect(try self.ids("invoice NOT draft", db) == [ids[0]])
        #expect(try self.ids("cafe", db) == [ids[0]]) // accent-insensitive
        #expect(try self.ids("1312", db) == [ids[0]]) // separator-agnostic
        #expect(try self.ids("\"acme invoice\"", db) == [ids[0]])
        #expect(try self.ids("electric*", db) == [ids[1]])
        #expect(try self.ids("beach OR electricity", db) == [ids[1], ids[2]])
        // Notes are only searched with the field prefix.
        #expect(try self.ids("insurance", db) == [])
        #expect(try self.ids("notes:insurance", db) == [ids[2]])
        #expect(try self.ids("", db) == Set(ids))
    }

    @Test func fieldSearch() throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        let ids = try seed(db)
        #expect(try self.ids("correspondent:acme", db) == [ids[0]])
        #expect(try self.ids("type:invoice", db) == [ids[0]])
        #expect(try self.ids("tag:bills", db) == [ids[0], ids[1]])
        #expect(try self.ids("tag:bills,unpaid", db) == [ids[0]])
        #expect(try self.ids("tag:un*", db) == [ids[0]])
        #expect(try self.ids("asn:[150 to 250]", db) == [ids[1]])
        #expect(try self.ids("page_count:2", db) == [ids[0]])
        #expect(try self.ids("num_notes:1", db) == [ids[2]])
        #expect(try self.ids("checksum:9f86d081*", db) == [ids[2]])
        #expect(try self.ids("created:2023", db) == [ids[1]])
        #expect(try self.ids("created:[2020 to 2023]", db) == [ids[1], ids[2]])
        #expect(try self.ids("title:holiday", db) == [ids[2]])
    }

    @Test func rankingAndHighlights() throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        let ids = try seed(db)
        let hits = try db.read { db in try SearchIndex.search(.term("invoice", field: .default), in: db) }
        #expect(hits.first?.documentId == ids[0]) // title match ranks first
        #expect(hits.first?.score == 1)
        #expect(hits.first?.rank == 0)
        let content = try db.read { db in try SearchIndex.search(.term("electricity", field: .default), in: db) }
        #expect(content.first?.highlights.contains("<span class=\"match\">electricity</span>") == true)
    }

    @Test func removeAndSoftDelete() throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        let ids = try seed(db)
        try db.write { db in
            try db.execute(sql: "UPDATE documents SET deleted_at = ? WHERE id = ?", arguments: [Date(), ids[1]])
        }
        #expect(try self.ids("invoice", db) == [ids[0]])
        try db.write { db in try SearchIndex.remove(documentId: ids[0], in: db) }
        #expect(try self.ids("invoice", db) == [])
    }

    @Test func simpleTextQueryUsesPrefixes() throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        let ids = try seed(db)
        let hits = try db.read { db in try SearchIndex.search(SearchIndex.simpleQuery("acme inv", titleOnly: true), in: db) }
        #expect(hits.map(\.documentId) == [ids[0]])
    }

    @Test func autocompleteAndMoreLikeThis() throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        let ids = try seed(db)
        let words = try db.read { db in try SearchIndex.autocomplete("elec", in: db) }
        #expect(words.first?.hasPrefix("elec") == true)
        // Completions are whole words, not Porter stems ("invoic").
        let invoiceWords = try db.read { db in try SearchIndex.autocomplete("invo", in: db) }
        #expect(Set(invoiceWords) == ["invoice", "invoices"])
        let similar = try db.read { db in try SearchIndex.moreLikeThis(documentId: ids[1], in: db) }
        #expect(!similar.map(\.documentId).contains(ids[1]))
    }

    @Test func rebuildKeepsResults() throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        let ids = try seed(db)
        try db.write { db in try SearchIndex.rebuild(in: db) }
        #expect(try self.ids("invoice", db) == [ids[0], ids[1]])
        try db.write { db in try SearchIndex.optimize(in: db) }
    }
}
