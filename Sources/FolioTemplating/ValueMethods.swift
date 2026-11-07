import Foundation

/// Method calls on values (`'a'.upper()`, `d.items()`, `date.strftime(...)`), plus global functions.
enum ValueMethods {
    static func call(
        _ base: TemplateValue,
        _ name: String,
        args: [TemplateValue],
        kwargs: [String: TemplateValue],
        environment: TemplateEnvironment
    ) throws -> TemplateValue {
        let typeName = Py.typeName(base)
        let binder = ArgumentBinder(owner: "Method '\(typeName).\(name)'", args: args, kwargs: kwargs)
        let limits = environment.limits
        let result: TemplateValue? = switch base.plain {
        case .string(let s): try stringMethod(s, name, binder, limits)
        case .dict(let dict): try dictMethod(dict, name, binder)
        case .array(let items): try listMethod(items, name, binder)
        case .date: try dateMethod(PyDateTime(base)!, name, binder, limits)
        default: nil
        }
        guard let result else { throw RuntimeFailure("'\(typeName)' object has no method '\(name)'") }
        return result
    }

    private static func optionalString(_ value: TemplateValue) -> String? {
        if case .none = value { return nil }
        return Py.str(value)
    }

    private static func stringMethod(
        _ s: String,
        _ name: String,
        _ binder: ArgumentBinder,
        _ limits: ValueLimits
    ) throws -> TemplateValue? {
        switch name {
        case "lower":
            _ = try binder.bind([])
            return .string(s.lowercased())
        case "upper":
            _ = try binder.bind([])
            return .string(s.uppercased())
        case "title":
            _ = try binder.bind([])
            return .string(PyString.title(s))
        case "capitalize":
            _ = try binder.bind([])
            return .string(PyString.capitalize(s))
        case "strip", "lstrip", "rstrip":
            let chars = optionalString(try binder.bind([("chars", TemplateValue.none)])[0])
            return .string(PyString.strip(s, chars: chars, leading: name != "rstrip", trailing: name != "lstrip"))
        case "replace":
            let bound = try binder.bind([("old", nil), ("new", nil), ("count", -1)])
            return .string(try PyString.replace(
                s, old: Py.str(bound[0]), new: Py.str(bound[1]), count: try Py.integer(bound[2]), limits: limits
            ))
        case "startswith", "endswith":
            let affix = try binder.bind([("prefix", nil)])[0]
            let candidates: [TemplateValue] = if case .array(let items) = affix { items } else { [affix] }
            let scalars = Py.scalars(s)
            return .bool(try candidates.contains { candidate in
                guard case .string(let text) = candidate else {
                    throw RuntimeFailure("\(name) first arg must be str or a tuple of str, not \(Py.typeName(candidate))")
                }
                let needle = Py.scalars(text)
                return name == "startswith" ? scalars.starts(with: needle) : scalars.reversed().starts(with: needle.reversed())
            })
        case "split":
            let bound = try binder.bind([("sep", TemplateValue.none), ("maxsplit", -1)])
            let parts = try PyString.split(s, separator: optionalString(bound[0]), maxSplit: try Py.integer(bound[1]))
            return .array(try limits.check(parts.map(TemplateValue.string)))
        case "splitlines":
            _ = try binder.bind([])
            return .array(PyString.splitLines(s).map(TemplateValue.string))
        case "join":
            let items = try Py.iterate(try binder.bind([("iterable", nil)])[0])
            let parts = try items.map { item -> String in
                guard case .string(let text) = item else {
                    throw RuntimeFailure("sequence item: expected str instance, \(Py.typeName(item)) found")
                }
                return text
            }
            return .string(try limits.check(parts.joined(separator: s)))
        case "zfill":
            let width = try Py.integer(try binder.bind([("width", nil)])[0])
            try limits.checkStringLength(width)
            var scalars = Py.scalars(s)
            guard width > scalars.count else { return .string(s) }
            let fill = Array(repeating: Unicode.Scalar("0"), count: width - scalars.count)
            let insertAt = scalars.first == "+" || scalars.first == "-" ? 1 : 0
            scalars.insert(contentsOf: fill, at: insertAt)
            return .string(Py.string(scalars))
        case "isdigit", "isalpha", "isalnum", "isspace", "islower", "isupper":
            _ = try binder.bind([])
            let scalars = Py.scalars(s)
            func isDigit(_ scalar: Unicode.Scalar) -> Bool {
                scalar.properties.numericType == .decimal || scalar.properties.numericType == .digit
            }
            func isAlpha(_ scalar: Unicode.Scalar) -> Bool {
                switch scalar.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
                default: false
                }
            }
            switch name {
            case "isdigit": return .bool(!scalars.isEmpty && scalars.allSatisfy(isDigit))
            case "isalpha": return .bool(!scalars.isEmpty && scalars.allSatisfy(isAlpha))
            case "isalnum":
                return .bool(!scalars.isEmpty && scalars.allSatisfy { isAlpha($0) || $0.properties.numericType != nil })
            case "isspace": return .bool(!scalars.isEmpty && scalars.allSatisfy(Py.isWhitespace))
            case "islower": return .bool(PyString.hasOnlyCase(s, lower: true))
            default: return .bool(PyString.hasOnlyCase(s, lower: false))
            }
        case "count":
            let needle = Py.scalars(Py.str(try binder.bind([("sub", nil)])[0]))
            let scalars = Py.scalars(s)
            if needle.isEmpty { return .int(scalars.count + 1) }
            var count = 0
            var index = 0
            while let found = Py.find(needle, in: scalars, from: index) {
                count += 1
                index = found + needle.count
            }
            return .int(count)
        case "find":
            let needle = Py.scalars(Py.str(try binder.bind([("sub", nil)])[0]))
            return .int(Py.find(needle, in: Py.scalars(s)) ?? -1)
        default:
            return nil
        }
    }

    private static func dictMethod(
        _ dict: [String: TemplateValue],
        _ name: String,
        _ binder: ArgumentBinder
    ) throws -> TemplateValue? {
        let keys = Py.sortedKeys(dict)
        switch name {
        case "items":
            _ = try binder.bind([])
            return .array(keys.map { .array([.string($0), dict[$0]!]) })
        case "keys":
            _ = try binder.bind([])
            return .array(keys.map(TemplateValue.string))
        case "values":
            _ = try binder.bind([])
            return .array(keys.map { dict[$0]! })
        case "get":
            let bound = try binder.bind([("key", nil), ("default", TemplateValue.none)])
            guard case .string(let key) = bound[0] else { return bound[1] }
            return dict[key] ?? bound[1]
        default:
            return nil
        }
    }

    private static func listMethod(
        _ items: [TemplateValue],
        _ name: String,
        _ binder: ArgumentBinder
    ) throws -> TemplateValue? {
        switch name {
        case "count":
            let value = try binder.bind([("value", nil)])[0]
            return .int(items.filter { Py.equals($0, value) }.count)
        case "index":
            let value = try binder.bind([("value", nil)])[0]
            guard let index = items.firstIndex(where: { Py.equals($0, value) }) else {
                throw RuntimeFailure("\(Py.repr(value)) is not in list")
            }
            return .int(index)
        default:
            return nil
        }
    }

    private static func dateMethod(
        _ value: PyDateTime,
        _ name: String,
        _ binder: ArgumentBinder,
        _ limits: ValueLimits
    ) throws -> TemplateValue? {
        switch name {
        case "strftime":
            let format = Py.str(try binder.bind([("format", nil)])[0])
            return .string(try DateSupport.strftime(format, value, limits: limits))
        case "isoformat":
            _ = try binder.bind([])
            return .string(DateSupport.isoFormat(value))
        case "weekday":
            _ = try binder.bind([])
            return .int(DateSupport.parts(value.date, value.timeZone).weekday)
        case "isoweekday":
            _ = try binder.bind([])
            return .int(DateSupport.parts(value.date, value.timeZone).weekday + 1)
        case "date":
            _ = try binder.bind([])
            let start = DateSupport.startOfDay(value.date, value.timeZone)
            return .date(start, includesTime: false, timeZone: value.timeZone)
        default:
            return nil
        }
    }

    // MARK: Global functions

    static let globalNames: Set<String> = ["range", "dict", "namespace"]

    static func callGlobal(
        _ name: String,
        args: [TemplateValue],
        kwargs: [String: TemplateValue],
        environment: TemplateEnvironment
    ) throws -> TemplateValue? {
        switch name {
        case "range":
            if !kwargs.isEmpty { throw RuntimeFailure("range() takes no keyword arguments") }
            let numbers = try args.map { try Py.integer($0) }
            let (start, stop, step): (Int, Int, Int)
            switch numbers.count {
            case 1: (start, stop, step) = (0, numbers[0], 1)
            case 2: (start, stop, step) = (numbers[0], numbers[1], 1)
            case 3: (start, stop, step) = (numbers[0], numbers[1], numbers[2])
            default: throw RuntimeFailure("range expected 1 to 3 arguments, got \(numbers.count)")
            }
            guard step != 0 else { throw RuntimeFailure("range() arg 3 must not be zero") }
            let span = step > 0 ? Double(stop) - Double(start) : Double(start) - Double(stop)
            let count = span <= 0 ? 0 : Int((span / Double(abs(step))).rounded(.up))
            if count > environment.maxLoopIterations {
                throw RuntimeFailure(
                    "range() of \(count) items exceeds the limit of \(environment.maxLoopIterations) loop iterations"
                )
            }
            return .array((0..<count).map { .int(start + $0 * step) })
        case "dict", "namespace":
            if !args.isEmpty { throw RuntimeFailure("\(name)() takes keyword arguments only") }
            return .dict(kwargs)
        default:
            return nil
        }
    }
}
