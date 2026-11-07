import Foundation

/// Jinja2's built-in filters.
enum BuiltinFilters {
    static let all: [String: TemplateEnvironment.FilterImplementation] = [
        "abs": abs,
        "attr": attr,
        "capitalize": capitalize,
        "center": center,
        "count": length,
        "d": defaultValue,
        "default": defaultValue,
        "dictsort": dictsort,
        "e": escape,
        "escape": escape,
        "first": first,
        "float": float,
        "forceescape": escape,
        "format": format,
        "indent": indent,
        "int": int,
        "items": items,
        "join": join,
        "last": last,
        "length": length,
        "list": list,
        "lower": lower,
        "map": map,
        "max": max,
        "min": min,
        "reject": reject,
        "rejectattr": rejectattr,
        "replace": replace,
        "reverse": reverse,
        "round": round,
        "safe": safe,
        "select": select,
        "selectattr": selectattr,
        "sort": sort,
        "string": string,
        "striptags": striptags,
        "sum": sum,
        "title": title,
        "trim": trim,
        "truncate": truncate,
        "unique": unique,
        "upper": upper,
        "urlencode": urlencode,
        "wordcount": wordcount,
    ]

    // MARK: Strings

    static func lower(_ call: FilterCall) throws -> TemplateValue {
        try call.noArguments()
        return .string(Py.str(call.value).lowercased())
    }

    static func upper(_ call: FilterCall) throws -> TemplateValue {
        try call.noArguments()
        return .string(Py.str(call.value).uppercased())
    }

