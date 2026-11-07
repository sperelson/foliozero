import Foundation

/// Filters, tests and limits used when rendering a template.
public struct TemplateEnvironment: Sendable {
    /// A filter: `value | name(args..., key=value...)`.
    public typealias Filter = @Sendable (
        _ value: TemplateValue,
        _ args: [TemplateValue],
        _ kwargs: [String: TemplateValue]
    ) throws -> TemplateValue

    typealias FilterImplementation = @Sendable (FilterCall) throws -> TemplateValue

    var filters: [String: FilterImplementation]

    /// When false (the default), undefined values render as "", are false, and iterate as empty.
    /// When true, using an undefined value throws, as with Jinja2's `StrictUndefined`.
    /// Tests such as `is defined` and the `default` filter work in both modes.
    public var strictUndefined = false

    /// Maximum size of the rendered output, in UTF-8 bytes. Every string built by concatenation,
    /// repetition, formatting, `join`, `replace`, padding or a `set` block is held to the same limit.
    /// In total, filters, methods and operators may produce at most 1024 times this many bytes per
    /// render, which bounds memory and time for templates that build data in loops.
    public var maxOutputLength = 64_000

    /// Maximum number of loop iterations per render, summed over all loops. It also caps the
    /// size of `range()` results and of lists built during the render.
    public var maxLoopIterations = 10_000

    /// The time zone for date strings without a UTC offset (for example "2024-01-15" passed to
    /// the `datetime` or `localize_date` filter). `.date` values always use their own time zone.
    public var timeZone: TimeZone = .current

    /// Jinja2 `trim_blocks`: remove the first newline after a block or comment tag.
    public var trimBlocks = false

    /// Jinja2 `lstrip_blocks`: remove spaces and tabs before a block or comment tag at the start of a line.
    public var lstripBlocks = false

    /// Jinja2 `keep_trailing_newline`: when false, one trailing newline of the template is dropped.
    public var keepTrailingNewline = false

    /// An environment with the built-in Jinja2 filters and tests.
    public init() {
        filters = BuiltinFilters.all
    }

    /// The built-in Jinja2 filters and tests, with Jinja2's default settings.
    public static var standard: TemplateEnvironment { TemplateEnvironment() }

    /// The Paperless-ngx environment: the built-ins plus `slugify`, `datetime`, `localize_date` and
    /// `get_cf_value`, with Paperless-ngx's settings (`trim_blocks`, `lstrip_blocks`, strict undefined).
    public static var paperless: TemplateEnvironment {
        var environment = TemplateEnvironment()
        for (name, filter) in PaperlessFilters.all {
            environment.filters[name] = filter
        }
        environment.strictUndefined = true
        environment.trimBlocks = true
        environment.lstripBlocks = true
        return environment
    }

    /// Adds a filter, or replaces one with the same name (built-ins included).
    public mutating func registerFilter(_ name: String, _ filter: @escaping Filter) {
        filters[name] = { call in try filter(call.value, call.args, call.kwargs) }
    }

    /// True when a filter with this name is available.
    public func hasFilter(_ name: String) -> Bool {
        filters[name] != nil
    }

    /// The names of all available filters, sorted.
    public var filterNames: [String] {
        filters.keys.sorted()
    }

    /// The names of all available tests (`value is name`), sorted.
    public var testNames: [String] {
        BuiltinTests.all.keys.sorted()
    }

    var limits: ValueLimits {
        ValueLimits(maxStringLength: maxOutputLength, maxListLength: maxLoopIterations)
    }

    var whitespace: WhitespaceOptions {
        WhitespaceOptions(trimBlocks: trimBlocks, lstripBlocks: lstripBlocks, keepTrailingNewline: keepTrailingNewline)
    }
}

/// Binds Python-style call arguments to named parameters.
struct ArgumentBinder {
    /// For error messages, for example "Filter 'replace'".
    var owner: String
    var args: [TemplateValue]
    var kwargs: [String: TemplateValue]

    /// Returns one value per parameter. A `nil` default marks a required parameter.
    func bind(_ parameters: [(name: String, defaultValue: TemplateValue?)]) throws -> [TemplateValue] {
        if args.count > parameters.count {
            throw RuntimeFailure("\(owner) takes at most \(parameters.count) argument(s) (\(args.count) given)")
        }
        let names = Set(parameters.map(\.name))
        for key in kwargs.keys.sorted() where !names.contains(key) {
            throw RuntimeFailure("\(owner) got an unexpected keyword argument '\(key)'")
        }
        var values: [TemplateValue] = []
        for (index, parameter) in parameters.enumerated() {
            let keyword = kwargs[parameter.name]
            if index < args.count {
                if keyword != nil {
                    throw RuntimeFailure("\(owner) got multiple values for argument '\(parameter.name)'")
                }
                values.append(args[index])
            } else if let keyword {
                values.append(keyword)
            } else if let defaultValue = parameter.defaultValue {
                values.append(defaultValue)
            } else {
                throw RuntimeFailure("\(owner) missing required argument '\(parameter.name)'")
            }
        }
        return values
    }
}

/// One filter application.
struct FilterCall {
    var name: String
    var value: TemplateValue
    var args: [TemplateValue]
    var kwargs: [String: TemplateValue]
    var environment: TemplateEnvironment

    var limits: ValueLimits { environment.limits }

    func bind(_ parameters: [(name: String, defaultValue: TemplateValue?)]) throws -> [TemplateValue] {
        try ArgumentBinder(owner: "Filter '\(name)'", args: args, kwargs: kwargs).bind(parameters)
    }

    func noArguments() throws {
        _ = try bind([])
    }
}
