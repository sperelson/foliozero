import Foundation
import GRDB
import ZIPFoundation

public struct PaperlessExportOptions: Sendable {
    /// Write one zip file into the target folder instead of loose files.
    public var zip: Bool
    /// Zip file name without `.zip`. Default `export-YYYY-MM-DD`.
    public var zipName: String?
    public var noArchive: Bool
    public var noThumbnails: Bool
    /// Name exported files with `FILENAME_FORMAT` / storage paths instead of `<created> <correspondent> <title>`.
    public var useFilenameFormat: Bool
    /// Remove files in the target that are not part of this export (with `zip`: everything except the zip).
    public var delete: Bool
    /// Encrypts mail account passwords and tokens, as `document_exporter --passphrase` does.
    public var passphrase: String?
    /// PBKDF2 iterations for `passphrase`. Paperless-ngx uses 1,000,000.
    public var keyIterations: Int

    public init(zip: Bool = false, zipName: String? = nil, noArchive: Bool = false, noThumbnails: Bool = false,
                useFilenameFormat: Bool = false, delete: Bool = false, passphrase: String? = nil, keyIterations: Int = 1_000_000) {
        self.zip = zip; self.zipName = zipName; self.noArchive = noArchive; self.noThumbnails = noThumbnails
        self.useFilenameFormat = useFilenameFormat; self.delete = delete; self.passphrase = passphrase; self.keyIterations = keyIterations
    }
}

/// Writes a `document_exporter`-compatible export (Paperless-ngx 3.4 manifest) that
/// Paperless-ngx's `document_importer` and FolioZero's importer can read.
public enum PaperlessExporter {
    struct ExportFile: Sendable {
        var source: URL
        var arcname: String
    }

