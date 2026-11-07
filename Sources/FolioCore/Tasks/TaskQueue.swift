import Foundation
import GRDB
import Logging

/// What a finished job reports.
public struct TaskOutcome: Sendable {
    public var message: String
    public var documentId: Int?
    public var data: [String: String]

    public init(message: String, documentId: Int? = nil, data: [String: String] = [:]) {
        self.message = message
        self.documentId = documentId
        self.data = data
    }
}

/// Runs background jobs with a concurrency limit and records each one in the
/// `tasks` table, so `/api/tasks/` can report progress (the Celery equivalent).
public actor TaskQueue {
    public typealias Work = @Sendable (_ progress: @escaping ConsumeProgress) async throws -> TaskOutcome

    struct Job {
        var taskId: String
        var work: Work
    }

    private let database: FolioDatabase
    private let logger: Logger
    private let workers: Int
    private var pending: [Job] = []
    private var running = 0
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var progressByTask: [String: (Int, String)] = [:]

    public init(database: FolioDatabase, workers: Int, logger: Logger) {
        self.database = database
        self.workers = max(1, workers)
        self.logger = logger
    }

    /// Marks tasks left `pending` or `started` by a previous run as failed.
    public func recoverInterrupted() async {
        do {
            try await database.write { db in
                try db.execute(sql: """
                    UPDATE tasks SET status = 'failure', date_done = ?, result_message = 'Interrupted: FolioZero stopped before the task finished'
                    WHERE status IN ('pending', 'started')
                    """, arguments: [FolioDateFormat.database.string(from: Date())])
            }
        } catch {
            logger.error("Could not recover interrupted tasks: \(error)")
        }
    }

    /// Records a task and schedules `work`. Returns the task id (a UUID).
    @discardableResult
    public func enqueue(
        type: TaskRecord.TaskType,
        source: TaskRecord.TriggerSource,
        input: [String: String] = [:],
        ownerId: Int? = nil,
        taskId: String = UUID().uuidString.lowercased(),
        work: @escaping Work
    ) async throws -> String {
        let record = TaskRecord(taskId: taskId, taskType: type, triggerSource: source, inputData: input, ownerId: ownerId)
        _ = try await database.write { db -> TaskRecord in
            var record = record
            try record.insert(db)
            return record
        }
        pending.append(Job(taskId: taskId, work: work))
        startJobs()
        return taskId
    }

    /// Consume a file in the background.
    @discardableResult
    public func enqueueConsume(_ request: ConsumeRequest, consumer: Consumer, ownerId: Int? = nil) async throws -> String {
        let taskId = request.taskId ?? UUID().uuidString.lowercased()
        var request = request
        request.taskId = taskId
        let input = ["filename": request.originalFilename, "source": String(request.source.rawValue)]
        return try await enqueue(type: .consumeFile, source: request.source.triggerSource, input: input, ownerId: ownerId, taskId: taskId) { [request] progress in
            do {
                let document = try await consumer.consume(request, progress: progress)
                return TaskOutcome(message: "Success. New document id \(document.id ?? 0) created", documentId: document.id)
            } catch let stop as ConsumeStopped {
                return TaskOutcome(message: stop.message)
            }
        }
    }

    /// Latest progress of a running task (percent, message).
    public func progress(of taskId: String) -> (Int, String)? {
        progressByTask[taskId]
    }

    public var activeCount: Int { running + pending.count }

    /// Suspends until no job is pending or running.
    public func waitUntilIdle() async {
        if running == 0 && pending.isEmpty { return }
        await withCheckedContinuation { idleWaiters.append($0) }
    }

    private func startJobs() {
        while running < workers, !pending.isEmpty {
            let job = pending.removeFirst()
            running += 1
            Task { await self.execute(job) }
        }
        if running == 0 && pending.isEmpty {
            let waiters = idleWaiters
            idleWaiters = []
            waiters.forEach { $0.resume() }
        }
    }

    private func execute(_ job: Job) async {
        let started = Date()
        let taskId = job.taskId
        await update(taskId) { record in
            record.status = .started
            record.dateStarted = started
            record.waitTimeSeconds = started.timeIntervalSince(record.dateCreated)
        }
        let reporter: ConsumeProgress = { [weak self] percent, message in
            guard let self else { return }
            Task { await self.setProgress(taskId, percent, message) }
        }
        do {
            let outcome = try await job.work(reporter)
            await update(taskId) { record in
                record.status = .success
                record.resultMessage = outcome.message
                record.relatedDocumentId = outcome.documentId
                record.resultData = outcome.data.merging(outcome.documentId.map { ["document_id": String($0)] } ?? [:]) { a, _ in a }
                record.dateDone = Date()
                record.durationSeconds = Date().timeIntervalSince(started)
            }
        } catch {
            logger.error("Task \(taskId) failed: \(error)")
            await update(taskId) { record in
                record.status = .failure
                record.resultMessage = "\(error)"
                if case let ConsumeError.duplicate(_, existingId, _) = error {
                    record.relatedDocumentId = existingId
                    record.resultData = ["duplicate_of": String(existingId)]
                }
                record.dateDone = Date()
                record.durationSeconds = Date().timeIntervalSince(started)
            }
        }
        progressByTask[taskId] = nil
        running -= 1
        startJobs()
    }

    private func setProgress(_ taskId: String, _ percent: Int, _ message: String) {
        progressByTask[taskId] = (percent, message)
    }

    private func update(_ taskId: String, _ change: @escaping @Sendable (inout TaskRecord) -> Void) async {
        do {
            try await database.write { db in
                guard var record = try TaskRecord.filter(Column("task_id") == taskId).fetchOne(db) else { return }
                change(&record)
                try record.update(db)
            }
        } catch {
            logger.error("Could not update task \(taskId): \(error)")
        }
    }
}
