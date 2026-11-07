import Foundation
import FolioCore
import GRDB
import Hummingbird

/// Mail accounts, mail rules and processed mail (Paperless-ngx `paperless_mail` API).
extension API {
    // MARK: - Shared

    /// Lists owned objects of `table` the caller may see, paginated, serialized by `serialize`.
    func listOwned<Record: IdentifiedRecord>(
        _ type: Record.Type, objectType: String, request: APIRequest, extra: [SQL] = [], defaultOrder: String,
        ordering: [String: String] = [:], serialize: @escaping @Sendable ([Record], GrantTable, Database) throws -> [JSON]
    ) async throws -> Response {
        let access = request.access
        try access.require(.view, objectType)
        let query = request.query
        let body = try await read { db -> JSONObject in
            let predicate = QueryFilters.and([access.visibilityPredicate(objectType: objectType, alias: "o")] + extra)
            let table = Record.databaseTableName
            let count = try Int.fetchOne(db, SQLRequest<Int>(literal: "SELECT COUNT(*) FROM \(sql: table) o WHERE \(predicate)")) ?? 0
            let page = try PageRequest.resolve(query, count: count)
            let order = QueryFilters.ordering(query["ordering"], allowed: ordering)?.joined(separator: ", ") ?? defaultOrder
            let records = try Record.fetchAll(db, SQLRequest<Record>(literal: """
                SELECT o.* FROM \(sql: table) o WHERE \(predicate) ORDER BY \(sql: order), o.id LIMIT \(page.size) OFFSET \(page.offset)
                """))
            let grants = try GrantTable.load(objectType: objectType, ids: records.compactMap(\.id), in: db)
            let all = request.version < 10
                ? try Int.fetchAll(db, SQLRequest<Int>(literal: "SELECT o.id FROM \(sql: table) o WHERE \(predicate) ORDER BY \(sql: order), o.id")) : nil
            return self.paginated(request, page: page, count: count, results: try serialize(records, grants, db), allIds: all)
        }
        return .json(.object(body))
    }

    /// A visible owned object, or 404.
    func loadOwned<Record: IdentifiedRecord>(_ type: Record.Type, id: Int, objectType: String, ownerId: (Record) -> Int?,
                                            access: AccessContext, in db: Database) throws -> Record {
        guard let record = try Record.fetchOne(db, key: id),
              try access.can(.view, objectType: objectType, objectId: id, ownerId: ownerId(record), in: db) else {
            throw APIError.notFound()
        }
        return record
    }

    static let obfuscated = "**********"

    // MARK: - Mail accounts

    func mailAccountJSON(_ account: MailAccount, grants: GrantTable, context: SerializeContext) -> JSON {
        let id = account.id ?? 0
        var json = JSONObject()
        json["id"] = .int(id)
        json["name"] = .string(account.name)
        json["imap_server"] = .string(account.config.imapServer)
        json["imap_port"] = JSON(account.config.imapPort)
        json["imap_security"] = .int(account.config.imapSecurity.rawValue)
        json["username"] = .string(account.config.username)
        json["password"] = .string(String(repeating: "*", count: max(10, account.config.password.count)))
        json["character_set"] = .string(account.config.characterSet)
        json["is_token"] = .bool(account.config.isToken)
        grants.addOwnedFields(to: &json, id: id, ownerId: account.ownerId, context: context)
        json["account_type"] = .int(account.config.accountType.rawValue)
        json["expiration"] = datetime(account.config.expiration)
        return .object(json)
    }

    func listMailAccounts(_ request: APIRequest) async throws -> Response {
        let context = SerializeContext(request)
        return try await listOwned(MailAccount.self, objectType: MailAccount.objectType, request: request, defaultOrder: "o.id",
                                   ordering: ["id": "o.id", "name": "o.name COLLATE NOCASE"]) { accounts, grants, _ in
            accounts.map { self.mailAccountJSON($0, grants: grants, context: context) }
        }
    }

