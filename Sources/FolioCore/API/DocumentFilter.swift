import Foundation
import GRDB

/// Turns Paperless-ngx `DocumentFilterSet` query parameters into an SQL predicate
/// over `documents d`, and `ordering` into an ORDER BY clause.
public struct DocumentFilter: Sendable {
    public var access: AccessContext
    public var timeZone: TimeZone
    public var now: Date

    public init(access: AccessContext, timeZone: TimeZone, now: Date = Date()) {
        self.access = access
        self.timeZone = timeZone
        self.now = now
    }

    /// Parameters that are not filters (pagination, search, serializer options).
    public static let nonFilterParameters: Set<String> = [
        "page", "page_size", "ordering", "format", "fields", "truncate_content", "full_perms",
        "include_selection_data", "query", "text", "title_search", "more_like_id", "search", "version",
    ]

    /// Combined predicate for every filter parameter present. Unknown parameters are ignored.
    public func predicate(_ items: [(name: String, value: String)], in db: Database) throws -> SQL {
        var parts: [SQL] = []
        for (name, value) in items where !Self.nonFilterParameters.contains(name) {
            if let part = try filter(name: name, value: value, in: db) { parts.append(part) }
        }
        return QueryFilters.and(parts)
    }

    // MARK: - Individual filters

    func filter(name: String, value: String, in db: Database) throws -> SQL? {
        func number(_ text: String) throws -> Int {
            guard let n = Int(text.trimmingCharacters(in: .whitespaces)) else { throw FilterError(field: name, message: "Enter a number.") }
            return n
        }
        func numbers(_ text: String) throws -> [Int] {
            guard let list = QueryFilters.intList(text) else { throw FilterError(field: name, message: "Enter a number.") }
            return list
        }
        let trimmed = value.trimmingCharacters(in: .whitespaces)

        switch name {
        case "id": return trimmed.isEmpty ? nil : "d.id = \(try number(trimmed))"
        case "id__in": return trimmed.isEmpty ? nil : "d.id IN \(try numbers(trimmed))"

        case "is_tagged":
            guard let flag = QueryFilters.bool(trimmed) else { return nil }
            return flag ? "EXISTS (SELECT 1 FROM document_tags dt WHERE dt.document_id = d.id)"
                        : "NOT EXISTS (SELECT 1 FROM document_tags dt WHERE dt.document_id = d.id)"
        case "tags__id":
            return trimmed.isEmpty ? nil : "EXISTS (SELECT 1 FROM document_tags dt WHERE dt.document_id = d.id AND dt.tag_id = \(try number(trimmed)))"
        case "tags__id__in":
            guard let ids = QueryFilters.intList(trimmed), !ids.isEmpty else { return nil }
            return "EXISTS (SELECT 1 FROM document_tags dt WHERE dt.document_id = d.id AND dt.tag_id IN \(ids))"
        case "tags__id__all":
            guard let ids = QueryFilters.intList(trimmed), !ids.isEmpty else { return nil }
            return QueryFilters.and(ids.map { "EXISTS (SELECT 1 FROM document_tags dt WHERE dt.document_id = d.id AND dt.tag_id = \($0))" })
        case "tags__id__none":
            guard let ids = QueryFilters.intList(trimmed), !ids.isEmpty else { return nil }
            return "NOT EXISTS (SELECT 1 FROM document_tags dt WHERE dt.document_id = d.id AND dt.tag_id IN \(ids))"
        case "is_in_inbox":
            let inbox: SQL = "EXISTS (SELECT 1 FROM document_tags dt JOIN tags t ON t.id = dt.tag_id WHERE dt.document_id = d.id AND t.is_inbox_tag = 1)"
            if trimmed == "true" { return inbox }
            if trimmed == "false" { return "NOT \(inbox)" }
            return nil

        case "title_content":
            guard !trimmed.isEmpty else { return nil }
            return QueryFilters.or([
                QueryFilters.charLookup("d.title", lookup: "icontains", value: trimmed)!,
                QueryFilters.charLookup("d.content", lookup: "icontains", value: trimmed)!,
            ])

        case "custom_fields__icontains":
            return try customFieldsContains(trimmed, in: db)
        case "custom_fields__id__all":
            guard let ids = QueryFilters.intList(trimmed), !ids.isEmpty else { return nil }
            return QueryFilters.and(ids.map { "EXISTS (SELECT 1 FROM custom_field_instances i WHERE i.document_id = d.id AND i.deleted_at IS NULL AND i.field_id = \($0))" })
        case "custom_fields__id__in":
            guard let ids = QueryFilters.intList(trimmed), !ids.isEmpty else { return nil }
            return "EXISTS (SELECT 1 FROM custom_field_instances i WHERE i.document_id = d.id AND i.deleted_at IS NULL AND i.field_id IN \(ids))"
        case "custom_fields__id__none":
            guard let ids = QueryFilters.intList(trimmed), !ids.isEmpty else { return nil }
            return "NOT EXISTS (SELECT 1 FROM custom_field_instances i WHERE i.document_id = d.id AND i.deleted_at IS NULL AND i.field_id IN \(ids))"
        case "has_custom_fields":
            guard let flag = QueryFilters.bool(trimmed) else { return nil }
            let exists: SQL = "EXISTS (SELECT 1 FROM custom_field_instances i WHERE i.document_id = d.id AND i.deleted_at IS NULL)"
            return flag ? exists : "NOT \(exists)"
        case "custom_field_query":
            guard !trimmed.isEmpty else { return nil }
            return try CustomFieldQuery.predicate(value, alias: "d", timeZone: timeZone, now: now, in: db)

        case "shared_by__id":
            guard !trimmed.isEmpty else { return nil }
            return """
                (d.owner_id = \(try number(trimmed)) AND EXISTS (
                    SELECT 1 FROM object_permissions op WHERE op.object_type = 'document' AND op.object_id = d.id))
                """
        case "mime_type":
            guard !trimmed.isEmpty else { return nil }
            return QueryFilters.charLookup("d.mime_type", lookup: "icontains", value: trimmed)
        case "has_duplicates":
            guard let flag = QueryFilters.bool(trimmed) else { return nil }
            let visible = access.visibilityPredicate(objectType: Document.objectType, alias: "o")
            let exists: SQL = """
                EXISTS (SELECT 1 FROM documents o WHERE o.id != d.id AND o.root_document_id IS NULL AND \(visible)
                    AND (o.checksum = d.checksum OR o.checksum = NULLIF(d.archive_checksum, '')
                         OR o.archive_checksum = d.checksum OR o.archive_checksum = NULLIF(d.archive_checksum, '')))
                """
            return flag ? exists : "NOT \(exists)"

        case "archive_serial_number":
            return trimmed.isEmpty ? nil : "d.archive_serial_number = \(try number(trimmed))"
        case "archive_serial_number__isnull":
            guard let flag = QueryFilters.bool(trimmed) else { return nil }
            return flag ? "d.archive_serial_number IS NULL" : "d.archive_serial_number IS NOT NULL"
        case "archive_serial_number__gt": return trimmed.isEmpty ? nil : "d.archive_serial_number > \(try number(trimmed))"
        case "archive_serial_number__gte": return trimmed.isEmpty ? nil : "d.archive_serial_number >= \(try number(trimmed))"
        case "archive_serial_number__lt": return trimmed.isEmpty ? nil : "d.archive_serial_number < \(try number(trimmed))"
        case "archive_serial_number__lte": return trimmed.isEmpty ? nil : "d.archive_serial_number <= \(try number(trimmed))"
        case "archive_serial_number__exact": return trimmed.isEmpty ? nil : "d.archive_serial_number = \(try number(trimmed))"

        default:
            break
        }

        // Relations: correspondent, document_type, storage_path, owner.
        for (prefix, column, table) in [
            ("correspondent", "d.correspondent_id", "correspondents"),
            ("document_type", "d.document_type_id", "document_types"),
            ("storage_path", "d.storage_path_id", "storage_paths"),
            ("owner", "d.owner_id", "users"),
        ] where name.hasPrefix(prefix + "__") {
            let lookup = String(name.dropFirst(prefix.count + 2))
            switch lookup {
            case "isnull":
                guard let flag = QueryFilters.bool(trimmed) else { return nil }
                return flag ? "\(sql: column) IS NULL" : "\(sql: column) IS NOT NULL"
            case "id", "id__exact":
                return trimmed.isEmpty ? nil : "\(sql: column) = \(try number(trimmed))"
            case "id__in":
                return trimmed.isEmpty ? nil : "\(sql: column) IN \(try numbers(trimmed))"
            case "id__none":
                guard let ids = QueryFilters.intList(trimmed), !ids.isEmpty else { return nil }
                // Django `exclude(fk__id=x)` keeps rows where the relation is NULL.
                return "(\(sql: column) IS NULL OR \(sql: column) NOT IN \(ids))"
            default:
                if lookup.hasPrefix("name__") || lookup.hasPrefix("username__") {
                    let charLookup = String(lookup.split(separator: "__").last ?? "")
                    let nameColumn = table == "users" ? "username" : "name"
                    guard !trimmed.isEmpty,
                          let condition = QueryFilters.charLookup("x.\(nameColumn)", lookup: charLookup, value: value) else { return nil }
                    return "EXISTS (SELECT 1 FROM \(sql: table) x WHERE x.id = \(sql: column) AND \(condition))"
                }
                return nil
            }
        }
        if name.hasPrefix("tags__name__") {
            let lookup = String(name.dropFirst("tags__name__".count))
            guard !value.isEmpty, let condition = QueryFilters.charLookup("t.name", lookup: lookup, value: value) else { return nil }
            return "EXISTS (SELECT 1 FROM document_tags dt JOIN tags t ON t.id = dt.tag_id WHERE dt.document_id = d.id AND \(condition))"
        }

        // Text lookups on document columns.
        for (prefix, column) in [("title", "d.title"), ("content", "d.content"), ("original_filename", "d.original_filename"), ("checksum", "d.checksum")]
        where name.hasPrefix(prefix + "__") {
            let lookup = String(name.dropFirst(prefix.count + 2))
            guard QueryFilters.charLookups.contains(lookup), !trimmed.isEmpty else { return nil }
            return QueryFilters.charLookup(column, lookup: lookup, value: prefix == "content" ? trimmed : value)
        }

        // created is a calendar date.
        if name == "created" || name.hasPrefix("created__") {
            return try createdFilter(name: name, value: trimmed)
        }
        if name.hasPrefix("added__") || name.hasPrefix("modified__") {
            let column = name.hasPrefix("added") ? "d.added" : "d.modified"
            let lookup = String(name.drop { $0 != "_" }.dropFirst(2))
            return try datetimeFilter(name: name, column: column, lookup: lookup, value: trimmed)
        }
        return nil
    }

