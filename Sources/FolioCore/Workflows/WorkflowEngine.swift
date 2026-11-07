import Darwin
import FolioTemplating
import Foundation
import GRDB
import Logging

/// Runs workflows (Paperless-ngx `documents/signals/handlers.py` run_workflows and
/// `documents/workflows/*`).
public struct WorkflowEngine: Sendable {
    public let app: FolioApp

    public init(app: FolioApp) {
        self.app = app
    }

    var logger: Logger { app.logger }

    /// What a "Consumption Started" run decided.
    public struct ConsumptionResult: Sendable {
        public var overrides: DocumentOverrides
        /// Title template to render once the document exists.
        public var titleTemplate: String?
        public var moveToTrash = false
        public var passwords: [String] = []
        /// Actions that need the stored document (email, webhook), run after it is added.
        public var deferredActions: [WorkflowAction] = []
        public var messages: [String] = []
        /// A "Remote OCR" action matched: send this document to the remote OCR engine
        /// even when `REMOTE_OCR_MODE` is `workflow_only`.
        public var remoteOCR = false
    }

    // MARK: Loading

    struct Loaded: Sendable {
        var workflow: Workflow
        var triggers: [WorkflowTrigger]
        var actions: [WorkflowAction]
    }

    func workflows(for type: WorkflowTriggerType, only workflowId: Int? = nil) async throws -> [Loaded] {
        try await app.database.read { db in
            var request = Workflow.filter(Column("enabled") == true)
            if let workflowId { request = request.filter(Column("id") == workflowId) }
            let workflows = try request.order(Column("order"), Column("id")).fetchAll(db)
            return try workflows.compactMap { workflow -> Loaded? in
                let triggers = try WorkflowTrigger.filter(Column("workflow_id") == workflow.id && Column("type") == type.rawValue).fetchAll(db)
                guard !triggers.isEmpty else { return nil }
                let actions = try WorkflowAction.filter(Column("workflow_id") == workflow.id).order(Column("order"), Column("id")).fetchAll(db)
                return Loaded(workflow: workflow, triggers: triggers, actions: actions)
            }
        }
    }

    // MARK: Consumption started

    /// Applies "Consumption Started" workflows to the overrides of an incoming file.
    public func consumptionStarted(fileName: String, path: String?, source: DocumentSource, mailRuleId: Int?, overrides: DocumentOverrides) async throws -> ConsumptionResult {
        var result = ConsumptionResult(overrides: overrides)
        for loaded in try await workflows(for: .consumption) {
            guard loaded.triggers.contains(where: { Self.consumableMatches($0.config, fileName: fileName, path: path, source: source, mailRuleId: mailRuleId) }) else { continue }
            result.messages.append("Applying workflow \(loaded.workflow.name)")
            for action in loaded.actions {
                switch action.type {
                case .assignment:
                    applyAssignment(action.config, to: &result)
                case .removal:
                    applyRemoval(action.config, to: &result.overrides)
                case .moveToTrash:
                    result.moveToTrash = true
                case .passwordRemoval:
                    result.passwords += action.config.passwords
                case .email, .webhook:
                    result.deferredActions.append(action)
                case .remoteOCR:
                    result.remoteOCR = true
                case .applyAISuggestions:
                    // The document has no content yet, so there is nothing to suggest from.
                    logger.debug("Apply AI suggestions action does not apply to consumption triggers, ignoring")
                }
            }
        }
        return result
    }

    static func consumableMatches(_ t: WorkflowTriggerConfig, fileName: String, path: String?, source: DocumentSource, mailRuleId: Int?) -> Bool {
        if !t.sources.isEmpty && !t.sources.contains(source.rawValue) { return false }
        if let rule = t.filterMailrule, rule != mailRuleId { return false }
        if let pattern = t.filterFilename, !pattern.isEmpty, fnmatch(pattern.lowercased(), fileName.lowercased(), 0) != 0 { return false }
        if let pattern = t.filterPath, !pattern.isEmpty, fnmatch(pattern, path ?? fileName, 0) != 0 { return false }
        return true
    }

