import FolioParsing
import Foundation
import GRDB

public struct PaperlessImportOptions: Sendable {
    /// Passphrase of an export made with `--passphrase`. Without it, encrypted fields are left empty.
    public var passphrase: String?
    /// Fail when a file does not match the checksum in the manifest. When false, mismatches are warnings.
    public var verifyChecksums: Bool
    /// Train the classifier for "Auto" matching after the import (exports do not contain it).
    public var trainClassifier: Bool

    public init(passphrase: String? = nil, verifyChecksums: Bool = true, trainClassifier: Bool = true) {
        self.passphrase = passphrase
        self.verifyChecksums = verifyChecksums
        self.trainClassifier = trainClassifier
    }
}

/// Imports a Paperless-ngx `document_exporter` export (folder or `--zip` file), or a
/// FolioZero export, into an empty FolioZero home. Primary keys are kept, files are
/// stored under FolioZero's naming, and everything happens in one transaction: on
/// failure the database is unchanged and copied files are removed.
public enum PaperlessImporter {
    public static func run(
        app: FolioApp, source: URL, options: PaperlessImportOptions = .init(),
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> TransferReport {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else { throw TransferError.notFound(source.path) }

        // Checked again inside the import transaction.
        try await app.database.read { db in try ImportLoader.ensureEmpty(db) }

        var root = source
        var extracted: URL?
        defer { if let extracted { try? fm.removeItem(at: extracted) } }
        if !TransferPaths.isDirectory(source) {
            guard TransferZip.isZip(source) else { throw TransferError.notAnExport(source.path) }
            progress("Extracting \(source.lastPathComponent)")
            let directory = try app.makeScratchDirectory(prefix: "import")
            extracted = directory
            try TransferZip.extract(source, to: directory)
            root = directory
        }
        let manifest = root.appendingPathComponent("manifest.json")
        guard fm.fileExists(atPath: manifest.path) else { throw TransferError.notAnExport(source.path) }

        var report = TransferReport()
        let (version, cryptoParameters) = try readMetadata(in: root)
        report.sourceVersion = version
        var crypto: ExportCrypto?
        if let cryptoParameters {
            if let passphrase = options.passphrase {
                crypto = try ExportCrypto(passphrase: passphrase, metadata: cryptoParameters)
            } else {
                report.warn("The export has encrypted fields (mail account passwords and tokens). They are left empty because no passphrase was given.")
            }
        } else if options.passphrase != nil {
            report.warn("A passphrase was given, but the export has no encrypted fields.")
        }

        progress("Reading the manifest")
        var records = try decodeManifest(manifest)
        for split in splitManifests(in: root) {
            records += try decodeManifest(split)
        }
        try decryptFields(&records, crypto: crypto, clear: cryptoParameters != nil && crypto == nil)

        let scratch = try app.makeScratchDirectory(prefix: "import-work")
        defer { try? fm.removeItem(at: scratch) }
        let placed = MovedFiles()
        let context = ImportContext(
            root: root, settings: app.settings, storage: app.storage, options: options,
            moveFiles: extracted != nil, placed: placed, scratch: scratch, progress: progress
        )
        let loaded: (TransferReport, [Int])
        do {
            loaded = try await app.database.write { [records, report] db in
                let loader = ImportLoader(db: db, context: context, report: report)
                try loader.load(records)
                return (loader.report, loader.missingThumbnails)
            }
        } catch {
            for url in placed.urls {
                try? fm.removeItem(at: url)
                for root in [app.storage.originalsDir, app.storage.archiveDir] where url.path.hasPrefix(root.path) {
                    app.storage.removeEmptyDirectories(from: url.deletingLastPathComponent(), root: root)
                }
            }
            throw error
        }
        report = loaded.0

        if !loaded.1.isEmpty {
            progress("Generating \(loaded.1.count) missing thumbnails")
            for (index, id) in loaded.1.enumerated() {
                if index > 0, index % 100 == 0 { progress("Generating thumbnails (\(index)/\(loaded.1.count))") }
                do {
                    guard let document = try await app.database.read({ db in try Document.fetchOne(db, key: id) }),
                          let file = app.storage.archiveURL(document) ?? app.storage.originalURL(document) else { continue }
                    let image = await TransferImages.render(file, maxPixels: app.settings.thumbnailMaxPixels)
                    let jpeg = try ThumbnailRenderer.write(image, to: scratch, fileName: "\(id).jpg")
                    _ = try app.storage.place(jpeg, at: app.storage.thumbnailURL(documentId: id).lastPathComponent, root: app.storage.thumbnailDir)
                    report.add("thumbnails generated")
                } catch {
                    report.warn("Document \(id): could not generate a thumbnail: \(error)")
                }
            }
        }
        if options.trainClassifier {
            progress("Training the classifier")
            do {
                report.messages.append(try await DocumentClassifier.trainAndSave(app: app))
            } catch {
                report.warn("Could not train the classifier: \(error). Run: foliozero train")
            }
        }
        return report
    }

    // MARK: Reading

    /// Version and `__crypto__` parameters from `metadata.json` (or the older `version.json`).
    static func readMetadata(in root: URL) throws -> (String?, [String: JSONValue]?) {
        for name in ["metadata.json", "version.json"] {
            let url = root.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let value: JSONValue
            do {
                value = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: url))
            } catch {
                throw TransferError.invalidExport("cannot read \(name): \(error)")
            }
            let object = value.manifestObject ?? [:]
            return (object["version"]?.stringValue, object[ExportCrypto.metadataKey]?.manifestObject)
        }
        return (nil, nil)
    }

    static func decodeManifest(_ url: URL) throws -> [ManifestRecord] {
        do {
            return try JSONDecoder().decode([ManifestRecord].self, from: Data(contentsOf: url))
        } catch {
            throw TransferError.invalidExport("cannot parse \(url.lastPathComponent): \(error)")
        }
    }

    /// Per-document manifests written with `--split-manifest`.
    static func splitManifests(in root: URL) -> [URL] {
        TransferPaths.files(under: root)
            .filter { $0.hasSuffix("-manifest.json") }
            .map { root.appendingPathComponent($0) }
    }

    static func decryptFields(_ records: inout [ManifestRecord], crypto: ExportCrypto?, clear: Bool) throws {
        guard crypto != nil || clear else { return }
        for index in records.indices {
            // Social tokens are encrypted too, but FolioZero does not import them.
            guard records[index].model == "paperless_mail.mailaccount",
                  let fields = ExportCrypto.encryptedFields[records[index].model] else { continue }
            for field in fields {
                guard let value = records[index].fields[field]?.stringValue, !value.isEmpty else { continue }
                if let crypto {
                    do {
                        records[index].fields[field] = .string(try crypto.decrypt(value))
                    } catch {
                        throw TransferError.invalidExport("cannot decrypt \(records[index].model) \(records[index].pk.manifestJSONText) \(field). Is the passphrase right?")
                    }
                } else {
                    records[index].fields[field] = field == "password" ? .string("") : .null
                }
            }
        }
    }
}

