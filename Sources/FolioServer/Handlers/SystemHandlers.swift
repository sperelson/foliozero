import Foundation
import FolioCore
import FolioParsing
import GRDB
import Hummingbird

extension API {
    // MARK: - Tasks

    static let taskTypeLabels: [String: String] = [
        "consume_file": "Consume File", "train_classifier": "Train Classifier", "sanity_check": "Sanity Check",
        "index_optimize": "Index Optimize", "mail_fetch": "Mail Fetch", "llm_index": "LLM Index", "empty_trash": "Empty Trash",
        "check_workflows": "Check Workflows", "bulk_update": "Bulk Update", "reprocess_document": "Reprocess Document",
        "build_share_link": "Build Share Link", "bulk_delete": "Bulk Delete", "apply_ai_suggestions": "Apply AI Suggestions",
    ]
    static let triggerSourceLabels: [String: String] = [
        "scheduled": "Scheduled", "web_ui": "Web UI", "api_upload": "API Upload", "folder_consume": "Folder Consume",
        "email_consume": "Email Consume", "system": "System", "manual": "Manual",
    ]

    /// Non-staff users see their own tasks and unowned (system) tasks.
    func taskVisibility(_ access: AccessContext) -> SQL {
        access.isSuperuser || access.user.isStaff ? "1" : "(t.owner_id IS NULL OR t.owner_id = \(access.userId))"
    }

    /// Result data with numeric ids as numbers, as Paperless-ngx stores them.
    func resultDataJSON(_ task: TaskRecord) -> JSON {
        guard var data = task.resultData else {
            if task.status == .failure, let message = task.resultMessage { return ["error_message": .string(message)] }
            return .null
        }
        var object = JSONObject()
        if task.status == .failure, data["error_message"] == nil, let message = task.resultMessage { data["error_message"] = message }
        for key in data.keys.sorted() {
            let value = data[key] ?? ""
            object[key] = ["document_id", "duplicate_of"].contains(key) ? (Int(value).map(JSON.int) ?? .string(value)) : .string(value)
        }
        return .object(object)
    }

    func relatedDocumentIds(_ task: TaskRecord) -> [Int] {
        if let id = task.resultData?["document_id"].flatMap({ Int($0) }) { return [id] }
        if task.status == .success, let id = task.relatedDocumentId { return [id] }
        return []
    }

    func taskJSONv10(_ task: TaskRecord) -> JSON {
        var input = JSONObject()
        for key in (task.inputData ?? [:]).keys.sorted() { input[key] = .string(task.inputData?[key] ?? "") }
        return .object(JSONObject([
            ("id", JSON(task.id)), ("task_id", .string(task.taskId)),
            ("task_type", .string(task.taskType.rawValue)),
            ("task_type_display", .string(Self.taskTypeLabels[task.taskType.rawValue] ?? task.taskType.rawValue)),
            ("trigger_source", .string(task.triggerSource.rawValue)),
            ("trigger_source_display", .string(Self.triggerSourceLabels[task.triggerSource.rawValue] ?? task.triggerSource.rawValue)),
            ("status", .string(task.status.rawValue)),
            ("status_display", .string(task.status.rawValue.capitalized)),
            ("date_created", datetime(task.dateCreated)), ("date_started", datetime(task.dateStarted)), ("date_done", datetime(task.dateDone)),
            ("duration_seconds", JSON(task.durationSeconds)), ("wait_time_seconds", JSON(task.waitTimeSeconds)),
            ("input_data", .object(input)), ("result_data", resultDataJSON(task)),
            ("related_document_ids", JSON(relatedDocumentIds(task))), ("acknowledged", .bool(task.acknowledged)),
            ("owner", JSON(task.ownerId)),
        ]))
    }

    func taskJSONv9(_ task: TaskRecord, access: AccessContext, in db: Database) throws -> JSON {
        let type: String
        switch task.triggerSource {
        case .scheduled: type = "scheduled_task"
        case .system, .emailConsume, .folderConsume: type = "auto_task"
        default: type = "manual_task"
        }
        var result: String?
        if let id = task.resultData?["document_id"] {
            result = "Success. New document id \(id) created"
        } else if let duplicate = task.resultData?["duplicate_of"] {
            result = task.resultMessage ?? "Not consuming: It is a duplicate of document #\(duplicate)"
        } else {
            result = task.resultMessage
        }
        var duplicates: [JSON] = []
        if let duplicate = task.resultData?["duplicate_of"].flatMap({ Int($0) }), let document = try Document.fetchOne(db, key: duplicate),
           try access.user.isStaff || access.isSuperuser || canAccess(document, .view, access: access, in: db) {
            duplicates = [.object(JSONObject([("id", .int(duplicate)), ("title", .string(document.title)), ("deleted_at", datetime(document.deletedAt))]))]
        }
        let name = task.taskType == .sanityCheck ? "check_sanity" : task.taskType.rawValue
        return .object(JSONObject([
            ("id", JSON(task.id)), ("task_id", .string(task.taskId)), ("task_name", .string(name)),
            ("task_file_name", JSON(task.inputData?["filename"])), ("type", .string(type)),
            ("status", .string(task.status.rawValue.uppercased())), ("date_created", datetime(task.dateCreated)),
            ("date_done", datetime(task.dateDone)), ("result", JSON(result)), ("acknowledged", .bool(task.acknowledged)),
            ("related_document", JSON(relatedDocumentIds(task).first)), ("duplicate_documents", .array(duplicates)),
            ("owner", JSON(task.ownerId)),
        ]))
    }

