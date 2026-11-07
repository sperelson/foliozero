import Foundation
import FolioCore
import GRDB
import Hummingbird

/// `/api/share_link_bundles/` (Paperless-ngx `ShareLinkBundleViewSet`) and the bundle
/// half of the public `/share/<slug>` view.
extension API {
    // MARK: - Serialisation

    /// `ShareLinkBundleSerializer` output.
    func shareLinkBundleJSON(_ bundle: ShareLinkBundle, documents: [Int], documentCount: Int) -> JSON {
        .object(JSONObject([
            ("id", JSON(bundle.id)), ("created", datetime(bundle.created)), ("expiration", datetime(bundle.expiration)),
            ("slug", .string(bundle.slug)), ("file_version", .string(bundle.fileVersion.rawValue)),
            ("status", .string(bundle.status.rawValue)), ("size_bytes", JSON(bundle.sizeBytes)),
            ("last_error", Self.lastErrorJSON(bundle.lastError)), ("built_at", datetime(bundle.builtAt)),
            ("documents", JSON(documents)), ("document_count", .int(documentCount)),
        ]))
    }

    /// `last_error` with the keys in the order the Paperless-ngx build task writes them.
    static func lastErrorJSON(_ error: [String: JSONValue]?) -> JSON {
        guard let error else { return .null }
        let known = ["bundle_id", "exception_type", "message", "timestamp"]
        var object = JSONObject()
        for key in known + error.keys.filter({ !known.contains($0) }).sorted() {
            if let value = error[key] { object[key] = JSON(value) }
        }
        return .object(object)
    }

    /// Serialises bundles with their documents (newest first, trashed ones left out, like the
    /// related manager) and the number of linked documents (a count of the links, like the annotation).
    func shareLinkBundlesJSON(_ bundles: [ShareLinkBundle], in db: Database) throws -> [JSON] {
        let ids = bundles.compactMap(\.id)
        var documents: [Int: [Int]] = [:]
        var counts: [Int: Int] = [:]
        if !ids.isEmpty {
            let rows = try Row.fetchAll(db, SQLRequest<Row>(literal: """
                SELECT b.bundle_id, d.id AS document_id, d.deleted_at FROM \(sql: ShareLinkBundle.documentsTable) b
                JOIN documents d ON d.id = b.document_id
                WHERE b.bundle_id IN \(ids) ORDER BY d.created DESC, d.id DESC
                """))
            for row in rows {
                let bundleId: Int = row["bundle_id"]
                counts[bundleId, default: 0] += 1
                if row["deleted_at"] == nil as String? { documents[bundleId, default: []].append(row["document_id"]) }
            }
        }
        return bundles.map { bundle in
            shareLinkBundleJSON(bundle, documents: documents[bundle.id ?? 0] ?? [], documentCount: counts[bundle.id ?? 0] ?? 0)
        }
    }

    // MARK: - Endpoints

