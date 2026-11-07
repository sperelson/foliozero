import Foundation

/// A five-field cron expression (minute hour day-of-month month day-of-week),
/// as used by the Paperless-ngx `*_TASK_CRON` settings. `disable` turns a job off.
public struct CronSchedule: Sendable, Equatable {
    let minutes: Set<Int>
    let hours: Set<Int>
    let daysOfMonth: Set<Int>
    let months: Set<Int>
    let daysOfWeek: Set<Int> // 0 = Sunday
    let dayOfMonthRestricted: Bool
    let dayOfWeekRestricted: Bool

    public struct ParseError: Error, CustomStringConvertible {
        public var description: String
    }

    /// nil for `disable`.
    public static func parse(_ expression: String) throws -> CronSchedule? {
        let trimmed = expression.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased() == "disable" { return nil }
        let fields = trimmed.split(separator: " ").map(String.init)
        guard fields.count == 5 else { throw ParseError(description: "Cron expression needs 5 fields: \(expression)") }
        let monthNames = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"]
        let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        var daysOfWeek = try field(fields[4], 0...7, names: dayNames, offset: 0)
        if daysOfWeek.remove(7) != nil { daysOfWeek.insert(0) }
        return CronSchedule(
            minutes: try field(fields[0], 0...59),
            hours: try field(fields[1], 0...23),
            daysOfMonth: try field(fields[2], 1...31),
            months: try field(fields[3], 1...12, names: monthNames, offset: 1),
            daysOfWeek: daysOfWeek,
            dayOfMonthRestricted: fields[2] != "*",
            dayOfWeekRestricted: fields[4] != "*"
        )
    }

    private static func field(_ text: String, _ range: ClosedRange<Int>, names: [String] = [], offset: Int = 0) throws -> Set<Int> {
        var result = Set<Int>()
        for part in text.lowercased().split(separator: ",") {
            let pieces = part.split(separator: "/", maxSplits: 1)
            let step = pieces.count == 2 ? Int(pieces[1]) : 1
            guard let step, step > 0 else { throw ParseError(description: "Bad step in \(text)") }
            var lower = range.lowerBound, upper = range.upperBound
            let base = String(pieces[0])
            if base != "*" {
                let bounds = base.split(separator: "-", maxSplits: 1).map(String.init)
                func value(_ s: String) throws -> Int {
                    if let n = Int(s) { return n }
                    if let index = names.firstIndex(of: String(s.prefix(3))) { return index + offset }
                    throw ParseError(description: "Bad value \(s) in \(text)")
                }
                lower = try value(bounds[0])
                upper = bounds.count == 2 ? try value(bounds[1]) : (pieces.count == 2 ? range.upperBound : lower)
            }
            guard range.contains(lower), range.contains(upper), lower <= upper else {
                throw ParseError(description: "Value out of range in \(text)")
            }
            result.formUnion(stride(from: lower, through: upper, by: step))
        }
        return result
    }

    /// The first matching minute strictly after `date`.
    public func nextDate(after date: Date, in timeZone: TimeZone = .current) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let floored = calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)),
              var candidate = calendar.date(byAdding: .minute, value: 1, to: floored) else { return nil }
        // Walk forward, skipping whole days and hours that cannot match. Bounded to about 5 years.
        for _ in 0..<(366 * 24 * 5 + 60) {
            let c = calendar.dateComponents([.month, .day, .hour, .minute, .weekday], from: candidate)
            if !months.contains(c.month!) || !dayMatches(day: c.day!, weekday: c.weekday! - 1) {
                candidate = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: candidate)!)
                continue
            }
            if !hours.contains(c.hour!) {
                candidate = calendar.date(byAdding: .minute, value: 60 - c.minute!, to: candidate)!
                continue
            }
            if let minute = minutes.sorted().first(where: { $0 >= c.minute! }) {
                return calendar.date(byAdding: .minute, value: minute - c.minute!, to: candidate)
            }
            candidate = calendar.date(byAdding: .minute, value: 60 - c.minute!, to: candidate)!
        }
        return nil
    }

    /// Standard cron rule: when both day fields are restricted, either may match.
    private func dayMatches(day: Int, weekday: Int) -> Bool {
        switch (dayOfMonthRestricted, dayOfWeekRestricted) {
        case (true, true): daysOfMonth.contains(day) || daysOfWeek.contains(weekday)
        case (true, false): daysOfMonth.contains(day)
        case (false, true): daysOfWeek.contains(weekday)
        case (false, false): true
        }
    }
}

/// Runs named jobs on cron schedules until cancelled.
public actor Scheduler {
    public struct Job: Sendable {
        public var name: String
        public var schedule: CronSchedule
        public var run: @Sendable () async -> Void

        public init(name: String, schedule: CronSchedule, run: @escaping @Sendable () async -> Void) {
            self.name = name
            self.schedule = schedule
            self.run = run
        }
    }

    private let timeZone: TimeZone
    private var jobs: [Job] = []
    private var loops: [Task<Void, Never>] = []

    public init(timeZone: TimeZone) {
        self.timeZone = timeZone
    }

    public func add(_ job: Job) {
        jobs.append(job)
    }

    public func start() {
        for job in jobs {
            let zone = timeZone
            loops.append(Task {
                while !Task.isCancelled {
                    guard let next = job.schedule.nextDate(after: Date(), in: zone) else { return }
                    let delay = next.timeIntervalSinceNow
                    if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                    if Task.isCancelled { return }
                    await job.run()
                }
            })
        }
    }

    public func stop() {
        loops.forEach { $0.cancel() }
        loops = []
    }
}