    func applyAssignment(_ a: WorkflowActionConfig, to result: inout ConsumptionResult) {
        result.overrides.tagIds = Array(Set(result.overrides.tagIds).union(a.assignTags)).sorted()
        if let v = a.assignCorrespondent { result.overrides.correspondentId = v }
        if let v = a.assignDocumentType { result.overrides.documentTypeId = v }
        if let v = a.assignStoragePath { result.overrides.storagePathId = v }
        if let v = a.assignOwner { result.overrides.ownerId = v }
        if let title = a.assignTitle, !title.isEmpty { result.titleTemplate = title }
        if !(a.assignViewUsers + a.assignViewGroups + a.assignChangeUsers + a.assignChangeGroups).isEmpty {
            var permissions = result.overrides.permissions ?? PermissionSet()
            permissions.view.users = Array(Set(permissions.view.users + a.assignViewUsers)).sorted()
            permissions.view.groups = Array(Set(permissions.view.groups + a.assignViewGroups)).sorted()
            permissions.change.users = Array(Set(permissions.change.users + a.assignChangeUsers)).sorted()
            permissions.change.groups = Array(Set(permissions.change.groups + a.assignChangeGroups)).sorted()
            result.overrides.permissions = permissions
        }
        for field in a.assignCustomFields {
            let value = a.assignCustomFieldsValues[String(field)]
            result.overrides.customFields[field] = (value?.isNull ?? true) ? (result.overrides.customFields[field] ?? nil) : value
        }
    }

    func applyRemoval(_ r: WorkflowActionConfig, to o: inout DocumentOverrides) {
        if r.removeAllTags { o.tagIds = [] } else { o.tagIds.removeAll { r.removeTags.contains($0) } }
        if r.removeAllCorrespondents || o.correspondentId.map(r.removeCorrespondents.contains) == true { o.correspondentId = nil }
        if r.removeAllDocumentTypes || o.documentTypeId.map(r.removeDocumentTypes.contains) == true { o.documentTypeId = nil }
        if r.removeAllStoragePaths || o.storagePathId.map(r.removeStoragePaths.contains) == true { o.storagePathId = nil }
        if r.removeAllOwners || o.ownerId.map(r.removeOwners.contains) == true { o.ownerId = nil }
        if r.removeAllPermissions {
            o.permissions = nil
        } else if var p = o.permissions {
            p.view.users.removeAll { r.removeViewUsers.contains($0) }
            p.view.groups.removeAll { r.removeViewGroups.contains($0) }
            p.change.users.removeAll { r.removeChangeUsers.contains($0) }
            p.change.groups.removeAll { r.removeChangeGroups.contains($0) }
            o.permissions = p
        }
        if r.removeAllCustomFields { o.customFields = [:] } else { for id in r.removeCustomFields { o.customFields[id] = nil } }
    }

    // MARK: Added, updated, scheduled

    /// Runs "Document Added" workflows (after consumption).
    public func documentAdded(_ documentId: Int, originalFile: URL? = nil) async {
        await run(.documentAdded, documentId: documentId, originalFile: originalFile)
    }

    /// Runs "Document Updated" workflows (after an edit through the API).
    public func documentUpdated(_ documentId: Int) async {
        await run(.documentUpdated, documentId: documentId)
        // Edited documents get fresh AI suggestions and index entries.
        let ai = FolioAI.shared(for: app)
        ai.suggestions.invalidate(documentId: documentId)
        if (try? ai.config().llmIndexEnabled) == true {
            do { try await ai.index.indexDocument(documentId) } catch {
                logger.warning("LLM index update for document #\(documentId) failed: \(error)")
            }
        }
    }

