import Foundation

/// What FolioZero needs to know about the Paperless-ngx schema (v3.4.2) to read
/// and write `document_exporter` manifests.
enum PaperlessCatalog {
    /// Version written to `metadata.json`. The manifest follows this release's models.
    static let version = "3.4.2"

    struct Model {
        var app: String
        var model: String
        var verboseName: String
        var extraPermissions: [(codename: String, name: String)] = []
    }

    /// Every model with a content type in a default Paperless-ngx install. The importer
    /// replaces all content types and permissions with the manifest's, so the export lists
    /// them all. Order decides which app wins for shared codenames (`view_logentry`).
    static let models: [Model] = [
        Model(app: "documents", model: "correspondent", verboseName: "correspondent"),
        Model(app: "documents", model: "tag", verboseName: "tag"),
        Model(app: "documents", model: "documenttype", verboseName: "document type"),
        Model(app: "documents", model: "storagepath", verboseName: "storage path"),
        Model(app: "documents", model: "document", verboseName: "document"),
        Model(app: "documents", model: "savedview", verboseName: "saved view"),
        Model(app: "documents", model: "savedviewfilterrule", verboseName: "filter rule"),
        Model(app: "documents", model: "uisettings", verboseName: "ui settings"),
        Model(app: "documents", model: "paperlesstask", verboseName: "Task"),
        Model(app: "documents", model: "note", verboseName: "note"),
        Model(app: "documents", model: "documentbarcode", verboseName: "document barcode"),
        Model(app: "documents", model: "sharelink", verboseName: "share link"),
        Model(app: "documents", model: "sharelinkbundle", verboseName: "share link bundle"),
        Model(app: "documents", model: "customfield", verboseName: "custom field"),
        Model(app: "documents", model: "customfieldinstance", verboseName: "custom field instance"),
        Model(app: "documents", model: "workflowtrigger", verboseName: "workflow trigger"),
        Model(app: "documents", model: "workflowactionemail", verboseName: "workflow action email"),
        Model(app: "documents", model: "workflowactionwebhook", verboseName: "workflow action webhook"),
        Model(app: "documents", model: "workflowaction", verboseName: "workflow action"),
        Model(app: "documents", model: "workflow", verboseName: "workflow"),
        Model(app: "documents", model: "workflowrun", verboseName: "workflow run"),
        Model(app: "paperless_mail", model: "mailaccount", verboseName: "mail account"),
        Model(app: "paperless_mail", model: "mailrule", verboseName: "mail rule"),
        Model(app: "paperless_mail", model: "processedmail", verboseName: "processed mail"),
        Model(app: "paperless", model: "applicationconfiguration", verboseName: "paperless application settings", extraPermissions: [
            ("view_global_statistics", "Can view global object counts"),
            ("view_system_monitoring", "Can view system status information"),
        ]),
        Model(app: "auditlog", model: "logentry", verboseName: "log entry"),
        Model(app: "auth", model: "permission", verboseName: "permission"),
        Model(app: "auth", model: "group", verboseName: "group"),
        Model(app: "auth", model: "user", verboseName: "user"),
        Model(app: "contenttypes", model: "contenttype", verboseName: "content type"),
        Model(app: "sessions", model: "session", verboseName: "session"),
        Model(app: "authtoken", model: "token", verboseName: "Token"),
        Model(app: "authtoken", model: "tokenproxy", verboseName: "Token"),
        Model(app: "guardian", model: "userobjectpermission", verboseName: "user object permission"),
        Model(app: "guardian", model: "groupobjectpermission", verboseName: "group object permission"),
        Model(app: "account", model: "emailaddress", verboseName: "email address"),
        Model(app: "account", model: "emailconfirmation", verboseName: "email confirmation"),
        Model(app: "socialaccount", model: "socialaccount", verboseName: "social account"),
        Model(app: "socialaccount", model: "socialapp", verboseName: "social application"),
        Model(app: "socialaccount", model: "socialtoken", verboseName: "social application token"),
        Model(app: "mfa", model: "authenticator", verboseName: "authenticator"),
        Model(app: "admin", model: "logentry", verboseName: "log entry"),
    ]

