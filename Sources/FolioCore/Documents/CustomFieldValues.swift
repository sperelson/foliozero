import Foundation
import GRDB

/// A JSON value, for API payloads and loosely typed inputs such as custom field values.
public enum JSONValue: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let b = try? container.decode(Bool.self) { self = .bool(b) }
        else if let i = try? container.decode(Int.self) { self = .int(i) }
        else if let d = try? container.decode(Double.self) { self = .double(d) }
        else if let s = try? container.decode(String.self) { self = .string(s) }
        else if let a = try? container.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let b): try container.encode(b)
        case .int(let i): try container.encode(i)
        case .double(let d): try container.encode(d)
        case .string(let s): try container.encode(s)
        case .array(let a): try container.encode(a)
        case .object(let o): try container.encode(o)
        }
    }

    public var stringValue: String? {
        switch self {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .bool(let b): b ? "true" : "false"
        default: nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .int(let i): i
        case .double(let d) where d == d.rounded(): Int(d)
        case .string(let s): Int(s)
        default: nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .int(let i): Double(i)
        case .double(let d): d
        case .string(let s): Double(s)
        default: nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let b): b
        case .int(let i): i != 0
        case .string(let s): ["true", "1", "yes"].contains(s.lowercased()) ? true : (["false", "0", "no"].contains(s.lowercased()) ? false : nil)
        default: nil
        }
    }

    public var isNull: Bool { self == .null }
}

public enum CustomFieldValueError: Error, CustomStringConvertible, Equatable {
    case invalid(field: String, reason: String)

    public var description: String {
        switch self {
        case let .invalid(field, reason): "Invalid value for custom field \(field): \(reason)"
        }
    }
}

/// Converts between API values and the typed columns of `custom_field_instances`.
public enum CustomFieldValues {
    /// Writes `value` into the column for the field's type. `.null` clears the value.
    public static func assign(_ value: JSONValue, field: CustomField, to instance: inout CustomFieldInstance) throws {
        clear(&instance)
        if value.isNull { return }
        func fail(_ reason: String) -> CustomFieldValueError { .invalid(field: field.name, reason: reason) }

        switch field.dataType {
        case .string:
            guard let s = value.stringValue else { throw fail("expected text") }
            guard s.count <= 128 else { throw fail("at most 128 characters") }
            instance.valueText = s
        case .longtext:
            guard let s = value.stringValue else { throw fail("expected text") }
            instance.valueLongText = s
        case .url:
            guard let s = value.stringValue else { throw fail("expected a URL") }
            if !s.isEmpty {
                guard let url = URL(string: s), url.scheme != nil, url.host != nil || url.scheme == "mailto" else { throw fail("not a valid URL") }
            }
            instance.valueUrl = s
        case .date:
            guard let s = value.stringValue, let date = CalendarDate(iso: s) else { throw fail("expected a date (YYYY-MM-DD)") }
            instance.valueDate = date
        case .boolean:
            guard let b = value.boolValue else { throw fail("expected true or false") }
            instance.valueBool = b
        case .integer:
            guard let i = value.intValue else { throw fail("expected an integer") }
            instance.valueInt = i
        case .float:
            guard let d = value.doubleValue else { throw fail("expected a number") }
            instance.valueFloat = d
        case .monetary:
            guard let s = value.stringValue, let normalized = normalizeMonetary(s, defaultCurrency: field.extraData?.defaultCurrency) else {
                throw fail("expected an amount like ZAR12.50 or 12.50")
            }
            instance.valueMonetary = normalized
        case .documentlink:
            guard case .array(let items) = value else { throw fail("expected a list of document ids") }
            let ids = items.compactMap(\.intValue)
            guard ids.count == items.count else { throw fail("expected a list of document ids") }
            instance.valueDocumentIds = Array(Set(ids)).sorted()
        case .select:
            guard let id = value.stringValue else { throw fail("expected an option id") }
            let options = field.extraData?.selectOptions ?? []
            guard options.contains(where: { $0.id == id }) else { throw fail("unknown option \(id)") }
            instance.valueSelect = id
        }
    }

