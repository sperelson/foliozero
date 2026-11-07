import Foundation

/// An error from parsing or rendering a template.
public enum TemplateError: Error, CustomStringConvertible, LocalizedError, Equatable, Sendable {
    /// The template source is invalid. `line` and `column` are 1-based.
    case syntax(message: String, line: Int, column: Int)
    /// Rendering failed. The message ends with the position, for example "(line 2, column 5)".
    case runtime(String)

    public var description: String {
        switch self {
        case let .syntax(message, line, column):
            "Template syntax error at line \(line), column \(column): \(message)"
        case let .runtime(message):
            "Template error: \(message)"
        }
    }

    public var errorDescription: String? { description }
}

/// A 1-based position in the template source.
struct SourceLocation: Sendable, Hashable {
    var line: Int
    var column: Int
}

/// The internal error raised while rendering. It becomes `TemplateError.runtime` at the API boundary.
struct RuntimeFailure: Error {
    var message: String
    var location: SourceLocation?

    init(_ message: String, at location: SourceLocation? = nil) {
        self.message = message
        self.location = location
    }

    var formatted: String {
        guard let location else { return message }
        return "\(message) (line \(location.line), column \(location.column))"
    }
}

func makeSyntaxError(_ message: String, at location: SourceLocation) -> TemplateError {
    .syntax(message: message, line: location.line, column: location.column)
}