    public static func run(
        app: FolioApp, target: URL, options: PaperlessExportOptions = .init(),
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> TransferReport {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else { throw TransferError.invalidTarget("That path doesn't exist: \(target.path)") }
        guard TransferPaths.isDirectory(target) else { throw TransferError.invalidTarget("That path isn't a directory: \(target.path)") }
        guard fm.isWritableFile(atPath: target.path) else { throw TransferError.invalidTarget("That path doesn't appear to be writable: \(target.path)") }

        let crypto = try options.passphrase.map { try ExportCrypto.generate(passphrase: $0, iterations: options.keyIterations) }
        let settings = app.settings
        let storage = app.storage
        progress("Reading the database")
        let (records, files, builtReport) = try await app.database.read { db in
            var builder = ManifestBuilder(db: db, settings: settings, storage: storage, options: options, crypto: crypto)
            try builder.build()
            return (builder.records, builder.files, builder.report)
        }
        var report = builtReport

        var metadata: [String: JSONValue] = ["version": .string(PaperlessCatalog.version), "exporter": .string("FolioZero")]
        if let crypto { metadata[ExportCrypto.metadataKey] = .object(crypto.metadata) }

        let sink: ExportSink
        if options.zip {
            let today = CalendarDate.today(in: settings.timeZone).iso
            sink = try ZipExportSink(target: target, name: options.zipName ?? "export-\(today)", delete: options.delete)
        } else {
            sink = DirectoryExportSink(target: target, delete: options.delete)
        }
        do {
            for (index, file) in files.enumerated() {
                if index % 200 == 0 { progress("Writing files (\(index)/\(files.count))") }
                try sink.addFile(file.source, as: file.arcname)
            }
            try sink.addData(try manifestData(records), as: "manifest.json")
            try sink.addData(try prettyJSON(.object(metadata)), as: "metadata.json")
            try sink.finish()
        } catch {
            sink.abort()
            throw error
        }
        report.add("files", files.count)
        report.outputPath = (sink as? ZipExportSink)?.finalURL.path ?? target.path
        return report
    }

    /// The manifest as Paperless-ngx writes it: a JSON array, one pretty-printed record per element.
    static func manifestData(_ records: [ManifestRecord]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = Data("[".utf8)
        for (index, record) in records.enumerated() {
            if index > 0 { data.append(Data(",\n".utf8)) }
            data.append(try encoder.encode(record))
        }
        data.append(Data("\n]".utf8))
        return data
    }

    static func prettyJSON(_ value: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}

// MARK: - Manifest

/// Reads FolioZero rows and turns them into Paperless-ngx manifest records.
struct ManifestBuilder {
    let db: Database
    let settings: Settings
    let storage: MediaStorage
    let options: PaperlessExportOptions
    let crypto: ExportCrypto?
    let tables = PaperlessCatalog.tables()

    var records: [ManifestRecord] = []
    var files: [PaperlessExporter.ExportFile] = []
    var report = TransferReport()

    private var ids: [String: Set<Int>] = [:]
    private var exportedStems = Set<String>()

    init(db: Database, settings: Settings, storage: MediaStorage, options: PaperlessExportOptions, crypto: ExportCrypto?) {
        self.db = db
        self.settings = settings
        self.storage = storage
        self.options = options
        self.crypto = crypto
    }

    private mutating func append(_ model: String, _ pk: JSONValue, _ fields: [String: JSONValue]) {
        records.append(ManifestRecord(model: model, pk: pk, fields: fields))
        report.add(model)
    }

    private func value(_ id: Int?) -> JSONValue { id.map(JSONValue.int) ?? .null }
    private func value(_ text: String?) -> JSONValue { text.map(JSONValue.string) ?? .null }
    private func value(_ date: Date?) -> JSONValue { date.map { .string(DjangoTime.format($0)) } ?? .null }

    /// `id` when it was exported as `type`, else null (Paperless-ngx checks every foreign key).
    private func existing(_ id: Int?, _ type: String) -> JSONValue {
        guard let id, ids[type, default: []].contains(id) else { return .null }
        return .int(id)
    }

    private func existing(_ list: [Int], _ type: String) -> JSONValue {
        .array(list.filter { ids[type, default: []].contains($0) }.map(JSONValue.int))
    }

    mutating func build() throws {
        let users = try User.order(Column("id")).fetchAll(db)
        ids["user"] = Set(users.compactMap(\.id))
        let groups = try Group.order(Column("id")).fetchAll(db)
        ids["group"] = Set(groups.compactMap(\.id))

        try exportMatchingObjects()
        try exportMail()
        try exportSavedViews()
        try exportGroupsAndUsers(groups: groups, users: users)
        exportContentTypes()
        try exportObjectPermissions()
        try exportWorkflows()
        try exportCustomFields()
        try exportBarcodes()
        try exportAppConfig()
        try exportNotes()
        try exportDocuments()
        try exportShareLinks()
        try exportProcessedMail()
        try exportAuditLog()
    }

    // MARK: Classification objects

    private func matchingFields<M: MatchingObject>(_ object: M) -> [String: JSONValue] {
        [
            "owner": existing(object.ownerId, "user"), "name": .string(object.name), "match": .string(object.match),
            "matching_algorithm": .int(object.matchingAlgorithm.rawValue), "is_insensitive": .bool(object.isInsensitive),
        ]
    }

    private mutating func exportMatchingObjects() throws {
        let correspondents = try Correspondent.order(Column("id")).fetchAll(db)
        let tags = try Tag.order(Column("id")).fetchAll(db)
        let types = try DocumentType.order(Column("id")).fetchAll(db)
        let paths = try StoragePath.order(Column("id")).fetchAll(db)
        ids[Correspondent.objectType] = Set(correspondents.compactMap(\.id))
        ids[Tag.objectType] = Set(tags.compactMap(\.id))
        ids[DocumentType.objectType] = Set(types.compactMap(\.id))
        ids[StoragePath.objectType] = Set(paths.compactMap(\.id))
        for object in correspondents { append("documents.correspondent", value(object.id), matchingFields(object)) }
        for tag in tags {
            var fields = matchingFields(tag)
            fields["tn_parent"] = existing(tag.parentId, Tag.objectType)
            fields["color"] = .string(tag.color)
            fields["is_inbox_tag"] = .bool(tag.isInboxTag)
            append("documents.tag", value(tag.id), fields)
        }
        for object in types { append("documents.documenttype", value(object.id), matchingFields(object)) }
        for path in paths {
            var fields = matchingFields(path)
            fields["path"] = .string(path.path)
            append("documents.storagepath", value(path.id), fields)
        }
    }

    // MARK: Mail

    private func secret(_ text: String?) throws -> JSONValue {
        guard let text else { return .null }
        guard let crypto, !text.isEmpty else { return .string(text) }
        return .string(try crypto.encrypt(text))
    }

    private mutating func exportMail() throws {
        let accounts = try MailAccount.order(Column("id")).fetchAll(db)
        ids[MailAccount.objectType] = Set(accounts.compactMap(\.id))
        for account in accounts {
            let c = account.config
            append("paperless_mail.mailaccount", value(account.id), [
                "owner": existing(account.ownerId, "user"), "name": .string(account.name),
                "imap_server": .string(c.imapServer), "imap_port": value(c.imapPort), "imap_security": .int(c.imapSecurity.rawValue),
                "username": .string(c.username), "password": try secret(c.password), "is_token": .bool(c.isToken),
                "character_set": .string(c.characterSet), "account_type": .int(c.accountType.rawValue),
                "refresh_token": try secret(c.refreshToken), "expiration": value(c.expiration),
            ])
        }
        let rules = try MailRule.order(Column("id")).fetchAll(db)
        ids[MailRule.objectType] = Set(rules.compactMap(\.id))
        for rule in rules {
            var fields = try JSONValue.manifestValue(of: rule.config).manifestObject ?? [:]
            fields["assign_tags"] = existing(rule.config.assignTags, Tag.objectType)
            fields["assign_document_type"] = existing(rule.config.assignDocumentType, DocumentType.objectType)
            fields["assign_correspondent"] = existing(rule.config.assignCorrespondent, Correspondent.objectType)
            fields["owner"] = existing(rule.ownerId, "user")
            fields["name"] = .string(rule.name)
            fields["order"] = .int(rule.order)
            fields["account"] = .int(rule.accountId)
            fields["enabled"] = .bool(rule.enabled)
            append("paperless_mail.mailrule", value(rule.id), fields)
        }
    }

    // MARK: Views, users, permissions

    private mutating func exportSavedViews() throws {
        let views = try SavedView.order(Column("id")).fetchAll(db)
        ids[SavedView.objectType] = Set(views.compactMap(\.id))
        for view in views {
            var fields: [String: JSONValue] = [
                "owner": existing(view.ownerId, "user"), "name": .string(view.name), "sort_field": value(view.sortField),
                "sort_reverse": .bool(view.sortReverse), "page_size": value(view.pageSize), "display_mode": value(view.displayMode),
                "display_fields": view.displayFields.map { .array($0.map(JSONValue.string)) } ?? .null,
            ]
            if let icon = view.icon { fields["icon"] = .string(icon) }
            append("documents.savedview", value(view.id), fields)
        }
        for rule in try SavedViewFilterRule.order(Column("id")).fetchAll(db) {
            append("documents.savedviewfilterrule", value(rule.id), [
                "saved_view": .int(rule.savedViewId), "rule_type": .int(rule.ruleType), "value": value(rule.value),
            ])
        }
    }

    private func permissionPKs(_ codenames: [String]) -> [JSONValue] {
        Set(codenames.compactMap { tables.permissionByCodename[$0] }).sorted().map(JSONValue.int)
    }

    private mutating func exportGroupsAndUsers(groups: [Group], users: [User]) throws {
        for group in groups {
            let codenames = try String.fetchAll(db, sql: "SELECT codename FROM group_permissions WHERE group_id = ?", arguments: [group.id])
            append("auth.group", value(group.id), ["name": .string(group.name), "permissions": .array(permissionPKs(codenames))])
        }
        for user in users {
            let groupIds = try Int.fetchAll(db, sql: "SELECT group_id FROM user_groups WHERE user_id = ? ORDER BY group_id", arguments: [user.id])
            let codenames = try String.fetchAll(db, sql: "SELECT codename FROM user_permissions WHERE user_id = ?", arguments: [user.id])
            let unknown = codenames.filter { tables.permissionByCodename[$0] == nil }
            if !unknown.isEmpty { report.warn("User \(user.username): permissions without a Paperless-ngx equivalent left out: \(unknown.sorted().joined(separator: ", "))") }
            // Django marks unusable passwords with a leading "!".
            let password = user.password.isEmpty ? "!" + PasswordHasher.randomString(length: 40) : user.password
            append("auth.user", value(user.id), [
                "password": .string(password), "last_login": value(user.lastLogin), "is_superuser": .bool(user.isSuperuser),
                "username": .string(user.username), "first_name": .string(user.firstName), "last_name": .string(user.lastName),
                "email": .string(user.email), "is_staff": .bool(user.isStaff), "is_active": .bool(user.isActive),
                "date_joined": value(user.dateJoined), "groups": .array(groupIds.map(JSONValue.int)),
                "user_permissions": .array(permissionPKs(codenames)),
            ])
        }
        for account in try SocialAccount.order(Column("id")).fetchAll(db) where ids["user", default: []].contains(account.userId) {
            append("socialaccount.socialaccount", value(account.id), [
                "user": .int(account.userId), "provider": .string(account.provider), "uid": .string(account.uid),
                "last_login": value(account.lastLogin), "date_joined": value(account.dateJoined), "extra_data": account.extraDataJSON,
            ])
        }

        // UI settings, with saved view visibility where Paperless-ngx 3.x keeps it.
        var settingsByUser: [Int: [String: JSONValue]] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT user_id, settings FROM ui_settings ORDER BY user_id") {
            let userId: Int = row["user_id"]
            let text: String = row["settings"] ?? "{}"
            settingsByUser[userId] = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))?.manifestObject ?? [:]
        }
        let views = try SavedView.fetchAll(db)
        for (ownerId, owned) in Dictionary(grouping: views.filter { $0.ownerId != nil }, by: { $0.ownerId! }) {
            let dashboard = owned.filter(\.showOnDashboard).compactMap(\.id).sorted()
            let sidebar = owned.filter(\.showInSidebar).compactMap(\.id).sorted()
            guard !dashboard.isEmpty || !sidebar.isEmpty, ids["user", default: []].contains(ownerId) else { continue }
            var settings = settingsByUser[ownerId] ?? [:]
            var savedViews = settings["saved_views"]?.manifestObject ?? [:]
            if savedViews["dashboard_views_visible_ids"] == nil { savedViews["dashboard_views_visible_ids"] = .array(dashboard.map(JSONValue.int)) }
            if savedViews["sidebar_views_visible_ids"] == nil { savedViews["sidebar_views_visible_ids"] = .array(sidebar.map(JSONValue.int)) }
            settings["saved_views"] = .object(savedViews)
            settingsByUser[ownerId] = settings
        }
        for (userId, settings) in settingsByUser.sorted(by: { $0.key < $1.key }) where ids["user", default: []].contains(userId) {
            append("documents.uisettings", .int(userId), ["user": .int(userId), "settings": .object(settings)])
        }
    }

    private mutating func exportContentTypes() {
        for record in tables.contentTypes { records.append(record); report.add(record.model) }
        for record in tables.permissions { records.append(record); report.add(record.model) }
    }

    private mutating func exportObjectPermissions() throws {
        var userPK = 0, groupPK = 0
        for permission in try ObjectPermission.order(Column("id")).fetchAll(db) {
            guard let contentType = tables.contentTypeByModel[permission.objectType],
                  let permissionPK = tables.permissionByContentType["\(contentType):\(permission.permission.rawValue)_\(permission.objectType)"] else {
                report.skip("object permissions (\(permission.objectType))")
                continue
            }
            var fields: [String: JSONValue] = [
                "permission": .int(permissionPK), "content_type": .int(contentType), "object_pk": .string(String(permission.objectId)),
            ]
            if let userId = permission.userId {
                fields["user"] = .int(userId)
                userPK += 1
                append("guardian.userobjectpermission", .int(userPK), fields)
            } else if let groupId = permission.groupId {
                fields["group"] = .int(groupId)
                groupPK += 1
                append("guardian.groupobjectpermission", .int(groupPK), fields)
            }
        }
    }

    // MARK: Workflows

    private mutating func exportWorkflows() throws {
        ids[CustomField.objectType] = Set(try Int.fetchAll(db, sql: "SELECT id FROM custom_fields"))
        let workflows = try Workflow.order(Column("id")).fetchAll(db)
        let triggers = try WorkflowTrigger.order(Column("id")).fetchAll(db)
        let actions = try WorkflowAction.order(Column("order"), Column("id")).fetchAll(db)

        for trigger in triggers {
            let c = trigger.config
            var fields = try JSONValue.manifestValue(of: c).manifestObject ?? [:]
            fields["type"] = .int(trigger.type.rawValue)
            fields["sources"] = .string(c.sources.map(String.init).joined(separator: ","))
            fields["filter_mailrule"] = existing(c.filterMailrule, MailRule.objectType)
            fields["filter_has_tags"] = existing(c.filterHasTags, Tag.objectType)
            fields["filter_has_all_tags"] = existing(c.filterHasAllTags, Tag.objectType)
            fields["filter_has_not_tags"] = existing(c.filterHasNotTags, Tag.objectType)
            fields["filter_has_correspondent"] = existing(c.filterHasCorrespondent, Correspondent.objectType)
            fields["filter_has_any_correspondents"] = existing(c.filterHasAnyCorrespondents, Correspondent.objectType)
            fields["filter_has_not_correspondents"] = existing(c.filterHasNotCorrespondents, Correspondent.objectType)
            fields["filter_has_document_type"] = existing(c.filterHasDocumentType, DocumentType.objectType)
            fields["filter_has_any_document_types"] = existing(c.filterHasAnyDocumentTypes, DocumentType.objectType)
            fields["filter_has_not_document_types"] = existing(c.filterHasNotDocumentTypes, DocumentType.objectType)
            fields["filter_has_storage_path"] = existing(c.filterHasStoragePath, StoragePath.objectType)
            fields["filter_has_any_storage_paths"] = existing(c.filterHasAnyStoragePaths, StoragePath.objectType)
            fields["filter_has_not_storage_paths"] = existing(c.filterHasNotStoragePaths, StoragePath.objectType)
            fields["schedule_date_custom_field"] = existing(c.scheduleDateCustomField, CustomField.objectType)
            append("documents.workflowtrigger", value(trigger.id), fields)
        }

        var actionRecords: [ManifestRecord] = []
        for action in actions {
            guard let id = action.id else { continue }
            let c = action.config
            var fields = try JSONValue.manifestValue(of: c).manifestObject ?? [:]
            fields["type"] = .int(action.type.rawValue)
            fields["order"] = .int(action.order)
            fields["assign_title"] = value(c.assignTitle)
            fields["assign_tags"] = existing(c.assignTags, Tag.objectType)
            fields["assign_correspondent"] = existing(c.assignCorrespondent, Correspondent.objectType)
            fields["assign_document_type"] = existing(c.assignDocumentType, DocumentType.objectType)
            fields["assign_storage_path"] = existing(c.assignStoragePath, StoragePath.objectType)
            fields["assign_owner"] = existing(c.assignOwner, "user")
            fields["assign_view_users"] = existing(c.assignViewUsers, "user")
            fields["assign_view_groups"] = existing(c.assignViewGroups, "group")
            fields["assign_change_users"] = existing(c.assignChangeUsers, "user")
            fields["assign_change_groups"] = existing(c.assignChangeGroups, "group")
            fields["assign_custom_fields"] = existing(c.assignCustomFields, CustomField.objectType)
            fields["remove_tags"] = existing(c.removeTags, Tag.objectType)
            fields["remove_document_types"] = existing(c.removeDocumentTypes, DocumentType.objectType)
            fields["remove_correspondents"] = existing(c.removeCorrespondents, Correspondent.objectType)
            fields["remove_storage_paths"] = existing(c.removeStoragePaths, StoragePath.objectType)
            fields["remove_owners"] = existing(c.removeOwners, "user")
            fields["remove_view_users"] = existing(c.removeViewUsers, "user")
            fields["remove_view_groups"] = existing(c.removeViewGroups, "group")
            fields["remove_change_users"] = existing(c.removeChangeUsers, "user")
            fields["remove_change_groups"] = existing(c.removeChangeGroups, "group")
            fields["remove_custom_fields"] = existing(c.removeCustomFields, CustomField.objectType)
            fields["email"] = .null
            fields["webhook"] = .null
            if let email = c.email {
                append("documents.workflowactionemail", .int(id), [
                    "subject": .string(email.subject), "body": .string(email.body), "to": .string(email.to),
                    "include_document": .bool(email.includeDocument),
                ])
                fields["email"] = .int(id)
            }
            if let webhook = c.webhook {
                append("documents.workflowactionwebhook", .int(id), [
                    "url": .string(webhook.url), "use_params": .bool(webhook.useParams), "as_json": .bool(webhook.asJSON),
                    "params": webhook.params.map { .object($0.mapValues(JSONValue.string)) } ?? .null,
                    "body": value(webhook.body),
                    "headers": webhook.headers.map { .object($0.mapValues(JSONValue.string)) } ?? .null,
                    "include_document": .bool(webhook.includeDocument),
                ])
                fields["webhook"] = .int(id)
            }
            actionRecords.append(ManifestRecord(model: "documents.workflowaction", pk: .int(id), fields: fields))
        }
        // Paperless-ngx writes actions before their email and webhook rows; any order imports.
        for record in actionRecords { records.append(record); report.add(record.model) }

        for workflow in workflows {
            guard let id = workflow.id else { continue }
            append("documents.workflow", .int(id), [
                "name": .string(workflow.name), "order": .int(workflow.order), "enabled": .bool(workflow.enabled),
                "triggers": .array(triggers.filter { $0.workflowId == id }.compactMap(\.id).map(JSONValue.int)),
                "actions": .array(actions.filter { $0.workflowId == id }.compactMap(\.id).map(JSONValue.int)),
            ])
        }
    }

    // MARK: Custom fields

    private mutating func exportCustomFields() throws {
        let fields = try CustomField.order(Column("id")).fetchAll(db)
        for field in fields {
            var extra: JSONValue = .null
            if let data = field.extraData {
                var object: [String: JSONValue] = [:]
                if let options = data.selectOptions {
                    object["select_options"] = .array(options.map { .object(["id": .string($0.id), "label": .string($0.label)]) })
                }
                if let currency = data.defaultCurrency { object["default_currency"] = .string(currency) }
                extra = .object(object)
            }
            append("documents.customfield", value(field.id), [
                "created": value(field.created), "name": .string(field.name), "data_type": .string(field.dataType.rawValue), "extra_data": extra,
            ])
        }
        for i in try CustomFieldInstance.order(Column("id")).fetchAll(db) {
            append("documents.customfieldinstance", value(i.id), [
                "deleted_at": value(i.deletedAt), "created": value(i.created), "document": .int(i.documentId), "field": .int(i.fieldId),
                "value_text": value(i.valueText), "value_bool": i.valueBool.map(JSONValue.bool) ?? .null, "value_url": value(i.valueUrl),
                "value_date": value(i.valueDate?.iso), "value_int": value(i.valueInt), "value_float": i.valueFloat.map(JSONValue.double) ?? .null,
                "value_monetary": value(i.valueMonetary),
                "value_document_ids": i.valueDocumentIds.map { .array($0.map(JSONValue.int)) } ?? .null,
                "value_select": value(i.valueSelect), "value_long_text": value(i.valueLongText),
            ])
        }
    }

    private mutating func exportBarcodes() throws {
        for barcode in try DocumentBarcode.order(Column("id")).fetchAll(db) {
            append("documents.documentbarcode", value(barcode.id), [
                "document": .int(barcode.documentId), "page": .int(barcode.page), "value": .string(barcode.value), "format": .string(barcode.format),
            ])
        }
    }

    private mutating func exportAppConfig() throws {
        guard let text = try String.fetchOne(db, sql: "SELECT config FROM app_config WHERE id = 1"),
              let object = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))?.manifestObject else { return }
        let fields = object.filter { PaperlessCatalog.appConfigFields.contains($0.key) }
        let dropped = object.keys.filter { !PaperlessCatalog.appConfigFields.contains($0) }
        if !dropped.isEmpty { report.warn("App config keys without a Paperless-ngx equivalent left out: \(dropped.sorted().joined(separator: ", "))") }
        append("paperless.applicationconfiguration", .int(1), fields)
    }

    // MARK: Documents

    private mutating func exportNotes() throws {
        for note in try Note.order(Column("id")).fetchAll(db) {
            append("documents.note", value(note.id), [
                "deleted_at": value(note.deletedAt), "note": .string(note.note), "created": value(note.created),
                "document": .int(note.documentId), "user": existing(note.userId, "user"),
            ])
        }
    }

    private mutating func exportDocuments() throws {
        let documents = try Document.order(Column("id")).fetchAll(db)
        for document in documents {
            guard let id = document.id else { continue }
            let tagIds = try DocumentStore.tagIds(of: id, in: db)
            var record = ManifestRecord(model: "documents.document", pk: .int(id), fields: [
                "owner": existing(document.ownerId, "user"), "deleted_at": value(document.deletedAt), "restored_at": value(document.restoredAt),
                "correspondent": value(document.correspondentId), "storage_path": value(document.storagePathId),
                // Paperless-ngx limits titles to 128 characters.
                "title": .string(String(document.title.prefix(128))), "document_type": value(document.documentTypeId),
                "content": .string(document.content), "mime_type": .string(document.mimeType), "tags": .array(tagIds.map(JSONValue.int)),
                "checksum": .string(document.checksum), "archive_checksum": value(document.archiveFilename == nil ? nil : document.archiveChecksum),
                "page_count": value(document.pageCount), "created": .string(document.created.iso), "modified": value(document.modified),
                "added": value(document.added), "filename": value(document.filename),
                "archive_filename": value(document.archiveFilename), "original_filename": value(document.originalFilename),
                "archive_serial_number": value(document.archiveSerialNumber), "root_document": value(document.rootDocumentId),
                "version_index": value(document.versionIndex), "version_label": value(document.versionLabel),
            ])
            guard let original = storage.originalURL(document), FileManager.default.fileExists(atPath: original.path) else {
                throw TransferError.missingFile("document \(id): original file \(document.filename ?? "(none)") is not in the media folder")
            }
            let context = try NamingContext.load(for: document, in: db)
            let base = exportName(for: document, context: context)
            let stem = (base as NSString).deletingPathExtension
            record.exportedFileName = base
            files.append(.init(source: original, arcname: base))

            if !options.noThumbnails {
                let thumbnail = storage.thumbnailURL(documentId: id)
                if FileManager.default.fileExists(atPath: thumbnail.path) {
                    // FolioZero thumbnails are JPEG; Paperless-ngx's importer copies the file whatever its name.
                    let name = stem + "-thumbnail.jpg"
                    record.exportedThumbnailName = name
                    files.append(.init(source: thumbnail, arcname: name))
                } else {
                    report.skip("thumbnails (missing in the media folder)")
                }
            }
            if !options.noArchive, let archive = storage.archiveURL(document) {
                guard FileManager.default.fileExists(atPath: archive.path) else {
                    throw TransferError.missingFile("document \(id): archive file \(document.archiveFilename ?? "") is not in the media folder")
                }
                let name = stem + "-archive.pdf"
                record.exportedArchiveName = name
                files.append(.init(source: archive, arcname: name))
            }
            records.append(record)
            report.add("documents.document")
        }
    }

    /// A unique name in the export, like `document_exporter`: `<created> <correspondent> <title>.<ext>`,
    /// or the filename format with `useFilenameFormat`.
    private mutating func exportName(for document: Document, context: NamingContext) -> String {
        let fileExtension = document.fileExtension
        let version = document.rootDocumentId != nil ? document.versionIndex : nil
        var counter = 0
        while true {
            let name: String
            if options.useFilenameFormat {
                name = storage.namer.filename(for: context, fileExtension: fileExtension, counter: counter, version: version)
            } else {
                let root = context.document
                var head = root.created.iso
                if let correspondent = context.correspondent { head += " \(correspondent.name)" }
                if !root.title.isEmpty { head += " \(root.title)" }
                let tail = (counter > 0 ? String(format: "_%02d", counter) : "") + fileExtension
                // Leave room for "-thumbnail.jpg" / "-archive.pdf" within 255 bytes.
                name = FileNamer.sanitize(FileNamer.truncate(head, maxBytes: 240 - tail.utf8.count) + tail)
            }
            let key = (name as NSString).deletingPathExtension.lowercased()
            if exportedStems.insert(key).inserted { return name }
            counter += 1
        }
    }

    private mutating func exportShareLinks() throws {
        for link in try ShareLink.order(Column("id")).fetchAll(db) {
            append("documents.sharelink", value(link.id), [
                "deleted_at": value(link.deletedAt), "created": value(link.created), "expiration": value(link.expiration),
                "slug": .string(link.slug), "document": .int(link.documentId), "file_version": .string(link.fileVersion.rawValue),
                "owner": existing(link.ownerId, "user"),
            ])
        }
    }

    private mutating func exportProcessedMail() throws {
        for mail in try ProcessedMail.order(Column("id")).fetchAll(db) {
            append("paperless_mail.processedmail", value(mail.id), [
                "owner": existing(mail.ownerId, "user"), "rule": .int(mail.ruleId), "folder": .string(mail.folder),
                "uid": .string(mail.uid), "subject": .string(mail.subject), "received": value(mail.received ?? mail.processed),
                "processed": value(mail.processed), "status": .string(mail.status), "error": value(mail.error),
            ])
        }
    }

    private mutating func exportAuditLog() throws {
        let actions: [AuditLogEntry.Action: Int] = [.create: 0, .update: 1, .delete: 2]
        for entry in try AuditLogEntry.order(Column("id")).fetchAll(db) {
            guard let contentType = tables.contentTypeByModel[entry.objectType] else {
                report.skip("audit log (\(entry.objectType))")
                continue
            }
            let changes: JSONValue = entry.changes.map { changes in
                .object(changes.mapValues { .array($0.map { $0.map(JSONValue.string) ?? .null }) })
            } ?? .null
            append("auditlog.logentry", value(entry.id), [
                "content_type": .int(contentType), "object_pk": .string(String(entry.objectId)), "object_id": .int(entry.objectId),
                "object_repr": .string(entry.objectRepr), "action": .int(actions[entry.action] ?? 1), "changes": changes,
                "actor": existing(entry.actorId, "user"), "remote_addr": value(entry.remoteAddr), "timestamp": value(entry.timestamp),
            ])
        }
    }
}