    public static func value(of instance: CustomFieldInstance, field: CustomField) -> JSONValue {
        switch field.dataType {
        case .string: instance.valueText.map(JSONValue.string) ?? .null
        case .longtext: instance.valueLongText.map(JSONValue.string) ?? .null
        case .url: instance.valueUrl.map(JSONValue.string) ?? .null
        case .date: instance.valueDate.map { .string($0.iso) } ?? .null
        case .boolean: instance.valueBool.map(JSONValue.bool) ?? .null
        case .integer: instance.valueInt.map(JSONValue.int) ?? .null
        case .float: instance.valueFloat.map(JSONValue.double) ?? .null
        case .monetary: instance.valueMonetary.map(JSONValue.string) ?? .null
        case .documentlink: instance.valueDocumentIds.map { .array($0.map(JSONValue.int)) } ?? .null
        case .select: instance.valueSelect.map(JSONValue.string) ?? .null
        }
    }

    static func clear(_ instance: inout CustomFieldInstance) {
        instance.valueText = nil; instance.valueBool = nil; instance.valueUrl = nil; instance.valueDate = nil
        instance.valueInt = nil; instance.valueFloat = nil; instance.valueMonetary = nil
        instance.valueDocumentIds = nil; instance.valueSelect = nil; instance.valueLongText = nil
    }

    /// Paperless-ngx monetary format: optional ISO 4217 code followed by an amount with two decimals.
    static func normalizeMonetary(_ raw: String, defaultCurrency: String?) -> String? {
        let text = raw.trimmingCharacters(in: .whitespaces).uppercased()
        let letters = text.prefix { $0.isLetter }
        guard letters.isEmpty || letters.count == 3 else { return nil }
        let amountText = text.dropFirst(letters.count).replacingOccurrences(of: ",", with: "")
        guard let amount = Decimal(string: String(amountText), locale: Locale(identifier: "en_US_POSIX")) else { return nil }
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.usesGroupingSeparator = false
        guard let formatted = formatter.string(from: amount as NSDecimalNumber) else { return nil }
        let currency = letters.isEmpty ? (defaultCurrency?.uppercased() ?? "") : String(letters)
        return currency + formatted
    }

    /// Sets (or adds) a custom field on a document. `nil` adds the field without a value
    /// and leaves an existing value untouched, as Paperless-ngx does.
    public static func set(fieldId: Int, value: JSONValue?, documentId: Int, in db: Database) throws {
        guard let field = try CustomField.fetchOne(db, key: fieldId) else { return }
        var instance = try CustomFieldInstance
            .filter(Column("document_id") == documentId && Column("field_id") == fieldId)
            .fetchOne(db) ?? CustomFieldInstance(documentId: documentId, fieldId: fieldId)
        instance.deletedAt = nil
        if let value {
            try assign(value, field: field, to: &instance)
        }
        try instance.save(db)
        if field.dataType == .documentlink {
            try syncReverseLinks(field: field, documentId: documentId, linked: instance.valueDocumentIds ?? [], in: db)
        }
    }

    public static func remove(fieldId: Int, documentId: Int, in db: Database) throws {
        if let field = try CustomField.fetchOne(db, key: fieldId), field.dataType == .documentlink {
            try syncReverseLinks(field: field, documentId: documentId, linked: [], in: db)
        }
        try db.execute(sql: "DELETE FROM custom_field_instances WHERE document_id = ? AND field_id = ?", arguments: [documentId, fieldId])
    }

    /// Document links are symmetrical: linking A to B also links B to A.
    static func syncReverseLinks(field: CustomField, documentId: Int, linked: [Int], in db: Database) throws {
        guard let fieldId = field.id else { return }
        let others = try CustomFieldInstance.filter(Column("field_id") == fieldId && Column("document_id") != documentId).fetchAll(db)
        let linkedSet = Set(linked)
        for var other in others {
            var ids = Set(other.valueDocumentIds ?? [])
            let shouldLink = linkedSet.contains(other.documentId)
            if shouldLink && !ids.contains(documentId) { ids.insert(documentId) }
            else if !shouldLink && ids.contains(documentId) { ids.remove(documentId) }
            else { continue }
            other.valueDocumentIds = ids.sorted()
            try other.update(db)
        }
        for target in linkedSet where !others.contains(where: { $0.documentId == target }) {
            guard try Document.fetchOne(db, key: target) != nil else { continue }
            var instance = CustomFieldInstance(documentId: target, fieldId: fieldId)
            instance.valueDocumentIds = [documentId]
            try instance.insert(db)
        }
    }
}
