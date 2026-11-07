import Foundation
import GRDB

/// Paperless-ngx `custom_field_query`: a JSON expression such as
/// `["OR", [["due", "range", ["today", "in 30 days"]], ["paid", "exact", false]]]`,
/// compiled to an SQL predicate over the `documents` table.
public enum CustomFieldQuery {
    /// SQL predicate over `documents <alias>`. Relative dates ("today", "in 30 days")
    /// resolve against `now` in `timeZone`. Invalid queries throw `FilterError` with
    /// field `custom_field_query` and the DRF error path.
    public static func predicate(_ json: String, alias: String = "d", timeZone: TimeZone, now: Date = Date(), in db: Database) throws -> SQL {
        var compiler = CustomFieldQueryCompiler(timeZone: timeZone, now: now, alias: alias)
        return try compiler.parse(json, in: db)
    }
}

struct CustomFieldQueryCompiler {
    static let maxDepth = 10
    static let maxAtoms = 20
    static let field = "custom_field_query"

    let timeZone: TimeZone
    let now: Date
    let alias: String
    private var depth = 0
    private var atoms = 0
    private var fields: [String: CustomField] = [:]

    init(timeZone: TimeZone, now: Date, alias: String = "d") {
        self.timeZone = timeZone
        self.now = now
        self.alias = alias
    }

    static let categories: [String: [String]] = [
        "basic": ["exact", "in", "isnull", "exists"],
        "string": ["icontains", "istartswith", "iendswith"],
        "arithmetic": ["gt", "gte", "lt", "lte", "range"],
        "containment": ["contains"],
    ]

    static let supported: [CustomFieldDataType: [String]] = [
        .string: ["basic", "string"], .url: ["basic", "string"], .date: ["basic", "arithmetic"],
        .boolean: ["basic"], .integer: ["basic", "arithmetic"], .float: ["basic", "arithmetic"],
        .monetary: ["basic", "string", "arithmetic"], .documentlink: ["basic", "containment"],
        .select: ["basic"], .longtext: ["basic", "string"],
    ]

    static let dateComponents = ["year", "iso_year", "month", "day", "week", "week_day", "iso_week_day", "quarter"]

    struct Failure: Error {
        var path: [String]
        var message: String
    }

