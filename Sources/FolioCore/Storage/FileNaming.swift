import Foundation
import FolioTemplating
import GRDB

/// Everything a filename template can refer to, loaded from the database.
public struct NamingContext: Sendable {
    public var document: Document
    public var correspondent: Correspondent?
    public var documentType: DocumentType?
    public var storagePath: StoragePath?
    public var tags: [Tag]
    public var owner: User?
    public var customFields: [(field: CustomField, instance: CustomFieldInstance)]

    public init(document: Document, correspondent: Correspondent? = nil, documentType: DocumentType? = nil,
                storagePath: StoragePath? = nil, tags: [Tag] = [], owner: User? = nil,
                customFields: [(field: CustomField, instance: CustomFieldInstance)] = []) {
        self.document = document
        self.correspondent = correspondent
        self.documentType = documentType
        self.storagePath = storagePath
        self.tags = tags
        self.owner = owner
        self.customFields = customFields
    }

    /// Loads the context for `document`. Versions use their root document's metadata.
    public static func load(for document: Document, in db: Database) throws -> NamingContext {
        let root = try document.rootDocumentId.flatMap { try Document.fetchOne(db, key: $0) } ?? document
        let fields = try Row.fetchAll(db, sql: """
            SELECT f.id AS f_id FROM custom_field_instances i JOIN custom_fields f ON f.id = i.field_id
            WHERE i.document_id = ? AND i.deleted_at IS NULL ORDER BY f.name
            """, arguments: [root.id])
        var customFields: [(CustomField, CustomFieldInstance)] = []
        for row in fields {
            let fieldId: Int = row["f_id"]
            if let field = try CustomField.fetchOne(db, key: fieldId),
               let instance = try CustomFieldInstance.filter(Column("document_id") == root.id && Column("field_id") == fieldId).fetchOne(db) {
                customFields.append((field, instance))
            }
        }
        return NamingContext(
            document: root,
            correspondent: try root.correspondentId.flatMap { try Correspondent.fetchOne(db, key: $0) },
            documentType: try root.documentTypeId.flatMap { try DocumentType.fetchOne(db, key: $0) },
            storagePath: try root.storagePathId.flatMap { try StoragePath.fetchOne(db, key: $0) },
            tags: try root.id.map { try DocumentStore.tags(of: $0, in: db) } ?? [],
            owner: try root.ownerId.flatMap { try User.fetchOne(db, key: $0) },
            customFields: customFields
        )
    }
}

/// Builds stored file names from `FILENAME_FORMAT` or a storage path, like
/// Paperless-ngx `documents/file_handling.py` and `templating/filepath.py`.
public struct FileNamer: Sendable {
    public var format: String?
    public var removeNone: Bool
    public var timeZone: TimeZone

    /// Maximum bytes per path component (APFS and most file systems).
    static let maxComponentBytes = 255
    static let noValue = "-none-"

    public init(format: String?, removeNone: Bool = false, timeZone: TimeZone = .current) {
        self.format = format
        self.removeNone = removeNone
        self.timeZone = timeZone
    }

    public init(settings: Settings) {
        self.init(format: settings.filenameFormat, removeNone: settings.filenameFormatRemoveNone, timeZone: settings.timeZone)
    }

    /// Relative path (with extension) for the original or the archive file.
    /// `version` is the document's version index when it is a version of another document.
    public func filename(for context: NamingContext, fileExtension: String, counter: Int = 0, version: Int? = nil, archive: Bool = false) -> String {
        let ext = archive ? ".pdf" : fileExtension
        let versionSuffix = version.map { "_v\($0)" } ?? ""
        let counterSuffix = counter > 0 ? String(format: "_%02d", counter) : ""
        let suffix = versionSuffix + counterSuffix + ext

        let template = context.storagePath?.path ?? format.map(Self.convertLegacyFormat)
        if let template, let rendered = render(template, context: context) {
            var components = rendered.split(separator: "/").map(String.init)
            let last = components.removeLast()
            components = components.map { Self.truncate($0, maxBytes: Self.maxComponentBytes) }
            components.append(Self.truncate(last, maxBytes: Self.maxComponentBytes - suffix.utf8.count) + suffix)
            return components.joined(separator: "/")
        }
        let pk = context.document.rootDocumentId ?? context.document.id ?? 0
        return String(format: "%07d", pk) + suffix
    }