struct ImportContext: Sendable {
    var root: URL
    var settings: Settings
    var storage: MediaStorage
    var options: PaperlessImportOptions
    /// Files come from a temporary extraction and can be moved instead of copied.
    var moveFiles: Bool
    var placed: MovedFiles
    var scratch: URL
    var progress: @Sendable (String) -> Void
}

/// Loads manifest records into the database inside one write transaction.
final class ImportLoader {
    let db: Database
    let context: ImportContext
    var report: TransferReport
    var missingThumbnails: [Int] = []

    private var byModel: [String: [ManifestRecord]] = [:]
    private var contentTypes: [Int: (app: String, model: String)] = [:]
    private var permissionCodenames: [Int: String] = [:]
    /// Imported ids by FolioZero object type ("user", "tag", "document", ...).
    private var ids: [String: Set<Int>] = [:]
    private var userIdsByName: [String: Int] = [:]
    private var groupIdsByName: [String: Int] = [:]
    /// Field id to option ids, for select fields from exports before Paperless-ngx 2.12.
    private var legacySelectOptions: [Int: [String]] = [:]
    private var clearedReferences: [String: Int] = [:]

    static let handledModels: Set<String> = [
        "contenttypes.contenttype", "auth.permission", "auth.group", "auth.user", "documents.uisettings",
        "documents.correspondent", "documents.documenttype", "documents.storagepath", "documents.tag",
        "documents.customfield", "documents.document", "documents.note", "documents.customfieldinstance",
        "documents.documentbarcode", "documents.savedview", "documents.savedviewfilterrule", "documents.sharelink",
        "documents.workflow", "documents.workflowtrigger", "documents.workflowaction", "documents.workflowactionemail",
        "documents.workflowactionwebhook", "documents.workflowrun", "paperless_mail.mailaccount",
        "paperless_mail.mailrule", "paperless_mail.processedmail", "guardian.userobjectpermission",
        "guardian.groupobjectpermission", "auditlog.logentry", "documents.paperlesstask",
        "paperless.applicationconfiguration", "authtoken.token", "socialaccount.socialaccount",
    ]

    init(db: Database, context: ImportContext, report: TransferReport) {
        self.db = db
        self.context = context
        self.report = report
    }

    func load(_ records: [ManifestRecord]) throws {
        try ensureEmpty()
        try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
        byModel = Dictionary(grouping: records, by: \.model)
        for (model, list) in byModel.sorted(by: { $0.key < $1.key }) where !Self.handledModels.contains(model) {
            report.skip(model, list.count)
            let reason = PaperlessCatalog.unsupportedModels[model] ?? "unknown model"
            report.warn("Skipped \(list.count) \(model) record(s): \(reason).")
        }

        loadContentTypes()
        loadPermissions()
        try loadGroups()
        try loadUsers()
        try loadUISettings()
        try loadMatchingObjects()
        try loadCustomFields()
        try loadDocuments()
        try loadNotes()
        try loadCustomFieldInstances()
        try loadBarcodes()
        try loadSavedViews()
        try loadShareLinks()
        try loadMail()
        try loadWorkflows()
        try loadObjectPermissions()
        try loadAuditLog()
        try loadTasks()
        try loadAppConfig()
        try loadTokens()
        try loadSocialAccounts()
        try placeFiles()
        context.progress("Rebuilding the search index")
        try SearchIndex.rebuild(in: db)
        try checkForeignKeys()

        for (field, count) in clearedReferences.sorted(by: { $0.key < $1.key }) {
            report.warn("\(field): \(count) reference(s) to objects missing from the export were cleared.")
        }
    }

    private func records(_ model: String) -> [ManifestRecord] {
        (byModel[model] ?? []).sorted { ($0.id ?? 0) < ($1.id ?? 0) }
    }

    // MARK: Checks

    /// Throws when the database already holds users, documents or other objects.
    static func ensureEmpty(_ db: Database) throws {
        var found: [String] = []
        for table in ["users", "groups", "documents", "tags", "correspondents", "document_types", "storage_paths",
                      "custom_fields", "saved_views", "workflows", "mail_accounts"] {
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            if count > 0 { found.append("\(count) \(table.replacingOccurrences(of: "_", with: " "))") }
        }
        if !found.isEmpty { throw TransferError.notEmpty(found.joined(separator: ", ")) }
    }

    private func ensureEmpty() throws {
        try Self.ensureEmpty(db)
        for directory in [context.storage.originalsDir, context.storage.archiveDir] where !TransferPaths.files(under: directory).isEmpty {
            report.warn("\(directory.path) already contains files. Imported files get names that do not collide with them.")
        }
    }

    private func checkForeignKeys() throws {
        let violations = try Row.fetchAll(db, sql: "PRAGMA foreign_key_check")
        guard !violations.isEmpty else { return }
        let details = violations.prefix(5).map { row -> String in
            let table: String = row["table"] ?? "?"
            let rowid: Int64? = row["rowid"]
            let parent: String = row["parent"] ?? "?"
            return "\(table) row \(rowid.map(String.init) ?? "?") refers to a missing \(parent) row"
        }
        throw TransferError.invalidExport("broken references: " + details.joined(separator: "; "))
    }

    // MARK: Reference helpers

    private func ref(_ value: JSONValue?, _ type: String, field: String) -> Int? {
        guard let value, !value.isNull else { return nil }
        var id: Int?
        switch value {
        case .array(let key) where type == "user": id = key.first?.stringValue.flatMap { userIdsByName[$0.lowercased()] }
        case .array(let key) where type == "group": id = key.first?.stringValue.flatMap { groupIdsByName[$0.lowercased()] }
        default: id = value.intValue
        }
        if let id, ids[type, default: []].contains(id) { return id }
        clearedReferences[field, default: 0] += 1
        return nil
    }

    private func refs(_ values: [JSONValue], _ type: String, field: String) -> [Int] {
        var seen = Set<Int>()
        return values.compactMap { ref($0, type, field: field) }.filter { seen.insert($0).inserted }
    }

    private func codename(_ value: JSONValue) -> String? {
        switch value {
        case .array(let key): key.first?.stringValue
        default: value.intValue.flatMap { permissionCodenames[$0] }
        }
    }