    private func createdFilter(name: String, value: String) throws -> SQL? {
        guard !value.isEmpty else { return nil }
        let lookup = name == "created" ? "exact" : String(name.dropFirst("created__".count)).replacingOccurrences(of: "date__", with: "")
        switch lookup {
        case "year", "month", "day":
            guard let n = Int(value) else { throw FilterError(field: name, message: "Enter a number.") }
            let (start, length) = lookup == "year" ? (1, 4) : lookup == "month" ? (6, 2) : (9, 2)
            return "CAST(substr(d.created, \(start), \(length)) AS INTEGER) = \(n)"
        default:
            guard let date = parseDateParameter(value) else { throw FilterError(field: name, message: "Enter a valid date.") }
            let op: String
            switch lookup {
            case "exact", "date": op = "="
            case "gt": op = ">"
            case "gte": op = ">="
            case "lt": op = "<"
            case "lte": op = "<="
            default: return nil
            }
            return "d.created \(sql: op) \(date.iso)"
        }
    }

    /// `created__date__gt=2024-01-01` and also datetime values (`2024-01-01T10:00:00Z`).
    private func parseDateParameter(_ value: String) -> CalendarDate? {
        if value.count == 10 { return CalendarDate(iso: value) }
        return QueryFilters.parseDateTime(value, timeZone: timeZone).map { CalendarDate($0, in: timeZone) }
    }