    mutating func parse(_ text: String, in db: Database) throws -> SQL {
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        } catch {
            throw FilterError(field: Self.field, message: "Value must be valid JSON.")
        }
        do {
            return try expression(value, path: [], in: db)
        } catch let failure as Failure {
            throw FilterError(field: Self.field, path: failure.path, message: failure.message)
        }
    }

    private mutating func expression(_ value: JSONValue, path: [String], in db: Database) throws -> SQL {
        depth += 1
        defer { depth -= 1 }
        if depth > Self.maxDepth { throw Failure(path: path, message: "Maximum nesting depth exceeded.") }
        guard case .array(let items) = value else {
            throw Failure(path: path, message: "Invalid custom field query expression")
        }
        if items.count == 2 { return try logical(items[0], items[1], path: path, in: db) }
        if items.count == 3 { return try atom(items[0], items[1], items[2], path: path, in: db) }
        throw Failure(path: path, message: "Invalid custom field query expression")
    }

    private mutating func logical(_ op: JSONValue, _ args: JSONValue, path: [String], in db: Database) throws -> SQL {
        let name = op.stringValue?.lowercased() ?? ""
        if name == "not" {
            return "NOT \(try expression(args, path: path + ["1"], in: db))"
        }
        guard name == "and" || name == "or" else {
            throw Failure(path: path + ["0"], message: "Invalid logical operator \(Self.repr(op))")
        }
        guard case .array(let list) = args, !list.isEmpty else {
            throw Failure(path: path + ["1"], message: "Invalid expression list. Must be nonempty.")
        }
        var parts: [SQL] = []
        for (index, item) in list.enumerated() {
            parts.append(try expression(item, path: path + ["1", String(index)], in: db))
        }
        return name == "and" ? QueryFilters.and(parts) : QueryFilters.or(parts)
    }

    private mutating func atom(_ fieldRef: JSONValue, _ opValue: JSONValue, _ value: JSONValue, path: [String], in db: Database) throws -> SQL {
        atoms += 1
        if atoms > Self.maxAtoms { throw Failure(path: path, message: "Maximum number of query conditions exceeded.") }

        let field = try customField(fieldRef, path: path + ["0"], in: db)
        let rawOp = opValue.stringValue ?? "\(opValue)"
        let pieces = rawOp.components(separatedBy: "__")
        let op = pieces.last ?? rawOp
        let prefix = pieces.count > 1 ? pieces.dropLast().joined(separator: "__") : nil

        var supported = (Self.supported[field.dataType] ?? []).contains { Self.categories[$0]?.contains(op) ?? false }
        if let prefix {
            supported = supported && field.dataType == .date && Self.dateComponents.contains(prefix)
        }
        guard supported else {
            throw Failure(path: path + ["1"], message: "\(field.dataType.rawValue) does not support query expr \(Self.repr(opValue)).")
        }
        let valuePath = path + ["2"]
        let fieldId = field.id ?? 0
        func instance(_ condition: SQL?) -> SQL {
            let base: SQL = "SELECT 1 FROM custom_field_instances i WHERE i.document_id = \(sql: alias).id AND i.deleted_at IS NULL AND i.field_id = \(fieldId)"
            return condition.map { "EXISTS (\(base) AND \($0))" } ?? "EXISTS (\(base))"
        }

        if op == "exists" || op == "isnull" {
            guard let flag = Self.boolValue(value) else { throw Failure(path: valuePath, message: "Must be a valid boolean.") }
            if op == "exists" { return flag ? instance(nil) : "NOT \(instance(nil))" }
            let column = Self.column(for: field.dataType)
            return instance(flag ? "\(sql: column) IS NULL" : "\(sql: column) IS NOT NULL")
        }

        if field.dataType == .documentlink {
            guard case .array(let items) = value, let ids = Optional(items.compactMap(\.intValue)), ids.count == items.count else {
                throw Failure(path: valuePath, message: "Expected a list of items but got type \"\(Self.typeName(value))\".")
            }
            if op == "contains" {
                if ids.isEmpty { return instance("i.value_document_ids IS NOT NULL") }
                return instance(QueryFilters.and(ids.map { "EXISTS (SELECT 1 FROM json_each(i.value_document_ids) j WHERE j.value = \($0))" }))
            }
            // exact
            return instance("i.value_document_ids = \(Self.jsonArray(Array(Set(ids)).sorted()))")
        }

        if let prefix {
            // Date component lookups take integers.
            let expression = Self.dateComponent(prefix, column: "i.value_date")
            return instance(try comparison(expression, op: op, value: value, path: valuePath) { item in
                guard let n = item.intValue else { throw Failure(path: [], message: "A valid integer is required.") }
                return n.databaseValue
            })
        }

        let column: String
        let convert: (JSONValue) throws -> DatabaseValue
        switch field.dataType {
        case .string, .longtext, .url:
            column = Self.column(for: field.dataType)
            convert = { item in
                guard let s = Self.scalarString(item), !(item == .bool(true) || item == .bool(false)) else {
                    throw Failure(path: [], message: "Not a valid string.")
                }
                return s.databaseValue
            }
        case .integer:
            column = "i.value_int"
            convert = { item in
                guard let n = item.intValue else { throw Failure(path: [], message: "A valid integer is required.") }
                return n.databaseValue
            }
        case .float:
            column = "i.value_float"
            convert = { item in
                guard let n = item.doubleValue else { throw Failure(path: [], message: "A valid number is required.") }
                return n.databaseValue
            }
        case .boolean:
            column = "i.value_bool"
            convert = { item in
                guard let b = Self.boolValue(item) else { throw Failure(path: [], message: "Must be a valid boolean.") }
                return b.databaseValue
            }
        case .date:
            column = "i.value_date"
            let zone = timeZone, reference = now
            convert = { item in
                guard let text = item.stringValue, let date = Self.resolveDate(text, timeZone: zone, now: reference) else {
                    throw Failure(path: [], message: "Expected a date or a relative date such as \"today\" or \"in 30 days\".")
                }
                return date.iso.databaseValue
            }
        case .monetary:
            if Self.categories["string"]!.contains(op) {
                column = "i.value_monetary"
                convert = { item in
                    guard let s = Self.scalarString(item) else { throw Failure(path: [], message: "Not a valid string.") }
                    return s.databaseValue
                }
            } else {
                column = Self.monetaryAmount("i.value_monetary")
                convert = { item in
                    guard var text = Self.scalarString(item)?.trimmingCharacters(in: .whitespaces) else {
                        throw Failure(path: [], message: "A valid number is required.")
                    }
                    if let first = text.first, !first.isNumber, first != "-" { text = String(text.dropFirst(3)) }
                    guard let amount = Double(text) else { throw Failure(path: [], message: "A valid number is required.") }
                    return amount.databaseValue
                }
            }
        case .select:
            column = "i.value_select"
            let options = field.extraData?.selectOptions ?? []
            convert = { item in
                guard let s = Self.scalarString(item) else { throw Failure(path: [], message: "Not a valid string.") }
                return (options.first { $0.label == s }?.id ?? s).databaseValue
            }
        case .documentlink:
            throw Failure(path: path + ["1"], message: "documentlink does not support query expr \(Self.repr(opValue)).")
        }
        return instance(try comparison(column, op: op, value: value, path: valuePath, convert: convert))
    }

    private func comparison(_ column: String, op: String, value: JSONValue, path: [String], convert: (JSONValue) throws -> DatabaseValue) throws -> SQL {
        func converted(_ item: JSONValue, _ itemPath: [String]) throws -> DatabaseValue {
            do { return try convert(item) } catch let failure as Failure {
                throw Failure(path: itemPath, message: failure.message)
            }
        }
        switch op {
        case "in", "range":
            guard case .array(let items) = value else {
                throw Failure(path: path, message: "Expected a list of items but got type \"\(Self.typeName(value))\".")
            }
            if op == "in" && items.isEmpty { throw Failure(path: path, message: "This list may not be empty.") }
            if op == "range" && items.count != 2 {
                throw Failure(path: path, message: items.count < 2 ? "Ensure this field has at least 2 elements." : "Ensure this field has no more than 2 elements.")
            }
            let values = try items.enumerated().map { try converted($0.element, path + [String($0.offset)]) }
            if op == "range" { return "\(sql: column) BETWEEN \(values[0]) AND \(values[1])" }
            return "\(sql: column) IN \(values)"
        default:
            let bound = try converted(value, path)
            switch op {
            case "exact": return "\(sql: column) = \(bound)"
            case "gt": return "\(sql: column) > \(bound)"
            case "gte": return "\(sql: column) >= \(bound)"
            case "lt": return "\(sql: column) < \(bound)"
            case "lte": return "\(sql: column) <= \(bound)"
            case "icontains", "istartswith", "iendswith":
                let text = String.fromDatabaseValue(bound) ?? ""
                return QueryFilters.charLookup(column, lookup: op, value: text)!
            default:
                throw Failure(path: path, message: "Unsupported operator \(op)")
            }
        }
    }

    private mutating func customField(_ ref: JSONValue, path: [String], in db: Database) throws -> CustomField {
        let key: String
        let field: CustomField?
        switch ref {
        case .int(let id):
            key = "#\(id)"
            field = try fields[key] ?? CustomField.fetchOne(db, key: id)
        case .string(let name):
            key = name
            field = try fields[key] ?? CustomField.filter(Column("name") == name).fetchOne(db)
        default:
            key = ""
            field = nil
        }
        guard let field else { throw Failure(path: path, message: "\(Self.repr(ref)) is not a valid custom field.") }
        fields[key] = field
        return field
    }

    // MARK: Helpers

    static func column(for type: CustomFieldDataType) -> String {
        switch type {
        case .string: "i.value_text"
        case .longtext: "i.value_long_text"
        case .url: "i.value_url"
        case .date: "i.value_date"
        case .boolean: "i.value_bool"
        case .integer: "i.value_int"
        case .float: "i.value_float"
        case .monetary: "i.value_monetary"
        case .documentlink: "i.value_document_ids"
        case .select: "i.value_select"
        }
    }

    /// The numeric amount of `ZAR12.50` or `12.50`.
    static func monetaryAmount(_ column: String) -> String {
        "CAST(CASE WHEN substr(\(column), 1, 1) GLOB '[0-9-]' THEN \(column) ELSE substr(\(column), 4) END AS REAL)"
    }

    static func dateComponent(_ name: String, column: String) -> String {
        switch name {
        case "year": "CAST(strftime('%Y', \(column)) AS INTEGER)"
        case "iso_year": "CAST(strftime('%G', \(column)) AS INTEGER)"
        case "month": "CAST(strftime('%m', \(column)) AS INTEGER)"
        case "day": "CAST(strftime('%d', \(column)) AS INTEGER)"
        case "week": "CAST(strftime('%V', \(column)) AS INTEGER)"
        case "week_day": "(CAST(strftime('%w', \(column)) AS INTEGER) + 1)"
        case "iso_week_day": "((CAST(strftime('%w', \(column)) AS INTEGER) + 6) % 7 + 1)"
        default: "((CAST(strftime('%m', \(column)) AS INTEGER) + 2) / 3)"
        }
    }

    static func boolValue(_ value: JSONValue) -> Bool? {
        switch value {
        case .bool(let b): b
        case .int(let i) where i == 0 || i == 1: i == 1
        case .string(let s): ["true", "1"].contains(s.lowercased()) ? true : (["false", "0"].contains(s.lowercased()) ? false : nil)
        default: nil
        }
    }

    static func scalarString(_ value: JSONValue) -> String? {
        switch value {
        case .string(let s): s
        case .int(let i): String(i)
        case .double(let d): String(d)
        case .bool(let b): b ? "True" : "False"
        default: nil
        }
    }

    static func typeName(_ value: JSONValue) -> String {
        switch value {
        case .string: "str"
        case .int: "int"
        case .double: "float"
        case .bool: "bool"
        case .null: "NoneType"
        case .object: "dict"
        case .array: "list"
        }
    }

    static func repr(_ value: JSONValue) -> String {
        switch value {
        case .string(let s): "'\(s)'"
        case .int(let i): String(i)
        default: "\(value)"
        }
    }

    static func jsonArray(_ ids: [Int]) -> String {
        "[" + ids.map(String.init).joined(separator: ",") + "]"
    }

    /// A fixed `YYYY-MM-DD` date or a relative expression: today, yesterday, tomorrow,
    /// now, `in 30 days`, `30 days ago`, `1 month ago`, `in 2 weeks`, `-3 days`.
    static func resolveDate(_ text: String, timeZone: TimeZone, now: Date) -> CalendarDate? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).lowercased()
        if let date = CalendarDate(iso: trimmed), trimmed.count == 10 { return date }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        switch trimmed {
        case "today", "now": return CalendarDate(now, in: timeZone)
        case "yesterday": return CalendarDate(calendar.date(byAdding: .day, value: -1, to: now)!, in: timeZone)
        case "tomorrow": return CalendarDate(calendar.date(byAdding: .day, value: 1, to: now)!, in: timeZone)
        default: break
        }
        var words = trimmed.split(separator: " ").map(String.init)
        var sign = 1
        if words.first == "in" { words.removeFirst() }
        if words.last == "ago" { words.removeLast(); sign = -1 }
        if words.first == "+" { words.removeFirst() }
        if words.first == "-" { words.removeFirst(); sign = -1 }
        if words.count == 1, let first = words.first, let signChar = first.first, signChar == "-" || signChar == "+" {
            // "-3days" style
            let rest = first.dropFirst()
            let digits = rest.prefix { $0.isNumber }
            words = [String(digits), String(rest.dropFirst(digits.count))]
            if signChar == "-" { sign = -sign }
        }
        guard words.count == 2, var amount = Int(words[0]) else { return nil }
        amount *= sign
        let unit = words[1].hasSuffix("s") ? String(words[1].dropLast()) : words[1]
        let component: Calendar.Component
        switch unit {
        case "day", "d": component = .day
        case "week", "w": component = .weekOfYear
        case "month": component = .month
        case "year", "y": component = .year
        case "hour", "h": component = .hour
        case "minute", "min": component = .minute
        default: return nil
        }
        guard let date = calendar.date(byAdding: component, value: amount, to: now) else { return nil }
        return CalendarDate(date, in: timeZone)
    }
}
