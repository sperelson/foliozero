import Foundation

/// Size limits that apply to values built during a render.
struct ValueLimits {
    /// Maximum length of any produced string, in UTF-8 bytes.
    var maxStringLength: Int
    /// Maximum number of elements in any produced list.
    var maxListLength: Int

    func check(_ string: String) throws -> String {
        if string.utf8.count > maxStringLength {
            throw RuntimeFailure("String result exceeds the maximum length of \(maxStringLength) bytes")
        }
        return string
    }

    func checkStringLength(_ length: Int) throws {
        if length > maxStringLength {
            throw RuntimeFailure("String result exceeds the maximum length of \(maxStringLength) bytes")
        }
    }

    func check(_ list: [TemplateValue]) throws -> [TemplateValue] {
        try checkListLength(list.count)
        return list
    }

    func checkListLength(_ count: Int) throws {
        if count > maxListLength {
            throw RuntimeFailure("List result exceeds the maximum length of \(maxListLength) items")
        }
    }
}

enum ComparisonOperator: String, Sendable {
    case equal = "=="
    case notEqual = "!="
    case less = "<"
    case lessOrEqual = "<="
    case greater = ">"
    case greaterOrEqual = ">="
    case `in` = "in"
    case notIn = "not in"
}

/// A number viewed through Python's numeric tower (bool is an int).
enum PyNumber {
    case int(Int)
    case double(Double)

    var asDouble: Double {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        }
    }
}

/// Python value semantics for `TemplateValue`.
enum Py {
    static func typeName(_ value: TemplateValue) -> String {
        switch value {
        case .string, .placeholder: "str"
        case .int: "int"
        case .double: "float"
        case .bool: "bool"
        case .none: "NoneType"
        case .undefined: "Undefined"
        case .array: "list"
        case .dict: "dict"
        case .date(_, let includesTime, _): includesTime ? "datetime" : "date"
        case .object(let object): object.typeName
        }
    }

    static func number(_ value: TemplateValue) -> PyNumber? {
        switch value {
        case .int(let i): .int(i)
        case .double(let d): .double(d)
        case .bool(let b): .int(b ? 1 : 0)
        default: nil
        }
    }

    static func truthy(_ value: TemplateValue) -> Bool {
        switch value {
        case .string(let s): !s.isEmpty
        case .int(let i): i != 0
        case .double(let d): d != 0
        case .bool(let b): b
        case .none, .undefined, .placeholder: false
        case .array(let a): !a.isEmpty
        case .dict(let d): !d.isEmpty
        case .date, .object: true
        }
    }

    // MARK: str() and repr()

    static func str(_ value: TemplateValue) -> String {
        switch value {
        case .string(let s), .placeholder(let s): s
        case .int(let i): String(i)
        case .double(let d): floatRepr(d)
        case .bool(let b): b ? "True" : "False"
        case .none: "None"
        case .undefined: ""
        case .array(let items): "[" + items.map(repr).joined(separator: ", ") + "]"
        case .dict(let dict):
            "{" + sortedKeys(dict).map { reprString($0) + ": " + repr(dict[$0]!) }.joined(separator: ", ") + "}"
        case let .date(date, includesTime, timeZone):
            DateSupport.pythonString(date, includesTime: includesTime, timeZone: timeZone)
        case .object(let object): object.text
        }
    }

    static func repr(_ value: TemplateValue) -> String {
        switch value {
        case .string(let s), .placeholder(let s): reprString(s)
        case .undefined: "Undefined"
        case let .date(date, includesTime, timeZone):
            DateSupport.pythonRepr(date, includesTime: includesTime, timeZone: timeZone)
        case .object(let object): "<\(object.typeName) object>"
        default: str(value)
        }
    }

    /// Python `repr(float)`: the shortest string that round-trips.
    static func floatRepr(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        // Swift's description already uses Python's shortest round-trip digits and
        // switches to exponent notation at the same thresholds (1e-05, 1e+16).
        return value.description
    }