    private func datetimeFilter(name: String, column: String, lookup: String, value: String) throws -> SQL? {
        guard !value.isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func stamp(_ date: Date) -> String { QueryFilters.timestamp(date) }
        switch lookup {
        case "year", "month", "day":
            guard let n = Int(value) else { throw FilterError(field: name, message: "Enter a number.") }
            let offset = timeZone.secondsFromGMT(for: now)
            let format = lookup == "year" ? "%Y" : lookup == "month" ? "%m" : "%d"
            return "CAST(strftime(\(format), \(sql: column), \("\(offset) seconds")) AS INTEGER) = \(n)"
        case "date__gt", "date__gte", "date__lt", "date__lte", "date":
            guard let date = parseDateParameter(value) else { throw FilterError(field: name, message: "Enter a valid date.") }
            let start = date.startDate(in: timeZone)
            let nextStart = date.adding(days: 1).startDate(in: timeZone)
            switch lookup {
            case "date__gt": return "\(sql: column) >= \(stamp(nextStart))"
            case "date__gte": return "\(sql: column) >= \(stamp(start))"
            case "date__lt": return "\(sql: column) < \(stamp(start))"
            case "date__lte": return "\(sql: column) < \(stamp(nextStart))"
            default: return "(\(sql: column) >= \(stamp(start)) AND \(sql: column) < \(stamp(nextStart)))"
            }
        case "gt", "gte", "lt", "lte":
            guard let date = QueryFilters.parseDateTime(value, timeZone: timeZone) else {
                throw FilterError(field: name, message: "Enter a valid date/time.")
            }
            let op = ["gt": ">", "gte": ">=", "lt": "<", "lte": "<="][lookup]!
            return "\(sql: column) \(sql: op) \(stamp(date))"
        default:
            return nil
        }
    }