    private func contentTypeModel(_ value: JSONValue?) -> String? {
        switch value {
        case .array(let key) where key.count >= 2: key[1].stringValue
        default: value?.intValue.flatMap { contentTypes[$0]?.model }
        }
    }

    private func insert<R: MutablePersistableRecord>(_ record: inout R, from source: ManifestRecord, onConflict: Database.ConflictResolution? = nil) throws {
        do {
            try record.insert(db, onConflict: onConflict)
        } catch {
            throw TransferError.invalidExport("cannot import \(source.model) \(source.pk.manifestJSONText): \(error)")
        }
    }

    private func register(_ type: String, _ id: Int) {
        ids[type, default: []].insert(id)
    }

    // MARK: Auth

    private func loadContentTypes() {
        for record in records("contenttypes.contenttype") {
            guard let id = record.id, let app = record.string("app_label"), let model = record.string("model") else { continue }
            contentTypes[id] = (app, model)
        }
    }

    private func loadPermissions() {
        for record in records("auth.permission") {
            guard let id = record.id, let codename = record.string("codename") else { continue }
            permissionCodenames[id] = codename
        }
    }

    private func uniqueName(_ name: String, id: Int, in names: [String: Int], kind: String) -> String {
        guard names[name.lowercased()] != nil else { return name }
        let renamed = "\(name)-\(id)"
        report.warn("\(kind) \"\(name)\" (id \(id)) differs from another only by letter case; imported as \"\(renamed)\".")
        return renamed
    }

    private func loadGroups() throws {
        for record in records("auth.group") {
            guard let id = record.id, let rawName = record.string("name") else { report.skip("auth.group (invalid)"); continue }
            let name = uniqueName(rawName, id: id, in: groupIdsByName, kind: "Group")
            var group = Group(id: id, name: name)
            try insert(&group, from: record)
            register("group", id)
            groupIdsByName[rawName.lowercased()] = id
            report.add("groups")
            for codename in Set(record.list("permissions").compactMap(codename)) {
                try db.execute(sql: "INSERT OR IGNORE INTO group_permissions(group_id, codename) VALUES (?, ?)", arguments: [id, codename])
                report.add("group permissions")
            }
        }
    }

    private func loadUsers() throws {
        let users = records("auth.user")
        for record in users {
            guard let id = record.id, let username = record.string("username"), !username.isEmpty else {
                report.skip("auth.user (invalid)")
                continue
            }
            if username == "AnonymousUser" {
                report.skip("auth.user AnonymousUser")
                continue
            }
            let name = uniqueName(username, id: id, in: userIdsByName, kind: "User")
            var password = record.string("password") ?? ""
            if password.hasPrefix("!") {
                password = "" // Django's "unusable password"
            } else if !password.isEmpty, !password.hasPrefix(PasswordHasher.algorithm + "$") {
                let algorithm = password.split(separator: "$").first.map(String.init) ?? "unknown"
                report.warn("User \(name) has a \(algorithm) password hash, which FolioZero cannot check. Set a new password with: foliozero user password \(name)")
            }
            var user = User(
                id: id, username: name, password: password, email: record.string("email") ?? "",
                firstName: record.string("first_name") ?? "", lastName: record.string("last_name") ?? "",
                isSuperuser: record.bool("is_superuser") ?? false, isStaff: record.bool("is_staff") ?? false,
                isActive: record.bool("is_active") ?? true, dateJoined: record.date("date_joined") ?? Date(),
                lastLogin: record.date("last_login")
            )
            try insert(&user, from: record)
            register("user", id)
            userIdsByName[username.lowercased()] = id
            report.add("users")
        }
        for record in users {
            guard let id = record.id, ids["user", default: []].contains(id) else { continue }
            for groupId in refs(record.list("groups"), "group", field: "auth.user.groups") {
                try db.execute(sql: "INSERT OR IGNORE INTO user_groups(user_id, group_id) VALUES (?, ?)", arguments: [id, groupId])
            }
            for codename in Set(record.list("user_permissions").compactMap(codename)) {
                try db.execute(sql: "INSERT OR IGNORE INTO user_permissions(user_id, codename) VALUES (?, ?)", arguments: [id, codename])
                report.add("user permissions")
            }
        }
    }

    private func loadUISettings() throws {
        for record in records("documents.uisettings") {
            guard let userId = ref(record.value("user"), "user", field: "documents.uisettings.user") else {
                report.skip("documents.uisettings (no user)")
                continue
            }
            let settings = record.json("settings")?.manifestObject.map { JSONValue.object($0).manifestJSONText } ?? "{}"
            try db.execute(sql: "INSERT OR REPLACE INTO ui_settings(user_id, settings) VALUES (?, ?)", arguments: [userId, settings])
            report.add("ui settings")
        }
    }

    // MARK: Classification objects

    private struct MatchingFields {
        var name: String
        var match: String
        var algorithm: MatchingAlgorithm
        var isInsensitive: Bool
        var ownerId: Int?
    }

    private func matchingFields(_ record: ManifestRecord) -> MatchingFields {
        let raw = record.int("matching_algorithm") ?? MatchingAlgorithm.any.rawValue
        var algorithm = MatchingAlgorithm.none
        if let known = MatchingAlgorithm(rawValue: raw) {
            algorithm = known
        } else {
            report.warn("\(record.model) \(record.pk.manifestJSONText): unknown matching algorithm \(raw); set to none.")
        }
        return MatchingFields(
            name: record.string("name") ?? "", match: record.string("match") ?? "", algorithm: algorithm,
            isInsensitive: record.bool("is_insensitive") ?? true,
            ownerId: ref(record.value("owner"), "user", field: "\(record.model).owner")
        )
    }