    /// Runs one workflow's actions against a stored document, when its triggers match.
    /// Returns true when the document was moved to the trash.
    @discardableResult
    func run(_ type: WorkflowTriggerType, documentId: Int, originalFile: URL? = nil, only workflowId: Int? = nil, skipMatching: Bool = false, extraActions: [WorkflowAction] = []) async -> Bool {
        do {
            var loadedWorkflows = try await workflows(for: type, only: workflowId)
            if !extraActions.isEmpty {
                loadedWorkflows.insert(Loaded(workflow: Workflow(name: "consumption"), triggers: [], actions: extraActions), at: 0)
            }
            for loaded in loadedWorkflows {
                let state = try await app.database.read { db in try DocumentState.load(documentId, in: db) }
                guard let state, state.document.deletedAt == nil, state.document.rootDocumentId == nil else { return false }
                let matched = loaded.triggers.isEmpty || skipMatching
                    ? true
                    : try await app.database.read { db in try loaded.triggers.contains { try self.existingMatches($0.config, state: state, in: db) } }
                guard matched else { continue }
                logger.info("Applying workflow \(loaded.workflow.name) to document #\(documentId)")
                var moveToTrash = false
                for action in loaded.actions {
                    switch action.type {
                    case .assignment: try await assign(action.config, documentId: documentId)
                    case .removal: try await remove(action.config, documentId: documentId)
                    case .webhook: await sendWebhook(action.config, documentId: documentId, originalFile: originalFile)
                    case .email: await sendEmail(action.config, documentId: documentId)
                    case .moveToTrash: moveToTrash = true
                    case .applyAISuggestions: queueAISuggestions(action.config, documentId: documentId)
                    case .remoteOCR:
                        // The document was parsed before this trigger fired.
                        logger.debug("Remote OCR action only applies to consumption triggers, ignoring")
                    case .passwordRemoval:
                        logger.info("Workflow action \(action.type) is not supported on stored documents yet; skipped")
                    }
                }
                if let workflowId = loaded.workflow.id {
                    try await app.database.write { db in
                        var run = WorkflowRun(workflowId: workflowId, type: type, documentId: documentId)
                        try run.insert(db)
                    }
                }
                if moveToTrash {
                    try await app.database.write { db in try DocumentStore.moveToTrash(documentId, in: db) }
                    return true
                }
            }
        } catch {
            logger.error("Workflow run for document #\(documentId) failed: \(error)")
        }
        return false
    }

    /// Scheduled triggers (Paperless-ngx `check_scheduled_workflows`, hourly).
    public func runScheduled(now: Date = Date()) async {
        do {
            for loaded in try await workflows(for: .scheduled) {
                guard let workflowId = loaded.workflow.id else { continue }
                for trigger in loaded.triggers {
                    let due = try await dueDocuments(trigger.config, workflowId: workflowId, now: now)
                    for documentId in due {
                        await run(.scheduled, documentId: documentId, only: workflowId)
                    }
                }
            }
        } catch {
            logger.error("Scheduled workflows failed: \(error)")
        }
    }

    func dueDocuments(_ t: WorkflowTriggerConfig, workflowId: Int, now: Date) async throws -> [Int] {
        try await app.database.read { db in
            let zone = app.settings.timeZone
            let candidates = try Row.fetchAll(db, sql: """
                SELECT d.id, d.added, d.created, d.modified,
                       (SELECT value_date FROM custom_field_instances WHERE document_id = d.id AND field_id = ?) AS cf_date,
                       (SELECT MAX(run_at) FROM workflow_runs WHERE workflow_id = ? AND type = 4 AND document_id = d.id) AS last_run
                FROM documents d WHERE d.deleted_at IS NULL AND d.root_document_id IS NULL
                """, arguments: [t.scheduleDateCustomField, workflowId])
            var due: [Int] = []
            for row in candidates {
                let base: Date?
                switch t.scheduleDateField {
                case "created": base = (row["created"] as String?).flatMap { CalendarDate(iso: $0) }?.startDate(in: zone)
                case "modified": base = row["modified"]
                case "custom_field": base = (row["cf_date"] as String?).flatMap { CalendarDate(iso: $0) }?.startDate(in: zone)
                default: base = row["added"]
                }
                guard let base else { continue }
                let trigger = base.addingTimeInterval(Double(t.scheduleOffsetDays) * 86_400)
                guard trigger <= now else { continue }
                let lastRun: Date? = row["last_run"]
                if let lastRun {
                    guard t.scheduleIsRecurring,
                          now.timeIntervalSince(lastRun) >= Double(max(1, t.scheduleRecurringIntervalDays)) * 86_400 else { continue }
                }
                let id: Int = row["id"]
                let state = try DocumentState.load(id, in: db)
                if let state, try existingMatches(t, state: state, in: db) { due.append(id) }
            }
            return due
        }
    }