    /// Jinja's `title`: capitalise each word, where words start after `-`, whitespace or an opening bracket.
    static func title(_ call: FilterCall) throws -> TemplateValue {
        try call.noArguments()
        func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
            Py.isWhitespace(scalar) || "-({[<".unicodeScalars.contains(scalar)
        }
        var result = ""
        var word: [Unicode.Scalar] = []
        func flush() {
            guard let first = word.first else { return }
            result += String(first).uppercased() + Py.string(word.dropFirst()).lowercased()
            word = []
        }
        for scalar in Py.str(call.value).unicodeScalars {
            if isSeparator(scalar) {
                flush()
                result.unicodeScalars.append(scalar)
            } else {
                word.append(scalar)
            }
        }
        flush()
        return .string(result)
    }

    static func capitalize(_ call: FilterCall) throws -> TemplateValue {
        try call.noArguments()
        return .string(PyString.capitalize(Py.str(call.value)))
    }

    static func trim(_ call: FilterCall) throws -> TemplateValue {
        let chars = try call.bind([("chars", TemplateValue.none)])[0]
        let set: String? = if case .none = chars { nil } else { Py.str(chars) }
        return .string(PyString.strip(Py.str(call.value), chars: set))
    }

    static func replace(_ call: FilterCall) throws -> TemplateValue {
        let bound = try call.bind([("old", nil), ("new", nil), ("count", TemplateValue.none)])
        let count: Int = if case .none = bound[2] { -1 } else { try Py.integer(bound[2]) }
        return .string(try PyString.replace(
            Py.str(call.value), old: Py.str(bound[0]), new: Py.str(bound[1]), count: count, limits: call.limits
        ))
    }

    static func string(_ call: FilterCall) throws -> TemplateValue {
        try call.noArguments()
        return .string(Py.str(call.value))
    }

    static func safe(_ call: FilterCall) throws -> TemplateValue {
        try call.noArguments()
        return call.value
    }

    static func escape(_ call: FilterCall) throws -> TemplateValue {
        try call.noArguments()
        return .string(try call.limits.check(PyString.htmlEscape(Py.str(call.value))))
    }

    static func striptags(_ call: FilterCall) throws -> TemplateValue {
        try call.noArguments()
        var text = Py.str(call.value)
        for (open, close) in [("<!--", "-->"), ("<", ">")] {
            while let start = text.range(of: open, options: .literal),
                  let end = text.range(of: close, options: .literal, range: start.upperBound..<text.endIndex) {
                text.removeSubrange(start.lowerBound..<end.upperBound)
            }
        }
        let collapsed = try PyString.split(text, separator: nil, maxSplit: -1).joined(separator: " ")
        return .string(PyString.htmlUnescape(collapsed))
    }

    static func wordcount(_ call: FilterCall) throws -> TemplateValue {
        try call.noArguments()
        var count = 0
        var inWord = false
        for scalar in Py.str(call.value).unicodeScalars {
            let isWord = Py.isWordCharacter(scalar)
            if isWord && !inWord { count += 1 }
            inWord = isWord
        }
        return .int(count)
    }

    static func center(_ call: FilterCall) throws -> TemplateValue {
        let width = try Py.integer(call.bind([("width", 80)])[0])
        return .string(try PyString.center(Py.str(call.value), width: width, limits: call.limits))
    }

    static func indent(_ call: FilterCall) throws -> TemplateValue {
        let bound = try call.bind([("width", 4), ("first", false), ("blank", false)])
        let indentation: String
        if case .string(let s) = bound[0] {
            indentation = s
        } else {
            let width = try Py.integer(bound[0])
            try call.limits.checkStringLength(width)
            indentation = String(repeating: " ", count: Swift.max(0, width))
        }
        let first = Py.truthy(bound[1])
        let blank = Py.truthy(bound[2])
        var lines = PyString.splitLines(Py.str(call.value) + "\n")
        var result: String
        if blank {
            result = lines.joined(separator: "\n" + indentation)
        } else {
            result = lines.isEmpty ? "" : lines.removeFirst()
            if !lines.isEmpty {
                result += "\n" + lines.map { $0.isEmpty ? $0 : indentation + $0 }.joined(separator: "\n")
            }
        }
        if first { result = indentation + result }
        return .string(try call.limits.check(result))
    }

    static func truncate(_ call: FilterCall) throws -> TemplateValue {
        let bound = try call.bind([("length", 255), ("killwords", false), ("end", "..."), ("leeway", TemplateValue.none)])
        let s = Py.scalars(Py.str(call.value))
        let length = try Py.integer(bound[0])
        let killWords = Py.truthy(bound[1])
        let end = Py.str(bound[2])
        let leeway: Int = if case .none = bound[3] { 5 } else { try Py.integer(bound[3]) }
        let endLength = Py.length(of: end)
        guard length >= endLength else { throw RuntimeFailure("expected length >= \(endLength), got \(length)") }
        guard leeway >= 0 else { throw RuntimeFailure("expected leeway >= 0, got \(leeway)") }
        if s.count <= length + leeway { return .string(Py.string(s)) }
        let kept = Array(s.prefix(length - endLength))
        if killWords { return .string(Py.string(kept) + end) }
        let cut = kept.lastIndex(of: " ").map { Array(kept[..<$0]) } ?? kept
        return .string(Py.string(cut) + end)
    }

    static func format(_ call: FilterCall) throws -> TemplateValue {
        if !call.args.isEmpty && !call.kwargs.isEmpty {
            throw RuntimeFailure("can't handle positional and keyword arguments at the same time")
        }
        let format = Py.str(call.value)
        if !call.kwargs.isEmpty {
            return .string(try PercentFormat.format(
                format, positional: [.dict(call.kwargs)], mapping: call.kwargs, limits: call.limits
            ))
        }
        return .string(try PercentFormat.format(format, positional: call.args, mapping: nil, limits: call.limits))
    }

    static func urlencode(_ call: FilterCall) throws -> TemplateValue {
        try call.noArguments()
        func pair(_ key: TemplateValue, _ value: TemplateValue) -> String {
            PyString.urlQuote(Py.str(key), safe: "", forQuery: true) + "="
                + PyString.urlQuote(Py.str(value), safe: "", forQuery: true)
        }
        switch call.value {
        case .dict(let dict):
            return .string(Py.sortedKeys(dict).map { pair(.string($0), dict[$0]!) }.joined(separator: "&"))
        case .array(let items):
            let pairs = try items.map { item -> String in
                guard case .array(let kv) = item, kv.count == 2 else {
                    throw RuntimeFailure("urlencode expects a list of key/value pairs")
                }
                return pair(kv[0], kv[1])
            }
            return .string(pairs.joined(separator: "&"))
        default:
            return .string(PyString.urlQuote(Py.str(call.value), safe: "/", forQuery: false))
        }
    }

    // MARK: Values

    static func defaultValue(_ call: FilterCall) throws -> TemplateValue {
        let bound = try call.bind([("default_value", ""), ("boolean", false)])
        if call.value.isUndefined || (Py.truthy(bound[1]) && !Py.truthy(call.value)) {
            return bound[0]
        }
        return call.value
    }

    static func length(_ call: FilterCall) throws -> TemplateValue {
        try call.noArguments()
        return .int(try Py.len(call.value))
    }

    static func int(_ call: FilterCall) throws -> TemplateValue {
        let bound = try call.bind([("default", 0), ("base", 10)])
        switch call.value.plain {
        case .int(let i): return .int(i)
        case .bool(let b): return .int(b ? 1 : 0)
        case .double(let d):
            return Int(exactly: d.rounded(.towardZero)).map(TemplateValue.int) ?? bound[0]
        case .string(let s):
            if let value = PyString.parseInt(s, base: try Py.integer(bound[1])) { return .int(value) }
            if let value = PyString.parseFloat(s), let truncated = Int(exactly: value.rounded(.towardZero)) {
                return .int(truncated)
            }
            return bound[0]
        default:
            return bound[0]
        }
    }

    static func float(_ call: FilterCall) throws -> TemplateValue {
        let fallback = try call.bind([("default", 0.0)])[0]
        switch call.value.plain {
        case .int(let i): return .double(Double(i))
        case .bool(let b): return .double(b ? 1 : 0)
        case .double: return call.value
        case .string(let s): return PyString.parseFloat(s).map(TemplateValue.double) ?? fallback
        default: return fallback
        }
    }

    static func abs(_ call: FilterCall) throws -> TemplateValue {
        try call.noArguments()
        switch Py.number(call.value) {
        case .int(let i)?:
            if i == .min { throw RuntimeFailure("Integer overflow") }
            return .int(Swift.abs(i))
        case .double(let d)?:
            return .double(Swift.abs(d))
        case nil:
            throw RuntimeFailure("bad operand type for abs(): '\(Py.typeName(call.value))'")
        }
    }

    static func round(_ call: FilterCall) throws -> TemplateValue {
        let bound = try call.bind([("precision", 0), ("method", "common")])
        let precision = try Py.integer(bound[0])
        let method = Py.str(bound[1])
        guard ["common", "ceil", "floor"].contains(method) else {
            throw RuntimeFailure("method must be common, ceil or floor")
        }
        guard let number = Py.number(call.value) else {
            throw RuntimeFailure("type \(Py.typeName(call.value)) doesn't define __round__ method")
        }
        if method != "common" {
            let scale = pow(10.0, Double(precision))
            let scaled = number.asDouble * scale
            return .double((method == "ceil" ? scaled.rounded(.up) : scaled.rounded(.down)) / scale)
        }
        switch number {
        case .int(let i):
            guard precision < 0 else { return .int(i) }
            guard precision > -19 else { return .int(0) }
            var scale = 1
            for _ in 0..<(-precision) { scale *= 10 }
            let rounded = (Double(i) / Double(scale)).rounded(.toNearestOrEven)
            return Int(exactly: rounded * Double(scale)).map(TemplateValue.int) ?? .int(i)
        case .double(let d):
            return .double(roundHalfEven(d, digits: precision))
        }
    }

    /// Python's `round(float, ndigits)`: correctly rounded, ties to even.
    static func roundHalfEven(_ value: Double, digits: Int) -> Double {
        guard value.isFinite else { return value }
        if digits > 22 { return value }
        if digits >= 0 {
            return Double(String(format: "%.\(digits)f", value)) ?? value
        }
        if digits < -308 { return 0 * value }
        let scale = pow(10.0, Double(-digits))
        return (value / scale).rounded(.toNearestOrEven) * scale
    }

    static func attr(_ call: FilterCall) throws -> TemplateValue {
        let name = try call.bind([("name", nil)])[0]
        return ValueAccess.attribute(call.value, Py.str(name))
    }

    // MARK: Sequences

    /// A sort key: the item (or its `attribute` path), lowercased unless case-sensitive.
    static func keyFunction(attribute: TemplateValue, caseSensitive: Bool) -> (TemplateValue) -> TemplateValue {
        let path: String? = switch attribute {
        case .none, .undefined: nil
        default: Py.str(attribute)
        }
        return { item in
            var key = path.map { ValueAccess.path(item, $0) } ?? item
            if !caseSensitive, case .string(let s) = key { key = .string(s.lowercased()) }
            return key
        }
    }

    static func first(_ call: FilterCall) throws -> TemplateValue {
        try call.noArguments()
        return try Py.iterate(call.value).first ?? .undefined
    }

    static func last(_ call: FilterCall) throws -> TemplateValue {
        try call.noArguments()
        return try Py.iterate(call.value).last ?? .undefined
    }

    static func list(_ call: FilterCall) throws -> TemplateValue {
        try call.noArguments()
        return .array(try Py.iterate(call.value))
    }

    static func reverse(_ call: FilterCall) throws -> TemplateValue {
        try call.noArguments()
        if case .string(let s) = call.value.plain { return .string(Py.string(s.unicodeScalars.reversed())) }
        return .array(try Py.iterate(call.value).reversed())
    }

    static func join(_ call: FilterCall) throws -> TemplateValue {
        let bound = try call.bind([("d", ""), ("attribute", TemplateValue.none)])
        let key = keyFunction(attribute: bound[1], caseSensitive: true)
        let parts = try Py.iterate(call.value).map { Py.str(key($0)) }
        let separator = Py.str(bound[0])
        let total = parts.reduce(separator.utf8.count * Swift.max(0, parts.count - 1)) { $0 + $1.utf8.count }
        try call.limits.checkStringLength(total)
        return .string(parts.joined(separator: separator))
    }

    static func sort(_ call: FilterCall) throws -> TemplateValue {
        let bound = try call.bind([("reverse", false), ("case_sensitive", false), ("attribute", TemplateValue.none)])
        let reverse = Py.truthy(bound[0])
        let key = keyFunction(attribute: bound[2], caseSensitive: Py.truthy(bound[1]))
        return .array(try stableSort(Py.iterate(call.value), key: key, reverse: reverse))
    }

    static func stableSort(
        _ items: [TemplateValue],
        key: (TemplateValue) -> TemplateValue,
        reverse: Bool
    ) throws -> [TemplateValue] {
        let keyed = items.enumerated().map { (offset: $0.offset, key: key($0.element), value: $0.element) }
        let sorted = try keyed.sorted { a, b in
            if try Py.order(.less, a.key, b.key) { return !reverse }
            if try Py.order(.less, b.key, a.key) { return reverse }
            return a.offset < b.offset
        }
        return sorted.map(\.value)
    }

    static func dictsort(_ call: FilterCall) throws -> TemplateValue {
        let bound = try call.bind([("case_sensitive", false), ("by", "key"), ("reverse", false)])
        guard case .dict(let dict) = call.value else {
            throw RuntimeFailure("dictsort requires a mapping, not \(Py.typeName(call.value))")
        }
        let position: Int
        switch Py.str(bound[1]) {
        case "key": position = 0
        case "value": position = 1
        default: throw RuntimeFailure("You can only sort by either 'key' or 'value'")
        }
        let caseSensitive = Py.truthy(bound[0])
        let pairs = dict.map { TemplateValue.array([.string($0.key), $0.value]) }
        let key: (TemplateValue) -> TemplateValue = { pair in
            guard case .array(let kv) = pair else { return pair }
            var key = kv[position]
            if !caseSensitive, case .string(let s) = key { key = .string(s.lowercased()) }
            return key
        }
        let byKey = try stableSort(pairs, key: { pair in
            if case .array(let kv) = pair { return kv[0] }
            return pair
        }, reverse: false)
        return .array(try stableSort(byKey, key: key, reverse: Py.truthy(bound[2])))
    }

    static func items(_ call: FilterCall) throws -> TemplateValue {
        try call.noArguments()
        switch call.value {
        case .dict(let dict):
            return .array(Py.sortedKeys(dict).map { .array([.string($0), dict[$0]!]) })
        case .undefined:
            return .array([])
        default:
            throw RuntimeFailure("Can only get item pairs from a mapping, not \(Py.typeName(call.value))")
        }
    }

    static func unique(_ call: FilterCall) throws -> TemplateValue {
        let bound = try call.bind([("case_sensitive", false), ("attribute", TemplateValue.none)])
        let key = keyFunction(attribute: bound[1], caseSensitive: Py.truthy(bound[0]))
        var seen = Set<TemplateValue>()
        var result: [TemplateValue] = []
        for item in try Py.iterate(call.value) where seen.insert(Py.hashKey(key(item))).inserted {
            result.append(item)
        }
        return .array(result)
    }

    private static func extreme(_ call: FilterCall, wantsMaximum: Bool) throws -> TemplateValue {
        let bound = try call.bind([("case_sensitive", false), ("attribute", TemplateValue.none)])
        let key = keyFunction(attribute: bound[1], caseSensitive: Py.truthy(bound[0]))
        let items = try Py.iterate(call.value)
        guard var best = items.first else { return .undefined }
        var bestKey = key(best)
        for item in items.dropFirst() {
            let itemKey = key(item)
            if try Py.order(wantsMaximum ? .greater : .less, itemKey, bestKey) {
                best = item
                bestKey = itemKey
            }
        }
        return best
    }

    static func min(_ call: FilterCall) throws -> TemplateValue {
        try extreme(call, wantsMaximum: false)
    }

    static func max(_ call: FilterCall) throws -> TemplateValue {
        try extreme(call, wantsMaximum: true)
    }

    static func sum(_ call: FilterCall) throws -> TemplateValue {
        let bound = try call.bind([("attribute", TemplateValue.none), ("start", 0)])
        let key = keyFunction(attribute: bound[0], caseSensitive: true)
        var total = bound[1]
        for item in try Py.iterate(call.value) {
            total = try Py.add(total, key(item), call.limits)
        }
        return total
    }

    static func map(_ call: FilterCall) throws -> TemplateValue {
        let items = try Py.iterate(call.value)
        if call.args.isEmpty, let attribute = call.kwargs["attribute"] {
            let fallback = call.kwargs["default"]
            for name in call.kwargs.keys where name != "attribute" && name != "default" {
                throw RuntimeFailure("Filter 'map' got an unexpected keyword argument '\(name)'")
            }
            let path = Py.str(attribute)
            return .array(items.map { item in
                let value = ValueAccess.path(item, path)
                if value.isUndefined, let fallback { return fallback }
                return value
            })
        }
        guard let first = call.args.first else {
            throw RuntimeFailure("map requires a filter name or attribute=")
        }
        let name = Py.str(first)
        guard let filter = call.environment.filters[name] else {
            throw RuntimeFailure("No filter named '\(name)'")
        }
        let rest = Array(call.args.dropFirst())
        return .array(try items.map { item in
            try filter(FilterCall(name: name, value: item, args: rest, kwargs: call.kwargs, environment: call.environment))
        })
    }

    private static func predicate(
        _ arguments: ArraySlice<TemplateValue>,
        _ call: FilterCall
    ) throws -> (TemplateValue) throws -> Bool {
        guard let first = arguments.first else { return { Py.truthy($0) } }
        let name = Py.str(first)
        guard let test = BuiltinTests.all[name] else { throw RuntimeFailure("No test named '\(name)'") }
        let rest = Array(arguments.dropFirst())
        return { value in
            try test(TestCall(name: name, value: value, args: rest, kwargs: call.kwargs, environment: call.environment))
        }
    }

    private static func selectItems(_ call: FilterCall, keep: Bool, byAttribute: Bool) throws -> TemplateValue {
        var arguments = call.args[...]
        var path: String?
        if byAttribute {
            guard let attribute = arguments.first else {
                throw RuntimeFailure("Filter '\(call.name)' requires an attribute name")
            }
            path = Py.str(attribute)
            arguments = arguments.dropFirst()
        }
        let check = try predicate(arguments, call)
        return .array(try Py.iterate(call.value).filter { item in
            let subject = path.map { ValueAccess.path(item, $0) } ?? item
            return try check(subject) == keep
        })
    }

    static func select(_ call: FilterCall) throws -> TemplateValue {
        try selectItems(call, keep: true, byAttribute: false)
    }

    static func reject(_ call: FilterCall) throws -> TemplateValue {
        try selectItems(call, keep: false, byAttribute: false)
    }

    static func selectattr(_ call: FilterCall) throws -> TemplateValue {
        try selectItems(call, keep: true, byAttribute: true)
    }

    static func rejectattr(_ call: FilterCall) throws -> TemplateValue {
        try selectItems(call, keep: false, byAttribute: true)
    }
}