    /// Filters of `PaperlessTaskFilterSet` plus the legacy `task_id` and v9 `task_name` / `type`.
    func taskPredicate(_ request: APIRequest, excludingStatus: Bool = false) throws -> SQL {
        let query = request.query
        var conditions: [SQL] = [taskVisibility(request.access)]
        if let taskId = query["task_id"] { conditions.append("t.task_id = \(taskId)") }
        if request.version < 10 {
            if let name = query["task_name"] {
                conditions.append("t.task_type = \(name == "check_sanity" ? "sanity_check" : name)")
            }
            if let type = query["type"] {
                let sources = ["auto_task": ["system", "email_consume", "folder_consume"], "scheduled_task": ["scheduled"],
                               "manual_task": ["manual", "web_ui", "api_upload"]][type]
                if let sources { conditions.append("t.trigger_source IN \(sources)") }
            }
        }
        let types = query.all("task_type").filter { !$0.isEmpty }
        if !types.isEmpty { conditions.append("t.task_type IN \(types)") }
        let sources = query.all("trigger_source").filter { !$0.isEmpty }
        if !sources.isEmpty { conditions.append("t.trigger_source IN \(sources)") }
        if !excludingStatus {
            let statuses = query.all("status").filter { !$0.isEmpty }.map { $0.lowercased() }
            if !statuses.isEmpty { conditions.append("t.status IN \(statuses)") }
            if let raw = query["is_complete"], let flag = QueryFilters.bool(raw) {
                conditions.append(flag ? "t.status IN ('success', 'failure', 'revoked')" : "t.status NOT IN ('success', 'failure', 'revoked')")
            }
        }
        if let raw = query["acknowledged"], let flag = QueryFilters.bool(raw) { conditions.append("t.acknowledged = \(flag)") }
        if let raw = query["owner"], let owner = Int(raw) { conditions.append("t.owner_id = \(owner)") }
        if let name = query["name"], !name.isEmpty {
            let lower = name.lowercased()
            let types = Self.taskTypeLabels.filter { $0.value.lowercased().contains(lower) }.map(\.key)
            let sources = Self.triggerSourceLabels.filter { $0.value.lowercased().contains(lower) }.map(\.key)
            conditions.append(QueryFilters.or([
                QueryFilters.charLookup("json_extract(t.input_data, '$.filename')", lookup: "icontains", value: name)!,
                "t.task_type IN \(types)", "t.trigger_source IN \(sources)",
            ]))
        }
        if let result = query["result"], !result.isEmpty {
            var parts: [SQL] = [QueryFilters.charLookup("t.result_message", lookup: "icontains", value: result)!]
            if Int(result) != nil {
                parts.append("json_extract(t.result_data, '$.document_id') = \(result)")
                parts.append("json_extract(t.result_data, '$.duplicate_of') = \(result)")
            }
            if result.lowercased().contains("duplicate") { parts.append("json_extract(t.result_data, '$.duplicate_of') IS NOT NULL") }
            conditions.append(QueryFilters.or(parts))
        }
        for (name, op) in [("date_created_after", ">="), ("date_created_before", "<=")] {
            if let raw = query[name], !raw.isEmpty {
                guard let date = QueryFilters.parseDateTime(raw, timeZone: settings.timeZone) else { throw APIError.field(name, "Enter a valid date/time.") }
                conditions.append("t.date_created \(sql: op) \(QueryFilters.timestamp(date))")
            }
        }
        return QueryFilters.and(conditions)
    }