    // MARK: Matching stored documents

    struct DocumentState: Sendable {
        var document: Document
        var tagIds: Set<Int>

        static func load(_ id: Int, in db: Database) throws -> DocumentState? {
            guard let document = try Document.fetchOne(db, key: id) else { return nil }
            return DocumentState(document: document, tagIds: Set(try DocumentStore.tagIds(of: id, in: db)))
        }
    }

    func existingMatches(_ t: WorkflowTriggerConfig, state: DocumentState, in db: Database) throws -> Bool {
        let d = state.document
        if t.matchingAlgorithm > 0, let algorithm = MatchingAlgorithm(rawValue: t.matchingAlgorithm),
           !app.matcher.matches(algorithm: algorithm, match: t.match, isInsensitive: t.isInsensitive, content: d.content) {
            return false
        }
        if !t.filterHasTags.isEmpty && state.tagIds.isDisjoint(with: t.filterHasTags) { return false }
        if !t.filterHasAllTags.isEmpty && !Set(t.filterHasAllTags).isSubset(of: state.tagIds) { return false }
        if !state.tagIds.isDisjoint(with: t.filterHasNotTags) { return false }
        func check(_ value: Int?, single: Int?, any: [Int], not: [Int]) -> Bool {
            if !any.isEmpty, !(value.map(any.contains) ?? false) { return false }
            if let single, value != single { return false }
            if let value, not.contains(value) { return false }
            return true
        }
        guard check(d.correspondentId, single: t.filterHasCorrespondent, any: t.filterHasAnyCorrespondents, not: t.filterHasNotCorrespondents),
              check(d.documentTypeId, single: t.filterHasDocumentType, any: t.filterHasAnyDocumentTypes, not: t.filterHasNotDocumentTypes),
              check(d.storagePathId, single: t.filterHasStoragePath, any: t.filterHasAnyStoragePaths, not: t.filterHasNotStoragePaths)
        else { return false }
        if let query = t.filterCustomFieldQuery, !query.isEmpty, let id = d.id {
            let predicate: SQL
            do {
                predicate = try CustomFieldQuery.predicate(query, alias: "d", timeZone: app.settings.timeZone, in: db)
            } catch {
                logger.warning("Invalid custom field query in a workflow trigger (\(error)); trigger skipped")
                return false
            }
            let count = try Int.fetchOne(db, SQLRequest<Int>(literal: "SELECT COUNT(*) FROM documents d WHERE d.id = \(id) AND \(predicate)")) ?? 0
            if count == 0 { return false }
        }
        return true
    }

    // MARK: Actions on stored documents

    func assign(_ a: WorkflowActionConfig, documentId: Int) async throws {
        let settings = app.settings
        let storage = app.storage
        try await app.database.write { db in
            var document = try DocumentStore.document(documentId, in: db)
            if !a.assignTags.isEmpty { try DocumentStore.addTags(documentId: documentId, tagIds: a.assignTags, in: db) }
            if let v = a.assignCorrespondent { document.correspondentId = v }
            if let v = a.assignDocumentType { document.documentTypeId = v }
            if let v = a.assignStoragePath { document.storagePathId = v }
            if let v = a.assignOwner { document.ownerId = v }
            for field in a.assignCustomFields {
                let value = a.assignCustomFieldsValues[String(field)]
                try CustomFieldValues.set(fieldId: field, value: (value?.isNull ?? true) ? nil : value, documentId: documentId, in: db)
            }
            if let template = a.assignTitle, !template.isEmpty {
                let context = try WorkflowPlaceholders.context(for: document, includeTitle: false, settings: settings, in: db)
                if let title = WorkflowPlaceholders.render(template, context: context, timeZone: settings.timeZone), !title.isEmpty {
                    document.title = String(title.prefix(128))
                }
            }
            if !(a.assignViewUsers + a.assignViewGroups + a.assignChangeUsers + a.assignChangeGroups).isEmpty {
                try PermissionSet(view: .init(users: a.assignViewUsers, groups: a.assignViewGroups),
                                  change: .init(users: a.assignChangeUsers, groups: a.assignChangeGroups))
                    .apply(objectType: Document.objectType, objectId: documentId, merge: true, in: db)
            }
            document = try storage.applyNaming(to: document, in: db)
            try DocumentStore.update(document, auditEnabled: settings.auditLogEnabled, in: db)
        }
    }

