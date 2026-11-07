import Foundation

/// A value passed into, or produced by, a template.
///
/// Values behave like the Python values that Jinja2 works with: truthiness, `str()`
/// rendering, equality and ordering follow Python rules.
public enum TemplateValue: Sendable, Hashable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    /// Python `None`. Renders as `None`.
    case none
    /// A missing variable, attribute or item. Renders as "" unless the environment is strict.
    case undefined
    case array([TemplateValue])
    /// A mapping. Iteration, `items()` and rendering use sorted key order, because
    /// Swift dictionaries do not keep insertion order.
    case dict([String: TemplateValue])
    /// A date or date-time. With `includesTime == false` it behaves like a Python `date`;
    /// otherwise like an aware Python `datetime`. Calendar fields (year, hour, ...) are
    /// read in `timeZone`, and the UTC offset of `timeZone` is printed.
    case date(Date, includesTime: Bool, timeZone: TimeZone)
    /// A string that is false in conditions, like Paperless-ngx's `PlaceholderString` for missing
    /// metadata (`"-none-"`). It renders as its text, `is string` is true, string filters and methods
    /// see its text, and it compares equal to its text. The text `"-none-"` also equals `"none"`.
    case placeholder(String)
    /// A plain Python object, such as Paperless-ngx's `MatchingModelContext`. It prints as its
    /// text, its attributes are readable with `obj.name` or `obj["name"]`, and it is always true.
    /// It is not iterable, has no length and equals only an identical object.
    case object(TemplateObject)
}

/// The payload of `TemplateValue.object`.
public struct TemplateObject: Sendable, Hashable {
    /// The Python class name, used in error messages and `repr()`.
    public var typeName: String
    /// What `str()` returns.
    public var text: String
    public var attributes: [String: TemplateValue]

    public init(typeName: String, text: String, attributes: [String: TemplateValue]) {
        self.typeName = typeName
        self.text = text
        self.attributes = attributes
    }
}

extension TemplateValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension TemplateValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension TemplateValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}

extension TemplateValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

extension TemplateValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: TemplateValue...) { self = .array(elements) }
}

extension TemplateValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, TemplateValue)...) {
        self = .dict(Dictionary(elements, uniquingKeysWith: { _, last in last }))
    }
}

extension TemplateValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .none }
}

extension TemplateValue: CustomStringConvertible {
    /// The Python `str()` of the value, as a template prints it. Undefined gives "".
    public var description: String { Py.str(self) }
}

extension TemplateValue {
    /// Python truthiness: empty strings, empty collections, zero, `None` and undefined are false.
    public var isTruthy: Bool { Py.truthy(self) }

    /// True for `.undefined`.
    public var isUndefined: Bool {
        if case .undefined = self { return true }
        return false
    }

    /// The Python `repr()` of the value, as used inside rendered lists and dicts.
    public var pythonRepr: String { Py.repr(self) }

    /// `.placeholder` as a plain `.string`; other values unchanged.
    var plain: TemplateValue {
        if case .placeholder(let text) = self { return .string(text) }
        return self
    }

    /// Wraps an optional string; `nil` becomes `.none`.
    public init(_ value: String?) { self = value.map(TemplateValue.string) ?? .none }

    /// Wraps an optional integer; `nil` becomes `.none`.
    public init(_ value: Int?) { self = value.map(TemplateValue.int) ?? .none }
}