// MARK: - Sinks

protocol ExportSink: AnyObject {
    func addFile(_ source: URL, as arcname: String) throws
    func addData(_ data: Data, as arcname: String) throws
    func finish() throws
    func abort()
}

/// Loose files in the target folder. Files with the same size and modification date are not copied again.
final class DirectoryExportSink: ExportSink {
    let target: URL
    let delete: Bool
    private let existing: [String]
    private var written = Set<String>()

    init(target: URL, delete: Bool) {
        self.target = target
        self.delete = delete
        existing = delete ? TransferPaths.files(under: target) : []
    }

    func addFile(_ source: URL, as arcname: String) throws {
        let destination = try TransferPaths.resolve(arcname, under: target)
        written.insert(arcname)
        let fm = FileManager.default
        if let a = try? fm.attributesOfItem(atPath: source.path), let b = try? fm.attributesOfItem(atPath: destination.path),
           (a[.size] as? Int) == (b[.size] as? Int), (a[.modificationDate] as? Date) == (b[.modificationDate] as? Date) {
            return
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: source, to: destination)
    }

    func addData(_ data: Data, as arcname: String) throws {
        let destination = try TransferPaths.resolve(arcname, under: target)
        written.insert(arcname)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Write next to the destination and rename, so a reader never sees half a manifest.
        let temporary = destination.appendingPathExtension("tmp")
        try data.write(to: temporary)
        guard Darwin.rename(temporary.path, destination.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temporary)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
    }

