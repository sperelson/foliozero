import Foundation

/// JSON that keeps the order of object keys, for HTTP request bodies.
///
/// Order matters for schemas: OpenAI and Ollama generate structured output in the order of
/// the schema's properties, so names must come before the `matched_*` and `*_ids` fields.
indirect enum OrderedJSON: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([OrderedJSON])
    case object([Member])

    struct Member: Sendable, Equatable {
        var key: String
        var value: OrderedJSON
    }

    /// An object with members in the given order.
    static func ordered(_ pairs: KeyValuePairs<String, OrderedJSON>) -> OrderedJSON {
        .object(pairs.map { Member(key: $0.key, value: $0.value) })
    }

    /// Converts an unordered value; object keys are sorted so the output is stable.
    init(_ value: JSONValue) {
        switch value {
        case .null: self = .null
        case .bool(let b): self = .bool(b)
        case .int(let i): self = .int(i)
        case .double(let d): self = .double(d)
        case .string(let s): self = .string(s)
        case .array(let a): self = .array(a.map(OrderedJSON.init))
        case .object(let o): self = .object(o.keys.sorted().map { Member(key: $0, value: OrderedJSON(o[$0] ?? .null)) })
        }
    }

    /// The same value without key order.
    var jsonValue: JSONValue {
        switch self {
        case .null: .null
        case .bool(let b): .bool(b)
        case .int(let i): .int(i)
        case .double(let d): .double(d)
        case .string(let s): .string(s)
        case .array(let a): .array(a.map(\.jsonValue))
        case .object(let members): .object(Dictionary(members.map { ($0.key, $0.value.jsonValue) }, uniquingKeysWith: { _, new in new }))
        }
    }

    /// For an object: `extra` replaces members with the same key in place and appends the
    /// rest in key order (`AI_LLM_EXTRA_PARAMS` semantics). Other values are returned unchanged.
    func merging(_ extra: [String: JSONValue]) -> OrderedJSON {
        guard case .object(var members) = self, !extra.isEmpty else { return self }
        for key in extra.keys.sorted() {
            let value = OrderedJSON(extra[key] ?? .null)
            if let index = members.firstIndex(where: { $0.key == key }) {
                members[index].value = value
            } else {
                members.append(Member(key: key, value: value))
            }
        }
        return .object(members)
    }

    /// Compact UTF-8 JSON.
    var data: Data {
        var text = ""
        write(into: &text)
        return Data(text.utf8)
    }

    private func write(into text: inout String) {
        switch self {
        case .null: text += "null"
        case .bool(let b): text += b ? "true" : "false"
        case .int(let i): text += String(i)
        case .double(let d): text += d.isFinite ? String(d) : "null"
        case .string(let s): text += AIPrompts.pythonJSONString(s)
        case .array(let values):
            text += "["
            for (index, value) in values.enumerated() {
                if index > 0 { text += "," }
                value.write(into: &text)
            }
            text += "]"
        case .object(let members):
            text += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { text += "," }
                text += AIPrompts.pythonJSONString(member.key)
                text += ":"
                member.value.write(into: &text)
            }
            text += "}"
        }
    }
}