    private func loadMatchingObjects() throws {
        for record in records("documents.correspondent") {
            guard let id = record.id else { continue }
            let f = matchingFields(record)
            var object = Correspondent(id: id, name: f.name, match: f.match, matchingAlgorithm: f.algorithm, isInsensitive: f.isInsensitive, ownerId: f.ownerId)
            try insert(&object, from: record)
            register(Correspondent.objectType, id)
            report.add("correspondents")
        }
        for record in records("documents.documenttype") {
            guard let id = record.id else { continue }
            let f = matchingFields(record)
            var object = DocumentType(id: id, name: f.name, match: f.match, matchingAlgorithm: f.algorithm, isInsensitive: f.isInsensitive, ownerId: f.ownerId)
            try insert(&object, from: record)
            register(DocumentType.objectType, id)
            report.add("document types")
        }
        for record in records("documents.storagepath") {
            guard let id = record.id else { continue }
            let f = matchingFields(record)
            var object = StoragePath(id: id, name: f.name, path: record.string("path") ?? "", match: f.match, matchingAlgorithm: f.algorithm, isInsensitive: f.isInsensitive, ownerId: f.ownerId)
            try insert(&object, from: record)
            register(StoragePath.objectType, id)
            report.add("storage paths")
        }
        let tagRecords = records("documents.tag")
        let tagIds = Set(tagRecords.compactMap(\.id))
        for record in tagRecords {
            guard let id = record.id else { continue }
            let f = matchingFields(record)
            var parentId = (record.value("tn_parent") ?? record.value("parent"))?.intValue
            if let parent = parentId, !tagIds.contains(parent) || parent == id {
                clearedReferences["documents.tag.parent", default: 0] += 1
                parentId = nil
            }
            var tag = Tag(id: id, name: f.name, color: record.string("color") ?? "#a6cee3", isInboxTag: record.bool("is_inbox_tag") ?? false,
                          parentId: parentId, match: f.match, matchingAlgorithm: f.algorithm, isInsensitive: f.isInsensitive, ownerId: f.ownerId)
            try insert(&tag, from: record)
            register(Tag.objectType, id)
            report.add("tags")
        }
    }

    // MARK: Custom fields

    private func loadCustomFields() throws {
        for record in records("documents.customfield") {
            guard let id = record.id, let name = record.string("name") else { continue }
            guard let type = CustomFieldDataType(rawValue: record.string("data_type") ?? "") else {
                report.skip("documents.customfield (unknown type)")
                report.warn("Custom field \(name): unknown data type \(record.string("data_type") ?? "nil"); skipped.")
                continue
            }
            var extra: CustomField.ExtraData?
            if let object = record.json("extra_data")?.manifestObject {
                var options: [CustomField.ExtraData.SelectOption]?
                if case .array(let items)? = object["select_options"] {
                    var legacy: [String] = []
                    options = items.compactMap { item in
                        if let option = item.manifestObject {
                            return .init(id: option["id"]?.stringValue ?? PasswordHasher.randomString(length: 16), label: option["label"]?.stringValue ?? "")
                        }
                        guard let label = item.stringValue else { return nil }
                        // Before Paperless-ngx 2.12 options were plain labels and values their index.
                        let newId = PasswordHasher.randomString(length: 16)
                        legacy.append(newId)
                        return .init(id: newId, label: label)
                    }
                    if !legacy.isEmpty { legacySelectOptions[id] = legacy }
                }
                let currency = object["default_currency"].flatMap { $0.isNull ? nil : $0.stringValue }
                if options != nil || currency != nil {
                    extra = CustomField.ExtraData(selectOptions: options, defaultCurrency: currency)
                }
            }
            var field = CustomField(id: id, name: name, dataType: type, extraData: extra, created: record.date("created") ?? Date())
            try insert(&field, from: record)
            register(CustomField.objectType, id)
            report.add("custom fields")
        }
    }

    private func loadCustomFieldInstances() throws {
        for record in records("documents.customfieldinstance") {
            guard let id = record.id,
                  let documentId = ref(record.value("document"), Document.objectType, field: "documents.customfieldinstance.document"),
                  let fieldId = ref(record.value("field"), CustomField.objectType, field: "documents.customfieldinstance.field") else {
                report.skip("documents.customfieldinstance (missing document or field)")
                continue
            }
            var instance = CustomFieldInstance(id: id, documentId: documentId, fieldId: fieldId, created: record.date("created") ?? Date())
            instance.valueText = record.string("value_text")
            instance.valueBool = record.bool("value_bool")
            instance.valueUrl = record.string("value_url")
            instance.valueDate = record.string("value_date").flatMap { CalendarDate(iso: $0) }
            instance.valueInt = record.int("value_int")
            instance.valueFloat = record.double("value_float")
            instance.valueMonetary = record.string("value_monetary")
            let links = record.list("value_document_ids")
            instance.valueDocumentIds = record.value("value_document_ids") == nil ? nil : links.compactMap(\.intValue)
            switch record.value("value_select") {
            case .int(let index)?:
                instance.valueSelect = legacySelectOptions[fieldId].flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? String(index)
            case let value?:
                instance.valueSelect = value.stringValue
            case nil:
                break
            }
            instance.valueLongText = record.string("value_long_text")
            instance.deletedAt = record.date("deleted_at")
            try insert(&instance, from: record, onConflict: .ignore)
            if db.changesCount > 0 { report.add("custom field values") } else { report.skip("documents.customfieldinstance (duplicate)") }
        }
    }

    // MARK: Documents

    private func loadDocuments() throws {
        let documents = records("documents.document")
        let documentIds = Set(documents.compactMap(\.id))
        for record in documents {
            guard let id = record.id else { continue }
            guard let mimeType = record.string("mime_type") else {
                throw TransferError.invalidExport("document \(id) has no mime_type")
            }
            let added = record.date("added") ?? Date()
            let created = record.string("created").flatMap { DjangoTime.parseCalendarDate($0, timeZone: context.settings.timeZone) }
                ?? CalendarDate(added, in: context.settings.timeZone)
            var rootId = record.int("root_document")
            if let root = rootId, !documentIds.contains(root) || root == id {
                clearedReferences["documents.document.root_document", default: 0] += 1
                rootId = nil
            }
            var document = Document(
                id: id, title: record.string("title") ?? "", content: record.string("content") ?? "",
                correspondentId: ref(record.value("correspondent"), Correspondent.objectType, field: "documents.document.correspondent"),
                documentTypeId: ref(record.value("document_type"), DocumentType.objectType, field: "documents.document.document_type"),
                storagePathId: ref(record.value("storage_path"), StoragePath.objectType, field: "documents.document.storage_path"),
                ownerId: ref(record.value("owner"), "user", field: "documents.document.owner"),
                created: created, modified: record.date("modified") ?? added, added: added, mimeType: mimeType,
                checksum: record.string("checksum") ?? "", originalFilename: record.string("original_filename"),
                archiveSerialNumber: record.int("archive_serial_number"), pageCount: record.int("page_count"),
                deletedAt: record.date("deleted_at"), restoredAt: record.date("restored_at"), rootDocumentId: rootId,
                versionIndex: rootId == nil ? nil : record.int("version_index"),
                versionLabel: record.string("version_label")
            )
            try insert(&document, from: record)
            register(Document.objectType, id)
            report.add(rootId == nil ? "documents" : "document versions")
            for tagId in refs(record.list("tags"), Tag.objectType, field: "documents.document.tags") {
                try DocumentTag(documentId: id, tagId: tagId).insert(db, onConflict: .ignore)
            }
        }
    }