    /// Deprecated `custom_fields__icontains`: field names, values, select option labels.
    private func customFieldsContains(_ value: String, in db: Database) throws -> SQL? {
        guard !value.isEmpty else { return nil }
        var optionIds: [String] = []
        for field in try CustomField.fetchAll(db) {
            for option in field.extraData?.selectOptions ?? [] where option.label.lowercased().contains(value.lowercased()) {
                optionIds.append(option.id)
            }
        }
        let columns = ["f.name", "i.value_text", "CAST(i.value_bool AS TEXT)", "CAST(i.value_int AS TEXT)", "CAST(i.value_float AS TEXT)",
                       "i.value_date", "i.value_url", "i.value_monetary", "i.value_document_ids", "i.value_long_text"]
        var conditions = columns.compactMap { QueryFilters.charLookup($0, lookup: "icontains", value: value) }
        if !optionIds.isEmpty { conditions.append("i.value_select IN \(optionIds)") }
        return """
            EXISTS (SELECT 1 FROM custom_field_instances i JOIN custom_fields f ON f.id = i.field_id
                    WHERE i.document_id = d.id AND i.deleted_at IS NULL AND \(QueryFilters.or(conditions)))
            """
    }

    // MARK: - Ordering

    /// ORDER BY terms for `ordering`. `searchRank` is the rank expression when a search is active.
    public func ordering(_ param: String?, in db: Database) throws -> SQL {
        let allowed: [String: String] = [
            "id": "d.id",
            "title": "d.title COLLATE NOCASE",
            "correspondent__name": "(SELECT name FROM correspondents WHERE id = d.correspondent_id) COLLATE NOCASE",
            "document_type__name": "(SELECT name FROM document_types WHERE id = d.document_type_id) COLLATE NOCASE",
            "storage_path__name": "(SELECT name FROM storage_paths WHERE id = d.storage_path_id) COLLATE NOCASE",
            "created": "d.created",
            "modified": "d.modified",
            "added": "d.added",
            "archive_serial_number": "d.archive_serial_number",
            "num_notes": "(SELECT COUNT(*) FROM notes n WHERE n.document_id = d.id AND n.deleted_at IS NULL)",
            "owner": "d.owner_id",
            "page_count": "d.page_count",
        ]
        if let param, param.contains("custom_field_") {
            let descending = param.hasPrefix("-")
            let raw = param.components(separatedBy: "custom_field_").last ?? ""
            guard let fieldId = Int(raw.prefix { $0.isNumber }), let field = try CustomField.fetchOne(db, key: fieldId) else {
                throw FilterError(field: "custom_field_\(raw)", message: "Custom field not found")
            }
            let column: String
            switch field.dataType {
            case .string, .longtext: column = "COALESCE(i.value_text, i.value_long_text)"
            case .integer: column = "i.value_int"
            case .float: column = "i.value_float"
            case .date: column = "i.value_date"
            case .monetary: column = CustomFieldQueryCompiler.monetaryAmount("i.value_monetary")
            case .documentlink: column = "i.value_document_ids"
            case .url: column = "i.value_url"
            case .boolean: column = "i.value_bool"
            case .select:
                let options = (field.extraData?.selectOptions ?? []).sorted { $0.label < $1.label }
                let cases = options.enumerated().map { "WHEN \(sqlLiteral($0.element.id)) THEN \($0.offset)" }.joined(separator: " ")
                column = "CASE WHEN i.value_select IS NULL THEN \(options.count) " + (cases.isEmpty ? "" : "ELSE CASE i.value_select \(cases) ELSE 0 END ") + "END"
            }
            let value = "(SELECT \(column) FROM custom_field_instances i WHERE i.document_id = d.id AND i.field_id = \(fieldId) LIMIT 1)"
            let has = "EXISTS (SELECT 1 FROM custom_field_instances i WHERE i.document_id = d.id AND i.field_id = \(fieldId))"
            let direction = descending ? "DESC" : "ASC"
            return SQL(sql: "\(has) DESC, \(value) \(direction), d.id \(direction)")
        }
        guard let terms = QueryFilters.ordering(param, allowed: allowed) else {
            return "d.created DESC, d.id DESC"
        }
        let tieBreaker = terms[0].hasSuffix("DESC") ? "d.id DESC" : "d.id ASC"
        return SQL(sql: (terms + [tieBreaker]).joined(separator: ", "))
    }

    private func sqlLiteral(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