    /// Field names of `paperless.applicationconfiguration`. Other keys of FolioZero's
    /// app config are left out of exports because the Paperless-ngx importer rejects them.
    static let appConfigFields: Set<String> = [
        "output_type", "pages", "language", "mode", "archive_file_generation", "image_dpi", "unpaper_clean",
        "deskew", "rotate_pages", "rotate_pages_threshold", "max_image_pixels", "color_conversion_strategy",
        "user_args", "app_title", "app_logo", "barcodes_enabled", "barcode_enable_tiff_support", "barcode_string",
        "barcode_retain_split_pages", "barcode_enable_asn", "barcode_asn_prefix", "barcode_upscale", "barcode_dpi",
        "barcode_max_pages", "barcode_enable_tag", "barcode_tag_mapping", "barcode_tag_split", "barcode_store_values",
        "remote_ocr_engine", "remote_ocr_api_key", "remote_ocr_endpoint", "remote_ocr_mode", "ai_enabled",
        "llm_embedding_backend", "llm_embedding_model", "llm_embedding_api_key", "llm_embedding_endpoint",
        "llm_embedding_chunk_size", "llm_context_size", "llm_backend", "llm_model", "llm_api_key", "llm_endpoint",
        "llm_output_language", "llm_request_timeout",
    ]

    /// Content types and permissions with stable primary keys (1...n in catalog order).
    struct Tables {
        var contentTypes: [ManifestRecord] = []
        var permissions: [ManifestRecord] = []
        /// Codename to permission pk. FolioZero uses Paperless-ngx codenames.
        var permissionByCodename: [String: Int] = [:]
        /// `app.model` to content type pk; also plain `model` (first app wins).
        var contentTypeByModel: [String: Int] = [:]
        /// (content type pk, Paperless codename) to permission pk.
        var permissionByContentType: [String: Int] = [:]
    }

    static func tables() -> Tables {
        var tables = Tables()
        var permissionPK = 0
        for (index, model) in models.enumerated() {
            let ctPK = index + 1
            tables.contentTypes.append(ManifestRecord(model: "contenttypes.contenttype", pk: .int(ctPK), fields: [
                "app_label": .string(model.app), "model": .string(model.model),
            ]))
            tables.contentTypeByModel["\(model.app).\(model.model)"] = ctPK
            if tables.contentTypeByModel[model.model] == nil { tables.contentTypeByModel[model.model] = ctPK }
            var permissions = Permission.Action.allCases.map { action in
                (codename: "\(action.rawValue)_\(model.model)", name: "Can \(action.rawValue) \(model.verboseName)")
            }
            permissions += model.extraPermissions
            for permission in permissions {
                permissionPK += 1
                tables.permissions.append(ManifestRecord(model: "auth.permission", pk: .int(permissionPK), fields: [
                    "name": .string(permission.name), "content_type": .int(ctPK), "codename": .string(permission.codename),
                ]))
                if tables.permissionByCodename[permission.codename] == nil { tables.permissionByCodename[permission.codename] = permissionPK }
                tables.permissionByContentType["\(ctPK):\(permission.codename)"] = permissionPK
            }
        }
        return tables
    }

    /// Models that FolioZero has no place for. The importer skips them with a warning.
    static let unsupportedModels: [String: String] = [
        "documents.sharelinkbundle": "share link bundles are rebuilt on demand",
        "socialaccount.socialapp": "OpenID Connect apps come from PAPERLESS_SOCIALACCOUNT_PROVIDERS",
        "socialaccount.socialtoken": "provider tokens are not stored",
        "mfa.authenticator": "two-factor authentication is not supported",
        "account.emailaddress": "allauth email addresses are not used",
        "account.emailconfirmation": "allauth email addresses are not used",
        "sessions.session": "sessions are not migrated",
        "admin.logentry": "Django admin history is not used",
        "authtoken.tokenproxy": "token proxies have no data",
    ]
}
