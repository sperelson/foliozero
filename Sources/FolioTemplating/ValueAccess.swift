import Foundation

/// Attribute and item lookup with Jinja2 rules: `a.b` falls back to `a["b"]`, `a["b"]` falls back
/// to `a.b`, and anything missing is undefined.
enum ValueAccess {
    static func attribute(_ value: TemplateValue, _ name: String) -> TemplateValue {
        switch value.plain {
        case .dict(let dict):
            return dict[name] ?? .undefined
        case .object(let object):
            return object.attributes[name] ?? .undefined
        case let .date(date, _, timeZone):
            let parts = DateSupport.parts(date, timeZone)
            switch name {
            case "year": return .int(parts.year)
            case "month": return .int(parts.month)
            case "day": return .int(parts.day)
            case "hour": return .int(parts.hour)
            case "minute": return .int(parts.minute)
            case "second": return .int(parts.second)
            case "microsecond": return .int(parts.microsecond)
            default: return .undefined
            }
        default:
            return .undefined
        }
    }

    static func item(_ value: TemplateValue, _ key: TemplateValue) -> TemplateValue {
        switch (value.plain, key.plain) {
        case let (.dict(dict), .string(name)):
            return dict[name] ?? .undefined
        case (.array(let items), .int), (.array(let items), .bool):
            guard let index = resolveIndex(key, count: items.count) else { return .undefined }
            return items[index]
        case (.string(let s), .int), (.string(let s), .bool):
            let scalars = Py.scalars(s)
            guard let index = resolveIndex(key, count: scalars.count) else { return .undefined }
            return .string(String(scalars[index]))
        case (_, .string(let name)):
            return attribute(value, name)
        default:
            return .undefined
        }
    }

    private static func resolveIndex(_ key: TemplateValue, count: Int) -> Int? {
        guard case .int(var index)? = Py.number(key) else { return nil }
        if index < 0 { index += count }
        return (0..<count).contains(index) ? index : nil
    }

    /// Follows a dotted path such as "owner.name" or "tags.0" (Jinja's `attribute=` arguments).
    static func path(_ value: TemplateValue, _ path: String) -> TemplateValue {
        var current = value
        for part in path.split(separator: ".", omittingEmptySubsequences: false) {
            if let index = Int(part) {
                current = item(current, .int(index))
            } else {
                current = item(current, .string(String(part)))
            }
        }
        return current
    }

    /// Python slice semantics for lists and strings.
    static func slice(
        _ value: TemplateValue,
        start: TemplateValue,
        stop: TemplateValue,
        step: TemplateValue
    ) throws -> TemplateValue {
        func bound(_ v: TemplateValue) throws -> Int? {
            switch v {
            case .none, .undefined: return nil
            default:
                guard case .int(let i)? = Py.number(v) else {
                    throw RuntimeFailure("slice indices must be integers or None")
                }
                return i
            }
        }
        let stepValue = try bound(step) ?? 1
        guard stepValue != 0 else { throw RuntimeFailure("slice step cannot be zero") }

        func indices(count: Int) throws -> [Int] {
            func adjust(_ index: Int?, defaultValue: Int, lower: Int, upper: Int) -> Int {
                guard var index else { return defaultValue }
                if index < 0 { index += count }
                return min(max(index, lower), upper)
            }
            var result: [Int] = []
            if stepValue > 0 {
                var i = adjust(try bound(start), defaultValue: 0, lower: 0, upper: count)
                let end = adjust(try bound(stop), defaultValue: count, lower: 0, upper: count)
                while i < end { result.append(i); i += stepValue }
            } else {
                var i = adjust(try bound(start), defaultValue: count - 1, lower: -1, upper: count - 1)
                let end = adjust(try bound(stop), defaultValue: -1, lower: -1, upper: count - 1)
                while i > end { result.append(i); i += stepValue }
            }
            return result
        }

        switch value.plain {
        case .array(let items):
            return .array(try indices(count: items.count).map { items[$0] })
        case .string(let s):
            let scalars = Py.scalars(s)
            return .string(Py.string(try indices(count: scalars.count).map { scalars[$0] }))
        case .undefined:
            return .undefined
        default:
            throw RuntimeFailure("'\(Py.typeName(value))' object is not subscriptable")
        }
    }
}
