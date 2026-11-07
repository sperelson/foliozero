import Foundation
import FolioCore
import GRDB
import Hummingbird

/// Workflows with nested triggers and actions (Paperless-ngx `WorkflowSerializer`).
extension API {
    static let triggerFields = [
        "filter_path", "filter_filename", "filter_mailrule", "matching_algorithm", "match", "is_insensitive",
        "filter_has_tags", "filter_has_all_tags", "filter_has_not_tags", "filter_custom_field_query",
        "filter_has_any_correspondents", "filter_has_not_correspondents", "filter_has_any_document_types",
        "filter_has_not_document_types", "filter_has_any_storage_paths", "filter_has_not_storage_paths",
        "filter_has_correspondent", "filter_has_document_type", "filter_has_storage_path", "schedule_offset_days",
        "schedule_is_recurring", "schedule_recurring_interval_days", "schedule_date_field", "schedule_date_custom_field",
    ]

    static let actionFields = [
        "assign_title", "assign_tags", "assign_correspondent", "assign_document_type", "assign_storage_path", "assign_owner",
        "assign_view_users", "assign_view_groups", "assign_change_users", "assign_change_groups", "assign_custom_fields",
        "assign_custom_fields_values", "remove_all_tags", "remove_tags", "remove_all_correspondents", "remove_correspondents",
        "remove_all_document_types", "remove_document_types", "remove_all_storage_paths", "remove_storage_paths",
        "remove_custom_fields", "remove_all_custom_fields", "remove_all_owners", "remove_owners", "remove_all_permissions",
        "remove_view_users", "remove_view_groups", "remove_change_users", "remove_change_groups",
    ]