    func listTasks(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, "paperlesstask")
        let predicate = try taskPredicate(request)
        let order = QueryFilters.ordering(request.query["ordering"], allowed: [
            "date_created": "t.date_created", "date_done": "t.date_done", "status": "t.status", "task_type": "t.task_type",
            "duration_seconds": "t.duration_seconds", "wait_time_seconds": "t.wait_time_seconds",
        ])?.joined(separator: ", ") ?? "t.date_created DESC"
        let json = try await read { db -> JSON in
            if request.version < 10 {
                let tasks = try TaskRecord.fetchAll(db, SQLRequest<TaskRecord>(literal: "SELECT t.* FROM tasks t WHERE \(predicate) ORDER BY \(sql: order), t.id DESC"))
                return .array(try tasks.map { try self.taskJSONv9($0, access: access, in: db) })
            }
            let count = try Int.fetchOne(db, SQLRequest<Int>(literal: "SELECT COUNT(*) FROM tasks t WHERE \(predicate)")) ?? 0
            let page = try PageRequest.resolve(request.query, count: count)
            let tasks = try TaskRecord.fetchAll(db, SQLRequest<TaskRecord>(literal: """
                SELECT t.* FROM tasks t WHERE \(predicate) ORDER BY \(sql: order), t.id DESC LIMIT \(page.size) OFFSET \(page.offset)
                """))
            return .object(self.paginated(request, page: page, count: count, results: tasks.map(self.taskJSONv10), allIds: nil))
        }
        return .json(json)
    }

    func getTask(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, "paperlesstask")
        let id = try request.intParam("id")
        let visibility = taskVisibility(access)
        let json = try await read { db -> JSON in
            guard let task = try TaskRecord.fetchOne(db, SQLRequest<TaskRecord>(literal: "SELECT t.* FROM tasks t WHERE t.id = \(id) AND \(visibility)")) else {
                throw APIError.notFound("PaperlessTask")
            }
            return request.version < 10 ? try self.taskJSONv9(task, access: access, in: db) : self.taskJSONv10(task)
        }
        return .json(json)
    }

    func acknowledgeTasks(_ request: APIRequest) async throws -> Response {
        let access = request.access
        guard access.has(.change, "paperlesstask") else { throw APIError.permissionDenied }
        let data = try request.data()
        let all = try data.optionalBool("all") ?? false
        let visibility = taskVisibility(access)
        var requested: [Int]?
        if let value = data["tasks"] {
            guard let items = value.array else { throw APIError.field("tasks", "tasks must be a list") }
            guard items.allSatisfy({ $0.strictInt != nil }) else { throw APIError.field("tasks", "tasks must be a list of integers") }
            requested = items.compactMap(\.strictInt)
        }
        let ids = requested
        if all && ids != nil { throw APIError.nonField("Set either all or tasks, not both.") }
        if !all && ids == nil { throw APIError.nonField("Either all must be true or tasks must be provided.") }
        let count = try await write { db -> Int in
            if let ids {
                let found = try Int.fetchOne(db, SQLRequest<Int>(literal: "SELECT COUNT(*) FROM tasks t WHERE t.id IN \(ids) AND \(visibility)")) ?? 0
                guard found == ids.count, Set(ids).count == ids.count else {
                    throw APIError.field("tasks", "Some tasks in tasks don't exist or were specified twice.")
                }
                try db.execute(literal: "UPDATE tasks SET acknowledged = 1 WHERE id IN \(ids)")
                return db.changesCount
            }
            try db.execute(literal: "UPDATE tasks SET acknowledged = 1 WHERE acknowledged = 0 AND id IN (SELECT t.id FROM tasks t WHERE \(visibility))")
            return db.changesCount
        }
        return .json(["result": .int(count)])
    }

    func taskSummary(_ request: APIRequest) async throws -> Response {
        let access = request.access
        let systemStatus = access.isSuperuser || access.user.isStaff || access.has(Permission.viewSystemMonitoring)
        if !systemStatus { try access.require(.view, "paperlesstask") }
        var days = 30
        if let raw = request.query["days"] {
            guard let value = Int(raw) else { throw APIError.validation(["days": "Must be a positive integer."]) }
            days = min(365, max(1, value))
        }
        let cutoff = QueryFilters.timestamp(Date().addingTimeInterval(-Double(days) * 86_400))
        let visibility: SQL = systemStatus ? "1" : taskVisibility(access)
        @Sendable func stamp(_ value: String?) -> JSON { self.datetime(value.flatMap { FolioDateFormat.database.date(from: $0) }) }
        let summary = try await read { db -> JSON in
            let rows = try Row.fetchAll(db, SQLRequest<Row>(literal: """
                SELECT t.task_type, COUNT(*) AS total_count,
                    SUM(t.status = 'pending') AS pending_count, SUM(t.status = 'success') AS success_count,
                    SUM(t.status = 'failure') AS failure_count, AVG(t.duration_seconds) AS avg_duration_seconds,
                    AVG(t.wait_time_seconds) AS avg_wait_time_seconds, MAX(t.date_created) AS last_run,
                    MAX(CASE WHEN t.status = 'success' THEN t.date_done END) AS last_success,
                    MAX(CASE WHEN t.status = 'failure' THEN t.date_done END) AS last_failure
                FROM tasks t WHERE t.date_created >= \(cutoff) AND \(visibility) GROUP BY t.task_type ORDER BY t.task_type
                """))
            return .array(rows.map { row in
            .object(JSONObject([
                ("task_type", .string(row["task_type"])), ("total_count", .int(row["total_count"])),
                ("pending_count", .int(row["pending_count"] ?? 0)), ("success_count", .int(row["success_count"] ?? 0)),
                ("failure_count", .int(row["failure_count"] ?? 0)),
                ("avg_duration_seconds", JSON(row["avg_duration_seconds"] as Double?)),
                ("avg_wait_time_seconds", JSON(row["avg_wait_time_seconds"] as Double?)),
                ("last_run", stamp(row["last_run"])), ("last_success", stamp(row["last_success"])), ("last_failure", stamp(row["last_failure"])),
            ]))
            })
        }
        return .json(summary)
    }

    func taskStatusCounts(_ request: APIRequest) async throws -> Response {
        try request.access.require(.view, "paperlesstask")
        let predicate = try taskPredicate(request, excludingStatus: true)
        let counts = try await read { db -> JSON in
            let row = try Row.fetchOne(db, SQLRequest<Row>(literal: """
                SELECT COUNT(*) AS total, SUM(t.status IN ('failure', 'revoked')) AS attention,
                    SUM(t.status IN ('pending', 'started')) AS progress, SUM(t.status = 'success') AS completed
                FROM tasks t WHERE \(predicate)
                """))
            return .object(JSONObject([
                ("all", .int(row?["total"] ?? 0)), ("needs_attention", .int(row?["attention"] ?? 0)),
                ("in_progress", .int(row?["progress"] ?? 0)), ("completed", .int(row?["completed"] ?? 0)),
            ]))
        }
        return .json(counts)
    }

    func activeTasks(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, "paperlesstask")
        let visibility = taskVisibility(access)
        let json = try await read { db -> JSON in
            let tasks = try TaskRecord.fetchAll(db, SQLRequest<TaskRecord>(literal: """
                SELECT t.* FROM tasks t WHERE t.status IN ('pending', 'started') AND \(visibility) ORDER BY t.date_created DESC LIMIT 50
                """))
            return .array(try tasks.map { request.version < 10 ? try self.taskJSONv9($0, access: access, in: db) : self.taskJSONv10($0) })
        }
        return .json(json)
    }

    func runTask(_ request: APIRequest) async throws -> Response {
        guard request.access.isSuperuser else { throw APIError.forbiddenText() }
        let data = try request.data()
        guard let type = data["task_type"]?.string else { throw APIError.field("task_type", APIError.requiredField) }
        guard Self.taskTypeLabels[type] != nil || type == "llmindex_update" else {
            throw APIError.field("task_type", "\"\(type)\" is not a valid choice.")
        }
        let app = self.app
        let taskId: String
        switch type {
        case "train_classifier":
            taskId = try await queue.enqueue(type: .trainClassifier, source: .manual) { _ in
                TaskOutcome(message: try await DocumentClassifier.trainAndSave(app: app))
            }
        case "index_optimize":
            taskId = try await queue.enqueue(type: .indexOptimize, source: .manual) { _ in
                try await Maintenance.optimizeIndex(app: app)
                return TaskOutcome(message: "Index optimized")
            }
        case "sanity_check":
            taskId = try await queue.enqueue(type: .sanityCheck, source: .manual) { progress in
                let messages = try await DocumentMaintenance.sanityCheck(app: app, progress: progress)
                let errors = messages.filter { $0.level == .error }
                if !errors.isEmpty {
                    throw SanityCheckFailed(message: "Sanity check found \(errors.count) errors: " + errors.prefix(5).map(\.description).joined(separator: "; "))
                }
                let warnings = messages.filter { $0.level == .warning }.count
                return TaskOutcome(message: warnings == 0 ? "No issues detected." : "Sanity check finished with \(warnings) warnings")
            }
        case "llmindex_update", "llm_index":
            let ai = self.ai
            taskId = try await queue.enqueue(type: .llmIndex, source: .manual) { _ in
                TaskOutcome(message: try await ai.index.update())
            }
        case "empty_trash":
            let delay = settings.emptyTrashDelayDays
            taskId = try await queue.enqueue(type: .emptyTrash, source: .manual) { _ in
                let count = try await Maintenance.emptyTrash(app: app, olderThan: delay)
                return TaskOutcome(message: "Deleted \(count) documents from the trash")
            }
        default:
            return .json(["error": .string("Task type '\(type)' cannot be manually triggered")], status: .badRequest)
        }
        return .json(["task_id": .string(taskId)])
    }

    struct SanityCheckFailed: Error, CustomStringConvertible {
        var message: String
        var description: String { message }
    }

    // MARK: - Search

    func globalSearch(_ request: APIRequest) async throws -> Response {
        let access = request.access
        guard let query = request.query["query"] else { throw APIError.badRequestText("Query required") }
        guard query.count >= 3 else { throw APIError.badRequestText("Query must be at least 3 characters") }
        guard query.count <= 4096 else { throw APIError.badRequestText("Query must be at most 4096 characters") }
        let dbOnly = request.query.flag("db_only")
        let context = SerializeContext(request, fullPerms: false)
        let limit = 3
        let timeZone = settings.timeZone
        let json = try await read { db -> JSON in
            var total = 0
            var documents: [JSON] = []
            if access.has(.view, Document.objectType) {
                let visible = self.countableDocuments(access)
                var found: [Document]
                if dbOnly {
                    found = try Document.fetchAll(db, SQLRequest<Document>(literal: """
                        SELECT d.* FROM documents d WHERE \(visible) AND \(QueryFilters.charLookup("d.title", lookup: "icontains", value: query)!)
                        ORDER BY d.created DESC, d.id DESC LIMIT \(limit)
                        """))
                } else {
                    let hits = try SearchIndex.search(SearchIndex.simpleQuery(query, titleOnly: false), in: db, visibility: visible,
                                                      limit: limit * 3, timeZone: timeZone)
                    let ids = hits.map(\.documentId)
                    let byId = Dictionary(try Document.fetchAll(db, keys: ids).map { ($0.id ?? 0, $0) }, uniquingKeysWith: { a, _ in a })
                    found = Array(ids.compactMap { byId[$0] }.prefix(limit))
                }
                var options = DocumentSerializeOptions()
                options.fields = ["id", "title", "created"]
                documents = try self.documentsJSON(found, context: context, options: options, in: db)
                total += documents.count
            }
            func objects<M: APIMatchingObject>(_ type: M.Type) throws -> [JSON] {
                guard access.has(.view, M.objectType) else { return [] }
                let rows = try Row.fetchAll(db, SQLRequest<Row>(literal: """
                    SELECT o.*, \(self.documentCountSQL(M.self, access: access)) AS document_count FROM \(sql: M.databaseTableName) o
                    WHERE \(access.visibilityPredicate(objectType: M.objectType, alias: "o"))
                      AND \(QueryFilters.charLookup("o.name", lookup: "icontains", value: query)!)
                    ORDER BY o.name COLLATE NOCASE LIMIT \(limit)
                    """))
                let items = try rows.map { try M(row: $0) }
                let grants = try GrantTable.load(objectType: M.objectType, ids: items.compactMap(\.id), in: db)
                let tree = M.self == Tag.self ? try self.visibleTagTree(access, orderBy: "o.name COLLATE NOCASE", in: db).0 : nil
                return zip(items, rows).map { self.matchingJSON($0, documentCount: $1["document_count"], grants: grants, context: context, tree: tree) }
            }
            let tags = try objects(Tag.self)
            let correspondents = try objects(Correspondent.self)
            let types = try objects(DocumentType.self)
            let paths = try objects(StoragePath.self)
            var savedViews: [JSON] = []
            if access.has(.view, SavedView.objectType) {
                let views = try SavedView.fetchAll(db, SQLRequest<SavedView>(literal: """
                    SELECT o.* FROM saved_views o WHERE \(access.visibilityPredicate(objectType: SavedView.objectType, alias: "o"))
                      AND \(QueryFilters.charLookup("o.name", lookup: "icontains", value: query)!) ORDER BY o.id LIMIT \(limit)
                    """))
                let grants = try GrantTable.load(objectType: SavedView.objectType, ids: views.compactMap(\.id), in: db)
                let rules = try SavedViewFilterRule.fetchAll(db)
                savedViews = views.map { view in
                    self.savedViewJSON(view, rules: rules.filter { $0.savedViewId == view.id }, grants: grants, context: context, ui: nil)
                }
            }
            var users: [JSON] = []
            if access.has(.view, "user") {
                let found = try User.fetchAll(db, SQLRequest<User>(literal: """
                    SELECT u.* FROM users u WHERE \(QueryFilters.charLookup("u.username", lookup: "icontains", value: query)!) LIMIT \(limit)
                    """))
                users = try found.map { try self.userJSON($0, in: db) }
            }
            var groups: [JSON] = []
            if access.has(.view, "group") {
                let found = try Group.fetchAll(db, SQLRequest<Group>(literal: """
                    SELECT g.* FROM groups g WHERE \(QueryFilters.charLookup("g.name", lookup: "icontains", value: query)!) LIMIT \(limit)
                    """))
                groups = try found.map { try self.groupJSON($0, in: db) }
            }
            var fields: [JSON] = []
            if access.has(.view, CustomField.objectType) {
                let rows = try Row.fetchAll(db, SQLRequest<Row>(literal: """
                    SELECT o.*, \(self.customFieldCountSQL(access)) AS document_count FROM custom_fields o
                    WHERE \(QueryFilters.charLookup("o.name", lookup: "icontains", value: query)!) LIMIT \(limit)
                    """))
                fields = try rows.map { self.customFieldJSON(try CustomField(row: $0), documentCount: $0["document_count"]) }
            }
            total += tags.count + correspondents.count + types.count + paths.count + savedViews.count + users.count + groups.count + fields.count
            return .object(JSONObject([
                ("total", .int(total)), ("documents", .array(documents)), ("saved_views", .array(savedViews)), ("tags", .array(tags)),
                ("correspondents", .array(correspondents)), ("document_types", .array(types)), ("storage_paths", .array(paths)),
                ("users", .array(users)), ("groups", .array(groups)), ("mail_rules", []), ("mail_accounts", []), ("workflows", []),
                ("custom_fields", .array(fields)),
            ]))
        }
        return .json(json)
    }

    func autocomplete(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, Document.objectType)
        guard let term = request.query["term"]?.trimmingCharacters(in: .whitespaces) else { throw APIError.badRequestText("Term required") }
        var requestedLimit = 10
        if let raw = request.query["limit"] {
            guard let value = Int(raw), value > 0 else { throw APIError.badRequestText("Invalid limit") }
            requestedLimit = min(value, 1000)
        }
        let limit = requestedLimit
        let visibility = access.visibilityPredicate(objectType: Document.objectType, alias: "d")
        let words = try await read { db in try APISearch.autocomplete(term, visibility: visibility, limit: limit, in: db) }
        return .json(JSON(words))
    }

    // MARK: - Statistics

    func statistics(_ request: APIRequest) async throws -> Response {
        let access = request.access
        let global = access.isSuperuser || access.has(Permission.viewGlobalStatistics)
        let json = try await read { db -> JSON in
            let docs: SQL = global ? "d.deleted_at IS NULL AND d.root_document_id IS NULL" : self.countableDocuments(access)
            func objectCount(_ table: String, _ model: String) throws -> Int {
                let visibility: SQL = global ? "1" : access.visibilityPredicate(objectType: model, alias: "o")
                return try Int.fetchOne(db, SQLRequest<Int>(literal: "SELECT COUNT(*) FROM \(sql: table) o WHERE \(visibility)")) ?? 0
            }
            let tagVisibility: SQL = global ? "1" : access.visibilityPredicate(objectType: Tag.objectType, alias: "o")
            let inboxTags = try Int.fetchAll(db, SQLRequest<Int>(literal: "SELECT o.id FROM tags o WHERE o.is_inbox_tag = 1 AND \(tagVisibility) ORDER BY o.id"))
            var inboxCount: JSON = .null
            if !inboxTags.isEmpty {
                inboxCount = .int(try Int.fetchOne(db, SQLRequest<Int>(literal: """
                    SELECT COUNT(DISTINCT d.id) FROM documents d JOIN document_tags dt ON dt.document_id = d.id
                    WHERE \(docs) AND dt.tag_id IN \(inboxTags)
                    """)) ?? 0)
            }
            let mimeRows = try Row.fetchAll(db, SQLRequest<Row>(literal: """
                SELECT d.mime_type, COUNT(*) AS n, SUM(length(d.content)) AS chars FROM documents d WHERE \(docs)
                GROUP BY d.mime_type ORDER BY n DESC, d.mime_type
                """))
            let total = mimeRows.reduce(0) { $0 + ($1["n"] as Int) }
            let characters = mimeRows.reduce(0) { $0 + (($1["chars"] as Int?) ?? 0) }
            let currentASN = try Int.fetchOne(db, sql: "SELECT MAX(archive_serial_number) FROM documents WHERE deleted_at IS NULL") ?? 0
            return .object(JSONObject([
                ("documents_total", .int(total)), ("documents_inbox", inboxCount),
                ("inbox_tag", JSON(inboxTags.first)), ("inbox_tags", inboxTags.isEmpty ? .null : JSON(inboxTags)),
                ("document_file_type_counts", .array(mimeRows.map { ["mime_type": .string($0["mime_type"]), "mime_type_count": .int($0["n"])] })),
                ("character_count", .int(characters)), ("tag_count", .int(try objectCount("tags", Tag.objectType))),
                ("correspondent_count", .int(try objectCount("correspondents", Correspondent.objectType))),
                ("document_type_count", .int(try objectCount("document_types", DocumentType.objectType))),
                ("storage_path_count", .int(try objectCount("storage_paths", StoragePath.objectType))),
                ("current_asn", .int(currentASN)),
            ]))
        }
        return .json(json)
    }

    // MARK: - Status and version

    func systemStatus(_ request: APIRequest) async throws -> Response {
        let access = request.access
        guard access.isSuperuser || access.user.isStaff || access.has(Permission.viewSystemMonitoring) else { throw APIError.forbiddenText() }
        let fm = FileManager.default
        let attributes = try? fm.attributesOfFileSystem(forPath: settings.mediaRoot.path)
        let total = (attributes?[.systemSize] as? NSNumber)?.intValue ?? 0
        let available = (attributes?[.systemFreeSize] as? NSNumber)?.intValue ?? 0
        var databaseStatus = "OK"
        var databaseError: JSON = .null
        do { _ = try await read { db in try Int.fetchOne(db, sql: "SELECT 1") } } catch {
            databaseStatus = "ERROR"
            databaseError = .string("\(error)")
        }
        let index = try? await read { db -> Date? in
            try String.fetchOne(db, sql: "SELECT MAX(date_done) FROM tasks WHERE task_type = 'index_optimize' AND status = 'success'")
                .flatMap { FolioDateFormat.database.date(from: $0) }
        }
        let sanity = try? await read { db -> [String: String]? in
            try Row.fetchOne(db, sql: "SELECT status, date_done, result_message FROM tasks WHERE task_type = 'sanity_check' ORDER BY date_created DESC LIMIT 1")
                .map { row in ["status": row["status"] ?? "", "date_done": row["date_done"] ?? "", "result_message": row["result_message"] ?? ""] }
        }
        let classifierDate = (try? fm.attributesOfItem(atPath: settings.classifierFile.path))?[.modificationDate] as? Date
        let hasDocuments = (try? await read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM documents") ?? 0 }) ?? 0 > 0
        let classifierStatus = classifierDate != nil ? "OK" : (hasDocuments ? "WARNING" : "OK")
        let pending = await queue.activeCount
        let llm = await llmIndexStatus()
        let sanityStatus: String
        switch sanity?["status"] {
        case "success": sanityStatus = "OK"
        case "failure": sanityStatus = "ERROR"
        default: sanityStatus = "WARNING"
        }
        var info = utsname()
        uname(&info)
        let machine = withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        return .json(.object(JSONObject([
            ("pngx_version", .string(reportedVersion)),
            ("server_os", .string("macOS \(os) \(machine)")),
            ("install_type", "bare-metal"),
            ("storage", ["total": .int(total), "available": .int(available)]),
            ("database", .object(JSONObject([
                ("type", "sqlite"), ("url", .string(settings.databaseFile.path)), ("status", .string(databaseStatus)),
                ("error", databaseError), ("migration_status", ["latest_migration": "v1-initial", "unapplied_migrations": []]),
            ]))),
            ("tasks", .object(JSONObject([
                ("redis_url", .null), ("redis_status", "OK"), ("redis_error", .null),
                ("celery_status", "OK"), ("celery_url", .string("foliozero (\(pending) active)")), ("celery_error", .null),
                ("index_status", "OK"), ("index_last_modified", datetime(index ?? nil)), ("index_error", .null),
                ("classifier_status", .string(classifierStatus)), ("classifier_last_trained", datetime(classifierDate)),
                ("classifier_error", classifierStatus == "OK" ? .null : "Classifier file does not exist (yet). Re-training may be pending."),
                ("sanity_check_status", .string(sanityStatus)),
                ("sanity_check_last_run", datetime(sanity?["date_done"].flatMap { FolioDateFormat.database.date(from: $0) })),
                ("sanity_check_error", sanityStatus == "ERROR" ? JSON(sanity?["result_message"]) : .null),
                ("llmindex_status", .string(llm.status)), ("llmindex_last_modified", datetime(llm.lastModified)), ("llmindex_error", JSON(llm.error)),
                ("summary", []),
            ]))),
        ])))
    }

    func remoteVersion(_ request: APIRequest) async throws -> Response {
        .json(["version": .string(reportedVersion), "update_available": false])
    }

    // MARK: - Application configuration

    static let configFields: [(String, JSON)] = [
        ("user_args", .null), ("barcode_tag_mapping", .null), ("llm_embedding_api_key", .null), ("llm_api_key", .null),
        ("remote_ocr_api_key", .null), ("output_type", .null), ("pages", .null), ("language", .null), ("mode", .null),
        ("archive_file_generation", .null), ("image_dpi", .null), ("unpaper_clean", .null), ("deskew", .null),
        ("rotate_pages", .null), ("rotate_pages_threshold", .null), ("max_image_pixels", .null), ("color_conversion_strategy", .null),
        ("app_title", .null), ("app_logo", .null), ("barcodes_enabled", .null), ("barcode_enable_tiff_support", .null),
        ("barcode_string", .null), ("barcode_retain_split_pages", .null), ("barcode_enable_asn", .null), ("barcode_asn_prefix", .null),
        ("barcode_upscale", .null), ("barcode_dpi", .null), ("barcode_max_pages", .null), ("barcode_enable_tag", .null),
        ("barcode_tag_split", .null), ("barcode_store_values", .null), ("remote_ocr_engine", .null), ("remote_ocr_endpoint", .null),
        ("remote_ocr_mode", .null), ("ai_enabled", .null), ("llm_embedding_backend", .null), ("llm_embedding_model", .null),
        ("llm_embedding_endpoint", .null), ("llm_embedding_chunk_size", .null), ("llm_context_size", .null), ("llm_backend", .null),
        ("llm_model", .null), ("llm_endpoint", .null), ("llm_output_language", .null), ("llm_request_timeout", .null),
    ]
    static let obfuscatedConfigFields: Set<String> = ["llm_embedding_api_key", "llm_api_key", "remote_ocr_api_key"]

    func loadConfig(in db: Database) throws -> JSONObject {
        let text = try String.fetchOne(db, sql: "SELECT config FROM app_config WHERE id = 1")
        return text.flatMap { try? JSON.parse($0) }?.object ?? JSONObject()
    }

    func configJSON(_ stored: JSONObject) -> JSON {
        var object = JSONObject()
        object["id"] = 1
        let env = ProcessInfo.processInfo.environment.keys.filter { $0.hasPrefix("PAPERLESS_") || $0.hasPrefix("FOLIOZERO_") }.sorted()
        object["externally_configured_variables"] = JSON(env)
        for (key, fallback) in Self.configFields {
            var value = stored[key] ?? fallback
            if Self.obfuscatedConfigFields.contains(key), let secret = value.string { value = .string(String(repeating: "*", count: max(10, secret.count))) }
            object[key] = value
        }
        return .object(object)
    }

    /// DRF `DjangoModelPermissions`: reading needs no model permission.
    func listConfig(_ request: APIRequest) async throws -> Response {
        let stored = try await read { db in try self.loadConfig(in: db) }
        return .json([configJSON(stored)])
    }

    func getConfig(_ request: APIRequest) async throws -> Response {
        guard try request.intParam("id") == 1 else { throw APIError.notFound("ApplicationConfiguration") }
        let stored = try await read { db in try self.loadConfig(in: db) }
        return .json(configJSON(stored))
    }

    func updateConfig(_ request: APIRequest) async throws -> Response {
        try request.access.require(.change, "applicationconfiguration")
        guard try request.intParam("id") == 1 else { throw APIError.notFound("ApplicationConfiguration") }
        let data = try request.data()
        let known = Set(Self.configFields.map(\.0))
        try validateRemoteOCRConfig(data.object)
        let normalised = try validatedConfigFields(data.object)
        let stored = try await write { db -> JSONObject in
            var config = try self.loadConfig(in: db)
            for (key, value) in data.object where known.contains(key) {
                var value = normalised[key] ?? value
                if ["user_args", "barcode_tag_mapping", "language", "llm_output_language"].contains(key), value.string == "" { value = .null }
                if ["user_args", "barcode_tag_mapping"].contains(key), !value.isNull {
                    if let text = value.stringValue, let parsed = try? JSON.parse(text) { value = parsed }
                    guard value.object != nil else { throw APIError.field(key, "\(key) must be a JSON object.") }
                }
                if Self.obfuscatedConfigFields.contains(key), let secret = value.string {
                    if secret.isEmpty { value = .null } else if secret.replacingOccurrences(of: "*", with: "").isEmpty { continue }
                }
                config[key] = value
            }
            try db.execute(sql: """
                INSERT INTO app_config(id, config) VALUES (1, ?) ON CONFLICT(id) DO UPDATE SET config = excluded.config
                """, arguments: [JSON.object(config).serialized()])
            return config
        }
        return .json(configJSON(stored))
    }

    // Paperless-ngx `ApplicationConfiguration` field types: choices, MinValueValidators, booleans.
    static let configChoiceFields: [String: [String]] = [
        "output_type": ["pdf", "pdfa", "pdfa-1", "pdfa-2", "pdfa-3"],
        "mode": OCRMode.allCases.map(\.rawValue),
        "archive_file_generation": ArchiveMode.allCases.map(\.rawValue),
        "unpaper_clean": ["clean", "clean-final", "none"],
        "color_conversion_strategy": ["LeaveColorUnchanged", "RGB", "UseDeviceIndependentColor", "Gray", "CMYK"],
    ]
    static let configIntegerFields: [String: Int] = ["pages": 1, "image_dpi": 1, "barcode_dpi": 1, "barcode_max_pages": 1]
    static let configFloatFields: [String: Double] = ["rotate_pages_threshold": 0.0, "max_image_pixels": 0.0, "barcode_upscale": 1.0]
    static let configBooleanFields: Set<String> = [
        "deskew", "rotate_pages", "barcodes_enabled", "barcode_enable_tiff_support", "barcode_retain_split_pages",
        "barcode_enable_asn", "barcode_enable_tag", "barcode_tag_split", "barcode_store_values",
    ]

    /// Validates the OCR, barcode and general fields like DRF does for the Paperless-ngx model,
    /// and returns the values with their JSON types normalised ("5" becomes 5, "true" becomes true).
    func validatedConfigFields(_ object: JSONObject) throws -> [String: JSON] {
        var errors = JSONObject()
        var normalised: [String: JSON] = [:]
        for (key, value) in object where !value.isNull {
            if let allowed = Self.configChoiceFields[key] {
                guard let text = value.stringValue, text.isEmpty || allowed.contains(text) else {
                    errors[key] = [.string("\"\(value.string ?? value.serialized())\" is not a valid choice.")]
                    continue
                }
            } else if let minimum = Self.configIntegerFields[key] {
                guard let number = value.int else { errors[key] = ["A valid integer is required."]; continue }
                guard number >= minimum else { errors[key] = [.string("Ensure this value is greater than or equal to \(minimum).")]; continue }
                normalised[key] = .int(number)
            } else if let minimum = Self.configFloatFields[key] {
                guard let number = value.double, number.isFinite else { errors[key] = ["A valid number is required."]; continue }
                guard number >= minimum else {
                    errors[key] = [.string("Ensure this value is greater than or equal to \(String(format: "%.1f", minimum)).")]
                    continue
                }
                normalised[key] = .double(number)
            } else if Self.configBooleanFields.contains(key) {
                guard let flag = value.bool else { errors[key] = ["Must be a valid boolean."]; continue }
                normalised[key] = .bool(flag)
            }
        }
        if !errors.isEmpty { throw APIError.validation(.object(errors)) }
        return normalised
    }

    /// `remote_ocr_engine` and `remote_ocr_mode` are model choices; `remote_ocr_endpoint` is
    /// checked like Paperless-ngx `validate_remote_ocr_endpoint`.
    func validateRemoteOCRConfig(_ object: JSONObject) throws {
        let choices: [(String, [String])] = [
            ("remote_ocr_engine", RemoteOCREngineKind.allCases.map(\.rawValue)),
            ("remote_ocr_mode", RemoteOCRMode.allCases.map(\.rawValue)),
        ]
        for (key, allowed) in choices {
            guard let value = object[key], !value.isNull else { continue }
            guard let text = value.string, text.isEmpty || allowed.contains(text) else {
                throw APIError.field(key, "\"\(value.string ?? value.serialized())\" is not a valid choice.")
            }
        }
        guard let endpoint = object["remote_ocr_endpoint"]?.string, !endpoint.isEmpty else { return }
        let problem: String?
        if let components = URLComponents(string: endpoint), let scheme = components.scheme?.lowercased(),
           ["http", "https"].contains(scheme), let host = components.host, !host.isEmpty {
            problem = !settings.remoteOCRAllowInternalEndpoints && NetworkPolicy.isInternal(host: host)
                ? "Connection blocked: \(host) resolves to a non-public address" : nil
        } else {
            problem = "Invalid URL scheme or hostname."
        }
        if let problem {
            logger.warning("Rejected remote OCR endpoint \(endpoint): \(problem)")
            throw APIError.field("remote_ocr_endpoint", "Invalid remote OCR endpoint: \(problem), see logs for details")
        }
    }

    // MARK: - Logs

    /// Paperless-ngx log names mapped to FolioZero's files.
    var logFiles: [(String, URL)] {
        [("paperless", settings.loggingDir.appendingPathComponent("foliozero.log")),
         ("mail", settings.loggingDir.appendingPathComponent("mail.log")),
         ("celery", settings.loggingDir.appendingPathComponent("celery.log"))]
    }

    func requireAdmin(_ access: AccessContext) throws {
        guard access.user.isActive, access.user.isStaff || access.isSuperuser else { throw APIError.permissionDenied }
    }

    func listLogs(_ request: APIRequest) async throws -> Response {
        try requireAdmin(request.access)
        let existing = logFiles.filter { FileManager.default.fileExists(atPath: $0.1.path) }.map(\.0)
        return .json(JSON(existing))
    }

    func getLog(_ request: APIRequest) async throws -> Response {
        try requireAdmin(request.access)
        guard let name = request.params["name"], let file = logFiles.first(where: { $0.0 == name })?.1,
              FileManager.default.fileExists(atPath: file.path) else { throw APIError.notFound() }
        var limit: Int?
        if let raw = request.query["limit"] {
            guard let value = Int(raw), value >= 1 else { throw APIError.validation(["limit": "Must be a positive integer"]) }
            limit = value
        }
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var trimmed = String(line)
            while let last = trimmed.last, last.isWhitespace { trimmed.removeLast() }
            return trimmed
        }
        if lines.last == "" { lines.removeLast() }
        if let limit { lines = Array(lines.suffix(limit)) }
        return .json(JSON(lines))
    }
}