    func getMailAccount(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, MailAccount.objectType)
        let id = try request.intParam("id")
        let context = SerializeContext(request)
        let json = try await read { db -> JSON in
            let account = try self.loadOwned(MailAccount.self, id: id, objectType: MailAccount.objectType, ownerId: \.ownerId, access: access, in: db)
            return self.mailAccountJSON(account, grants: try GrantTable.load(objectType: MailAccount.objectType, ids: [id], in: db), context: context)
        }
        return .json(json)
    }

    /// Applies the writable fields; `isCreate` makes required fields required.
    func applyMailAccountFields(_ account: inout MailAccount, data: RequestData, isCreate: Bool) throws {
        var errors = JSONObject()
        func capture(_ block: () throws -> Void) {
            do { try block() } catch let error as APIError {
                if case .json(.object(let object)) = error.body { for (key, value) in object { errors[key] = value } }
            } catch {}
        }
        capture { if isCreate || data.has("name") { account.name = try data.requiredString("name", maxLength: 256) } }
        capture { if isCreate || data.has("imap_server") { account.config.imapServer = try data.requiredString("imap_server", maxLength: 256) } }
        capture {
            if isCreate || data.has("imap_port") {
                guard let port = try data.optionalInt("imap_port") else { throw APIError.field("imap_port", data.has("imap_port") ? "This field may not be null." : APIError.requiredField) }
                guard (0...65535).contains(port) else { throw APIError.field("imap_port", "Ensure this value is less than or equal to 65535.") }
                account.config.imapPort = port
            }
        }
        capture {
            if let raw = data["imap_security"] {
                guard let value = raw.int, let security = IMAPClient.Security(rawValue: value) else {
                    throw APIError.field("imap_security", "\"\(raw.string ?? "")\" is not a valid choice.")
                }
                account.config.imapSecurity = security
            }
        }
        capture { if isCreate || data.has("username") { account.config.username = try data.requiredString("username", maxLength: 256) } }
        capture {
            if isCreate || data.has("password") {
                let password = try data.requiredString("password")
                if !password.replacingOccurrences(of: "*", with: "").isEmpty || isCreate { account.config.password = password }
            }
        }
        capture { if let charset = data["character_set"]?.string, !charset.isEmpty { account.config.characterSet = charset } }
        capture { if let token = try data.optionalBool("is_token") { account.config.isToken = token } }
        capture {
            if let raw = data["account_type"] {
                guard let value = raw.int, let type = MailAccount.AccountType(rawValue: value) else {
                    throw APIError.field("account_type", "\"\(raw.string ?? "")\" is not a valid choice.")
                }
                account.config.accountType = type
            }
        }
        capture {
            if let raw = data["expiration"] {
                if raw.isNull { account.config.expiration = nil } else {
                    guard let text = raw.string, let date = QueryFilters.parseDateTime(text, timeZone: settings.timeZone) else {
                        throw APIError.field("expiration", "Datetime has wrong format. Use one of these formats instead: YYYY-MM-DDThh:mm[:ss[.uuuuuu]][+HH:MM|-HH:MM|Z].")
                    }
                    account.config.expiration = date
                }
            }
        }
        if !errors.isEmpty { throw APIError.validation(.object(errors)) }
    }

    func createMailAccount(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.add, MailAccount.objectType)
        let data = try request.data()
        let context = SerializeContext(request)
        var account = MailAccount(name: "", config: .init())
        try applyMailAccountFields(&account, data: data, isCreate: true)
        let prepared = account
        let json = try await write { db -> JSON in
            var account = prepared
            if try MailAccount.filter(Column("name") == account.name).fetchCount(db) > 0 {
                throw APIError.field("name", "mail account with this name already exists.")
            }
            account.ownerId = data.has("owner") ? try data.foreignKey("owner", table: "users", in: db) ?? nil : access.user.id
            let spec = try PermissionSpec.parse(data["set_permissions"], in: db)
            try account.insert(db)
            try spec?.apply(objectType: MailAccount.objectType, objectIds: [account.id!], merge: false, in: db)
            return self.mailAccountJSON(account, grants: try GrantTable.load(objectType: MailAccount.objectType, ids: [account.id!], in: db), context: context)
        }
        return .json(json, status: .created)
    }

    func updateMailAccount(_ request: APIRequest, partial: Bool) async throws -> Response {
        let access = request.access
        try access.require(.change, MailAccount.objectType)
        let id = try request.intParam("id")
        let data = try request.data()
        let context = SerializeContext(request)
        let json = try await write { db -> JSON in
            var account = try self.loadOwned(MailAccount.self, id: id, objectType: MailAccount.objectType, ownerId: \.ownerId, access: access, in: db)
            guard try access.can(.change, objectType: MailAccount.objectType, objectId: id, ownerId: account.ownerId, in: db) else {
                throw APIError.permissionDenied
            }
            let before = account
            try self.applyMailAccountFields(&account, data: data, isCreate: !partial)
            if try MailAccount.filter(Column("name") == account.name && Column("id") != id).fetchCount(db) > 0 {
                throw APIError.field("name", "mail account with this name already exists.")
            }
            try self.applyOwnership(&account.ownerId, before: before.ownerId, objectType: MailAccount.objectType, id: id, data: data, access: access, in: db)
            try account.update(db)
            return self.mailAccountJSON(account, grants: try GrantTable.load(objectType: MailAccount.objectType, ids: [id], in: db), context: context)
        }
        return .json(json)
    }

    /// `owner` and `set_permissions` on update: only the owner (or a superuser) may change them.
    func applyOwnership(_ ownerId: inout Int?, before: Int?, objectType: String, id: Int, data: RequestData,
                        access: AccessContext, in db: Database) throws {
        let newOwner: Int?? = data.has("owner") ? try data.foreignKey("owner", table: "users", in: db) : .none
        let spec = try PermissionSpec.parse(data["set_permissions"], in: db)
        if (newOwner != nil && newOwner! != before) || spec != nil {
            guard access.isOwner(ownerId: before) else { throw APIError.insufficientPermissions }
        }
        if case .some(let owner) = newOwner { ownerId = owner }
        try spec?.apply(objectType: objectType, objectIds: [id], merge: false, in: db)
    }

    func deleteMailAccount(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.delete, MailAccount.objectType)
        let id = try request.intParam("id")
        try await write { db in
            let account = try self.loadOwned(MailAccount.self, id: id, objectType: MailAccount.objectType, ownerId: \.ownerId, access: access, in: db)
            guard access.isOwner(ownerId: account.ownerId) else { throw APIError.permissionDenied }
            _ = try MailAccount.deleteOne(db, key: id)
            try PermissionSet.removeAll(objectType: MailAccount.objectType, objectId: id, in: db)
        }
        return .noContent()
    }

    /// `POST /api/mail_accounts/test/`: connect and log in with the posted settings.
    func testMailAccount(_ request: APIRequest) async throws -> Response {
        let access = request.access
        let data = try request.data()
        var account = MailAccount(name: "test", config: .init())
        try applyMailAccountFields(&account, data: data.with("name", .string(ISO8601DateFormatter().string(from: Date()))), isCreate: true)
        let existingId = try data.optionalInt("id")
        var existing: MailAccount?
        if let existingId {
            existing = try await read { db -> MailAccount? in
                guard let found = try MailAccount.fetchOne(db, key: existingId),
                      access.has(.change, MailAccount.objectType),
                      try access.can(.change, objectType: MailAccount.objectType, objectId: existingId, ownerId: found.ownerId, in: db) else { return nil }
                return found
            }
            guard let existing else { throw APIError.forbiddenText() }
            if account.config.password.replacingOccurrences(of: "*", with: "").isEmpty {
                account.config.password = existing.config.password
                account.config.accountType = existing.config.accountType
                account.config.refreshToken = existing.config.refreshToken
                account.config.expiration = existing.config.expiration
            }
        } else if !access.has(.add, MailAccount.objectType) {
            throw APIError.forbiddenText()
        }
        var config = account.config
        // An expired stored token: refresh and save it before logging in, as Paperless-ngx does.
        if let existing, config.needsTokenRefresh() {
            do {
                config.password = try await mailOAuth.refreshAccessToken(of: existing, in: app.database).config.password
            } catch {
                logger.error("Mail account connectivity test failed: Unable to refresh oauth token: \(error)")
                throw APIError.badRequestText("Unable to connect to server")
            }
        }
        do {
            let client = IMAPClient(host: config.imapServer, port: config.effectivePort, security: config.imapSecurity, timeout: 15)
            try await client.connect()
            try await client.login(account: config)
            await client.logout()
        } catch {
            logger.error("Mail account connectivity test failed: \(error)")
            throw APIError.badRequestText("Unable to connect to server")
        }
        return .json(["success": true])
    }

    /// `POST /api/mail_accounts/{id}/process/`: fetch this account's mail in the background.
    func processMailAccount(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, MailAccount.objectType)
        let id = try request.intParam("id")
        let account = try await read { db in
            try self.loadOwned(MailAccount.self, id: id, objectType: MailAccount.objectType, ownerId: \.ownerId, access: access, in: db)
        }
        let app = self.app, queue = self.queue, oauth = self.mailOAuth
        _ = try await queue.enqueue(type: .mailFetch, source: .manual, input: ["account": account.name], ownerId: access.user.id) { _ in
            let summary = await MailProcessor(app: app, queue: queue, parse: MailProcessor.mimeParser, oauth: oauth).process(account: account)
            return TaskOutcome(message: "\(summary.messages) messages checked, \(summary.documents) documents queued"
                + (summary.errors.isEmpty ? "" : "; errors: " + summary.errors.joined(separator: "; ")))
        }
        return .json(["result": "OK"])
    }

    // MARK: - Mail rules

    func mailRuleJSON(_ rule: MailRule, grants: GrantTable, context: SerializeContext) -> JSON {
        let id = rule.id ?? 0
        let c = rule.config
        var json = JSONObject()
        json["id"] = .int(id)
        json["name"] = .string(rule.name)
        json["account"] = .int(rule.accountId)
        json["enabled"] = .bool(rule.enabled)
        json["folder"] = .string(c.folder)
        json["filter_from"] = JSON(c.filterFrom)
        json["filter_to"] = JSON(c.filterTo)
        json["filter_subject"] = JSON(c.filterSubject)
        json["filter_body"] = JSON(c.filterBody)
        json["filter_attachment_filename_include"] = JSON(c.filterAttachmentFilenameInclude)
        json["filter_attachment_filename_exclude"] = JSON(c.filterAttachmentFilenameExclude)
        json["maximum_age"] = .int(c.maximumAge)
        json["action"] = .int(c.action.rawValue)
        json["action_parameter"] = JSON(c.actionParameter)
        json["assign_title_from"] = .int(c.assignTitleFrom.rawValue)
        json["assign_tags"] = JSON(c.assignTags)
        json["assign_correspondent_from"] = .int(c.assignCorrespondentFrom.rawValue)
        json["assign_correspondent"] = JSON(c.assignCorrespondent)
        json["assign_document_type"] = JSON(c.assignDocumentType)
        json["assign_owner_from_rule"] = .bool(c.assignOwnerFromRule)
        json["order"] = .int(rule.order)
        json["attachment_type"] = .int(c.attachmentType.rawValue)
        json["consumption_scope"] = .int(c.consumptionScope.rawValue)
        json["pdf_layout"] = .int(c.pdfLayout)
        grants.addOwnedFields(to: &json, id: id, ownerId: rule.ownerId, context: context)
        json["stop_processing"] = .bool(c.stopProcessing)
        return .object(json)
    }

    func listMailRules(_ request: APIRequest) async throws -> Response {
        let context = SerializeContext(request)
        return try await listOwned(MailRule.self, objectType: MailRule.objectType, request: request, defaultOrder: "o.\"order\"",
                                   ordering: ["order": "o.\"order\"", "name": "o.name COLLATE NOCASE", "id": "o.id"]) { rules, grants, _ in
            rules.map { self.mailRuleJSON($0, grants: grants, context: context) }
        }
    }

    func getMailRule(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, MailRule.objectType)
        let id = try request.intParam("id")
        let context = SerializeContext(request)
        let json = try await read { db -> JSON in
            let rule = try self.loadOwned(MailRule.self, id: id, objectType: MailRule.objectType, ownerId: \.ownerId, access: access, in: db)
            return self.mailRuleJSON(rule, grants: try GrantTable.load(objectType: MailRule.objectType, ids: [id], in: db), context: context)
        }
        return .json(json)
    }

    func applyMailRuleFields(_ rule: inout MailRule, data: RequestData, isCreate: Bool, access: AccessContext, in db: Database) throws {
        var errors = JSONObject()
        func capture(_ block: () throws -> Void) throws {
            do { try block() } catch let error as APIError where error.status == .badRequest {
                if case .json(.object(let object)) = error.body { for (key, value) in object { errors[key] = value } }
            }
        }
        func choice<E: RawRepresentable>(_ key: String, _ type: E.Type) throws -> E? where E.RawValue == Int {
            guard let raw = data[key], !raw.isNull else { return nil }
            guard let value = raw.int, let parsed = E(rawValue: value) else {
                throw APIError.field(key, "\"\(raw.string ?? "")\" is not a valid choice.")
            }
            return parsed
        }
        func optionalText(_ key: String) -> String?? {
            guard let raw = data[key] else { return .none }
            if raw.isNull { return .some(nil) }
            return .some(raw.string)
        }
        try capture { if isCreate || data.has("name") { rule.name = try data.requiredString("name", maxLength: 256) } }
        try capture {
            if isCreate || data.has("account") {
                guard let raw = data["account"], !raw.isNull else { throw APIError.field("account", APIError.requiredField) }
                guard let accountId = raw.int, let account = try MailAccount.fetchOne(db, key: accountId),
                      try access.can(.view, objectType: MailAccount.objectType, objectId: accountId, ownerId: account.ownerId, in: db) else {
                    throw APIError.field("account", APIError.invalidPK(raw.string ?? ""))
                }
                guard try access.can(.change, objectType: MailAccount.objectType, objectId: accountId, ownerId: account.ownerId, in: db) else {
                    throw APIError.insufficientPermissions
                }
                rule.accountId = accountId
            }
        }
        if let enabled = try data.optionalBool("enabled") { rule.enabled = enabled }
        if let folder = data["folder"]?.string, !folder.isEmpty { rule.config.folder = folder }
        if case .some(let value) = optionalText("filter_from") { rule.config.filterFrom = value }
        if case .some(let value) = optionalText("filter_to") { rule.config.filterTo = value }
        if case .some(let value) = optionalText("filter_subject") { rule.config.filterSubject = value }
        if case .some(let value) = optionalText("filter_body") { rule.config.filterBody = value }
        if case .some(let value) = optionalText("filter_attachment_filename_include") { rule.config.filterAttachmentFilenameInclude = value }
        if case .some(let value) = optionalText("filter_attachment_filename_exclude") { rule.config.filterAttachmentFilenameExclude = value }
        try capture {
            if let age = try data.optionalInt("maximum_age") {
                guard age <= 36_500 else { throw APIError.field("maximum_age", "Maximum mail age is unreasonably large.") }
                rule.config.maximumAge = age
            }
        }
        try capture { if let value = try choice("action", MailRule.Action.self) { rule.config.action = value } }
        if case .some(let value) = optionalText("action_parameter") { rule.config.actionParameter = value }
        try capture { if let value = try choice("assign_title_from", MailRule.TitleSource.self) { rule.config.assignTitleFrom = value } }
        try capture {
            if let tags = try data.idList("assign_tags") {
                for tag in tags where try Tag.fetchOne(db, key: tag) == nil { throw APIError.field("assign_tags", APIError.invalidPK(String(tag))) }
                rule.config.assignTags = tags
            }
        }
        try capture { if let value = try choice("assign_correspondent_from", MailRule.CorrespondentSource.self) { rule.config.assignCorrespondentFrom = value } }
        try capture { if case .some(let value) = try data.foreignKey("assign_correspondent", table: "correspondents", in: db) { rule.config.assignCorrespondent = value } }
        try capture { if case .some(let value) = try data.foreignKey("assign_document_type", table: "document_types", in: db) { rule.config.assignDocumentType = value } }
        if let flag = try data.optionalBool("assign_owner_from_rule") { rule.config.assignOwnerFromRule = flag }
        try capture { if let order = try data.optionalInt("order") { rule.order = order } }
        try capture { if let value = try choice("attachment_type", MailRule.AttachmentProcessing.self) { rule.config.attachmentType = value } }
        try capture { if let value = try choice("consumption_scope", MailRule.ConsumptionScope.self) { rule.config.consumptionScope = value } }
        try capture { if let layout = try data.optionalInt("pdf_layout") { rule.config.pdfLayout = layout } }
        if let stop = try data.optionalBool("stop_processing") { rule.config.stopProcessing = stop }
        if !errors.isEmpty { throw APIError.validation(.object(errors)) }
        if [.tag, .move].contains(rule.config.action), (rule.config.actionParameter ?? "").isEmpty {
            throw APIError.nonField("An action parameter is required.")
        }
    }

    private func checkMailRuleName(_ rule: MailRule, in db: Database) throws {
        let ownerClause: SQL = rule.ownerId.map { "owner_id = \($0)" } ?? "owner_id IS NULL"
        let exists = try Int.fetchOne(db, SQLRequest<Int>(literal: """
            SELECT COUNT(*) FROM mail_rules WHERE name = \(rule.name) AND \(ownerClause) AND id IS NOT \(rule.id)
            """)) ?? 0
        if exists > 0 { throw APIError.nonField("The fields name, owner must make a unique set.") }
    }

    func createMailRule(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.add, MailRule.objectType)
        let data = try request.data()
        let context = SerializeContext(request)
        let json = try await write { db -> JSON in
            var rule = MailRule(name: "", accountId: 0)
            try self.applyMailRuleFields(&rule, data: data, isCreate: true, access: access, in: db)
            rule.ownerId = data.has("owner") ? try data.foreignKey("owner", table: "users", in: db) ?? nil : access.user.id
            let spec = try PermissionSpec.parse(data["set_permissions"], in: db)
            try self.checkMailRuleName(rule, in: db)
            try rule.insert(db)
            try spec?.apply(objectType: MailRule.objectType, objectIds: [rule.id!], merge: false, in: db)
            return self.mailRuleJSON(rule, grants: try GrantTable.load(objectType: MailRule.objectType, ids: [rule.id!], in: db), context: context)
        }
        return .json(json, status: .created)
    }

    func updateMailRule(_ request: APIRequest, partial: Bool) async throws -> Response {
        let access = request.access
        try access.require(.change, MailRule.objectType)
        let id = try request.intParam("id")
        let data = try request.data()
        let context = SerializeContext(request)
        let json = try await write { db -> JSON in
            var rule = try self.loadOwned(MailRule.self, id: id, objectType: MailRule.objectType, ownerId: \.ownerId, access: access, in: db)
            guard try access.can(.change, objectType: MailRule.objectType, objectId: id, ownerId: rule.ownerId, in: db) else {
                throw APIError.permissionDenied
            }
            let before = rule
            try self.applyMailRuleFields(&rule, data: data, isCreate: !partial, access: access, in: db)
            try self.applyOwnership(&rule.ownerId, before: before.ownerId, objectType: MailRule.objectType, id: id, data: data, access: access, in: db)
            try self.checkMailRuleName(rule, in: db)
            try rule.update(db)
            return self.mailRuleJSON(rule, grants: try GrantTable.load(objectType: MailRule.objectType, ids: [id], in: db), context: context)
        }
        return .json(json)
    }

    func deleteMailRule(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.delete, MailRule.objectType)
        let id = try request.intParam("id")
        try await write { db in
            let rule = try self.loadOwned(MailRule.self, id: id, objectType: MailRule.objectType, ownerId: \.ownerId, access: access, in: db)
            guard access.isOwner(ownerId: rule.ownerId) else { throw APIError.permissionDenied }
            _ = try MailRule.deleteOne(db, key: id)
            try PermissionSet.removeAll(objectType: MailRule.objectType, objectId: id, in: db)
        }
        return .noContent()
    }

    // MARK: - Processed mail

    func processedMailJSON(_ mail: ProcessedMail) -> JSON {
        .object(JSONObject([
            ("id", JSON(mail.id)), ("owner", JSON(mail.ownerId)), ("rule", .int(mail.ruleId)), ("folder", .string(mail.folder)),
            ("uid", .string(mail.uid)), ("subject", .string(mail.subject)), ("received", datetime(mail.received)),
            ("processed", datetime(mail.processed)), ("status", .string(mail.status)), ("error", JSON(mail.error)),
        ]))
    }

    func listProcessedMail(_ request: APIRequest) async throws -> Response {
        var extra: [SQL] = []
        if let raw = request.query["rule"], !raw.isEmpty {
            guard let rule = Int(raw) else { throw APIError.field("rule", "Select a valid choice. That choice is not one of the available choices.") }
            extra.append("o.rule_id = \(rule)")
        }
        if let status = request.query["status"], !status.isEmpty { extra.append("o.status = \(status)") }
        return try await listOwned(ProcessedMail.self, objectType: "processedmail", request: request, extra: extra, defaultOrder: "o.processed DESC",
                                   ordering: ["processed": "o.processed", "received": "o.received", "status": "o.status", "subject": "o.subject", "id": "o.id"]) { mails, _, _ in
            mails.map(self.processedMailJSON)
        }
    }

    func getProcessedMail(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, "processedmail")
        let id = try request.intParam("id")
        let mail = try await read { db in
            try self.loadOwned(ProcessedMail.self, id: id, objectType: "processedmail", ownerId: \.ownerId, access: access, in: db)
        }
        return .json(processedMailJSON(mail))
    }

    func bulkDeleteProcessedMail(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.delete, "processedmail")
        let data = try request.data()
        let value = data["mail_ids"] ?? []
        guard let items = value.array, items.allSatisfy({ $0.strictInt != nil }) else {
            throw APIError.badRequestText("mail_ids must be a list of integers")
        }
        let ids = items.compactMap(\.strictInt)
        try await write { db in
            let mails = try ProcessedMail.fetchAll(db, keys: ids)
            guard mails.allSatisfy({ access.isOwner(ownerId: $0.ownerId) }) else { throw APIError.forbiddenText() }
            _ = try ProcessedMail.deleteAll(db, keys: ids)
        }
        return .json(["result": "OK", "deleted_mail_ids": JSON(ids)])
    }
}

extension RequestData {
    /// A copy with one field replaced.
    func with(_ key: String, _ value: JSON) -> RequestData {
        var object = json.object ?? JSONObject()
        object[key] = value
        var copy = self
        copy.json = .object(object)
        return copy
    }
}
