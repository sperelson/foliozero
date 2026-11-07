import Foundation
import Testing
@testable import FolioCore

@Suite struct DateExtractorTests {
    let utc = TimeZone(identifier: "UTC")!
    var now: Date { CalendarDate(year: 2026, month: 11, day: 7).startDate(in: utc) }

    func first(_ text: String, order: DateOrder = .DMY, languages: [String] = []) -> CalendarDate? {
        DateExtractor(contentOrder: order, languages: languages, timeZone: utc).firstDate(filename: "", content: text, now: now)
    }

    @Test func numericDayFirst() {
        #expect(first("Invoice date: 14.03.2024") == CalendarDate(year: 2024, month: 3, day: 14))
        #expect(first("Invoice date: 14/03/2024") == CalendarDate(year: 2024, month: 3, day: 14))
        #expect(first("Invoice date: 4-3-24") == CalendarDate(year: 2024, month: 3, day: 4))
    }

    @Test func numericMonthFirst() {
        #expect(first("Date 03/14/2024", order: .MDY) == CalendarDate(year: 2024, month: 3, day: 14))
    }

    @Test func isoDates() {
        #expect(first("Generated 2024-03-14 10:00") == CalendarDate(year: 2024, month: 3, day: 14))
        #expect(first("Generated 2024/03/14") == CalendarDate(year: 2024, month: 3, day: 14))
    }

    @Test func textualMonths() {
        #expect(first("Dated 14 March 2024.") == CalendarDate(year: 2024, month: 3, day: 14))
        #expect(first("Dated March 14, 2024.") == CalendarDate(year: 2024, month: 3, day: 14))
        #expect(first("Berlin, 14. März 2024") == CalendarDate(year: 2024, month: 3, day: 14))
        #expect(first("Statement for March 2024") == CalendarDate(year: 2024, month: 3, day: 1))
        #expect(first("Due 14-Mar-2024") == CalendarDate(year: 2024, month: 3, day: 14))
        #expect(first("Paid on the 14th March 2024") == CalendarDate(year: 2024, month: 3, day: 14))
        #expect(first("Pretoria, 14 Maart 2024", languages: ["af"]) == CalendarDate(year: 2024, month: 3, day: 14))
    }

    @Test func rejectsInvalidFutureAndOldDates() {
        #expect(first("Version 31.02.2024") == nil)
        #expect(first("Expires 01.01.2030") == nil)
        #expect(first("Founded 01.01.1850") == nil)
        // Skips the invalid candidate and finds the next one.
        #expect(first("31.02.2024 then 01.02.2024") == CalendarDate(year: 2024, month: 2, day: 1))
    }

    @Test func ignoreDates() {
        let extractor = DateExtractor(ignoreDates: [CalendarDate(year: 2024, month: 3, day: 14)], timeZone: utc)
        #expect(extractor.firstDate(filename: "", content: "14.03.2024 and 15.03.2024", now: now) == CalendarDate(year: 2024, month: 3, day: 15))
    }

    @Test func filenameFirstWhenConfigured() {
        let extractor = DateExtractor(contentOrder: .DMY, filenameOrder: .YMD, timeZone: utc)
        let date = extractor.firstDate(filename: "2023-12-01 scan.pdf", content: "14.03.2024", now: now)
        #expect(date == CalendarDate(year: 2023, month: 12, day: 1))
        #expect(extractor.dates(filename: "2023-12-01 scan.pdf", content: "14.03.2024", now: now).count == 2)
    }
}