    static func reprString(_ string: String) -> String {
        let quote: Unicode.Scalar = string.contains("'") && !string.contains("\"") ? "\"" : "'"
        var out = String.UnicodeScalarView()
        out.append(quote)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": out.append(contentsOf: "\\\\".unicodeScalars)
            case "\n": out.append(contentsOf: "\\n".unicodeScalars)
            case "\r": out.append(contentsOf: "\\r".unicodeScalars)
            case "\t": out.append(contentsOf: "\\t".unicodeScalars)
            case quote: out.append("\\"); out.append(quote)
            default:
                if isPrintable(scalar) {
                    out.append(scalar)
                } else if scalar.value <= 0xFF {
                    out.append(contentsOf: "\\x\(hex(scalar.value, width: 2))".unicodeScalars)
                } else if scalar.value <= 0xFFFF {
                    out.append(contentsOf: "\\u\(hex(scalar.value, width: 4))".unicodeScalars)
                } else {
                    out.append(contentsOf: "\\U\(hex(scalar.value, width: 8))".unicodeScalars)
                }
            }
        }
        out.append(quote)
        return String(out)
    }

    private static func hex(_ value: UInt32, width: Int) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, width - digits.count)) + digits
    }

    /// Python `str.isprintable()` for one character.
    static func isPrintable(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == " " { return true }
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .privateUse, .unassigned,
             .lineSeparator, .paragraphSeparator, .spaceSeparator:
            return false
        default:
            return true
        }
    }

    // MARK: Strings as Python sees them (sequences of code points)

    static func scalars(_ string: String) -> [Unicode.Scalar] {
        Array(string.unicodeScalars)
    }

    static func string(_ scalars: some Sequence<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars)
        return String(view)
    }

    static func length(of string: String) -> Int {
        string.unicodeScalars.count
    }

    /// Python `str.isspace()` for one character.
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A,
             0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            true
        default:
            false
        }
    }

    /// Python regex `\w` for one character (Unicode mode).
    static func isWordCharacter(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "_" { return true }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber:
            return true
        default:
            return false
        }
    }

    static func lessThan(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
    }

    static func sortedKeys(_ dict: [String: TemplateValue]) -> [String] {
        dict.keys.sorted(by: lessThan)
    }

    // MARK: Equality and ordering

    static func equals(_ a: TemplateValue, _ b: TemplateValue) -> Bool {
        switch (a, b) {
        case let (.placeholder(x), .placeholder(y)):
            return x.unicodeScalars.elementsEqual(y.unicodeScalars)
        case let (.placeholder(text), .string(other)), let (.string(other), .placeholder(text)):
            return other.unicodeScalars.elementsEqual(text.unicodeScalars) || (other == "none" && text == "-none-")
        case let (.string(x), .string(y)):
            return x.unicodeScalars.elementsEqual(y.unicodeScalars)
        case (.none, .none), (.undefined, .undefined):
            return true
        case let (.array(x), .array(y)):
            return x.count == y.count && zip(x, y).allSatisfy { equals($0, $1) }
        case let (.dict(x), .dict(y)):
            guard x.count == y.count else { return false }
            return x.allSatisfy { key, value in y[key].map { equals(value, $0) } ?? false }
        case let (.object(x), .object(y)):
            return x == y
        case let (.date(d1, t1, z1), .date(d2, t2, z2)):
            guard t1 == t2 else { return false }
            if t1 { return d1 == d2 }
            return DateSupport.dayOrdinal(d1, z1) == DateSupport.dayOrdinal(d2, z2)
        default:
            guard let x = number(a), let y = number(b) else { return false }
            switch (x, y) {
            case let (.int(i), .int(j)): return i == j
            default: return x.asDouble == y.asDouble
            }
        }
    }

    /// Evaluates an ordering operator (`<`, `<=`, `>`, `>=`) with Python rules.
    static func order(_ op: ComparisonOperator, _ a: TemplateValue, _ b: TemplateValue) throws -> Bool {
        func apply<T: Comparable>(_ x: T, _ y: T) -> Bool {
            switch op {
            case .less: x < y
            case .lessOrEqual: x <= y
            case .greater: x > y
            default: x >= y
            }
        }
        func applyOrdering(_ ordering: Int) -> Bool { apply(ordering, 0) }

        switch (a.plain, b.plain) {
        case let (.string(x), .string(y)):
            let ordering = lessThan(x, y) ? -1 : (lessThan(y, x) ? 1 : 0)
            return applyOrdering(ordering)
        case let (.array(x), .array(y)):
            for (left, right) in zip(x, y) where !equals(left, right) {
                return try order(op, left, right)
            }
            return apply(x.count, y.count)
        case let (.date(d1, t1, z1), .date(d2, t2, z2)):
            if !t1 && !t2 {
                return apply(DateSupport.dayOrdinal(d1, z1), DateSupport.dayOrdinal(d2, z2))
            }
            return apply(d1, d2)
        default:
            if let x = number(a), let y = number(b) {
                switch (x, y) {
                case let (.int(i), .int(j)): return apply(i, j)
                default: return apply(x.asDouble, y.asDouble)
                }
            }
            throw RuntimeFailure(
                "'\(op.rawValue)' not supported between instances of '\(typeName(a))' and '\(typeName(b))'"
            )
        }
    }

    /// Python `item in container`.
    static func contains(_ container: TemplateValue, _ item: TemplateValue) throws -> Bool {
        switch container.plain {
        case .string(let s):
            guard case .string(let needle) = item.plain else {
                throw RuntimeFailure("'in <string>' requires string as left operand, not \(typeName(item))")
            }
            return find(scalars(needle), in: scalars(s)) != nil
        case .array(let items):
            return items.contains { equals($0, item) }
        case .dict(let dict):
            guard case .string(let key) = item.plain else { return false }
            return dict[key] != nil
        case .undefined:
            return false
        default:
            throw RuntimeFailure("argument of type '\(typeName(container))' is not iterable")
        }
    }

    /// The index of the first occurrence of `needle` in `haystack`, starting at `start`.
    static func find(_ needle: [Unicode.Scalar], in haystack: [Unicode.Scalar], from start: Int = 0) -> Int? {
        if needle.isEmpty { return start <= haystack.count ? start : nil }
        guard haystack.count >= needle.count else { return nil }
        var index = start
        while index <= haystack.count - needle.count {
            if haystack[index] == needle[0], haystack[index..<(index + needle.count)].elementsEqual(needle) {
                return index
            }
            index += 1
        }
        return nil
    }

    // MARK: Iteration

    /// The items a Python `for` loop would produce.
    static func iterate(_ value: TemplateValue) throws -> [TemplateValue] {
        switch value.plain {
        case .array(let items): return items
        case .dict(let dict): return sortedKeys(dict).map(TemplateValue.string)
        case .string(let s): return s.unicodeScalars.map { .string(String($0)) }
        case .undefined: return []
        default: throw RuntimeFailure("'\(typeName(value))' object is not iterable")
        }
    }

    /// Python `len()`.
    static func len(_ value: TemplateValue) throws -> Int {
        switch value.plain {
        case .string(let s): return length(of: s)
        case .array(let items): return items.count
        case .dict(let dict): return dict.count
        case .undefined: return 0
        default: throw RuntimeFailure("object of type '\(typeName(value))' has no len()")
        }
    }

    // MARK: Arithmetic

    static func integer(_ value: TemplateValue, what: String = "") throws -> Int {
        switch value {
        case .int(let i): return i
        case .bool(let b): return b ? 1 : 0
        default:
            throw RuntimeFailure("'\(typeName(value))' object cannot be interpreted as an integer")
        }
    }

    private static func unsupported(_ op: String, _ a: TemplateValue, _ b: TemplateValue) -> RuntimeFailure {
        RuntimeFailure("unsupported operand type(s) for \(op): '\(typeName(a))' and '\(typeName(b))'")
    }

    private static func checked(_ result: (partialValue: Int, overflow: Bool)) throws -> TemplateValue {
        if result.overflow { throw RuntimeFailure("Integer overflow") }
        return .int(result.partialValue)
    }

    static func add(_ a: TemplateValue, _ b: TemplateValue, _ limits: ValueLimits) throws -> TemplateValue {
        switch (a.plain, b.plain) {
        case let (.string(x), .string(y)):
            try limits.checkStringLength(x.utf8.count + y.utf8.count)
            return .string(x + y)
        case let (.array(x), .array(y)):
            try limits.checkListLength(x.count + y.count)
            return .array(x + y)
        default:
            guard let x = number(a), let y = number(b) else { throw unsupported("+", a, b) }
            if case let (.int(i), .int(j)) = (x, y) { return try checked(i.addingReportingOverflow(j)) }
            return .double(x.asDouble + y.asDouble)
        }
    }

    static func subtract(_ a: TemplateValue, _ b: TemplateValue) throws -> TemplateValue {
        guard let x = number(a), let y = number(b) else { throw unsupported("-", a, b) }
        if case let (.int(i), .int(j)) = (x, y) { return try checked(i.subtractingReportingOverflow(j)) }
        return .double(x.asDouble - y.asDouble)
    }

    static func multiply(_ a: TemplateValue, _ b: TemplateValue, _ limits: ValueLimits) throws -> TemplateValue {
        switch (a.plain, b.plain) {
        case (.string(let s), .int), (.string(let s), .bool):
            return try repeatString(s, try integer(b), limits)
        case (.int, .string(let s)), (.bool, .string(let s)):
            return try repeatString(s, try integer(a), limits)
        case (.array(let items), .int), (.array(let items), .bool):
            return try repeatList(items, try integer(b), limits)
        case (.int, .array(let items)), (.bool, .array(let items)):
            return try repeatList(items, try integer(a), limits)
        default:
            guard let x = number(a), let y = number(b) else { throw unsupported("*", a, b) }
            if case let (.int(i), .int(j)) = (x, y) { return try checked(i.multipliedReportingOverflow(by: j)) }
            return .double(x.asDouble * y.asDouble)
        }
    }

    private static func repeatString(_ s: String, _ count: Int, _ limits: ValueLimits) throws -> TemplateValue {
        guard count > 0, !s.isEmpty else { return .string("") }
        let (total, overflow) = s.utf8.count.multipliedReportingOverflow(by: count)
        if overflow { throw RuntimeFailure("String result exceeds the maximum length of \(limits.maxStringLength) bytes") }
        try limits.checkStringLength(total)
        return .string(String(repeating: s, count: count))
    }

    private static func repeatList(_ items: [TemplateValue], _ count: Int, _ limits: ValueLimits) throws -> TemplateValue {
        guard count > 0, !items.isEmpty else { return .array([]) }
        let (total, overflow) = items.count.multipliedReportingOverflow(by: count)
        if overflow { throw RuntimeFailure("List result exceeds the maximum length of \(limits.maxListLength) items") }
        try limits.checkListLength(total)
        var result: [TemplateValue] = []
        result.reserveCapacity(total)
        for _ in 0..<count { result.append(contentsOf: items) }
        return .array(result)
    }

    static func divide(_ a: TemplateValue, _ b: TemplateValue) throws -> TemplateValue {
        guard let x = number(a), let y = number(b) else { throw unsupported("/", a, b) }
        if y.asDouble == 0 { throw RuntimeFailure("division by zero") }
        return .double(x.asDouble / y.asDouble)
    }

    static func floorDivide(_ a: TemplateValue, _ b: TemplateValue) throws -> TemplateValue {
        guard let x = number(a), let y = number(b) else { throw unsupported("//", a, b) }
        if y.asDouble == 0 { throw RuntimeFailure("division by zero") }
        if case let (.int(i), .int(j)) = (x, y) {
            if i == .min && j == -1 { throw RuntimeFailure("Integer overflow") }
            let quotient = i / j
            return .int((i % j != 0 && (i < 0) != (j < 0)) ? quotient - 1 : quotient)
        }
        return .double((x.asDouble / y.asDouble).rounded(.down))
    }

    static func modulo(_ a: TemplateValue, _ b: TemplateValue, _ limits: ValueLimits) throws -> TemplateValue {
        if case .string(let format) = a.plain {
            return .string(try PercentFormat.format(format, operand: b.plain, limits: limits))
        }
        guard let x = number(a), let y = number(b) else { throw unsupported("%", a, b) }
        if y.asDouble == 0 { throw RuntimeFailure("modulo by zero") }
        if case let (.int(i), .int(j)) = (x, y) {
            if j == -1 { return .int(0) }
            let remainder = i % j
            return .int((remainder != 0 && (remainder < 0) != (j < 0)) ? remainder + j : remainder)
        }
        let divisor = y.asDouble
        var remainder = fmod(x.asDouble, divisor)
        if remainder != 0, (divisor < 0) != (remainder < 0) { remainder += divisor }
        return .double(remainder)
    }

    static func power(_ a: TemplateValue, _ b: TemplateValue) throws -> TemplateValue {
        guard let x = number(a), let y = number(b) else { throw unsupported("**", a, b) }
        if case let (.int(base), .int(exponent)) = (x, y), exponent >= 0 {
            var result = 1
            var factor = base
            var remaining = exponent
            while remaining > 0 {
                if remaining & 1 == 1 {
                    let (product, overflow) = result.multipliedReportingOverflow(by: factor)
                    if overflow { throw RuntimeFailure("Integer overflow") }
                    result = product
                }
                remaining >>= 1
                if remaining > 0 {
                    let (square, overflow) = factor.multipliedReportingOverflow(by: factor)
                    if overflow { throw RuntimeFailure("Integer overflow") }
                    factor = square
                }
            }
            return .int(result)
        }
        if x.asDouble == 0 && y.asDouble < 0 {
            throw RuntimeFailure("0.0 cannot be raised to a negative power")
        }
        return .double(pow(x.asDouble, y.asDouble))
    }

    static func negate(_ value: TemplateValue) throws -> TemplateValue {
        switch number(value) {
        case .int(let i)?:
            if i == .min { throw RuntimeFailure("Integer overflow") }
            return .int(-i)
        case .double(let d)?:
            return .double(-d)
        case nil:
            throw RuntimeFailure("bad operand type for unary -: '\(typeName(value))'")
        }
    }

    static func positive(_ value: TemplateValue) throws -> TemplateValue {
        switch number(value) {
        case .int(let i)?: return .int(i)
        case .double(let d)?: return .double(d)
        case nil: throw RuntimeFailure("bad operand type for unary +: '\(typeName(value))'")
        }
    }

    // MARK: Nesting

    /// Deepest list/dict nesting a template may build. Rendering, comparing and hashing values
    /// recurse once per level.
    static let maxValueDepth = 100

    /// Throws when `value` is nested deeper than `maxValueDepth`. Iterative, so it is safe on any input.
    static func checkDepth(_ value: TemplateValue) throws {
        var pending: [(value: TemplateValue, depth: Int)] = [(value, 1)]
        while let (current, depth) = pending.popLast() {
            let children: [TemplateValue]
            switch current {
            case .array(let items): children = items
            case .dict(let dict): children = Array(dict.values)
            default: continue
            }
            if depth > maxValueDepth {
                throw RuntimeFailure("Value is nested too deeply (more than \(maxValueDepth) levels)")
            }
            for child in children {
                switch child {
                case .array, .dict: pending.append((child, depth + 1))
                default: break
                }
            }
        }
    }

    // MARK: Hashing for `unique`

    /// A key under which Python-equal values collide (1, 1.0 and True; equal strings).
    static func hashKey(_ value: TemplateValue) -> TemplateValue {
        switch value {
        case .bool(let b): return .int(b ? 1 : 0)
        case .double(let d):
            if d.rounded() == d, let i = Int(exactly: d) { return .int(i) }
            return value
        case .placeholder(let s): return .string(s)
        case .array(let items): return .array(items.map(hashKey))
        case .dict(let dict): return .dict(dict.mapValues(hashKey))
        default: return value
        }
    }
}