    func remove(_ r: WorkflowActionConfig, documentId: Int) async throws {
        let settings = app.settings
        let storage = app.storage
        try await app.database.write { db in
            var document = try DocumentStore.document(documentId, in: db)
            if r.removeAllTags {
                try DocumentStore.setTags(documentId: documentId, tagIds: [], in: db)
            } else if !r.removeTags.isEmpty {
                try DocumentStore.removeTags(documentId: documentId, tagIds: r.removeTags, in: db)
            }
            if r.removeAllCorrespondents || document.correspondentId.map(r.removeCorrespondents.contains) == true { document.correspondentId = nil }
            if r.removeAllDocumentTypes || document.documentTypeId.map(r.removeDocumentTypes.contains) == true { document.documentTypeId = nil }
            if r.removeAllStoragePaths || document.storagePathId.map(r.removeStoragePaths.contains) == true { document.storagePathId = nil }
            if r.removeAllOwners || document.ownerId.map(r.removeOwners.contains) == true { document.ownerId = nil }
            if r.removeAllPermissions {
                try PermissionSet.removeAll(objectType: Document.objectType, objectId: documentId, in: db)
            } else {
                var current = try PermissionSet.load(objectType: Document.objectType, objectId: documentId, in: db)
                current.view.users.removeAll { r.removeViewUsers.contains($0) }
                current.view.groups.removeAll { r.removeViewGroups.contains($0) }
                current.change.users.removeAll { r.removeChangeUsers.contains($0) }
                current.change.groups.removeAll { r.removeChangeGroups.contains($0) }
                try current.apply(objectType: Document.objectType, objectId: documentId, in: db)
            }
            if r.removeAllCustomFields {
                try db.execute(sql: "DELETE FROM custom_field_instances WHERE document_id = ?", arguments: [documentId])
            } else {
                for field in r.removeCustomFields { try CustomFieldValues.remove(fieldId: field, documentId: documentId, in: db) }
            }
            document = try storage.applyNaming(to: document, in: db)
            try DocumentStore.update(document, auditEnabled: settings.auditLogEnabled, in: db)
        }
    }

    /// Runs "Apply AI Suggestions" in the background, as Paperless-ngx queues it.
    func queueAISuggestions(_ config: WorkflowActionConfig, documentId: Int) {
        let ai = FolioAI.shared(for: app)
        guard (try? ai.config().enabled) == true else {
            logger.warning("Workflow action \"Apply AI suggestions\" skipped: AI is not enabled")
            return
        }
        let fields = Set(config.aiSuggestionFields.compactMap(AISuggestionField.init(rawValue:)))
        let logger = self.logger
        Task {
            do {
                let applied = try await ai.suggestions.apply(to: documentId, fields: fields, createMissing: config.aiCreateMissing, overwrite: config.aiOverwriteExisting)
                logger.info("AI suggestions applied to document #\(documentId): \(applied.joined(separator: ", "))")
            } catch {
                logger.error("AI suggestions for document #\(documentId) failed: \(error)")
            }
        }
    }

