import Foundation
import Testing
@testable import FolioCore

@Suite struct CronScheduleTests {
    let utc = TimeZone(identifier: "UTC")!

    func date(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)!
    }

    func next(_ cron: String, after: String) throws -> String? {
        let schedule = try #require(try CronSchedule.parse(cron))
        return schedule.nextDate(after: date(after), in: utc).map { ISO8601DateFormatter().string(from: $0) }
    }

    @Test func paperlessDefaults() throws {
        // EMAIL_TASK_CRON every 10 minutes
        #expect(try next("*/10 * * * *", after: "2026-11-07T10:03:12Z") == "2026-11-07T10:10:00Z")
        // TRAIN_TASK_CRON at minute 5 of every hour
        #expect(try next("5 */1 * * *", after: "2026-11-07T10:05:00Z") == "2026-11-07T11:05:00Z")
        // SANITY_TASK_CRON Sunday 00:30 (7 Nov 2026 is a Saturday)
        #expect(try next("30 0 * * sun", after: "2026-11-07T10:00:00Z") == "2026-11-08T00:30:00Z")
        // INDEX_TASK_CRON midnight
        #expect(try next("0 0 * * *", after: "2026-12-31T23:59:59Z") == "2027-01-01T00:00:00Z")
    }

    @Test func listsRangesAndNames() throws {
        #expect(try next("15,45 9-17 * * mon-fri", after: "2026-11-07T10:00:00Z") == "2026-11-09T09:15:00Z")
        #expect(try next("0 12 1 jan *", after: "2026-11-07T10:00:00Z") == "2027-01-01T12:00:00Z")
        // Day-of-month OR day-of-week when both are restricted.
        #expect(try next("0 0 13 * fri", after: "2026-11-07T10:00:00Z") == "2026-11-13T00:00:00Z")
    }

    @Test func disableAndErrors() throws {
        #expect(try CronSchedule.parse("disable") == nil)
        #expect(throws: CronSchedule.ParseError.self) { try CronSchedule.parse("* * *") }
        #expect(throws: CronSchedule.ParseError.self) { try CronSchedule.parse("61 * * * *") }
        #expect(throws: CronSchedule.ParseError.self) { try CronSchedule.parse("*/0 * * * *") }
    }
}

@Suite struct TaskQueueTests {
    @Test func recordsSuccessAndFailure() async throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        let queue = TaskQueue(database: db, workers: 2, logger: .init(label: "test"))
        let ok = try await queue.enqueue(type: .indexOptimize, source: .manual) { progress in
            progress(50, "half way")
            return TaskOutcome(message: "done", documentId: 42)
        }
        struct Boom: Error, CustomStringConvertible { var description: String { "boom" } }
        let bad = try await queue.enqueue(type: .sanityCheck, source: .scheduled) { _ in throw Boom() }
        await queue.waitUntilIdle()

        let records = try await db.read { db in try TaskRecord.fetchAll(db) }
        let success = try #require(records.first { $0.taskId == ok })
        #expect(success.status == .success)
        #expect(success.resultMessage == "done")
        #expect(success.relatedDocumentId == 42)
        #expect(success.dateStarted != nil && success.dateDone != nil)
        let failure = try #require(records.first { $0.taskId == bad })
        #expect(failure.status == .failure)
        #expect(failure.resultMessage == "boom")
    }

    @Test func concurrencyLimit() async throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        let queue = TaskQueue(database: db, workers: 2, logger: .init(label: "test"))
        let counter = Counter()
        for _ in 0..<6 {
            try await queue.enqueue(type: .bulkUpdate, source: .manual) { _ in
                await counter.enter()
                try await Task.sleep(for: .milliseconds(30))
                await counter.leave()
                return TaskOutcome(message: "ok")
            }
        }
        await queue.waitUntilIdle()
        #expect(await counter.peak == 2)
    }

    @Test func interruptedTasksAreMarkedFailed() async throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        try await db.write { db in
            var record = TaskRecord(taskType: .consumeFile, triggerSource: .apiUpload, status: .started)
            try record.insert(db)
        }
        let queue = TaskQueue(database: db, workers: 1, logger: .init(label: "test"))
        await queue.recoverInterrupted()
        let status = try await db.read { db in try TaskRecord.fetchOne(db)?.status }
        #expect(status == .failure)
    }
}

actor Counter {
    var current = 0
    var peak = 0
    func enter() { current += 1; peak = max(peak, current) }
    func leave() { current -= 1 }
}
