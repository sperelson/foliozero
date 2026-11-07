import Foundation
import FolioCore
import GRDB
import Hummingbird

extension API {
    // MARK: - Custom fields

    func extraDataJSON(_ extra: CustomField.ExtraData?) -> JSON {
        guard let extra else { return .null }
        var object = JSONObject()
        if let options = extra.selectOptions {
            object["select_options"] = .array(options.map { ["id": .string($0.id), "label": .string($0.label)] })
        }
        if extra.defaultCurrency != nil || extra.selectOptions == nil {
            object["default_currency"] = JSON(extra.defaultCurrency)
        }
        return .object(object)
    }

    func customFieldJSON(_ field: CustomField, documentCount: Int) -> JSON {
        .object(JSONObject([
            ("id", JSON(field.id)),
            ("name", .string(field.name)),
            ("data_type", .string(field.dataType.rawValue)),
            ("extra_data", extraDataJSON(field.extraData)),
            ("document_count", .int(documentCount)),
        ]))
    }

    func customFieldCountSQL(_ access: AccessContext) -> SQL {
        """
        (SELECT COUNT(DISTINCT i.document_id) FROM custom_field_instances i JOIN documents d ON d.id = i.document_id
         WHERE i.field_id = o.id AND i.deleted_at IS NULL AND \(countableDocuments(access)))
        """
    }