    func finish() throws {
        guard delete else { return }
        let fm = FileManager.default
        let root = target.resolvingSymlinksInPath()
        for path in existing where !written.contains(path) {
            let url = root.appendingPathComponent(path)
            try? fm.removeItem(at: url)
            var directory = url.deletingLastPathComponent()
            while directory.path.hasPrefix(root.path + "/"),
                  (try? fm.contentsOfDirectory(atPath: directory.path))?.allSatisfy({ $0 == ".DS_Store" }) == true {
                try? fm.removeItem(at: directory)
                directory = directory.deletingLastPathComponent()
            }
        }
    }

    func abort() {}
}

/// One zip file, written as `<name>.zip.tmp` and renamed when complete.
final class ZipExportSink: ExportSink {
    let target: URL
    let finalURL: URL
    let temporaryURL: URL
    let delete: Bool
    private var archive: Archive?
    private var directories = Set<String>()

    init(target: URL, name: String, delete: Bool) throws {
        self.target = target
        self.delete = delete
        finalURL = target.appendingPathComponent(name.hasSuffix(".zip") ? name : name + ".zip")
        temporaryURL = finalURL.appendingPathExtension("tmp")
        try? FileManager.default.removeItem(at: temporaryURL)
        archive = try Archive(url: temporaryURL, accessMode: .create, pathEncoding: nil)
    }

