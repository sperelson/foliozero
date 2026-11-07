import Foundation

/// A parsed Jinja2-subset template.
///
/// Parse once, render many times; a `Template` is immutable and safe to share between tasks.
///
/// ```swift
/// let template = try Template("{{ created_year }}/{{ correspondent }}/{{ title }}")
/// let path = try template.render(["created_year": "2024", "correspondent": "Bank", "title": "Statement"])
/// ```
public struct Template: Sendable {
    /// The template text as given.
    public let source: String
    let nodes: [Node]

    /// Parses `source`. Throws `TemplateError.syntax` with the line and column of the problem.
    public init(_ source: String) throws {
        self.source = source
        var lexer = Lexer(source)
        var parser = Parser(tokens: try lexer.tokenize())
        nodes = try parser.parseTemplate()
    }

    /// Renders the template.
    ///
    /// Throws `TemplateError.syntax` when the template uses a filter or test that `environment`
    /// does not have, and `TemplateError.runtime` when evaluation fails or a safety limit is hit.
    public func render(
        _ context: [String: TemplateValue] = [:],
        environment: TemplateEnvironment = .standard
    ) throws -> String {
        try validate(environment: environment)
        return try Interpreter(environment: environment, context: context).render(nodes)
    }

    /// Renders a filename format or storage path the way Paperless-ngx's `FilePathTemplate` does:
    /// the output is NFC-normalised, newlines are removed, whitespace around `/` is removed, and
    /// leading and trailing whitespace and `/` are stripped.
    public func renderFilePath(
        _ context: [String: TemplateValue] = [:],
        environment: TemplateEnvironment = .paperless
    ) throws -> String {
        Self.cleanFilePath(try render(context, environment: environment))
    }

    /// Checks that every filter and test the template uses exists in `environment`.
    /// Jinja2 reports these at compile time, so this runs before every render too.
    public func validate(environment: TemplateEnvironment = .standard) throws {
        try Self.forEachExpression(in: nodes) { expression in
            switch expression.kind {
            case let .filter(_, name, _) where !environment.hasFilter(name):
                throw makeSyntaxError("No filter named '\(name)'", at: expression.location)
            case let .test(_, name, _, _) where BuiltinTests.all[name] == nil:
                throw makeSyntaxError("No test named '\(name)'", at: expression.location)
            default:
                break
            }
        }
    }

    /// Names the template reads from the render context (like `jinja2.meta.find_undeclared_variables`).
    /// Variables assigned with `set` or bound by `for`, `loop`, and the global functions
    /// (`range`, `dict`, `namespace`) are not included.
    public var undeclaredVariables: Set<String> {
        var declared = Set<String>()
        var result = Set<String>()
        Self.collect(nodes, declared: &declared, into: &result)
        return result
    }

    /// Converts a pre-Jinja Paperless-ngx format such as `{created_year}/{title}` to template syntax
    /// (`{{ created_year }}/{{ title }}`). Existing `{{ ... }}` placeholders are left alone.
    public static func convertLegacyFormat(_ format: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"(?<!\{)\{(\w*)\}(?!\})"#) else { return format }
        let range = NSRange(format.startIndex..., in: format)
        return regex.stringByReplacingMatches(in: format, range: range, withTemplate: "{{ $1 }}")
    }

    // MARK: Helpers

    static func cleanFilePath(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        var scalars: [Unicode.Scalar] = []
        var skippingWhitespace = false
        for scalar in normalized.unicodeScalars where scalar != "\n" && scalar != "\r" {
            if scalar == "/" {
                while let last = scalars.last, Py.isWhitespace(last) { scalars.removeLast() }
                scalars.append(scalar)
                skippingWhitespace = true
            } else if skippingWhitespace && Py.isWhitespace(scalar) {
                continue
            } else {
                skippingWhitespace = false
                scalars.append(scalar)
            }
        }
        let stripped = PyString.strip(Py.string(scalars), chars: nil)
        return PyString.strip(stripped, chars: "/")
    }

    static func forEachExpression(in nodes: [Node], _ body: (Expression) throws -> Void) rethrows {
        func visit(_ expression: Expression) throws {
            try body(expression)
            for child in expression.children { try visit(child) }
        }
        for node in nodes {
            switch node {
            case .text, .loopControl:
                break
            case .output(let expression):
                try visit(expression)
            case let .ifBlock(branches, otherwise):
                for branch in branches {
                    try visit(branch.condition)
                    try forEachExpression(in: branch.body, body)
                }
                if let otherwise { try forEachExpression(in: otherwise, body) }
            case .forLoop(let loop):
                try visit(loop.iterable)
                if let condition = loop.condition { try visit(condition) }
                try forEachExpression(in: loop.body, body)
                if let otherwise = loop.otherwise { try forEachExpression(in: otherwise, body) }
            case let .set(_, expression, _):
                try visit(expression)
            case let .setBlock(_, body2, _):
                try forEachExpression(in: body2, body)
            }
        }
    }

    private static func collect(_ nodes: [Node], declared: inout Set<String>, into result: inout Set<String>) {
        func visit(_ expression: Expression, _ declared: Set<String>) {
            if case .name(let name) = expression.kind, !declared.contains(name),
               !ValueMethods.globalNames.contains(name) {
                result.insert(name)
            }
            for child in expression.children { visit(child, declared) }
        }
        for node in nodes {
            switch node {
            case .text, .loopControl:
                break
            case .output(let expression):
                visit(expression, declared)
            case let .ifBlock(branches, otherwise):
                for branch in branches {
                    visit(branch.condition, declared)
                    collect(branch.body, declared: &declared, into: &result)
                }
                if let otherwise { collect(otherwise, declared: &declared, into: &result) }
            case .forLoop(let loop):
                visit(loop.iterable, declared)
                var inner = declared.union(loop.target.names).union(["loop"])
                if let condition = loop.condition { visit(condition, inner) }
                collect(loop.body, declared: &inner, into: &result)
                if let otherwise = loop.otherwise {
                    var outer = declared
                    collect(otherwise, declared: &outer, into: &result)
                }
            case let .set(target, expression, _):
                visit(expression, declared)
                if case .attribute(let name, _) = target, !declared.contains(name) { result.insert(name) }
                declared.formUnion(target.names)
            case let .setBlock(target, body, _):
                var inner = declared
                collect(body, declared: &inner, into: &result)
                declared.formUnion(target.names)
            }
        }
    }
}