    private func loadNotes() throws {
        for record in records("documents.note") {
            guard let id = record.id, let documentId = ref(record.value("document"), Document.objectType, field: "documents.note.document") else {
                report.skip("documents.note (missing document)")
                continue
            }
            var note = Note(id: id, documentId: documentId, note: record.string("note") ?? "", created: record.date("created") ?? Date(),
                            userId: ref(record.value("user"), "user", field: "documents.note.user"), deletedAt: record.date("deleted_at"))
            try insert(&note, from: record)
            register(Note.objectType, id)
            report.add("notes")
        }
    }

    private func loadBarcodes() throws {
        for record in records("documents.documentbarcode") {
            guard let id = record.id, let documentId = ref(record.value("document"), Document.objectType, field: "documents.documentbarcode.document") else {
                report.skip("documents.documentbarcode (missing document)")
                continue
            }
            var barcode = DocumentBarcode(id: id, documentId: documentId, page: record.int("page") ?? 1, value: record.string("value") ?? "", format: record.string("format") ?? "")
            try insert(&barcode, from: record)
            report.add("barcodes")
        }
    }

    // MARK: Views and sharing

    private func loadSavedViews() throws {
        // Paperless-ngx 3.x keeps dashboard/sidebar visibility in the owner's UI settings.
        var dashboard: [Int: Set<Int>] = [:]
        var sidebar: [Int: Set<Int>] = [:]
        for record in records("documents.uisettings") {
            guard let userId = record.int("user"),
                  let views = record.json("settings")?.manifestObject?["saved_views"]?.manifestObject else { continue }
            if case .array(let list)? = views["dashboard_views_visible_ids"] { dashboard[userId] = Set(list.compactMap(\.intValue)) }
            if case .array(let list)? = views["sidebar_views_visible_ids"] { sidebar[userId] = Set(list.compactMap(\.intValue)) }
        }
        for record in records("documents.savedview") {
            guard let id = record.id else { continue }
            let ownerId = ref(record.value("owner"), "user", field: "documents.savedview.owner")
            var view = SavedView(id: id, name: record.string("name") ?? "", ownerId: ownerId)
            view.icon = record.string("icon")
            view.sortField = record.string("sort_field")
            view.sortReverse = record.bool("sort_reverse") ?? false
            view.pageSize = record.int("page_size")
            view.displayMode = record.string("display_mode")
            view.displayFields = record.value("display_fields") == nil ? nil : record.list("display_fields").compactMap(\.stringValue)
            view.showOnDashboard = record.bool("show_on_dashboard") ?? ownerId.map { dashboard[$0]?.contains(id) ?? false } ?? false
            view.showInSidebar = record.bool("show_in_sidebar") ?? ownerId.map { sidebar[$0]?.contains(id) ?? false } ?? false
            try insert(&view, from: record)
            register(SavedView.objectType, id)
            report.add("saved views")
        }
        for record in records("documents.savedviewfilterrule") {
            guard let id = record.id, let viewId = ref(record.value("saved_view"), SavedView.objectType, field: "documents.savedviewfilterrule.saved_view") else {
                report.skip("documents.savedviewfilterrule (missing view)")
                continue
            }
            var rule = SavedViewFilterRule(id: id, savedViewId: viewId, ruleType: record.int("rule_type") ?? 0, value: record.string("value"))
            try insert(&rule, from: record)
            report.add("saved view filter rules")
        }
    }

    private func loadShareLinks() throws {
        for record in records("documents.sharelink") {
            guard let id = record.id, let slug = record.string("slug"),
                  let documentId = ref(record.value("document"), Document.objectType, field: "documents.sharelink.document") else {
                report.skip("documents.sharelink (missing document)")
                continue
            }
            var link = ShareLink(id: id, slug: slug, documentId: documentId, created: record.date("created") ?? Date(),
                                 expiration: record.date("expiration"),
                                 fileVersion: ShareLink.FileVersion(rawValue: record.string("file_version") ?? "") ?? .archive,
                                 ownerId: ref(record.value("owner"), "user", field: "documents.sharelink.owner"))
            link.deletedAt = record.date("deleted_at")
            try insert(&link, from: record)
            register(ShareLink.objectType, id)
            report.add("share links")
        }
    }

    // MARK: Mail

    private func loadMail() throws {
        for record in records("paperless_mail.mailaccount") {
            guard let id = record.id, let name = record.string("name") else { continue }
            var fields = record.fields.filter { !$0.value.isNull }
            for key in ["name", "owner", "expiration"] { fields.removeValue(forKey: key) }
            do {
                var config = try JSONValue.object(fields).decoded(as: MailAccount.Config.self)
                config.expiration = record.date("expiration")
                var account = MailAccount(id: id, name: name, ownerId: ref(record.value("owner"), "user", field: "paperless_mail.mailaccount.owner"), config: config)
                try insert(&account, from: record)
                register(MailAccount.objectType, id)
                report.add("mail accounts")
            } catch let error as DecodingError {
                report.skip("paperless_mail.mailaccount (invalid)")
                report.warn("Mail account \(name): \(error); skipped.")
            }
        }
        for record in records("paperless_mail.mailrule") {
            guard let id = record.id, let name = record.string("name") else { continue }
            guard let accountId = ref(record.value("account"), MailAccount.objectType, field: "paperless_mail.mailrule.account") else {
                report.skip("paperless_mail.mailrule (missing account)")
                continue
            }
            var fields = record.fields.filter { !$0.value.isNull }
            for key in ["name", "account", "order", "enabled", "owner"] { fields.removeValue(forKey: key) }
            do {
                let config = try JSONValue.object(fields).decoded(as: MailRule.Config.self)
                var rule = MailRule(id: id, name: name, accountId: accountId, order: record.int("order") ?? 0, enabled: record.bool("enabled") ?? true,
                                    ownerId: ref(record.value("owner"), "user", field: "paperless_mail.mailrule.owner"), config: config)
                try insert(&rule, from: record)
                register(MailRule.objectType, id)
                report.add("mail rules")
            } catch let error as DecodingError {
                report.skip("paperless_mail.mailrule (invalid)")
                report.warn("Mail rule \(name): \(error); skipped.")
            }
        }
        for record in records("paperless_mail.processedmail") {
            guard let id = record.id, let ruleId = ref(record.value("rule"), MailRule.objectType, field: "paperless_mail.processedmail.rule") else {
                report.skip("paperless_mail.processedmail (missing rule)")
                continue
            }
            var mail = ProcessedMail(ruleId: ruleId, folder: record.string("folder") ?? "", uid: record.string("uid") ?? "",
                                     subject: record.string("subject") ?? "", received: record.date("received"),
                                     status: record.string("status") ?? "", error: record.string("error"),
                                     ownerId: ref(record.value("owner"), "user", field: "paperless_mail.processedmail.owner"))
            mail.id = id
            mail.processed = record.date("processed") ?? mail.processed
            try insert(&mail, from: record, onConflict: .ignore)
            if db.changesCount > 0 { report.add("processed mails") }
        }
    }

