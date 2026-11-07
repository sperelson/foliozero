import Foundation
import GRDB

/// Owns the SQLite connection pool and runs migrations.
public final class FolioDatabase: Sendable {
    public let pool: DatabasePool
    public let url: URL

    /// Open (and migrate) the database at `url`.
    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.busyMode = .timeout(10)
        config.prepareDatabase { db in
            // Durable enough for a document archive, much faster than FULL.
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        pool = try DatabasePool(path: url.path, configuration: config)
        try Schema.migrator().migrate(pool)
    }

    /// Read-only access.
    public func read<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
        try pool.read(block)
    }

    /// Read-write access inside a transaction.
    public func write<T: Sendable>(_ block: @Sendable (Database) throws -> T) throws -> T {
        try pool.write(block)
    }

    public func read<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await pool.read(block)
    }

    public func write<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await pool.write(block)
    }

    /// Value from the `meta` key/value table.
    public func meta(_ key: String) throws -> String? {
        try read { db in
            try String.fetchOne(db, sql: "SELECT value FROM meta WHERE key = ?", arguments: [key])
        }
    }

    public func setMeta(_ key: String, _ value: String) throws {
        try write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", arguments: [key, value])
        }
    }
}

/// Records use snake_case columns and camelCase Swift properties.
public protocol FolioRecord: Codable, FetchableRecord, MutablePersistableRecord, Sendable {}

extension FolioRecord {
    public static var databaseColumnDecodingStrategy: DatabaseColumnDecodingStrategy { .convertFromSnakeCase }
    public static var databaseColumnEncodingStrategy: DatabaseColumnEncodingStrategy { .convertToSnakeCase }
    public static var databaseDateEncodingStrategy: DatabaseDateEncodingStrategy { .formatted(FolioDateFormat.database) }
    public static var databaseDateDecodingStrategy: DatabaseDateDecodingStrategy { .formatted(FolioDateFormat.database) }
}

/// Records with an auto-incremented integer primary key named `id`.
public protocol IdentifiedRecord: FolioRecord {
    var id: Int? { get set }
}

extension IdentifiedRecord {
    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = Int(inserted.rowID)
    }
}

public enum FolioDateFormat {
    /// UTC timestamps with milliseconds, sortable as text.
    public static let database: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f
    }()
}
