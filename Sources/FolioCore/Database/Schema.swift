import Foundation
import GRDB

/// Database schema. Column names follow Paperless-ngx field names so the REST
/// API, the exporter and a future Paperless-ngx importer map one to one.
enum Schema {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1-initial", migrate: createInitialSchema)
        migrator.registerMigration("v3-mfa", migrate: MFAStore.createTable)
        migrator.registerMigration("v2-ai", migrate: AISchema.migrate)
        migrator.registerMigration("v4-share-link-bundles", migrate: ShareLinkBundleStore.createTables)
        migrator.registerMigration("v4-social-accounts", migrate: SocialAccountStore.createTable)
        return migrator
    }

    private static func matchingColumns(_ t: TableDefinition) {
        t.autoIncrementedPrimaryKey("id")
        t.column("name", .text).notNull()
        t.column("match", .text).notNull().defaults(to: "")
        t.column("matching_algorithm", .integer).notNull().defaults(to: 1)
        t.column("is_insensitive", .boolean).notNull().defaults(to: true)
        t.column("owner_id", .integer).references("users", onDelete: .setNull)
    }

    private static func uniqueNamePerOwner(_ db: Database, table: String) throws {
        try db.execute(sql: """
            CREATE UNIQUE INDEX \(table)_name_owner_uniq ON \(table)(name, owner_id) WHERE owner_id IS NOT NULL;
            CREATE UNIQUE INDEX \(table)_name_uniq ON \(table)(name) WHERE owner_id IS NULL;
            """)
    }

    private static func createInitialSchema(_ db: Database) throws {
        // MARK: Users, groups, auth
        try db.create(table: "users") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("username", .text).notNull().unique().collate(.nocase)
            t.column("password", .text).notNull().defaults(to: "")
            t.column("email", .text).notNull().defaults(to: "")
            t.column("first_name", .text).notNull().defaults(to: "")
            t.column("last_name", .text).notNull().defaults(to: "")
            t.column("is_superuser", .boolean).notNull().defaults(to: false)
            t.column("is_staff", .boolean).notNull().defaults(to: false)
            t.column("is_active", .boolean).notNull().defaults(to: true)
            t.column("date_joined", .datetime).notNull()
            t.column("last_login", .datetime)
        }
        try db.create(table: "groups") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique().collate(.nocase)
        }
        try db.create(table: "user_groups") { t in
            t.column("user_id", .integer).notNull().references("users", onDelete: .cascade)
            t.column("group_id", .integer).notNull().references("groups", onDelete: .cascade)
            t.primaryKey(["user_id", "group_id"])
        }
        try db.create(table: "user_permissions") { t in
            t.column("user_id", .integer).notNull().references("users", onDelete: .cascade)
            t.column("codename", .text).notNull()
            t.primaryKey(["user_id", "codename"])
        }
        try db.create(table: "group_permissions") { t in
            t.column("group_id", .integer).notNull().references("groups", onDelete: .cascade)
            t.column("codename", .text).notNull()
            t.primaryKey(["group_id", "codename"])
        }
        try db.create(table: "auth_tokens") { t in
            t.primaryKey("key", .text)
            t.column("user_id", .integer).notNull().unique().references("users", onDelete: .cascade)
            t.column("created", .datetime).notNull()
        }
        try db.create(table: "sessions") { t in
            t.primaryKey("key", .text)
            t.column("user_id", .integer).notNull().indexed().references("users", onDelete: .cascade)
            t.column("csrf_token", .text).notNull()
            t.column("created", .datetime).notNull()
            t.column("expires", .datetime).notNull().indexed()
        }
        try db.create(table: "ui_settings") { t in
            t.primaryKey("user_id", .integer).references("users", onDelete: .cascade)
            t.column("settings", .jsonText).notNull().defaults(to: "{}")
        }

        // MARK: Classification objects
        try db.create(table: "correspondents") { t in matchingColumns(t) }
        try uniqueNamePerOwner(db, table: "correspondents")
        try db.create(table: "document_types") { t in matchingColumns(t) }
        try uniqueNamePerOwner(db, table: "document_types")
        try db.create(table: "storage_paths") { t in
            matchingColumns(t)
            t.column("path", .text).notNull()
        }
        try uniqueNamePerOwner(db, table: "storage_paths")
        try db.create(table: "tags") { t in
            matchingColumns(t)
            t.column("color", .text).notNull().defaults(to: "#a6cee3")
            t.column("is_inbox_tag", .boolean).notNull().defaults(to: false)
            t.column("parent_id", .integer).indexed().references("tags", onDelete: .cascade)
        }
        try uniqueNamePerOwner(db, table: "tags")

        // Object-level permissions (django-guardian equivalent).
        try db.create(table: "object_permissions") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("object_type", .text).notNull()
            t.column("object_id", .integer).notNull()
            t.column("permission", .text).notNull().check { ["view", "change"].contains($0) }
            t.column("user_id", .integer).indexed().references("users", onDelete: .cascade)
            t.column("group_id", .integer).indexed().references("groups", onDelete: .cascade)
            t.check(sql: "(user_id IS NULL) != (group_id IS NULL)")
        }
        try db.create(index: "object_permissions_object", on: "object_permissions", columns: ["object_type", "object_id"])

        // MARK: Documents
        try db.create(table: "documents") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("title", .text).notNull().defaults(to: "").indexed()
            t.column("content", .text).notNull().defaults(to: "")
            t.column("correspondent_id", .integer).indexed().references("correspondents", onDelete: .setNull)
            t.column("document_type_id", .integer).indexed().references("document_types", onDelete: .setNull)
            t.column("storage_path_id", .integer).indexed().references("storage_paths", onDelete: .setNull)
            t.column("owner_id", .integer).indexed().references("users", onDelete: .setNull)
            t.column("created", .text).notNull().indexed() // yyyy-MM-dd
            t.column("modified", .datetime).notNull().indexed()
            t.column("added", .datetime).notNull().indexed()
            t.column("mime_type", .text).notNull()
            t.column("checksum", .text).notNull().indexed()
            t.column("archive_checksum", .text).indexed()
            t.column("filename", .text).unique()
            t.column("archive_filename", .text).unique()
            t.column("original_filename", .text)
            t.column("archive_serial_number", .integer).unique()
            t.column("page_count", .integer)
            t.column("language", .text)
            t.column("original_metadata", .jsonText)
            t.column("archive_metadata", .jsonText)
            t.column("deleted_at", .datetime).indexed()
            t.column("restored_at", .datetime)
            t.column("root_document_id", .integer).indexed().references("documents", onDelete: .cascade)
            t.column("version_index", .integer)
            t.column("version_label", .text)
        }
        try db.execute(sql: """
            CREATE UNIQUE INDEX documents_root_version_index_uniq
            ON documents(root_document_id, version_index)
            WHERE root_document_id IS NOT NULL AND version_index IS NOT NULL
            """)
        try db.create(table: "document_tags") { t in
            t.column("document_id", .integer).notNull().references("documents", onDelete: .cascade)
            t.column("tag_id", .integer).notNull().indexed().references("tags", onDelete: .cascade)
            t.primaryKey(["document_id", "tag_id"])
        }
        try db.create(table: "document_barcodes") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("document_id", .integer).notNull().indexed().references("documents", onDelete: .cascade)
            t.column("page", .integer).notNull()
            t.column("value", .text).notNull()
            t.column("format", .text).notNull()
        }
        try db.create(table: "notes") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("document_id", .integer).notNull().indexed().references("documents", onDelete: .cascade)
            t.column("note", .text).notNull()
            t.column("created", .datetime).notNull()
            t.column("user_id", .integer).references("users", onDelete: .setNull)
            t.column("deleted_at", .datetime)
        }

        // MARK: Custom fields
        try db.create(table: "custom_fields") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique()
            t.column("data_type", .text).notNull()
            t.column("extra_data", .jsonText)
            t.column("created", .datetime).notNull()
        }
        try db.create(table: "custom_field_instances") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("document_id", .integer).notNull().indexed().references("documents", onDelete: .cascade)
            t.column("field_id", .integer).notNull().indexed().references("custom_fields", onDelete: .cascade)
            t.column("created", .datetime).notNull()
            t.column("value_text", .text)
            t.column("value_bool", .boolean)
            t.column("value_url", .text)
            t.column("value_date", .text)
            t.column("value_int", .integer)
            t.column("value_float", .double)
            t.column("value_monetary", .text)
            t.column("value_document_ids", .jsonText)
            t.column("value_select", .text)
            t.column("value_long_text", .text)
            t.column("deleted_at", .datetime)
            t.uniqueKey(["document_id", "field_id"])
        }

        // MARK: Views, sharing
        try db.create(table: "saved_views") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull()
            t.column("icon", .text)
            t.column("sort_field", .text)
            t.column("sort_reverse", .boolean).notNull().defaults(to: false)
            t.column("page_size", .integer)
            t.column("display_mode", .text)
            t.column("display_fields", .jsonText)
            t.column("show_on_dashboard", .boolean).notNull().defaults(to: false)
            t.column("show_in_sidebar", .boolean).notNull().defaults(to: false)
            t.column("owner_id", .integer).indexed().references("users", onDelete: .setNull)
        }
        try db.create(table: "saved_view_filter_rules") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("saved_view_id", .integer).notNull().indexed().references("saved_views", onDelete: .cascade)
            t.column("rule_type", .integer).notNull()
            t.column("value", .text)
        }
        try db.create(table: "share_links") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("slug", .text).notNull().unique()
            t.column("document_id", .integer).notNull().indexed().references("documents", onDelete: .cascade)
            t.column("created", .datetime).notNull()
            t.column("expiration", .datetime)
            t.column("file_version", .text).notNull().defaults(to: "archive")
            t.column("owner_id", .integer).references("users", onDelete: .setNull)
            t.column("deleted_at", .datetime)
        }

        // MARK: Tasks, audit
        try db.create(table: "tasks") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("task_id", .text).notNull().unique()
            t.column("task_type", .text).notNull().indexed()
            t.column("trigger_source", .text).notNull()
            t.column("status", .text).notNull().indexed()
            t.column("date_created", .datetime).notNull().indexed()
            t.column("date_started", .datetime)
            t.column("date_done", .datetime)
            t.column("duration_seconds", .double)
            t.column("wait_time_seconds", .double)
            t.column("input_data", .jsonText)
            t.column("result_data", .jsonText)
            t.column("result_message", .text)
            t.column("related_document_id", .integer)
            t.column("acknowledged", .boolean).notNull().defaults(to: false)
            t.column("owner_id", .integer).references("users", onDelete: .setNull)
        }
        try db.create(table: "audit_log") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("timestamp", .datetime).notNull().indexed()
            t.column("actor_id", .integer).references("users", onDelete: .setNull)
            t.column("action", .text).notNull() // create | update | delete
            t.column("object_type", .text).notNull()
            t.column("object_id", .integer).notNull()
            t.column("object_repr", .text).notNull().defaults(to: "")
            t.column("changes", .jsonText)
            t.column("remote_addr", .text)
        }
        try db.create(index: "audit_log_object", on: "audit_log", columns: ["object_type", "object_id"])

        // MARK: Workflows (trigger and action options are JSON; the API maps them)
        try db.create(table: "workflows") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique()
            t.column("order", .integer).notNull().defaults(to: 0)
            t.column("enabled", .boolean).notNull().defaults(to: true)
        }
        try db.create(table: "workflow_triggers") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("workflow_id", .integer).notNull().indexed().references("workflows", onDelete: .cascade)
            t.column("type", .integer).notNull()
            t.column("config", .jsonText).notNull().defaults(to: "{}")
        }
        try db.create(table: "workflow_actions") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("workflow_id", .integer).notNull().indexed().references("workflows", onDelete: .cascade)
            t.column("type", .integer).notNull()
            t.column("order", .integer).notNull().defaults(to: 0)
            t.column("config", .jsonText).notNull().defaults(to: "{}")
        }
        try db.create(table: "workflow_runs") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("workflow_id", .integer).notNull().indexed().references("workflows", onDelete: .cascade)
            t.column("type", .integer).notNull()
            t.column("document_id", .integer).indexed().references("documents", onDelete: .cascade)
            t.column("run_at", .datetime).notNull()
        }

        // MARK: Mail
        try db.create(table: "mail_accounts") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull().unique()
            t.column("owner_id", .integer).references("users", onDelete: .setNull)
            t.column("config", .jsonText).notNull().defaults(to: "{}")
        }
        try db.create(table: "mail_rules") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("name", .text).notNull()
            t.column("account_id", .integer).notNull().indexed().references("mail_accounts", onDelete: .cascade)
            t.column("order", .integer).notNull().defaults(to: 0)
            t.column("enabled", .boolean).notNull().defaults(to: true)
            t.column("owner_id", .integer).references("users", onDelete: .setNull)
            t.column("config", .jsonText).notNull().defaults(to: "{}")
        }
        try db.create(table: "processed_mail") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("rule_id", .integer).notNull().indexed().references("mail_rules", onDelete: .cascade)
            t.column("folder", .text).notNull()
            t.column("uid", .text).notNull()
            t.column("subject", .text).notNull().defaults(to: "")
            t.column("received", .datetime)
            t.column("processed", .datetime).notNull()
            t.column("status", .text).notNull()
            t.column("error", .text)
            t.column("owner_id", .integer).references("users", onDelete: .setNull)
            t.uniqueKey(["rule_id", "folder", "uid"])
        }

        // MARK: Application config (single row) and key/value metadata
        try db.create(table: "app_config") { t in
            t.primaryKey("id", .integer).check { $0 == 1 }
            t.column("config", .jsonText).notNull().defaults(to: "{}")
        }
        try db.create(table: "meta") { t in
            t.primaryKey("key", .text)
            t.column("value", .text).notNull()
        }

        try SearchSchema.createIndex(db)
    }
}

