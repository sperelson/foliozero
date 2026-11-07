import Foundation
import Testing
@testable import FolioTemplating

/// Parses and renders `source` in one step.
func render(
    _ source: String,
    _ context: [String: TemplateValue] = [:],
    environment: TemplateEnvironment = .standard
) throws -> String {
    try Template(source).render(context, environment: environment)
}

/// Returns the syntax error that parsing or rendering `source` throws, or nil.
func syntaxError(
    _ source: String,
    _ context: [String: TemplateValue] = [:],
    environment: TemplateEnvironment = .standard
) -> (message: String, line: Int, column: Int)? {
    do {
        _ = try render(source, context, environment: environment)
        return nil
    } catch let TemplateError.syntax(message, line, column) {
        return (message, line, column)
    } catch {
        return nil
    }
}

/// Returns the runtime error message that rendering `source` throws, or nil.
func runtimeError(
    _ source: String,
    _ context: [String: TemplateValue] = [:],
    environment: TemplateEnvironment = .standard
) -> String? {
    do {
        _ = try render(source, context, environment: environment)
        return nil
    } catch let TemplateError.runtime(message) {
        return message
    } catch {
        return nil
    }
}

let utc = TimeZone(identifier: "UTC")!
let plusTwo = TimeZone(secondsFromGMT: 7200)!

/// Builds a `Date` from wall-clock components in `timeZone`.
func makeDate(
    _ year: Int, _ month: Int, _ day: Int,
    _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0,
    nanosecond: Int = 0,
    timeZone: TimeZone = utc
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    let components = DateComponents(
        year: year, month: month, day: day,
        hour: hour, minute: minute, second: second, nanosecond: nanosecond
    )
    return calendar.date(from: components)!
}

/// A date-only value, like a Python `date`.
func day(_ year: Int, _ month: Int, _ day: Int, timeZone: TimeZone = utc) -> TemplateValue {
    .date(makeDate(year, month, day, timeZone: timeZone), includesTime: false, timeZone: timeZone)
}

/// An aware date-time value, like a Python `datetime` with tzinfo.
func dateTime(
    _ year: Int, _ month: Int, _ day: Int,
    _ hour: Int, _ minute: Int, _ second: Int = 0,
    nanosecond: Int = 0,
    timeZone: TimeZone = utc
) -> TemplateValue {
    .date(
        makeDate(year, month, day, hour, minute, second, nanosecond: nanosecond, timeZone: timeZone),
        includesTime: true,
        timeZone: timeZone
    )
}
