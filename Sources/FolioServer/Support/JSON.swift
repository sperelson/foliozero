import Foundation
import FolioCore

/// A JSON value with ordered object keys, so responses keep the field order of
/// the Paperless-ngx serializers.
public enum JSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object(JSONObject)
}

/// An insertion-ordered JSON object.
public struct JSONObject: Sendable, Equatable, Sequence {
    public private(set) var keys: [String] = []
    private var storage: [String: JSON] = [:]

    public init() {}

    public init(_ pairs: [(String, JSON)]) {
        for (key, value) in pairs { self[key] = value }
    }

    public subscript(key: String) -> JSON? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil { keys.append(key) }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    /// Objects are equal when they hold the same keys and values, in any order.
    public static func == (lhs: JSONObject, rhs: JSONObject) -> Bool {
        lhs.storage == rhs.storage
    }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    public func contains(_ key: String) -> Bool { storage[key] != nil }

    public func makeIterator() -> AnyIterator<(key: String, value: JSON)> {
        var index = 0
        let keys = self.keys
        let storage = self.storage
        return AnyIterator {
            guard index < keys.count else { return nil }
            defer { index += 1 }
            return (keys[index], storage[keys[index]]!)
        }
    }

    /// Keeps only the given keys (DRF `fields=`), in the original order.
    public func filtered(_ allowed: Set<String>) -> JSONObject {
        var result = JSONObject()
        for key in keys where allowed.contains(key) { result[key] = storage[key] }
        return result
    }
}

extension JSON: ExpressibleByDictionaryLiteral, ExpressibleByArrayLiteral, ExpressibleByStringLiteral,
    ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral, ExpressibleByNilLiteral, ExpressibleByFloatLiteral {
    public init(dictionaryLiteral elements: (String, JSON)...) { self = .object(JSONObject(elements)) }
    public init(arrayLiteral elements: JSON...) { self = .array(elements) }
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
    public init(nilLiteral: ()) { self = .null }
    public init(floatLiteral value: Double) { self = .double(value) }
}

// MARK: - Convenience initialisers

extension JSON {
    public init(_ value: String?) { self = value.map(JSON.string) ?? .null }
    public init(_ value: Int?) { self = value.map(JSON.int) ?? .null }
    public init(_ value: Double?) { self = value.map(JSON.double) ?? .null }
    public init(_ value: Bool?) { self = value.map(JSON.bool) ?? .null }
    public init(_ values: [Int]) { self = .array(values.map(JSON.int)) }
    public init(_ values: [String]) { self = .array(values.map(JSON.string)) }
    public init(_ object: JSONObject) { self = .object(object) }

    public init(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let b): self = .bool(b)
        case .int(let i): self = .int(i)
        case .double(let d): self = .double(d)
        case .string(let s): self = .string(s)
        case .array(let a): self = .array(a.map(JSON.init))
        case .object(let o):
            var object = JSONObject()
            for key in o.keys.sorted() { object[key] = JSON(o[key]!) }
            self = .object(object)
        }
    }

    /// The FolioCore representation (custom field values, settings blobs).
    public var jsonValue: JSONValue {
        switch self {
        case .null: .null
        case .bool(let b): .bool(b)
        case .int(let i): .int(i)
        case .double(let d): .double(d)
        case .string(let s): .string(s)
        case .array(let a): .array(a.map(\.jsonValue))
        case .object(let o):
            .object(Dictionary(uniqueKeysWithValues: o.map { ($0.key, $0.value.jsonValue) }))
        }
    }
}

// MARK: - Accessors

extension JSON {
    public var isNull: Bool { self == .null }

    public var object: JSONObject? {
        if case .object(let o) = self { return o }
        return nil
    }

    public var array: [JSON]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Strings as they are; numbers and booleans as text (form fields arrive as text).
    public var string: String? {
        switch self {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .bool(let b): b ? "true" : "false"
        default: nil
        }
    }

    /// Strictly a string value.
    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    /// Integers, and strings that hold an integer (DRF `IntegerField`).
    public var int: Int? {
        switch self {
        case .int(let i): i
        case .double(let d) where d == d.rounded() && abs(d) < 9e15: Int(d)
        case .string(let s): Int(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    /// Strictly an integer value (DRF `isinstance(x, int)` checks).
    public var strictInt: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    public var double: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        case .string(let s): Double(s.trimmingCharacters(in: .whitespaces))
        default: nil
        }
    }

    /// DRF `BooleanField` parsing.
    public var bool: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i == 1 ? true : (i == 0 ? false : nil)
        case .string(let s):
            switch s.lowercased() {
            case "true", "1", "yes", "y", "on", "t": return true
            case "false", "0", "no", "n", "off", "f", "": return false
            default: return nil
            }
        default: return nil
        }
    }

    public subscript(key: String) -> JSON? {
        object?[key]
    }
}

// MARK: - Serialisation

extension JSON {
    public func serialized() -> String {
        var output = ""
        output.reserveCapacity(256)
        write(to: &output)
        return output
    }

    public var data: Data { Data(serialized().utf8) }

    func write(to output: inout String) {
        switch self {
        case .null: output += "null"
        case .bool(let b): output += b ? "true" : "false"
        case .int(let i): output += String(i)
        case .double(let d):
            output += d.isFinite ? String(d) : "null"
        case .string(let s): JSON.writeString(s, to: &output)
        case .array(let items):
            output += "["
            for (index, item) in items.enumerated() {
                if index > 0 { output += "," }
                item.write(to: &output)
            }
            output += "]"
        case .object(let object):
            output += "{"
            var first = true
            for (key, value) in object {
                if !first { output += "," }
                first = false
                JSON.writeString(key, to: &output)
                output += ":"
                value.write(to: &output)
            }
            output += "}"
        }
    }

    static func writeString(_ string: String, to output: inout String) {
        output += "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": output += "\\\""
            case "\\": output += "\\\\"
            case "\n": output += "\\n"
            case "\r": output += "\\r"
            case "\t": output += "\\t"
            case "\u{08}": output += "\\b"
            case "\u{0C}": output += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    output += String(format: "\\u%04x", scalar.value)
                } else {
                    output.unicodeScalars.append(scalar)
                }
            }
        }
        output += "\""
    }
}

// MARK: - Parsing

public struct JSONParseError: Error, CustomStringConvertible {
    public var description: String
}

extension JSON {
    public static func parse(_ data: Data) throws -> JSON {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw JSONParseError(description: "JSON parse error - \(error.localizedDescription)")
        }
        return JSON(any: object)
    }

    public static func parse(_ string: String) throws -> JSON {
        try parse(Data(string.utf8))
    }

    init(any value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                self = .bool(number.boolValue)
            } else {
                let type = String(cString: number.objCType)
                if type == "d" || type == "f" {
                    let d = number.doubleValue
                    self = .double(d)
                } else {
                    self = .int(number.intValue)
                }
            }
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map { JSON(any: $0) })
        case let dictionary as [String: Any]:
            var object = JSONObject()
            for key in dictionary.keys.sorted() { object[key] = JSON(any: dictionary[key]!) }
            self = .object(object)
        default:
            self = .null
        }
    }
}