/// The full-text index lives in its own table so it can be rebuilt.
enum SearchSchema {
    public static let table = "documents_fts"

    /// Columns of the FTS table, in order. The API's field names map onto these.
    static let columns = [
        "title", "content", "correspondent", "document_type", "storage_path", "tags",
        "original_filename", "notes", "notes_user", "custom_field_names", "custom_field_values",
        "barcode_values", "barcode_formats",
    ]

    /// Unstemmed words of titles and content, for autocomplete. Contentless, so it only
    /// costs the term index.
    public static let wordsTable = "documents_words"

    /// Columns a plain search term (no field prefix) looks at, as in Paperless-ngx.
    static let defaultColumns = ["title", "content", "correspondent", "document_type", "tags"]

    static func createIndex(_ db: Database, stemming: Bool = true) throws {
        let tokenizer = stemming
            ? "porter unicode61 remove_diacritics 2"
            : "unicode61 remove_diacritics 2"
        try db.execute(sql: """
            CREATE VIRTUAL TABLE \(table) USING fts5(
                \(columns.joined(separator: ", ")),
                tokenize = '\(tokenizer)',
                prefix = '2 3 4'
            )
            """)
        try db.execute(sql: "CREATE VIRTUAL TABLE \(table)_vocab USING fts5vocab(\(table), 'row')")
        try db.execute(sql: "CREATE VIRTUAL TABLE \(table)_inst USING fts5vocab(\(table), 'instance')")
        try db.execute(sql: """
            CREATE VIRTUAL TABLE \(wordsTable) USING fts5(
                title, content, content = '', contentless_delete = 1, detail = none,
                tokenize = 'unicode61 remove_diacritics 2'
            )
            """)
        try db.execute(sql: "CREATE VIRTUAL TABLE \(wordsTable)_inst USING fts5vocab(\(wordsTable), 'instance')")
        try db.execute(sql: "INSERT OR REPLACE INTO meta(key, value) VALUES ('fts_stemming', ?)", arguments: [stemming ? "1" : "0"])
    }

    static func dropIndex(_ db: Database) throws {
        try db.execute(sql: "DROP TABLE IF EXISTS \(table)_vocab")
        try db.execute(sql: "DROP TABLE IF EXISTS \(table)_inst")
        try db.execute(sql: "DROP TABLE IF EXISTS \(wordsTable)_inst")
        try db.execute(sql: "DROP TABLE IF EXISTS \(wordsTable)")
        try db.execute(sql: "DROP TABLE IF EXISTS \(table)")
    }
}
