import Foundation
import GRDB

/// A public link to a zip of several documents (Paperless-ngx `ShareLinkBundle`).
/// The zip is built in the background and kept under `SHARE_LINK_BUNDLE_DIR`.
public struct ShareLinkBundle: IdentifiedRecord, Hashable {
    public static let databaseTableName = "share_link_bundles"
    public static let objectType = "sharelinkbundle"
    /// The join table that links bundles to documents.
    public static let documentsTable = "share_link_bundle_documents"

    public enum Status: String, Codable, Sendable, DatabaseValueConvertible, CaseIterable {
        case pending, processing, ready, failed
    }

    public var id: Int?
    public var slug: String
    public var created: Date
    public var expiration: Date?
    public var ownerId: Int?
    public var fileVersion: ShareLink.FileVersion
    public var status: Status
    public var sizeBytes: Int?
    /// `bundle_id`, `exception_type`, `message` and `timestamp` of the last failed build.
    public var lastError: [String: JSONValue]?
    /// The zip, relative to `SHARE_LINK_BUNDLE_DIR`. Empty until a build succeeds.
    public var filePath: String
    public var builtAt: Date?

    public init(id: Int? = nil, slug: String, created: Date = Date(), expiration: Date? = nil, ownerId: Int? = nil,
                fileVersion: ShareLink.FileVersion = .archive, status: Status = .pending, filePath: String = "") {
        self.id = id; self.slug = slug; self.created = created; self.expiration = expiration; self.ownerId = ownerId
        self.fileVersion = fileVersion; self.status = status; self.filePath = filePath
    }

    /// Clears the build result so the bundle can be built again.
    public mutating func resetBuild(status: Status) {
        self.status = status
        lastError = nil
        sizeBytes = nil
        builtAt = nil
        filePath = ""
    }
}

/// Storage and housekeeping of share link bundles.
public enum ShareLinkBundleStore {
    static func createTables(_ db: Database) throws {
        try db.create(table: ShareLinkBundle.databaseTableName) { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("slug", .text).notNull().unique()
            t.column("created", .datetime).notNull().indexed()
            t.column("expiration", .datetime).indexed()
            t.column("owner_id", .integer).indexed().references("users", onDelete: .setNull)
            t.column("file_version", .text).notNull().defaults(to: "archive")
            t.column("status", .text).notNull().defaults(to: "pending")
            t.column("size_bytes", .integer)
            t.column("last_error", .jsonText)
            t.column("file_path", .text).notNull().defaults(to: "")
            t.column("built_at", .datetime)
        }
        try db.create(table: ShareLinkBundle.documentsTable) { t in
            t.column("bundle_id", .integer).notNull().references(ShareLinkBundle.databaseTableName, onDelete: .cascade)
            t.column("document_id", .integer).notNull().indexed().references("documents", onDelete: .cascade)
            t.primaryKey(["bundle_id", "document_id"])
        }
    }

    /// Links `documentIds` to the bundle.
    public static func setDocuments(_ documentIds: [Int], bundleId: Int, in db: Database) throws {
        try db.execute(sql: "DELETE FROM \(ShareLinkBundle.documentsTable) WHERE bundle_id = ?", arguments: [bundleId])
        for documentId in documentIds {
            try db.execute(sql: "INSERT OR IGNORE INTO \(ShareLinkBundle.documentsTable)(bundle_id, document_id) VALUES (?, ?)",
                           arguments: [bundleId, documentId])
        }
    }

    /// The zip of `bundle` under `directory`, or nil when the stored path is empty,
    /// absolute or leaves the directory (Paperless-ngx `absolute_file_path`).
    public static func fileURL(_ bundle: ShareLinkBundle, in directory: URL) -> URL? {
        let relative = bundle.filePath
        let components = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              !components.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else { return nil }
        return directory.appendingPathComponent(relative)
    }

    /// Deletes the zip of `bundle`, if there is one. Errors are ignored.
    public static func removeFile(_ bundle: ShareLinkBundle, in directory: URL) {
        guard let url = fileURL(bundle, in: directory), FileManager.default.fileExists(atPath: url.path) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes bundles whose expiration has passed, with their zips. Returns how many were found.
    @discardableResult
    public static func cleanupExpired(app: FolioApp, now: Date = Date()) async -> Int {
        let directory = app.settings.shareLinkBundleDir
        let expired: [ShareLinkBundle]
        do {
            expired = try await app.database.read { db in
                try ShareLinkBundle
                    .filter(sql: "expiration IS NOT NULL AND expiration < ?", arguments: [FolioDateFormat.database.string(from: now)])
                    .fetchAll(db)
            }
        } catch {
            app.logger.warning("Could not list expired share link bundles: \(error)")
            return 0
        }
        for bundle in expired {
            do {
                removeFile(bundle, in: directory)
                _ = try await app.database.write { db in try ShareLinkBundle.deleteOne(db, key: bundle.id) }
            } catch {
                app.logger.warning("Failed to delete expired share link bundle \(bundle.id ?? 0): \(error)")
            }
        }
        if !expired.isEmpty { app.logger.info("Deleted \(expired.count) expired share link bundle(s)") }
        return expired.count
    }

    /// Marks bundles left `pending` or `processing` by a previous run as failed.
    /// Builds run in memory, so nothing finishes them after a restart. A rebuild retries them.
    public static func recoverInterrupted(app: FolioApp) async {
        do {
            try await app.database.write { db in
                let stale = try ShareLinkBundle.filter([ShareLinkBundle.Status.pending, .processing].contains(Column("status"))).fetchAll(db)
                for var bundle in stale {
                    bundle.status = .failed
                    bundle.lastError = failure(bundleId: bundle.id ?? 0, type: "Interrupted",
                                               message: "FolioZero stopped before the bundle was built")
                    try bundle.update(db)
                }
            }
        } catch {
            app.logger.error("Could not recover interrupted share link bundles: \(error)")
        }
    }

    /// The `last_error` value of a failed build.
    public static func failure(bundleId: Int, type: String, message: String, at date: Date = Date()) -> [String: JSONValue] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ["bundle_id": .int(bundleId), "exception_type": .string(type), "message": .string(message),
                "timestamp": .string(formatter.string(from: date))]
    }
}