    func sendWebhook(_ config: WorkflowActionConfig, documentId: Int, originalFile: URL?) async {
        guard let hook = config.webhook, let url = URL(string: hook.url) else { return }
        guard let scheme = url.scheme?.lowercased(), app.settings.webhooksAllowedSchemes.contains(scheme) else {
            logger.warning("Webhook to \(hook.url) blocked: scheme not allowed")
            return
        }
        if !app.settings.webhooksAllowedPorts.isEmpty, let port = url.port, !app.settings.webhooksAllowedPorts.contains(port) {
            logger.warning("Webhook to \(hook.url) blocked: port not allowed")
            return
        }
        if !app.settings.webhooksAllowInternalRequests, NetworkPolicy.isInternal(host: url.host ?? "") {
            logger.warning("Webhook to \(hook.url) blocked: internal address")
            return
        }
        do {
            let context = try await app.database.read { [app] db -> [String: TemplateValue] in
                let document = try DocumentStore.document(documentId, in: db)
                return try WorkflowPlaceholders.context(for: document, includeTitle: true, settings: app.settings, in: db)
            }
            var request = URLRequest(url: url, timeoutInterval: 10)
            request.httpMethod = "POST"
            for (name, value) in hook.headers ?? [:] { request.setValue(value, forHTTPHeaderField: name) }
            let zone = app.settings.timeZone
            if hook.useParams {
                let params = (hook.params ?? [:]).mapValues { WorkflowPlaceholders.render($0, context: context, timeZone: zone) ?? $0 }
                if hook.asJSON {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = try JSONSerialization.data(withJSONObject: params)
                } else {
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    var components = URLComponents()
                    components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
                    request.httpBody = Data((components.percentEncodedQuery ?? "").utf8)
                }
            } else if let body = hook.body {
                let rendered = WorkflowPlaceholders.render(body, context: context, timeZone: zone) ?? body
                if hook.asJSON { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
                request.httpBody = Data(rendered.utf8)
            }
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            logger.info("Webhook \(hook.url) answered \(status)")
        } catch {
            logger.error("Webhook \(hook.url) failed: \(error)")
        }
    }

    func sendEmail(_ config: WorkflowActionConfig, documentId: Int) async {
        guard let action = config.email else { return }
        let settings = app.settings
        guard let client = try? SMTPClient(settings: settings) else {
            logger.warning("Workflow email action skipped: EMAIL_HOST is not configured")
            return
        }
        do {
            let (context, document) = try await app.database.read { db -> ([String: TemplateValue], Document) in
                let document = try DocumentStore.document(documentId, in: db)
                return (try WorkflowPlaceholders.context(for: document, includeTitle: true, settings: settings, in: db), document)
            }
            let zone = settings.timeZone
            var attachments: [OutgoingEmail.Attachment] = []
            if action.includeDocument, let file = app.storage.archiveURL(document) ?? app.storage.originalURL(document) {
                let isArchive = app.storage.archiveURL(document) != nil
                attachments.append(.init(
                    filename: FileNamer.sanitize(document.title) + (isArchive ? ".pdf" : document.fileExtension),
                    contentType: isArchive ? "application/pdf" : document.mimeType,
                    data: try Data(contentsOf: file)))
            }
            let recipients = action.to.split(whereSeparator: { $0 == "," || $0 == ";" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            guard !recipients.isEmpty else { return }
            let email = OutgoingEmail(
                from: settings.emailFrom ?? settings.emailHostUser ?? "foliozero@localhost",
                to: recipients,
                subject: WorkflowPlaceholders.render(action.subject, context: context, timeZone: zone) ?? action.subject,
                body: WorkflowPlaceholders.renderBody(action.body, context: context, timeZone: zone) ?? action.body,
                attachments: attachments)
            try await client.send(email)
            logger.info("Workflow email for document #\(documentId) sent to \(recipients.joined(separator: ", "))")
        } catch {
            logger.error("Workflow email for document #\(documentId) failed: \(error)")
        }
    }
}

/// Placeholders for workflow titles and webhook bodies (usage.md "Workflow placeholders").
public enum WorkflowPlaceholders {
    public static func context(for document: Document, includeTitle: Bool, settings: Settings, in db: Database) throws -> [String: TemplateValue] {
        let zone = settings.timeZone
        let naming = try NamingContext.load(for: document, in: db)
        func parts(_ prefix: String, _ date: Date, includesTime: Bool) -> [String: TemplateValue] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = zone
            func f(_ format: String) -> TemplateValue {
                formatter.dateFormat = format
                return .string(formatter.string(from: date))
            }
            return [
                prefix: .date(date, includesTime: includesTime, timeZone: zone),
                "\(prefix)_year": f("yyyy"), "\(prefix)_year_short": f("yy"), "\(prefix)_month": f("MM"),
                "\(prefix)_month_name": f("MMMM"), "\(prefix)_month_name_short": f("MMM"), "\(prefix)_day": f("dd"),
                "\(prefix)_time": f("HH:mm"),
            ]
        }
        var context: [String: TemplateValue] = [
            "correspondent": .string(naming.correspondent?.name ?? ""),
            "document_type": .string(naming.documentType?.name ?? ""),
            "owner_username": .string(naming.owner?.username ?? ""),
            "original_filename": .string(((document.originalFilename ?? "") as NSString).deletingPathExtension),
            "filename": .string(((document.filename ?? "") as NSString).lastPathComponent.replacingOccurrences(of: (document.fileExtension), with: "")),
            "doc_title": .string(includeTitle ? document.title : ""),
            "doc_id": .int(document.id ?? 0),
            "doc_url": .string(settings.url.map { "\($0)/documents/\(document.id ?? 0)/" } ?? ""),
        ]
        context.merge(parts("added", document.added, includesTime: true)) { _, new in new }
        context.merge(parts("created", document.created.startDate(in: zone), includesTime: false)) { _, new in new }
        var fields: [String: TemplateValue] = [:]
        for (field, instance) in naming.customFields {
            let value: TemplateValue
            switch CustomFieldValues.value(of: instance, field: field) {
            case .string(let s): value = .string(s)
            case .int(let i): value = .int(i)
            case .double(let d): value = .double(d)
            case .bool(let b): value = .bool(b)
            case .array(let a): value = .array(a.compactMap { $0.intValue.map(TemplateValue.int) })
            default: value = .none
            }
            fields[field.name] = .dict(["type": .string(field.dataType.rawValue), "value": value])
        }
        context["custom_fields"] = .dict(fields)
        return context
    }

    /// Renders a multi-line template (email bodies keep their line breaks); nil on error.
    public static func renderBody(_ template: String, context: [String: TemplateValue], timeZone: TimeZone) -> String? {
        guard let parsed = try? Template(template) else { return nil }
        var environment = TemplateEnvironment.paperless
        environment.timeZone = timeZone
        return try? parsed.render(context, environment: environment)
    }

    /// Renders a template; nil on error.
    public static func render(_ template: String, context: [String: TemplateValue], timeZone: TimeZone) -> String? {
        guard let parsed = try? Template(template) else { return nil }
        var environment = TemplateEnvironment.paperless
        environment.timeZone = timeZone
        return (try? parsed.render(context, environment: environment))?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Decides whether a host is loopback, private, link-local or otherwise internal.
public enum NetworkPolicy {
    public static func isInternal(host: String) -> Bool {
        let lower = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if lower == "localhost" || lower.hasSuffix(".local") || lower.hasSuffix(".localhost") || lower.hasSuffix(".internal") { return true }
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(lower, nil, &hints, &result) == 0, let first = result else { return false }
        defer { freeaddrinfo(result) }
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            if let address = info.pointee.ai_addr {
                if info.pointee.ai_family == AF_INET {
                    let ipv4 = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
                    let a = ipv4 >> 24, b = (ipv4 >> 16) & 0xFF
                    if a == 10 || a == 127 || a == 0 || (a == 172 && (16...31).contains(b)) || (a == 192 && b == 168) || (a == 169 && b == 254) || (a == 100 && (64...127).contains(b)) {
                        return true
                    }
                } else if info.pointee.ai_family == AF_INET6 {
                    let bytes = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                        withUnsafeBytes(of: pointer.pointee.sin6_addr) { Array($0) }
                    }
                    let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
                    if loopback || bytes[0] & 0xFE == 0xFC || (bytes[0] == 0xFE && bytes[1] & 0xC0 == 0x80) { return true }
                }
            }
            cursor = info.pointee.ai_next
        }
        return false
    }
}