    /// A filename that does not collide with files under `root`, keeping `current` when it is still right.
    public func uniqueFilename(for context: NamingContext, fileExtension: String, version: Int? = nil, archive: Bool = false,
                               current: String?, originalFilename: String? = nil, root: URL) -> String {
        // Archive files follow the original's name when possible.
        if archive, let originalFilename {
            let stem = (originalFilename as NSString).deletingPathExtension
            let candidate = stem + ".pdf"
            if candidate == current || !FileManager.default.fileExists(atPath: root.appendingPathComponent(candidate).path) {
                return candidate
            }
        }
        var counter = 0
        while true {
            let name = filename(for: context, fileExtension: fileExtension, counter: counter, version: version, archive: archive)
            if name == current { return name }
            if !FileManager.default.fileExists(atPath: root.appendingPathComponent(name).path) { return name }
            counter += 1
        }
    }

    // MARK: Rendering

    /// Renders a filename template. nil means "fall back to the default name" (errors, unsafe paths).
    public func render(_ template: String, context: NamingContext) -> String? {
        guard let parsed = try? Template(template) else { return nil }
        var environment = TemplateEnvironment.paperless
        environment.strictUndefined = true
        environment.timeZone = timeZone
        guard let output = try? parsed.render(templateContext(context), environment: environment) else { return nil }

        var result = Self.cleanFilepath(output)
        if removeNone {
            result = result.replacingOccurrences(of: "/-none-/", with: "/")
                .replacingOccurrences(of: " -none-", with: "")
                .replacingOccurrences(of: "-none-", with: "")
            // Docs: "spaces before empty placeholders are removed, empty directories are omitted".
            result = result.split(separator: "/")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: "/")
        }
        result = result.replacingOccurrences(of: "-none-", with: "none")
        return Self.isSafeRelativePath(result) ? result : nil
    }

    /// `{title}` style formats from old Paperless versions become `{{ title }}`.
    static func convertLegacyFormat(_ format: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: "(?<!\\{)\\{(\\w*)\\}(?!\\})") else { return format }
        return regex.stringByReplacingMatches(in: format, range: NSRange(format.startIndex..., in: format), withTemplate: "{{ $1 }}")
    }

    static func cleanFilepath(_ value: String) -> String {
        var text = value.precomposedStringWithCanonicalMapping
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        if let regex = try? NSRegularExpression(pattern: "\\s*/\\s*") {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "/")
        }
        return text.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains { $0 == ".." || $0.isEmpty }
    }

    /// `pathvalidate.sanitize_filename(value, replacement_text="-")`.
    public static func sanitize(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let replaced = String(String.UnicodeScalarView(value.precomposedStringWithCanonicalMapping.unicodeScalars.map {
            invalid.contains($0) ? "-" : $0
        }))
        return replaced.trimmingCharacters(in: .whitespaces)
    }

    static func truncate(_ value: String, maxBytes: Int) -> String {
        guard value.utf8.count > maxBytes, maxBytes > 0 else { return value }
        var result = ""
        for character in value {
            if result.utf8.count + String(character).utf8.count > maxBytes { break }
            result.append(character)
        }
        return result
    }

    // MARK: Context

    func templateContext(_ c: NamingContext) -> [String: TemplateValue] {
        let doc = c.document
        let none = TemplateValue.placeholder(Self.noValue)
        var context: [String: TemplateValue] = [
            "title": .string(Self.sanitize(doc.title)),
            "correspondent": c.correspondent.map { .string(Self.sanitize($0.name)) } ?? none,
            "document_type": c.documentType.map { .string(Self.sanitize($0.name)) } ?? none,
            "asn": doc.archiveSerialNumber.map { .string(String($0)) } ?? none,
            "owner_username": c.owner.map { .string($0.username) } ?? none,
            "original_name": doc.originalFilename.map { .string((($0 as NSString).lastPathComponent as NSString).deletingPathExtension.precomposedStringWithCanonicalMapping) } ?? none,
            "doc_pk": .string(String(format: "%07d", doc.id ?? 0)),
            "tag_list": .string(Self.sanitize(c.tags.map(\.name).sorted().joined(separator: ","))),
            "tag_name_list": .array(c.tags.map { .string($0.name.precomposedStringWithCanonicalMapping) }),
        ]
        for (key, value) in dateParts(prefix: "created", date: doc.created) { context[key] = value }
        for (key, value) in dateParts(prefix: "added", date: CalendarDate(doc.added, in: timeZone)) { context[key] = value }

        var fields: [String: TemplateValue] = [:]
        for (field, instance) in c.customFields {
            fields[field.name] = .dict(["type": .string(field.dataType.rawValue), "value": customFieldValue(field, instance)])
        }
        context["custom_fields"] = .dict(fields)

        // Paperless-ngx MatchingModelContext: prints as the name, with `id`, `name` and `path` attributes.
        func related(_ id: Int?, _ name: String?, path: String? = nil) -> TemplateValue {
            guard let id, let name else { return .none }
            return .object(TemplateObject(typeName: "MatchingModelContext", text: name, attributes: [
                "id": .int(id), "name": .string(name), "path": path.map { .string($0) } ?? .none,
            ]))
        }
        context["document"] = .dict([
            "id": .int(doc.id ?? 0), "pk": .int(doc.id ?? 0),
            "title": .string(doc.title), "content": .string(doc.content),
            "page_count": doc.pageCount.map { .int($0) } ?? .none,
            "created": .date(doc.created.startDate(in: timeZone), includesTime: false, timeZone: timeZone),
            "added": .date(doc.added, includesTime: true, timeZone: timeZone),
            "modified": .date(doc.modified, includesTime: true, timeZone: timeZone),
            "archive_serial_number": doc.archiveSerialNumber.map { .int($0) } ?? .none,
            "mime_type": .string(doc.mimeType),
            "checksum": .string(doc.checksum),
            "archive_checksum": doc.archiveChecksum.map { .string($0) } ?? .none,
            "filename": doc.filename.map { .string($0) } ?? .none,
            "archive_filename": doc.archiveFilename.map { .string($0) } ?? .none,
            "original_filename": doc.originalFilename.map { .string($0) } ?? .none,
            "owner": c.owner.map { .dict(["username": .string($0.username), "id": .int($0.id ?? 0)]) } ?? .none,
            "tags": .array(c.tags.map { .dict(["name": .string($0.name), "id": .int($0.id ?? 0)]) }),
            "correspondent": related(c.correspondent?.id, c.correspondent?.name),
            "document_type": related(c.documentType?.id, c.documentType?.name),
            "storage_path": related(c.storagePath?.id, c.storagePath?.name, path: c.storagePath?.path),
        ])
        return context
    }

    func dateParts(prefix: String, date: CalendarDate) -> [String: TemplateValue] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        let instant = date.startDate(in: timeZone)
        formatter.dateFormat = "MMMM"
        let monthName = formatter.string(from: instant)
        formatter.dateFormat = "MMM"
        let monthShort = formatter.string(from: instant)
        return [
            prefix: .string(date.iso),
            "\(prefix)_year": .string(String(format: "%04d", date.year)),
            "\(prefix)_year_short": .string(String(format: "%02d", date.year % 100)),
            "\(prefix)_month": .string(String(format: "%02d", date.month)),
            "\(prefix)_month_name": .string(monthName),
            "\(prefix)_month_name_short": .string(monthShort),
            "\(prefix)_day": .string(String(format: "%02d", date.day)),
        ]
    }

    func customFieldValue(_ field: CustomField, _ i: CustomFieldInstance) -> TemplateValue {
        switch field.dataType {
        case .string: return i.valueText.map { .string(Self.sanitize($0)) } ?? .none
        case .longtext: return i.valueLongText.map { .string(Self.sanitize($0)) } ?? .none
        case .url: return i.valueUrl.map { .string(Self.sanitize($0)) } ?? .none
        case .monetary: return i.valueMonetary.map { .string(Self.sanitize($0)) } ?? .none
        case .boolean: return i.valueBool.map { .bool($0) } ?? .none
        case .integer: return i.valueInt.map { .int($0) } ?? .none
        case .float: return i.valueFloat.map { .double($0) } ?? .none
        case .date: return i.valueDate.map { .string($0.iso) } ?? .none
        case .documentlink: return i.valueDocumentIds.map { .array($0.map { .int($0) }) } ?? .none
        case .select:
            guard let id = i.valueSelect else { return .none }
            let label = field.extraData?.selectOptions?.first { $0.id == id }?.label ?? id
            return .string(Self.sanitize(label))
        }
    }
}