    func listShareLinkBundles(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, ShareLinkBundle.objectType)
        let query = request.query
        let timeZone = settings.timeZone
        let body = try await read { db -> JSONObject in
            var conditions = [access.visibilityPredicate(objectType: ShareLinkBundle.objectType, alias: "o")]
            for (name, value) in query.items where !value.isEmpty {
                for field in ["created", "expiration"] where name.hasPrefix(field + "__") {
                    if let condition = try Self.dateTimeCondition(name, column: "o.\(field)", lookup: String(name.dropFirst(field.count + 2)),
                                                                   value: value, timeZone: timeZone) {
                        conditions.append(condition)
                    }
                }
            }
            if let status = query["status"], !status.isEmpty {
                guard ShareLinkBundle.Status(rawValue: status) != nil else {
                    throw APIError.field("status", "Select a valid choice. \(status) is not one of the available choices.")
                }
                conditions.append("o.status = \(status)")
            }
            if let documents = query["documents"], !documents.isEmpty {
                // Paperless-ngx `filter_documents`: a bad id matches nothing; no ids matches everything.
                if let ids = QueryFilters.intList(documents) {
                    if !ids.isEmpty {
                        conditions.append("""
                            EXISTS (SELECT 1 FROM \(sql: ShareLinkBundle.documentsTable) sb WHERE sb.bundle_id = o.id AND sb.document_id IN \(ids))
                            """)
                    }
                } else {
                    conditions.append("0")
                }
            }
            let predicate = QueryFilters.and(conditions)
            let from: SQL = "\(sql: ShareLinkBundle.databaseTableName) o"
            let count = try Int.fetchOne(db, SQLRequest<Int>(literal: "SELECT COUNT(*) FROM \(from) WHERE \(predicate)")) ?? 0
            let page = try PageRequest.resolve(query, count: count)
            let order = QueryFilters.ordering(query["ordering"], allowed: [
                "created": "o.created", "expiration": "o.expiration", "status": "o.status",
            ]).map { $0.joined(separator: ", ") + ", o.id" } ?? "o.created DESC, o.id DESC"
            let bundles = try ShareLinkBundle.fetchAll(db, SQLRequest<ShareLinkBundle>(literal: """
                SELECT o.* FROM \(from) WHERE \(predicate) ORDER BY \(sql: order) LIMIT \(page.size) OFFSET \(page.offset)
                """))
            let all = request.version < 10
                ? try Int.fetchAll(db, SQLRequest<Int>(literal: "SELECT o.id FROM \(from) WHERE \(predicate) ORDER BY \(sql: order)")) : nil
            return self.paginated(request, page: page, count: count, results: try self.shareLinkBundlesJSON(bundles, in: db), allIds: all)
        }
        return .json(.object(body))
    }

    /// django-filter `DATETIME_KWARGS` lookups (`gt`, `gte`, `lt`, `lte`, `date__*`) on a datetime column.
    static func dateTimeCondition(_ name: String, column: String, lookup: String, value: String, timeZone: TimeZone) throws -> SQL? {
        let operators = ["gt": ">", "gte": ">=", "lt": "<", "lte": "<=", "date__gt": ">=", "date__gte": ">=", "date__lt": "<", "date__lte": "<"]
        guard let op = operators[lookup] else { return nil }
        guard let date = QueryFilters.parseDateTime(value, timeZone: timeZone) else {
            throw APIError.field(name, "Enter a valid date/time.")
        }
        var bound = date
        if lookup == "date__gt" || lookup == "date__lte" { bound = CalendarDate(date, in: timeZone).adding(days: 1).startDate(in: timeZone) }
        return "\(sql: column) \(sql: op) \(QueryFilters.timestamp(bound))"
    }

    private func loadShareLinkBundle(_ id: Int, access: AccessContext, in db: Database) throws -> ShareLinkBundle {
        guard let bundle = try ShareLinkBundle.fetchOne(db, key: id),
              try access.can(.view, objectType: ShareLinkBundle.objectType, objectId: id, ownerId: bundle.ownerId, in: db) else {
            throw APIError.notFound("ShareLinkBundle")
        }
        return bundle
    }

    func getShareLinkBundle(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.view, ShareLinkBundle.objectType)
        let id = try request.intParam("id")
        let json = try await read { db in
            try self.shareLinkBundlesJSON([try self.loadShareLinkBundle(id, access: access, in: db)], in: db)[0]
        }
        return .json(json)
    }

    func createShareLinkBundle(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.add, ShareLinkBundle.objectType)
        try access.require(.view, Document.objectType)
        let data = try request.data()
        var errors = JSONObject()

        var expirationDays: Int?
        if let value = data["expiration_days"], !value.isNull, !(data.isForm && value.string == "") {
            if let days = value.int {
                if days < 1 { errors["expiration_days"] = ["Ensure this value is greater than or equal to 1."] } else { expirationDays = days }
            } else {
                errors["expiration_days"] = ["A valid integer is required."]
            }
        }

        var version = ShareLink.FileVersion.archive
        if let value = data["file_version"] {
            if value.isNull {
                errors["file_version"] = ["This field may not be null."]
            } else if let parsed = value.string.flatMap(ShareLink.FileVersion.init(rawValue:)) {
                version = parsed
            } else {
                errors["file_version"] = [.string("\"\(value.string ?? value.serialized())\" is not a valid choice.")]
            }
        }

        var documentIds: [Int] = []
        if let value = data["document_ids"] {
            if value.isNull {
                errors["document_ids"] = ["This field may not be null."]
            } else if !data.isForm && value.array == nil {
                errors["document_ids"] = [.string("Expected a list of items but got type \"\(value.typeName)\".")]
            } else {
                let items = data.list("document_ids") ?? []
                var itemErrors = JSONObject()
                for (index, item) in items.enumerated() {
                    guard let id = item.int else { itemErrors[String(index)] = ["A valid integer is required."]; continue }
                    if id < 1 { itemErrors[String(index)] = ["Ensure this value is greater than or equal to 1."] } else { documentIds.append(id) }
                }
                if items.isEmpty {
                    errors["document_ids"] = ["This list may not be empty."]
                } else if !itemErrors.isEmpty {
                    errors["document_ids"] = .object(itemErrors)
                } else if Set(documentIds).count != documentIds.count {
                    errors["document_ids"] = ["Duplicate document identifiers are not allowed."]
                }
            }
        } else {
            errors["document_ids"] = [.string(APIError.requiredField)]
        }
        if !errors.isEmpty { throw APIError.validation(.object(errors)) }

        let ids = documentIds, fileVersion = version
        let expiration = expirationDays.map { Date().addingTimeInterval(Double($0) * 86_400) }
        let json = try await write { db -> JSON in
            let found = Set(try Int.fetchAll(db, SQLRequest<Int>(literal: "SELECT id FROM documents WHERE id IN \(ids) AND deleted_at IS NULL")))
            let missing = Set(ids).subtracting(found).sorted()
            if !missing.isEmpty {
                throw APIError.validation(["document_ids": .string("Documents not found: " + missing.map(String.init).joined(separator: ", "))])
            }
            for document in try self.fetchDocuments(ids, in: db).sorted(by: { ($0.id ?? 0) < ($1.id ?? 0) })
            where try !self.canAccess(document, .view, access: access, in: db) {
                throw APIError.validation(["document_ids": .string("Insufficient permissions to share document \(document.id ?? 0).")])
            }
            var bundle = ShareLinkBundle(slug: PasswordHasher.randomString(length: 50), expiration: expiration,
                                         ownerId: access.user.id, fileVersion: fileVersion)
            try bundle.insert(db)
            try ShareLinkBundleStore.setDocuments(ids, bundleId: bundle.id ?? 0, in: db)
            return try self.shareLinkBundlesJSON([bundle], in: db)[0]
        }
        if let id = json["id"]?.int { try await enqueueShareLinkBundleBuild(id) }
        return .json(json, status: .created)
    }

    func rebuildShareLinkBundle(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.add, ShareLinkBundle.objectType)
        let id = try request.intParam("id")
        let (json, previous) = try await write { db -> (JSON, ShareLinkBundle) in
            var bundle = try self.loadShareLinkBundle(id, access: access, in: db)
            guard access.isOwner(ownerId: bundle.ownerId) else { throw APIError.permissionDenied }
            guard bundle.status != .processing else { throw APIError.detail(.badRequest, "Bundle is already being processed.") }
            let previous = bundle
            bundle.resetBuild(status: .pending)
            try bundle.update(db)
            return (try self.shareLinkBundlesJSON([bundle], in: db)[0], previous)
        }
        ShareLinkBundleStore.removeFile(previous, in: settings.shareLinkBundleDir)
        try await enqueueShareLinkBundleBuild(id)
        return .json(json)
    }

    func deleteShareLinkBundle(_ request: APIRequest) async throws -> Response {
        let access = request.access
        try access.require(.delete, ShareLinkBundle.objectType)
        let id = try request.intParam("id")
        let bundle = try await write { db -> ShareLinkBundle in
            let bundle = try self.loadShareLinkBundle(id, access: access, in: db)
            guard access.isOwner(ownerId: bundle.ownerId) else { throw APIError.permissionDenied }
            _ = try ShareLinkBundle.deleteOne(db, key: id)
            return bundle
        }
        ShareLinkBundleStore.removeFile(bundle, in: settings.shareLinkBundleDir)
        return .noContent()
    }

    /// The bundle half of the public `/share/<slug>` view. Called when no share link has the slug.
    func serveShareLinkBundle(slug: String, context: APIRequestContext) async throws -> Response {
        let found = try await read { db in try ShareLinkBundle.filter(Column("slug") == slug).fetchOne(db) }
        guard let bundle = found else { return .redirect("/accounts/login/?sharelink_notfound=1") }
        if let expiration = bundle.expiration, expiration < Date() { return .redirect("/accounts/login/?sharelink_expired=1") }
        if bundle.status == .pending || bundle.status == .processing {
            return .text("The share link bundle is still being prepared. Please try again later.", status: .accepted)
        }
        guard bundle.status != .failed, let url = ShareLinkBundleStore.fileURL(bundle, in: settings.shareLinkBundleDir),
              FileManager.default.fileExists(atPath: url.path) else {
            return .text("The share link bundle is unavailable.", status: .serviceUnavailable)
        }
        return try await fileResponse(url, contentType: "application/zip", disposition: "attachment",
                                      filename: "paperless-share-\(bundle.slug.prefix(12)).zip", context: context)
    }

    // MARK: - Building

    /// Queues `build_share_link_bundle` as a tracked task.
    func enqueueShareLinkBundleBuild(_ bundleId: Int) async throws {
        try await queue.enqueue(type: .buildShareLink, source: .manual) { [self] _ in
            try await self.buildShareLinkBundle(bundleId)
        }
    }

    /// A document file that is not on disk (Python's `FileNotFoundError`, the usual build failure).
    struct FileNotFoundError: Error, CustomStringConvertible {
        var path: String
        var description: String { "[Errno 2] No such file or directory: '\(path)'" }
    }

    /// Paperless-ngx `build_share_link_bundle`: zips the bundle's documents into
    /// `SHARE_LINK_BUNDLE_DIR/<slug>.zip` and records the result on the bundle.
    func buildShareLinkBundle(_ bundleId: Int) async throws -> TaskOutcome {
        let directory = settings.shareLinkBundleDir
        let prepared = try await write { db -> (ShareLinkBundle, ShareLinkBundle, [(Document, String?)])? in
            guard var bundle = try ShareLinkBundle.fetchOne(db, key: bundleId) else { return nil }
            let previous = bundle
            bundle.resetBuild(status: .processing)
            try bundle.update(db)
            let documents = try Document.fetchAll(db, SQLRequest<Document>(literal: """
                SELECT d.* FROM documents d JOIN \(sql: ShareLinkBundle.documentsTable) b ON b.document_id = d.id
                WHERE b.bundle_id = \(bundleId) AND d.deleted_at IS NULL ORDER BY d.id
                """))
            let entries = try documents.map { document in
                (document, try document.correspondentId.flatMap { try Correspondent.fetchOne(db, key: $0)?.name })
            }
            return (bundle, previous, entries)
        }
        guard let (bundle, previous, entries) = prepared else {
            logger.warning("Share link bundle \(bundleId) no longer exists.")
            return TaskOutcome(message: "Share link bundle \(bundleId) no longer exists")
        }
        ShareLinkBundleStore.removeFile(previous, in: directory)

        let fm = FileManager.default
        let temporary = settings.scratchDir.appendingPathComponent("share-link-bundle-\(UUID().uuidString).zip")
        defer { try? fm.removeItem(at: temporary) }
        do {
            let useArchive = bundle.fileVersion == .archive
            for (document, _) in entries {
                let file = useArchive && document.hasArchiveVersion ? app.storage.archiveURL(document) : app.storage.originalURL(document)
                guard let file, fm.fileExists(atPath: file.path) else {
                    throw FileNotFoundError(path: file?.path ?? app.storage.originalsDir.path)
                }
            }
            try fm.createDirectory(at: settings.scratchDir, withIntermediateDirectories: true)
            try BulkArchive.write(entries: entries, to: temporary, content: useArchive ? "archive" : "originals", deflate: true,
                                  followFormatting: false, storage: app.storage, api: self)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let relative = "\(bundle.slug).zip"
            let final = directory.appendingPathComponent(relative)
            if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
            try fm.moveItem(at: temporary, to: final)
            let size = ((try? fm.attributesOfItem(atPath: final.path))?[.size] as? NSNumber)?.intValue
            let stillExists = try await write { db -> Bool in
                guard var current = try ShareLinkBundle.fetchOne(db, key: bundleId) else { return false }
                current.filePath = relative
                current.sizeBytes = size
                current.status = .ready
                current.builtAt = Date()
                current.lastError = nil
                try current.update(db)
                return true
            }
            guard stillExists else {
                // Deleted while it was being built: drop the zip instead of leaving an orphan.
                try? fm.removeItem(at: final)
                return TaskOutcome(message: "Share link bundle \(bundleId) no longer exists")
            }
            logger.info("Built share link bundle \(bundleId)")
            return TaskOutcome(message: "Built share link bundle \(bundleId)")
        } catch {
            logger.error("Failed to build share link bundle \(bundleId): \(error)")
            let failure = ShareLinkBundleStore.failure(bundleId: bundleId, type: String(describing: type(of: error)), message: "\(error)")
            try? await write { db in
                guard var current = try ShareLinkBundle.fetchOne(db, key: bundleId) else { return }
                current.status = .failed
                current.lastError = failure
                try current.update(db)
            }
            throw error
        }
    }
}