    /// A Codable value as a JSON object (keys as encoded).
    static func encodedObject<T: Encodable>(_ value: T) -> JSONObject {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value), let json = try? JSON.parse(data) else { return JSONObject() }
        return json.object ?? JSONObject()
    }

    static func decoded<T: Decodable>(_ type: T.Type, from object: JSONObject) throws -> T {
        do {
            return try JSONDecoder().decode(T.self, from: JSON.object(object).data)
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            let key = context.codingPath.first?.stringValue ?? "non_field_errors"
            throw APIError.field(key, "Invalid value.")
        } catch let DecodingError.dataCorrupted(context) {
            let key = context.codingPath.first?.stringValue ?? "non_field_errors"
            throw APIError.field(key, "\"\(context.debugDescription)\" is not a valid choice.")
        }
    }

    func triggerJSON(_ trigger: WorkflowTrigger) -> JSON {
        let encoded = Self.encodedObject(trigger.config)
        var json = JSONObject()
        json["id"] = JSON(trigger.id)
        json["sources"] = JSON(trigger.config.sources)
        json["type"] = .int(trigger.type.rawValue)
        for field in Self.triggerFields { json[field] = encoded[field] ?? .null }
        return .object(json)
    }

    func actionJSON(_ action: WorkflowAction) -> JSON {
        let config = action.config
        let encoded = Self.encodedObject(config)
        var json = JSONObject()
        json["id"] = JSON(action.id)
        json["type"] = .int(action.type.rawValue)
        for field in Self.actionFields { json[field] = encoded[field] ?? .null }
        if json["assign_custom_fields_values"] == .null { json["assign_custom_fields_values"] = .object(JSONObject()) }
        json["email"] = config.email.map { email in
            .object(JSONObject([("id", JSON(action.id)), ("subject", .string(email.subject)), ("body", .string(email.body)),
                                ("to", .string(email.to)), ("include_document", .bool(email.includeDocument))]))
        } ?? .null
        json["webhook"] = config.webhook.map { hook in
            .object(JSONObject([
                ("id", JSON(action.id)), ("url", .string(hook.url)), ("use_params", .bool(hook.useParams)), ("as_json", .bool(hook.asJSON)),
                ("params", hook.params.map { JSON(Self.encodedObject($0)) } ?? .null), ("body", JSON(hook.body)),
                ("headers", hook.headers.map { JSON(Self.encodedObject($0)) } ?? .null), ("include_document", .bool(hook.includeDocument)),
            ]))
        } ?? .null
        json["passwords"] = JSON(config.passwords)
        json["ai_suggestion_fields"] = []
        json["ai_create_missing"] = false
        json["ai_overwrite_existing"] = false
        return .object(json)
    }

    func workflowJSON(_ workflow: Workflow, in db: Database) throws -> JSON {
        let id = workflow.id ?? 0
        let triggers = try WorkflowTrigger.filter(Column("workflow_id") == id).order(Column("id")).fetchAll(db)
        let actions = try WorkflowAction.filter(Column("workflow_id") == id).order(Column("order"), Column("id")).fetchAll(db)
        return .object(JSONObject([
            ("id", .int(id)), ("name", .string(workflow.name)), ("order", .int(workflow.order)), ("enabled", .bool(workflow.enabled)),
            ("triggers", .array(triggers.map(triggerJSON))), ("actions", .array(actions.map(actionJSON))),
        ]))
    }

    // MARK: - Parsing

    /// A trigger from its API form, validated like `WorkflowTriggerSerializer`.
    func parseTrigger(_ object: JSONObject, existing: WorkflowTrigger?, workflowId: Int, in db: Database) throws -> WorkflowTrigger {
        var merged = existing.map { Self.encodedObject($0.config) } ?? JSONObject()
        for (key, value) in object where key != "id" && key != "type" { merged[key] = value }
        for key in ["filter_filename", "filter_path", "filter_custom_field_query"] where merged[key]?.string == "" { merged[key] = .null }
        for (key, value) in merged where value.isNull { merged[key] = nil }
        if let sources = merged["sources"]?.array { merged["sources"] = JSON(sources.compactMap(\.int)) }
        let config = try Self.decoded(WorkflowTriggerConfig.self, from: merged)
        let rawType = object["type"] ?? existing.map { .int($0.type.rawValue) }
        guard let rawType else { throw APIError.field("type", APIError.requiredField) }
        guard let typeValue = rawType.int, let type = WorkflowTriggerType(rawValue: typeValue) else {
            throw APIError.field("type", "\"\(rawType.string ?? "")\" is not a valid choice.")
        }
        if let query = config.filterCustomFieldQuery {
            do {
                _ = try CustomFieldQuery.predicate(query, timeZone: settings.timeZone, in: db)
            } catch let error as FilterError {
                throw Self.filterError(FilterError(field: "filter_custom_field_query", path: error.path, message: error.message))
            }
        }
        // Paperless-ngx checks whether the `filter_mailrule` key is present, not its value. The web UI
        // always sends the key (often as null), so a consumption trigger from the UI needs no filter.
        if type == .consumption, config.filterMailrule == nil, !object.contains("filter_mailrule"),
           config.filterFilename == nil, config.filterPath == nil {
            throw APIError.nonField("File name, path or mail rule filter are required")
        }
        return WorkflowTrigger(id: existing?.id, workflowId: workflowId, type: type, config: config)
    }

    /// An action from its API form, validated like `WorkflowActionSerializer`.
    func parseAction(_ object: JSONObject, existing: WorkflowAction?, workflowId: Int, order: Int, in db: Database) throws -> WorkflowAction {
        var merged = existing.map { Self.encodedObject($0.config) } ?? JSONObject()
        for (key, value) in object where !["id", "type", "ai_suggestion_fields", "ai_create_missing", "ai_overwrite_existing"].contains(key) {
            merged[key] = value
        }
        if merged["assign_title"]?.string == "" { merged["assign_title"] = .null }
        if var email = merged["email"]?.object { email["id"] = nil; merged["email"] = .object(email) }
        if var hook = merged["webhook"]?.object {
            hook["id"] = nil
            guard let url = hook["url"]?.string, let parsed = URL(string: url), parsed.scheme != nil, parsed.host != nil else {
                throw APIError.validation(["webhook": ["url": ["Enter a valid URL."]]])
            }
            merged["webhook"] = .object(hook)
        }
        if var values = merged["assign_custom_fields_values"]?.object {
            for (key, value) in values where value.string == "" { values[key] = .null }
            merged["assign_custom_fields_values"] = .object(values)
        }
        for (key, value) in merged where value.isNull { merged[key] = nil }
        let config = try Self.decoded(WorkflowActionConfig.self, from: merged)
        let rawType = object["type"] ?? existing.map { .int($0.type.rawValue) } ?? .int(WorkflowActionType.assignment.rawValue)
        guard let typeValue = rawType.int, let type = WorkflowActionType(rawValue: typeValue) else {
            throw APIError.field("type", "\"\(rawType.string ?? "")\" is not a valid choice.")
        }
        for (key, table) in [("assign_correspondent", "correspondents"), ("assign_document_type", "document_types"), ("assign_storage_path", "storage_paths")] {
            if let id = merged[key]?.int, try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE id = ?", arguments: [id]) == 0 {
                throw APIError.field(key, APIError.invalidPK(String(id)))
            }
        }
        for tag in config.assignTags where try Tag.fetchOne(db, key: tag) == nil {
            throw APIError.field("assign_tags", APIError.invalidPK(String(tag)))
        }
        if let title = config.assignTitle, FileNamer(format: nil).render(title, context: NamingContext(document: Document(
            id: 1, title: "t", created: CalendarDate.today(), mimeType: "application/pdf", checksum: "0"))) == nil {
            throw APIError.field("assign_title", "Invalid template")
        }
        switch type {
        case .email where config.email == nil: throw APIError.nonField("Email data is required for email actions")
        case .webhook where config.webhook == nil: throw APIError.nonField("Webhook data is required for webhook actions")
        case .passwordRemoval where config.passwords.isEmpty || config.passwords.contains { $0.trimmingCharacters(in: .whitespaces).isEmpty }:
            throw APIError.nonField("Passwords are required for password removal actions")
        default: break
        }
        return WorkflowAction(id: existing?.id, workflowId: workflowId, type: type, order: order, config: config)
    }

    /// Replaces the triggers and actions of a workflow; items with an `id` update the existing row.
    private func saveNested(_ data: RequestData, workflowId: Int, isCreate: Bool, in db: Database) throws {
        if let triggersValue = data["triggers"] {
            guard let items = triggersValue.array else { throw APIError.field("triggers", "Expected a list of items.") }
            let existing = try WorkflowTrigger.filter(Column("workflow_id") == workflowId).fetchAll(db)
            var keep: [Int] = []
            for (index, item) in items.enumerated() {
                guard let object = item.object else { throw APIError.field("triggers", "Invalid data.") }
                let current = object["id"]?.int.flatMap { id in existing.first { $0.id == id } }
                var trigger: WorkflowTrigger
                do { trigger = try parseTrigger(object, existing: current, workflowId: workflowId, in: db) } catch let error as APIError {
                    throw Self.nested(error, field: "triggers", index: index, count: items.count)
                }
                try trigger.save(db)
                keep.append(trigger.id!)
            }
            try db.execute(literal: "DELETE FROM workflow_triggers WHERE workflow_id = \(workflowId) AND id NOT IN \(keep)")
        } else if isCreate {
            throw APIError.field("triggers", APIError.requiredField)
        }
        if let actionsValue = data["actions"] {
            guard let items = actionsValue.array else { throw APIError.field("actions", "Expected a list of items.") }
            let existing = try WorkflowAction.filter(Column("workflow_id") == workflowId).fetchAll(db)
            var keep: [Int] = []
            for (index, item) in items.enumerated() {
                guard let object = item.object else { throw APIError.field("actions", "Invalid data.") }
                let current = object["id"]?.int.flatMap { id in existing.first { $0.id == id } }
                var action: WorkflowAction
                do { action = try parseAction(object, existing: current, workflowId: workflowId, order: index, in: db) } catch let error as APIError {
                    throw Self.nested(error, field: "actions", index: index, count: items.count)
                }
                try action.save(db)
                keep.append(action.id!)
            }
            try db.execute(literal: "DELETE FROM workflow_actions WHERE workflow_id = \(workflowId) AND id NOT IN \(keep)")
        } else if isCreate {
            throw APIError.field("actions", APIError.requiredField)
        }
    }

    /// Paperless-ngx `WorkflowSerializer.validate`: the document is parsed before any other
    /// trigger fires, so a remote OCR action needs a "Consumption Started" trigger.
    func validateRemoteOCRActions(workflowId: Int, in db: Database) throws {
        let remote = try WorkflowAction.filter(Column("workflow_id") == workflowId && Column("type") == WorkflowActionType.remoteOCR.rawValue).fetchCount(db)
        guard remote > 0 else { return }
        let consumption = try WorkflowTrigger.filter(Column("workflow_id") == workflowId && Column("type") == WorkflowTriggerType.consumption.rawValue).fetchCount(db)
        if consumption == 0 { throw APIError.nonField("Remote OCR actions require a consumption started trigger") }
    }

    /// DRF nested list errors: `{"triggers": [{}, {"type": [...]}]}`.
    static func nested(_ error: APIError, field: String, index: Int, count: Int) -> APIError {
        guard error.status == .badRequest, case .json(let body) = error.body else { return error }
        var list = [JSON](repeating: .object(JSONObject()), count: count)
        list[index] = body
        return .validation(.object(JSONObject([(field, .array(list))])))
    }

    // MARK: - Workflows

    func listWorkflows(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, "workflow")
        let query = request.query
        let body = try await read { db -> JSONObject in
            let count = try Workflow.fetchCount(db)
            let page = try PageRequest.resolve(query, count: count)
            let order = QueryFilters.ordering(query["ordering"], allowed: ["order": "\"order\"", "name": "name COLLATE NOCASE", "id": "id"])?
                .joined(separator: ", ") ?? "\"order\""
            let workflows = try Workflow.fetchAll(db, sql: "SELECT * FROM workflows ORDER BY \(order), id LIMIT ? OFFSET ?", arguments: [page.size, page.offset])
            let all = request.version < 10 ? try Int.fetchAll(db, sql: "SELECT id FROM workflows ORDER BY \(order), id") : nil
            return self.paginated(request, page: page, count: count, results: try workflows.map { try self.workflowJSON($0, in: db) }, allIds: all)
        }
        return .json(.object(body))
    }

    func getWorkflow(_ request: APIRequest) async throws -> Response {
        try request.access.require(.view, "workflow")
        let id = try request.intParam("id")
        let json = try await read { db -> JSON in
            guard let workflow = try Workflow.fetchOne(db, key: id) else { throw APIError.notFound("Workflow") }
            return try self.workflowJSON(workflow, in: db)
        }
        return .json(json)
    }

    func createWorkflow(_ request: APIRequest) async throws -> Response {
        try request.access.require(.add, "workflow")
        let data = try request.data()
        let name = try data.requiredString("name", maxLength: 256)
        let json = try await write { db -> JSON in
            if try Workflow.filter(Column("name") == name).fetchCount(db) > 0 {
                throw APIError.field("name", "workflow with this name already exists.")
            }
            var workflow = Workflow(name: name, order: try data.optionalInt("order") ?? 0, enabled: try data.optionalBool("enabled") ?? true)
            try workflow.insert(db)
            try self.saveNested(data, workflowId: workflow.id!, isCreate: true, in: db)
            try self.validateRemoteOCRActions(workflowId: workflow.id!, in: db)
            return try self.workflowJSON(workflow, in: db)
        }
        return .json(json, status: .created)
    }

    func updateWorkflow(_ request: APIRequest, partial: Bool) async throws -> Response {
        try request.access.require(.change, "workflow")
        let id = try request.intParam("id")
        let data = try request.data()
        let json = try await write { db -> JSON in
            guard var workflow = try Workflow.fetchOne(db, key: id) else { throw APIError.notFound("Workflow") }
            if !partial || data.has("name") {
                let name = try data.requiredString("name", maxLength: 256)
                if try Workflow.filter(Column("name") == name && Column("id") != id).fetchCount(db) > 0 {
                    throw APIError.field("name", "workflow with this name already exists.")
                }
                workflow.name = name
            }
            if let order = try data.optionalInt("order") { workflow.order = order }
            if let enabled = try data.optionalBool("enabled") { workflow.enabled = enabled }
            try workflow.update(db)
            try self.saveNested(data, workflowId: id, isCreate: !partial, in: db)
            try self.validateRemoteOCRActions(workflowId: id, in: db)
            return try self.workflowJSON(workflow, in: db)
        }
        return .json(json)
    }

    func deleteWorkflow(_ request: APIRequest) async throws -> Response {
        try request.access.require(.delete, "workflow")
        let id = try request.intParam("id")
        try await write { db in
            guard try Workflow.deleteOne(db, key: id) else { throw APIError.notFound("Workflow") }
        }
        return .noContent()
    }

    // MARK: - Triggers and actions on their own

    func listWorkflowParts(_ request: APIRequest, triggers: Bool) async throws -> Response {
        try request.access.require(.view, "workflow")
        let query = request.query
        let table = triggers ? "workflow_triggers" : "workflow_actions"
        let body = try await read { db -> JSONObject in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            let page = try PageRequest.resolve(query, count: count)
            let results: [JSON] = triggers
                ? try WorkflowTrigger.fetchAll(db, sql: "SELECT * FROM workflow_triggers ORDER BY id LIMIT ? OFFSET ?", arguments: [page.size, page.offset]).map(self.triggerJSON)
                : try WorkflowAction.fetchAll(db, sql: "SELECT * FROM workflow_actions ORDER BY id LIMIT ? OFFSET ?", arguments: [page.size, page.offset]).map(self.actionJSON)
            let all = request.version < 10 ? try Int.fetchAll(db, sql: "SELECT id FROM \(table) ORDER BY id") : nil
            return self.paginated(request, page: page, count: count, results: results, allIds: all)
        }
        return .json(.object(body))
    }

    func getWorkflowPart(_ request: APIRequest, triggers: Bool) async throws -> Response {
        try request.access.require(.view, "workflow")
        let id = try request.intParam("id")
        let json = try await read { db -> JSON in
            if triggers {
                guard let trigger = try WorkflowTrigger.fetchOne(db, key: id) else { throw APIError.notFound("WorkflowTrigger") }
                return self.triggerJSON(trigger)
            }
            guard let action = try WorkflowAction.fetchOne(db, key: id) else { throw APIError.notFound("WorkflowAction") }
            return self.actionJSON(action)
        }
        return .json(json)
    }

    func updateWorkflowPart(_ request: APIRequest, triggers: Bool) async throws -> Response {
        try request.access.require(.change, "workflow")
        let id = try request.intParam("id")
        let data = try request.data()
        let json = try await write { db -> JSON in
            if triggers {
                guard let existing = try WorkflowTrigger.fetchOne(db, key: id) else { throw APIError.notFound("WorkflowTrigger") }
                var trigger = try self.parseTrigger(data.object, existing: existing, workflowId: existing.workflowId, in: db)
                try trigger.save(db)
                return self.triggerJSON(trigger)
            }
            guard let existing = try WorkflowAction.fetchOne(db, key: id) else { throw APIError.notFound("WorkflowAction") }
            var action = try self.parseAction(data.object, existing: existing, workflowId: existing.workflowId, order: existing.order, in: db)
            try action.save(db)
            return self.actionJSON(action)
        }
        return .json(json)
    }

    func deleteWorkflowPart(_ request: APIRequest, triggers: Bool) async throws -> Response {
        try request.access.require(.delete, "workflow")
        let id = try request.intParam("id")
        try await write { db in
            let deleted = triggers ? try WorkflowTrigger.deleteOne(db, key: id) : try WorkflowAction.deleteOne(db, key: id)
            guard deleted else { throw APIError.notFound() }
        }
        return .noContent()
    }
}