    func listCustomFields(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, CustomField.objectType)
        let query = request.query
        let body = try await read { db -> JSONObject in
            var conditions = try Self.strictIdFilters(query, column: "o.id")
            for (name, value) in query.items where name.hasPrefix("name__") && !value.isEmpty {
                if let condition = QueryFilters.charLookup("o.name", lookup: String(name.dropFirst(6)), value: value) { conditions.append(condition) }
            }
            let predicate = QueryFilters.and(conditions)
            let count = try Int.fetchOne(db, SQLRequest<Int>(literal: "SELECT COUNT(*) FROM custom_fields o WHERE \(predicate)")) ?? 0
            let page = try PageRequest.resolve(query, count: count)
            let order = QueryFilters.ordering(query["ordering"], allowed: [
                "id": "o.id", "name": "o.name", "data_type": "o.data_type", "document_count": "document_count",
            ])?.joined(separator: ", ") ?? "o.name"
            let rows = try Row.fetchAll(db, SQLRequest<Row>(literal: """
                SELECT o.*, \(self.customFieldCountSQL(access)) AS document_count FROM custom_fields o WHERE \(predicate)
                ORDER BY \(sql: order), o.id LIMIT \(page.size) OFFSET \(page.offset)
                """))
            let results = try rows.map { self.customFieldJSON(try CustomField(row: $0), documentCount: $0["document_count"]) }
            let all = request.version < 10 ? try Int.fetchAll(db, SQLRequest<Int>(literal: "SELECT o.id FROM custom_fields o WHERE \(predicate) ORDER BY o.name")) : nil
            return self.paginated(request, page: page, count: count, results: results, allIds: all)
        }
        return .json(.object(body))
    }

    private func customFieldResponse(_ id: Int, access: AccessContext, in db: Database) throws -> JSON {
        guard let row = try Row.fetchOne(db, SQLRequest<Row>(literal: """
            SELECT o.*, \(customFieldCountSQL(access)) AS document_count FROM custom_fields o WHERE o.id = \(id)
            """)) else { throw APIError.notFound("CustomField") }
        return customFieldJSON(try CustomField(row: row), documentCount: row["document_count"])
    }

    func getCustomField(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, CustomField.objectType)
        let id = try request.intParam("id")
        return .json(try await read { db in try self.customFieldResponse(id, access: access, in: db) })
    }

    /// Validates `extra_data` like Paperless-ngx `CustomFieldSerializer.validate`.
    private func parseExtraData(_ value: JSON?, dataType: CustomFieldDataType, existing: CustomField.ExtraData?) throws -> CustomField.ExtraData? {
        guard let value else {
            if dataType == .select, existing?.selectOptions?.isEmpty ?? true {
                throw APIError.field("error", "extra_data.select_options must be a valid list")
            }
            return existing
        }
        if value.isNull {
            if dataType == .select { throw APIError.field("error", "extra_data.select_options must be a valid list") }
            return nil
        }
        guard let object = value.object else { throw APIError.field("extra_data", "Value must be valid JSON.") }
        var extra = CustomField.ExtraData()
        if dataType == .select {
            guard let options = object["select_options"]?.array, !options.isEmpty,
                  options.allSatisfy({ ($0["label"]?.string ?? "").isEmpty == false }) else {
                throw APIError.field("error", "extra_data.select_options must be a valid list")
            }
            extra.selectOptions = options.map { option in
                let id = option["id"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? PasswordHasher.randomString(length: 16)
                return CustomField.ExtraData.SelectOption(id: id, label: option["label"]?.string ?? "")
            }
        } else if let options = object["select_options"]?.array {
            extra.selectOptions = options.compactMap { option in
                guard let id = option["id"]?.string, let label = option["label"]?.string else { return nil }
                return CustomField.ExtraData.SelectOption(id: id, label: label)
            }
        }
        if let currency = object["default_currency"], !currency.isNull {
            guard let text = currency.stringValue, text.isEmpty || text.count == 3 else {
                if dataType == .monetary { throw APIError.field("error", "extra_data.default_currency must be a 3-character string") }
                return extra
            }
            extra.defaultCurrency = text.isEmpty ? nil : text.uppercased()
        }
        return extra
    }

    func createCustomField(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.add, CustomField.objectType)
        let data = try request.data()
        let name = try data.requiredString("name", maxLength: 128)
        guard let rawType = data["data_type"]?.string else { throw APIError.field("data_type", APIError.requiredField) }
        guard let dataType = CustomFieldDataType(rawValue: rawType) else {
            throw APIError.field("data_type", "\"\(rawType)\" is not a valid choice.")
        }
        let extra = try parseExtraData(data["extra_data"], dataType: dataType, existing: nil)
        let json = try await write { db -> JSON in
            if try CustomField.filter(Column("name") == name).fetchCount(db) > 0 {
                throw APIError.field("error", "Object violates name unique constraint")
            }
            var field = CustomField(name: name, dataType: dataType, extraData: extra)
            try field.insert(db)
            return try self.customFieldResponse(field.id!, access: access, in: db)
        }
        return .json(json, status: .created)
    }

    func updateCustomField(_ request: APIRequest, partial: Bool) async throws -> Response {
        let access = request.access
        try access.require(.change, CustomField.objectType)
        let id = try request.intParam("id")
        let data = try request.data()
        let json = try await write { db -> JSON in
            guard var field = try CustomField.fetchOne(db, key: id) else { throw APIError.notFound("CustomField") }
            if !partial || data.has("name") {
                let name = try data.requiredString("name", maxLength: 128)
                if try CustomField.filter(Column("name") == name && Column("id") != id).fetchCount(db) > 0 {
                    throw APIError.field("error", "Object violates name unique constraint")
                }
                field.name = name
            }
            if let rawType = data["data_type"]?.string {
                guard let dataType = CustomFieldDataType(rawValue: rawType) else {
                    throw APIError.field("data_type", "\"\(rawType)\" is not a valid choice.")
                }
                field.dataType = dataType
            }
            field.extraData = try self.parseExtraData(data["extra_data"], dataType: field.dataType, existing: field.extraData)
            try field.update(db)
            // Select values whose option was removed are cleared, as in Paperless-ngx.
            if field.dataType == .select {
                let valid = (field.extraData?.selectOptions ?? []).map(\.id)
                try db.execute(sql: """
                    UPDATE custom_field_instances SET value_select = NULL
                    WHERE field_id = ? AND value_select IS NOT NULL AND value_select NOT IN (\(valid.map { _ in "?" }.joined(separator: ",").ifEmpty("NULL")))
                    """, arguments: StatementArguments([id] as [any DatabaseValueConvertible] + valid))
            }
            for documentId in try Int.fetchAll(db, sql: "SELECT document_id FROM custom_field_instances WHERE field_id = ?", arguments: [id]) {
                try SearchIndex.update(documentId: documentId, in: db)
            }
            return try self.customFieldResponse(id, access: access, in: db)
        }
        return .json(json)
    }

    func deleteCustomField(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.delete, CustomField.objectType)
        let id = try request.intParam("id")
        try await write { db in
            guard try CustomField.fetchOne(db, key: id) != nil else { throw APIError.notFound("CustomField") }
            let documents = try Int.fetchAll(db, sql: "SELECT document_id FROM custom_field_instances WHERE field_id = ?", arguments: [id])
            _ = try CustomField.deleteOne(db, key: id)
            for documentId in documents { try SearchIndex.update(documentId: documentId, in: db) }
        }
        return .noContent()
    }

    // MARK: - Saved views

    static let savedViewDisplayFields: Set<String> = [
        "title", "created", "added", "tag", "correspondent", "documenttype", "storagepath", "note", "owner", "shared", "asn", "pagecount",
    ]

    func savedViewJSON(_ view: SavedView, rules: [SavedViewFilterRule], grants: GrantTable, context: SerializeContext, ui: JSONObject?) -> JSON {
        let id = view.id ?? 0
        var json = JSONObject()
        json["id"] = .int(id)
        json["name"] = .string(view.name)
        json["icon"] = JSON(view.icon)
        json["sort_field"] = JSON(view.sortField)
        json["sort_reverse"] = .bool(view.sortReverse)
        json["filter_rules"] = .array(rules.map { ["rule_type": .int($0.ruleType), "value": JSON($0.value)] })
        json["page_size"] = JSON(view.pageSize)
        json["display_mode"] = JSON(view.displayMode)
        json["display_fields"] = view.displayFields.map { JSON($0) } ?? .null
        grants.addOwnedFields(to: &json, id: id, ownerId: view.ownerId, context: context)
        if context.version < 10 {
            let savedViews = ui?["saved_views"]?.object
            let dashboard = (savedViews?["dashboard_views_visible_ids"]?.array ?? []).compactMap(\.int)
            let sidebar = (savedViews?["sidebar_views_visible_ids"]?.array ?? []).compactMap(\.int)
            json["show_on_dashboard"] = .bool(dashboard.contains(id))
            json["show_in_sidebar"] = .bool(sidebar.contains(id))
        }
        return .object(json)
    }

    private func savedViewsJSON(_ views: [SavedView], context: SerializeContext, in db: Database) throws -> [JSON] {
        let ids = views.compactMap(\.id)
        let grants = try GrantTable.load(objectType: SavedView.objectType, ids: ids, in: db)
        let rules = try SavedViewFilterRule.filter(ids.contains(Column("saved_view_id"))).order(Column("id")).fetchAll(db)
        let ui = context.version < 10 ? try storedUISettings(userId: context.access.userId, in: db) : nil
        return views.map { view in
            savedViewJSON(view, rules: rules.filter { $0.savedViewId == view.id }, grants: grants, context: context, ui: ui)
        }
    }

    func listSavedViews(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, SavedView.objectType)
        let query = request.query
        let context = SerializeContext(request)
        let body = try await read { db -> JSONObject in
            let predicate = access.visibilityPredicate(objectType: SavedView.objectType, alias: "o")
            let count = try Int.fetchOne(db, SQLRequest<Int>(literal: "SELECT COUNT(*) FROM saved_views o WHERE \(predicate)")) ?? 0
            let page = try PageRequest.resolve(query, count: count)
            let order = QueryFilters.ordering(query["ordering"], allowed: ["name": "o.name COLLATE NOCASE", "id": "o.id"])?.joined(separator: ", ") ?? "o.id"
            let views = try SavedView.fetchAll(db, SQLRequest<SavedView>(literal: """
                SELECT o.* FROM saved_views o WHERE \(predicate) ORDER BY \(sql: order), o.id LIMIT \(page.size) OFFSET \(page.offset)
                """))
            let all = request.version < 10 ? try Int.fetchAll(db, SQLRequest<Int>(literal: "SELECT o.id FROM saved_views o WHERE \(predicate) ORDER BY o.id")) : nil
            return self.paginated(request, page: page, count: count, results: try self.savedViewsJSON(views, context: context, in: db), allIds: all)
        }
        return .json(.object(body))
    }

    private func loadSavedView(_ id: Int, access: AccessContext, in db: Database) throws -> SavedView {
        guard let view = try SavedView.fetchOne(db, key: id),
              try access.can(.view, objectType: SavedView.objectType, objectId: id, ownerId: view.ownerId, in: db) else {
            throw APIError.notFound("SavedView")
        }
        return view
    }

    func getSavedView(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, SavedView.objectType)
        let id = try request.intParam("id")
        let context = SerializeContext(request)
        let json = try await read { db -> JSON in
            let view = try self.loadSavedView(id, access: access, in: db)
            return try self.savedViewsJSON([view], context: context, in: db)[0]
        }
        return .json(json)
    }

    private func applySavedViewFields(_ view: inout SavedView, data: RequestData, isCreate: Bool, in db: Database) throws -> [SavedViewFilterRule]? {
        if isCreate || data.has("name") { view.name = try data.requiredString("name", maxLength: 128) }
        if let icon = data["icon"] { view.icon = icon.isNull ? nil : icon.string }
        if let sortField = data["sort_field"] { view.sortField = sortField.isNull ? nil : sortField.string }
        if let reverse = try data.optionalBool("sort_reverse") { view.sortReverse = reverse }
        if data.has("page_size") {
            let size = try data.optionalInt("page_size")
            if let size, size < 1 || size > 100_000 { throw APIError.field("page_size", "Ensure this value is greater than or equal to 1.") }
            view.pageSize = size
        }
        if let mode = data["display_mode"] {
            if mode.isNull { view.displayMode = nil } else {
                guard let text = mode.string, ["table", "smallCards", "largeCards"].contains(text) else {
                    throw APIError.field("display_mode", "\"\(mode.string ?? "")\" is not a valid choice.")
                }
                view.displayMode = text
            }
        }
        if let fields = data["display_fields"] {
            if fields.isNull { view.displayFields = nil } else {
                guard let items = fields.array else { throw APIError.field("display_fields", "Expected a list of items.") }
                var values: [String] = []
                for item in items {
                    let text = item.string ?? ""
                    if text.hasPrefix("custom_field_") {
                        guard let fieldId = Int(text.dropFirst("custom_field_".count)), try CustomField.fetchOne(db, key: fieldId) != nil else {
                            throw APIError.nonField("Invalid field: \(text)")
                        }
                    } else if !Self.savedViewDisplayFields.contains(text) {
                        throw APIError.nonField("Invalid field: \(text)")
                    }
                    values.append(text)
                }
                view.displayFields = values.isEmpty ? nil : values
            }
        }
        guard let rulesValue = data["filter_rules"] else {
            if isCreate { throw APIError.field("filter_rules", APIError.requiredField) }
            return nil
        }
        guard let items = rulesValue.array else { throw APIError.field("filter_rules", "Expected a list of items but got type \"\(rulesValue.typeName)\".") }
        var rules: [SavedViewFilterRule] = []
        for item in items {
            guard let type = item["rule_type"]?.int else {
                throw APIError.validation(["filter_rules": [["rule_type": ["This field is required."]]]])
            }
            let value = item["value"].flatMap { $0.isNull ? nil : $0.string }
            rules.append(SavedViewFilterRule(savedViewId: view.id ?? 0, ruleType: type, value: value))
        }
        return rules
    }

    /// API v9: `show_on_dashboard` / `show_in_sidebar` live in the user's UI settings.
    private func updateLegacyVisibility(viewId: Int, data: RequestData, version: Int, userId: Int, in db: Database) throws {
        guard version < 10 else { return }
        let dashboard = try data.optionalBool("show_on_dashboard")
        let sidebar = try data.optionalBool("show_in_sidebar")
        guard dashboard != nil || sidebar != nil else { return }
        var settingsObject = try storedUISettings(userId: userId, in: db)
        var savedViews = settingsObject["saved_views"]?.object ?? JSONObject()
        var dashboardIds = Set((savedViews["dashboard_views_visible_ids"]?.array ?? []).compactMap(\.int))
        var sidebarIds = Set((savedViews["sidebar_views_visible_ids"]?.array ?? []).compactMap(\.int))
        if let dashboard { if dashboard { dashboardIds.insert(viewId) } else { dashboardIds.remove(viewId) } }
        if let sidebar { if sidebar { sidebarIds.insert(viewId) } else { sidebarIds.remove(viewId) } }
        savedViews["dashboard_views_visible_ids"] = JSON(dashboardIds.sorted())
        savedViews["sidebar_views_visible_ids"] = JSON(sidebarIds.sorted())
        settingsObject["saved_views"] = .object(savedViews)
        try db.execute(sql: """
            INSERT INTO ui_settings(user_id, settings) VALUES (?, ?)
            ON CONFLICT(user_id) DO UPDATE SET settings = excluded.settings
            """, arguments: [userId, JSON.object(settingsObject).serialized()])
    }

    func createSavedView(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.add, SavedView.objectType)
        let data = try request.data()
        let context = SerializeContext(request)
        let json = try await write { db -> JSON in
            var view = SavedView(name: "")
            let rules = try self.applySavedViewFields(&view, data: data, isCreate: true, in: db) ?? []
            if data.has("owner") { view.ownerId = try data.foreignKey("owner", table: "users", in: db) ?? nil } else { view.ownerId = access.user.id }
            let spec = try PermissionSpec.parse(data["set_permissions"], in: db)
            try view.insert(db)
            for var rule in rules {
                rule.savedViewId = view.id!
                try rule.insert(db)
            }
            try spec?.apply(objectType: SavedView.objectType, objectIds: [view.id!], merge: false, in: db)
            try self.updateLegacyVisibility(viewId: view.id!, data: data, version: request.version, userId: access.userId, in: db)
            return try self.savedViewsJSON([view], context: context, in: db)[0]
        }
        return .json(json, status: .created)
    }

    func updateSavedView(_ request: APIRequest, partial: Bool) async throws -> Response {
        let access = request.access
        try access.require(.change, SavedView.objectType)
        let id = try request.intParam("id")
        let data = try request.data()
        let context = SerializeContext(request)
        let json = try await write { db -> JSON in
            var view = try self.loadSavedView(id, access: access, in: db)
            guard try access.can(.change, objectType: SavedView.objectType, objectId: id, ownerId: view.ownerId, in: db) else {
                throw APIError.permissionDenied
            }
            let before = view
            let rules = try self.applySavedViewFields(&view, data: data, isCreate: !partial, in: db)
            let newOwner: Int?? = data.has("owner") ? try data.foreignKey("owner", table: "users", in: db) : .none
            let spec = try PermissionSpec.parse(data["set_permissions"], in: db)
            if (newOwner != nil && newOwner! != before.ownerId) || spec != nil {
                guard access.isOwner(ownerId: before.ownerId) else { throw APIError.insufficientPermissions }
            }
            if case .some(let owner) = newOwner { view.ownerId = owner }
            try view.update(db)
            if let rules {
                try db.execute(sql: "DELETE FROM saved_view_filter_rules WHERE saved_view_id = ?", arguments: [id])
                for var rule in rules {
                    rule.savedViewId = id
                    try rule.insert(db)
                }
            }
            try spec?.apply(objectType: SavedView.objectType, objectIds: [id], merge: false, in: db)
            try self.updateLegacyVisibility(viewId: id, data: data, version: request.version, userId: access.userId, in: db)
            return try self.savedViewsJSON([view], context: context, in: db)[0]
        }
        return .json(json)
    }

    func deleteSavedView(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.delete, SavedView.objectType)
        let id = try request.intParam("id")
        try await write { db in
            let view = try self.loadSavedView(id, access: access, in: db)
            guard access.isOwner(ownerId: view.ownerId) else { throw APIError.permissionDenied }
            _ = try SavedView.deleteOne(db, key: id)
            try PermissionSet.removeAll(objectType: SavedView.objectType, objectId: id, in: db)
        }
        return .noContent()
    }
}
