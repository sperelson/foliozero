import Foundation

/// Python printf-style string formatting (`"%s-%03d" % (a, b)`).
enum PercentFormat {
    /// Formats with the right operand of `%`: a list acts as a tuple of arguments, a dict as a
    /// mapping, anything else as a single argument.
    static func format(_ format: String, operand: TemplateValue, limits: ValueLimits) throws -> String {
        switch operand {
        case .array(let items): try self.format(format, positional: items, mapping: nil, limits: limits)
        case .dict(let dict): try self.format(format, positional: [operand], mapping: dict, limits: limits)
        default: try self.format(format, positional: [operand], mapping: nil, limits: limits)
        }
    }

    private struct Spec {
        var leftAlign = false
        var plus = false
        var space = false
        var alternate = false
        var zeroPad = false
        var width: Int?
        var precision: Int?
    }

    static func format(
        _ format: String,
        positional: [TemplateValue],
        mapping: [String: TemplateValue]?,
        limits: ValueLimits
    ) throws -> String {
        let s = Array(format.unicodeScalars)
        var out = ""
        var argumentIndex = 0
        var index = 0

        func nextArgument() throws -> TemplateValue {
            guard argumentIndex < positional.count else {
                throw RuntimeFailure("not enough arguments for format string")
            }
            defer { argumentIndex += 1 }
            return positional[argumentIndex]
        }
        func number() throws -> Int? {
            if index < s.count, s[index] == "*" {
                index += 1
                let value = try Py.integer(nextArgument())
                try limits.checkStringLength(value)
                return value
            }
            var value: Int?
            while index < s.count, ("0"..."9").contains(s[index]) {
                let (product, overflow) = (value ?? 0).multipliedReportingOverflow(by: 10)
                if overflow { throw RuntimeFailure("width too big") }
                value = product + Int(s[index].value - 48)
                index += 1
            }
            if let value { try limits.checkStringLength(value) }
            return value
        }

        while index < s.count {
            let scalar = s[index]
            index += 1
            guard scalar == "%" else {
                out.unicodeScalars.append(scalar)
                continue
            }
            guard index < s.count else { throw RuntimeFailure("incomplete format") }

            var key: String?
            if s[index] == "(" {
                guard mapping != nil else { throw RuntimeFailure("format requires a mapping") }
                var depth = 1
                let start = index + 1
                index += 1
                while index < s.count, depth > 0 {
                    if s[index] == "(" { depth += 1 } else if s[index] == ")" { depth -= 1 }
                    index += 1
                }
                guard depth == 0 else { throw RuntimeFailure("incomplete format key") }
                key = Py.string(s[start..<(index - 1)])
            }

            var spec = Spec()
            flags: while index < s.count {
                switch s[index] {
                case "-": spec.leftAlign = true
                case "+": spec.plus = true
                case " ": spec.space = true
                case "#": spec.alternate = true
                case "0": spec.zeroPad = true
                default: break flags
                }
                index += 1
            }
            spec.width = try number()
            if index < s.count, s[index] == "." {
                index += 1
                spec.precision = try number() ?? 0
            }
            while index < s.count, ["h", "l", "L"].contains(s[index]) { index += 1 }
            guard index < s.count else { throw RuntimeFailure("incomplete format") }
            let conversion = s[index]
            index += 1

            if conversion == "%" {
                out += "%"
                continue
            }
            let value: TemplateValue
            if let key {
                guard let found = mapping?[key] else { throw RuntimeFailure("KeyError: '\(key)'") }
                value = found
            } else {
                value = try nextArgument()
            }
            let piece = try convert(value, conversion, spec, limits)
            out += piece
            try limits.checkStringLength(out.utf8.count)
        }

        if mapping == nil, argumentIndex < positional.count {
            throw RuntimeFailure("not all arguments converted during string formatting")
        }
        return out
    }

    private static func pad(_ body: String, _ spec: Spec, zeroPrefix: String? = nil) -> String {
        let length = Py.length(of: body)
        guard let width = spec.width, width > length else { return body }
        let fill = width - length
        if spec.leftAlign { return body + String(repeating: " ", count: fill) }
        if let zeroPrefix {
            return zeroPrefix + String(repeating: "0", count: fill) + body.dropFirst(zeroPrefix.count)
        }
        return String(repeating: " ", count: fill) + body
    }

    private static func convert(
        _ value: TemplateValue,
        _ conversion: Unicode.Scalar,
        _ spec: Spec,
        _ limits: ValueLimits
    ) throws -> String {
        switch conversion {
        case "s", "r", "a":
            var text = conversion == "s" ? Py.str(value) : Py.repr(value)
            if let precision = spec.precision, precision < Py.length(of: text) {
                text = Py.string(text.unicodeScalars.prefix(precision))
            }
            return pad(text, spec)

        case "d", "i", "u", "x", "X", "o":
            let integer: Int
            switch value {
            case .int(let i): integer = i
            case .bool(let b): integer = b ? 1 : 0
            case .double(let d) where ["d", "i", "u"].contains(conversion):
                guard d.isFinite else { throw RuntimeFailure("cannot convert float \(Py.floatRepr(d)) to integer") }
                guard let truncated = Int(exactly: d.rounded(.towardZero)) else { throw RuntimeFailure("Integer overflow") }
                integer = truncated
            default:
                let requirement = ["d", "i", "u"].contains(conversion) ? "a real number" : "an integer"
                throw RuntimeFailure("%\(conversion) format: \(requirement) is required, not \(Py.typeName(value))")
            }
            let radix = switch conversion {
            case "x", "X": 16
            case "o": 8
            default: 10
            }
            var digits = String(integer.magnitude, radix: radix, uppercase: conversion == "X")
            if let precision = spec.precision, digits.count < precision {
                digits = String(repeating: "0", count: precision - digits.count) + digits
            }
            var prefix = integer < 0 ? "-" : (spec.plus ? "+" : (spec.space ? " " : ""))
            if spec.alternate {
                switch conversion {
                case "x": prefix += "0x"
                case "X": prefix += "0X"
                case "o": prefix += "0o"
                default: break
                }
            }
            return pad(prefix + digits, spec, zeroPrefix: spec.zeroPad && !spec.leftAlign ? prefix : nil)

        case "e", "E", "f", "F", "g", "G":
            guard let number = Py.number(value) else {
                throw RuntimeFailure("must be real number, not \(Py.typeName(value))")
            }
            var cFormat = "%"
            if spec.leftAlign { cFormat += "-" }
            if spec.plus { cFormat += "+" }
            if spec.space { cFormat += " " }
            if spec.alternate { cFormat += "#" }
            if spec.zeroPad { cFormat += "0" }
            if let width = spec.width { cFormat += String(width) }
            cFormat += "." + String(min(spec.precision ?? 6, 400))
            cFormat.unicodeScalars.append(conversion)
            return try limits.check(String(format: cFormat, number.asDouble))

        case "c":
            switch value {
            case .int(let code):
                guard let scalar = Unicode.Scalar(UInt32(clamping: max(0, code))), code >= 0 else {
                    throw RuntimeFailure("%c arg not in range(0x110000)")
                }
                return pad(String(scalar), spec)
            case .string(let s) where Py.length(of: s) == 1:
                return pad(s, spec)
            default:
                throw RuntimeFailure("%c requires an int or a unicode character, not \(Py.typeName(value))")
            }

        default:
            throw RuntimeFailure("unsupported format character '\(conversion)'")
        }
    }
}