    private func ensureDirectories(_ arcname: String) throws {
        guard let archive else { return }
        var path = ""
        for part in arcname.split(separator: "/").dropLast() {
            path += part + "/"
            if directories.insert(path).inserted {
                try archive.addEntry(with: path, type: .directory, uncompressedSize: Int64(0), provider: { (_: Int64, _: Int) in Data() })
            }
        }
    }

    func addFile(_ source: URL, as arcname: String) throws {
        _ = try TransferPaths.resolve(arcname, under: target)
        try ensureDirectories(arcname)
        try archive?.addEntry(with: arcname, fileURL: source, compressionMethod: .deflate)
    }

    func addData(_ data: Data, as arcname: String) throws {
        try ensureDirectories(arcname)
        try archive?.addEntry(with: arcname, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) { (position: Int64, size: Int) in
            let start = Int(position)
            return data.subdata(in: start..<min(start + size, data.count))
        }
    }

    func finish() throws {
        archive = nil
        let fm = FileManager.default
        if delete {
            for item in (try? fm.contentsOfDirectory(at: target, includingPropertiesForKeys: nil)) ?? [] {
                let name = item.lastPathComponent
                if name == finalURL.lastPathComponent || name == temporaryURL.lastPathComponent { continue }
                try fm.removeItem(at: item)
            }
        }
        if fm.fileExists(atPath: finalURL.path) { try fm.removeItem(at: finalURL) }
        try fm.moveItem(at: temporaryURL, to: finalURL)
    }

    func abort() {
        archive = nil
        try? FileManager.default.removeItem(at: temporaryURL)
    }
}