    // MARK: Workflows

    private func loadWorkflows() throws {
        let triggers = Dictionary(records("documents.workflowtrigger").compactMap { r in r.id.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        let actions = Dictionary(records("documents.workflowaction").compactMap { r in r.id.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        let emails = Dictionary(records("documents.workflowactionemail").compactMap { r in r.id.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })
        let webhooks = Dictionary(records("documents.workflowactionwebhook").compactMap { r in r.id.map { ($0, r) } }, uniquingKeysWith: { a, _ in a })

        var usedTriggers = Set<Int>(), usedActions = Set<Int>()
        // Shared triggers/actions (Paperless links them many-to-many) are copied after
        // every original id is in place, so the copies' new ids cannot collide.
        var copies: [(workflowId: Int, trigger: ManifestRecord?, action: ManifestRecord?)] = []

        for record in records("documents.workflow") {
            guard let id = record.id, let name = record.string("name") else { continue }
            var workflow = Workflow(id: id, name: name, order: record.int("order") ?? 0, enabled: record.bool("enabled") ?? true)
            try insert(&workflow, from: record)
            register("workflow", id)
            report.add("workflows")
            for triggerId in record.intList("triggers") {
                guard let trigger = triggers[triggerId] else { clearedReferences["documents.workflow.triggers", default: 0] += 1; continue }
                if usedTriggers.insert(triggerId).inserted {
                    try insertTrigger(trigger, workflowId: id, keepId: true)
                } else {
                    copies.append((id, trigger, nil))
                }
            }
            for actionId in record.intList("actions") {
                guard let action = actions[actionId] else { clearedReferences["documents.workflow.actions", default: 0] += 1; continue }
                if usedActions.insert(actionId).inserted {
                    try insertAction(action, workflowId: id, keepId: true, emails: emails, webhooks: webhooks)
                } else {
                    copies.append((id, nil, action))
                }
            }
        }
        for copy in copies {
            if let trigger = copy.trigger { try insertTrigger(trigger, workflowId: copy.workflowId, keepId: false) }
            if let action = copy.action { try insertAction(action, workflowId: copy.workflowId, keepId: false, emails: emails, webhooks: webhooks) }
        }
        let orphanTriggers = triggers.count - usedTriggers.count, orphanActions = actions.count - usedActions.count
        if orphanTriggers > 0 { report.skip("documents.workflowtrigger (not used by a workflow)", orphanTriggers) }
        if orphanActions > 0 { report.skip("documents.workflowaction (not used by a workflow)", orphanActions) }

        for record in records("documents.workflowrun") {
            guard let id = record.id, let workflowId = ref(record.value("workflow"), "workflow", field: "documents.workflowrun.workflow"),
                  let type = WorkflowTriggerType(rawValue: record.int("type") ?? 0) else {
                report.skip("documents.workflowrun (missing workflow)")
                continue
            }
            var run = WorkflowRun(id: id, workflowId: workflowId, type: type,
                                  documentId: ref(record.value("document"), Document.objectType, field: "documents.workflowrun.document"),
                                  runAt: record.date("run_at") ?? Date())
            try insert(&run, from: record)
            report.add("workflow runs")
        }
    }

    private func insertTrigger(_ record: ManifestRecord, workflowId: Int, keepId: Bool) throws {
        guard let type = WorkflowTriggerType(rawValue: record.int("type") ?? WorkflowTriggerType.consumption.rawValue) else {
            report.skip("documents.workflowtrigger (unknown type)")
            return
        }
        var fields = record.fields.filter { !$0.value.isNull }
        fields.removeValue(forKey: "type")
        switch fields["sources"] {
        case .string(let text)?:
            fields["sources"] = .array(text.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map(JSONValue.int))
        case .array(let items)?:
            fields["sources"] = .array(items.compactMap(\.intValue).map(JSONValue.int))
        default: break
        }
        if let query = fields["filter_custom_field_query"], query.stringValue == nil || query.isManifestContainer {
            fields["filter_custom_field_query"] = .string(query.manifestJSONText)
        }
        do {
            let config = try JSONValue.object(fields).decoded(as: WorkflowTriggerConfig.self)
            var trigger = WorkflowTrigger(id: keepId ? record.id : nil, workflowId: workflowId, type: type, config: config)
            try insert(&trigger, from: record)
            report.add("workflow triggers")
        } catch let error as DecodingError {
            report.skip("documents.workflowtrigger (invalid)")
            report.warn("Workflow trigger \(record.pk.manifestJSONText): \(error); skipped.")
        }
    }

    private func insertAction(_ record: ManifestRecord, workflowId: Int, keepId: Bool, emails: [Int: ManifestRecord], webhooks: [Int: ManifestRecord]) throws {
        guard let type = WorkflowActionType(rawValue: record.int("type") ?? WorkflowActionType.assignment.rawValue) else {
            report.skip("documents.workflowaction (unknown type)")
            report.warn("Workflow action \(record.pk.manifestJSONText): unknown type \(record.int("type") ?? 0); skipped.")
            return
        }
        var fields = record.fields.filter { !$0.value.isNull }
        for key in ["type", "order", "email", "webhook"] { fields.removeValue(forKey: key) }
        for key in ["assign_custom_fields_values", "passwords"] {
            if let value = record.json(key) { fields[key] = value }
        }
        if case .array(let passwords)? = fields["passwords"] {
            fields["passwords"] = .array(passwords.compactMap { $0.stringValue.map(JSONValue.string) })
        }
        if let emailId = record.int("email") {
            if let email = emails[emailId] { fields["email"] = .object(email.fields.filter { !$0.value.isNull }) }
            else { clearedReferences["documents.workflowaction.email", default: 0] += 1 }
        }
        if let webhookId = record.int("webhook") {
            if let webhook = webhooks[webhookId] {
                var webhookFields = webhook.fields.filter { !$0.value.isNull }
                for key in ["params", "headers"] {
                    if let object = webhook.json(key)?.manifestObject {
                        webhookFields[key] = .object(object.mapValues { .string($0.stringValue ?? $0.manifestJSONText) })
                    } else {
                        webhookFields.removeValue(forKey: key)
                    }
                }
                fields["webhook"] = .object(webhookFields)
            } else {
                clearedReferences["documents.workflowaction.webhook", default: 0] += 1
            }
        }
        do {
            let config = try JSONValue.object(fields).decoded(as: WorkflowActionConfig.self)
            var action = WorkflowAction(id: keepId ? record.id : nil, workflowId: workflowId, type: type, order: record.int("order") ?? 0, config: config)
            try insert(&action, from: record)
            report.add("workflow actions")
        } catch let error as DecodingError {
            report.skip("documents.workflowaction (invalid)")
            report.warn("Workflow action \(record.pk.manifestJSONText): \(error); skipped.")
        }
    }

    // MARK: Permissions, history, tasks

    private func loadObjectPermissions() throws {
        var seen = Set<String>()
        for (model, principal) in [("guardian.userobjectpermission", "user"), ("guardian.groupobjectpermission", "group")] {
            for record in records(model) {
                guard let codename = record.value("permission").flatMap(codename),
                      let objectType = contentTypeModel(record.value("content_type")),
                      let objectId = record.value("object_pk")?.intValue else {
                    report.skip("\(model) (unresolvable)")
                    continue
                }
                let kind: ObjectPermission.Kind
                if codename.hasPrefix("view_") { kind = .view }
                else if codename.hasPrefix("change_") { kind = .change }
                else { report.skip("\(model) (\(codename.split(separator: "_").first ?? "") permission)"); continue }
                guard ids[objectType, default: []].contains(objectId) else {
                    report.skip("\(model) (object not imported)")
                    continue
                }
                guard let principalId = ref(record.value(principal), principal, field: "\(model).\(principal)") else {
                    report.skip("\(model) (missing \(principal))")
                    continue
                }
                guard seen.insert("\(objectType):\(objectId):\(kind.rawValue):\(principal):\(principalId)").inserted else { continue }
                var permission = ObjectPermission(objectType: objectType, objectId: objectId, permission: kind,
                                                  userId: principal == "user" ? principalId : nil,
                                                  groupId: principal == "group" ? principalId : nil)
                try insert(&permission, from: record)
                report.add("object permissions")
            }
        }
    }

    private func loadAuditLog() throws {
        for record in records("auditlog.logentry") {
            let action: AuditLogEntry.Action
            switch record.int("action") {
            case 0: action = .create
            case 1: action = .update
            case 2: action = .delete
            default:
                report.skip("auditlog.logentry (access entries)")
                continue
            }
            guard let objectType = contentTypeModel(record.value("content_type")),
                  let objectId = record.int("object_id") ?? record.string("object_pk").flatMap({ Int($0) }) else {
                report.skip("auditlog.logentry (unresolvable)")
                continue
            }
            var entry = AuditLogEntry(
                timestamp: record.date("timestamp") ?? Date(),
                actorId: ref(record.value("actor"), "user", field: "auditlog.logentry.actor"),
                action: action, objectType: objectType, objectId: objectId,
                objectRepr: record.string("object_repr") ?? "",
                changes: Self.auditChanges(record.json("changes")),
                remoteAddr: record.string("remote_addr")
            )
            entry.id = record.id
            try insert(&entry, from: record)
            report.add("audit log entries")
        }
    }

    /// django-auditlog changes (`{"field": [old, new]}`, many-to-many as
    /// `{"type": "m2m", "operation": "add", "objects": [...]}`) as `[old, new]` strings.
    static func auditChanges(_ value: JSONValue?) -> [String: [String?]]? {
        guard let object = value?.manifestObject else { return nil }
        func text(_ value: JSONValue) -> String? {
            switch value {
            case .null: nil
            case .string(let s): s
            default: value.stringValue ?? value.manifestJSONText
            }
        }
        var result: [String: [String?]] = [:]
        for (field, change) in object {
            switch change {
            case .array(let pair) where pair.count == 2:
                result[field] = pair.map(text)
            case .object(let m2m):
                let objects: String
                if case .array(let items)? = m2m["objects"] { objects = items.compactMap(text).joined(separator: ", ") } else { objects = "" }
                result[field] = m2m["operation"]?.stringValue == "add" ? [nil, objects] : [objects, nil]
            default:
                result[field] = [nil, text(change)]
            }
        }
        return result
    }

    private func loadTasks() throws {
        for record in records("documents.paperlesstask") {
            let rawType = (record.string("task_type") ?? record.string("task_name") ?? "")
                .replacingOccurrences(of: "documents.tasks.", with: "")
            let type = TaskRecord.TaskType(rawValue: rawType) ?? (rawType == "check_sanity" ? .sanityCheck : nil)
            guard let type, let taskId = record.string("task_id") else {
                report.skip("documents.paperlesstask (unknown type)")
                continue
            }
            let status: TaskRecord.Status = switch (record.string("status") ?? "").lowercased() {
            case "success": .success
            case "failure": .failure
            case "started", "retry": .started
            case "revoked": .revoked
            default: .pending
            }
            let trigger: TaskRecord.TriggerSource = record.string("trigger_source").flatMap(TaskRecord.TriggerSource.init(rawValue:)) ?? {
                switch record.string("type") {
                case "scheduled_task": .scheduled
                case "manual_task": .manual
                default: .system
                }
            }()
            func strings(_ value: JSONValue?) -> [String: String]? {
                value?.manifestObject?.compactMapValues { $0.isNull ? nil : ($0.stringValue ?? $0.manifestJSONText) }
            }
            var input = strings(record.json("input_data"))
            if input == nil, let file = record.string("task_file_name") { input = ["filename": file] }
            var task = TaskRecord(taskId: taskId, taskType: type, triggerSource: trigger, status: status,
                                  dateCreated: record.date("date_created") ?? Date(), inputData: input,
                                  ownerId: ref(record.value("owner"), "user", field: "documents.paperlesstask.owner"))
            task.id = record.id
            task.dateStarted = record.date("date_started")
            task.dateDone = record.date("date_done")
            task.durationSeconds = record.double("duration_seconds")
            task.waitTimeSeconds = record.double("wait_time_seconds")
            let result = record.json("result_data")
            task.resultData = strings(result)
            task.resultMessage = record.string("result") ?? record.string("result_message")
            if let related = (result?.manifestObject?["document_id"] ?? record.value("related_document"))?.intValue,
               ids[Document.objectType, default: []].contains(related) {
                task.relatedDocumentId = related
            }
            task.acknowledged = record.bool("acknowledged") ?? false
            try insert(&task, from: record, onConflict: .ignore)
            if db.changesCount > 0 { report.add("tasks") }
        }
    }

    private func loadAppConfig() throws {
        guard let record = records("paperless.applicationconfiguration").first else { return }
        try db.execute(sql: "INSERT OR REPLACE INTO app_config(id, config) VALUES (1, ?)", arguments: [JSONValue.object(record.fields).manifestJSONText])
        report.add("app config")
    }

    private func loadTokens() throws {
        for record in records("authtoken.token") {
            guard let key = record.pk.stringValue, let userId = ref(record.value("user"), "user", field: "authtoken.token.user") else {
                report.skip("authtoken.token (missing user)")
                continue
            }
            var token = AuthToken(key: key, userId: userId, created: record.date("created") ?? Date())
            try insert(&token, from: record, onConflict: .ignore)
            if db.changesCount > 0 { report.add("api tokens") }
        }
    }

    /// allauth `SocialAccount` rows keep OpenID Connect users signing in to the same account.
    private func loadSocialAccounts() throws {
        for record in records("socialaccount.socialaccount") {
            guard let userId = ref(record.value("user"), "user", field: "socialaccount.socialaccount.user"),
                  let provider = record.string("provider"), let uid = record.string("uid") else {
                report.skip("socialaccount.socialaccount (missing user)")
                continue
            }
            let extra = record.json("extra_data") ?? .object([:])
            var account = SocialAccount(id: record.id, userId: userId, provider: provider, uid: uid, extraData: extra.manifestJSONText,
                                        dateJoined: record.date("date_joined") ?? Date(), lastLogin: record.date("last_login") ?? Date())
            try insert(&account, from: record, onConflict: .ignore)
            if db.changesCount > 0 { report.add("social accounts") }
        }
    }

    // MARK: Files

    private func placeFiles() throws {
        let storage = context.storage
        var withoutArchive = 0
        defer {
            if withoutArchive > 0 {
                report.warn("\(withoutArchive) document(s) had an archive file that is not in the export (made with --no-archive?). Regenerate them with the archiver.")
            }
        }
        let documents = records("documents.document").filter { $0.id.map { ids[Document.objectType, default: []].contains($0) } ?? false }
        for (index, record) in documents.enumerated() {
            guard let id = record.id, var document = try Document.fetchOne(db, key: id) else { continue }
            if index % 100 == 0 { context.progress("Copying files (\(index)/\(documents.count))") }
            guard let name = record.exportedFileName else {
                throw TransferError.invalidExport("document \(id) does not refer to a file (\(ManifestRecord.fileNameKey) is missing)")
            }
            let source = try existingFile(name, documentId: id)
            let checksum = try Checksum.sha256(of: source)
            try verify(record.string("checksum"), sha256: checksum, file: source, label: name, documentId: id)
            document.checksum = checksum
            document.originalMetadata = TransferImages.metadata(of: source, mimeType: document.mimeType)

            let naming = try NamingContext.load(for: document, in: db)
            let version = document.rootDocumentId != nil ? document.versionIndex : nil
            let fileExtension = Consumer.fileExtension(for: name, mimeType: document.mimeType)
            let originalName = storage.namer.uniqueFilename(for: naming, fileExtension: fileExtension, version: version, current: nil, root: storage.originalsDir)
            try put(source, at: originalName, root: storage.originalsDir)
            document.filename = originalName
            report.add("files")

            if let archiveName = record.exportedArchiveName {
                let archive = try existingFile(archiveName, documentId: id)
                let archiveChecksum = try Checksum.sha256(of: archive)
                try verify(record.string("archive_checksum"), sha256: archiveChecksum, file: archive, label: archiveName, documentId: id)
                document.archiveMetadata = TransferImages.metadata(of: archive, mimeType: "application/pdf")
                let storedName = storage.namer.uniqueFilename(for: naming, fileExtension: ".pdf", version: version, archive: true, current: nil,
                                                              originalFilename: version == nil ? originalName : nil, root: storage.archiveDir)
                try put(archive, at: storedName, root: storage.archiveDir)
                document.archiveFilename = storedName
                document.archiveChecksum = archiveChecksum
                report.add("files")
            } else if record.string("archive_filename") != nil {
                withoutArchive += 1
            }

            if let thumbnailName = record.exportedThumbnailName,
               let thumbnail = try? TransferPaths.resolve(thumbnailName, under: context.root),
               FileManager.default.fileExists(atPath: thumbnail.path),
               let jpeg = try TransferImages.jpegThumbnail(from: thumbnail, maxPixels: context.settings.thumbnailMaxPixels, scratch: context.scratch) {
                let target = storage.thumbnailURL(documentId: id).lastPathComponent
                if jpeg == thumbnail {
                    try put(jpeg, at: target, root: storage.thumbnailDir)
                } else {
                    context.placed.add(try storage.place(jpeg, at: target, root: storage.thumbnailDir))
                }
                report.add("thumbnails")
            } else {
                missingThumbnails.append(id)
            }
            try document.update(db)
        }
    }

    private func existingFile(_ name: String, documentId: Int) throws -> URL {
        let url = try TransferPaths.resolve(name, under: context.root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TransferError.missingFile("\(name) (document \(documentId)). Was the export made with --data-only?")
        }
        return url
    }

    private func verify(_ expected: String?, sha256: String, file: URL, label: String, documentId: Int) throws {
        guard let expected = expected?.lowercased(), !expected.isEmpty else { return }
        let matches: Bool
        switch expected.count {
        case 64: matches = expected == sha256
        case 32: matches = try TransferChecksum.md5(of: file) == expected // exports before Paperless-ngx 3.0
        default:
            report.warn("Document \(documentId): unknown checksum format for \(label); not verified.")
            return
        }
        guard !matches else { return }
        if context.options.verifyChecksums { throw TransferError.checksumMismatch(documentId: documentId, file: label) }
        report.warn("Document \(documentId): \(label) does not match its checksum in the manifest; imported anyway.")
    }

    /// Copies (or, for a temporary zip extraction, moves) `source` to `relativePath` under `root`.
    private func put(_ source: URL, at relativePath: String, root: URL) throws {
        let destination: URL
        if context.moveFiles {
            destination = try context.storage.place(source, at: relativePath, root: root)
        } else {
            destination = try TransferPaths.resolve(relativePath, under: root)
            let fm = FileManager.default
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
        }
        context.placed.add(destination)
    }
}

extension JSONValue {
    var isManifestContainer: Bool {
        switch self {
        case .array, .object: true
        default: false
        }
    }
}
