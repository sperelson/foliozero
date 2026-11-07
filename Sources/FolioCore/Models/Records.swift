import Foundation
import GRDB
import FolioParsing
import UniformTypeIdentifiers

// MARK: - Matching

/// Paperless-ngx matching algorithms, with the same integer values.
public enum MatchingAlgorithm: Int, Sendable, Codable, CaseIterable, DatabaseValueConvertible {
    case none = 0
    case any = 1
    case all = 2
    case literal = 3
    case regex = 4
    case fuzzy = 5
    case auto = 6

    public var label: String {
        switch self {
        case .none: "None"
        case .any: "Any word"
        case .all: "All words"
        case .literal: "Exact match"
        case .regex: "Regular expression"
        case .fuzzy: "Fuzzy word"
        case .auto: "Automatic"
        }
    }
}

/// Fields shared by tags, correspondents, document types and storage paths.
public protocol MatchingObject: IdentifiedRecord {
    var name: String { get set }
    var match: String { get set }
    var matchingAlgorithm: MatchingAlgorithm { get set }
    var isInsensitive: Bool { get set }
    var ownerId: Int? { get set }
    /// Value of `object_permissions.object_type` and of the audit log `object_type`.
    static var objectType: String { get }
}

public struct Correspondent: MatchingObject, Hashable {
    public static let databaseTableName = "correspondents"
    public static let objectType = "correspondent"
    public var id: Int?
    public var name: String
    public var match: String = ""
    public var matchingAlgorithm: MatchingAlgorithm = .any
    public var isInsensitive: Bool = true
    public var ownerId: Int?

    public init(id: Int? = nil, name: String, match: String = "", matchingAlgorithm: MatchingAlgorithm = .any, isInsensitive: Bool = true, ownerId: Int? = nil) {
        self.id = id; self.name = name; self.match = match
        self.matchingAlgorithm = matchingAlgorithm; self.isInsensitive = isInsensitive; self.ownerId = ownerId
    }
}

public struct DocumentType: MatchingObject, Hashable {
    public static let databaseTableName = "document_types"
    public static let objectType = "documenttype"
    public var id: Int?
    public var name: String
    public var match: String = ""
    public var matchingAlgorithm: MatchingAlgorithm = .any
    public var isInsensitive: Bool = true
    public var ownerId: Int?

    public init(id: Int? = nil, name: String, match: String = "", matchingAlgorithm: MatchingAlgorithm = .any, isInsensitive: Bool = true, ownerId: Int? = nil) {
        self.id = id; self.name = name; self.match = match
        self.matchingAlgorithm = matchingAlgorithm; self.isInsensitive = isInsensitive; self.ownerId = ownerId
    }
}

public struct StoragePath: MatchingObject, Hashable {
    public static let databaseTableName = "storage_paths"
    public static let objectType = "storagepath"
    public var id: Int?
    public var name: String
    public var path: String
    public var match: String = ""
    public var matchingAlgorithm: MatchingAlgorithm = .any
    public var isInsensitive: Bool = true
    public var ownerId: Int?

    public init(id: Int? = nil, name: String, path: String, match: String = "", matchingAlgorithm: MatchingAlgorithm = .any, isInsensitive: Bool = true, ownerId: Int? = nil) {
        self.id = id; self.name = name; self.path = path; self.match = match
        self.matchingAlgorithm = matchingAlgorithm; self.isInsensitive = isInsensitive; self.ownerId = ownerId
    }
}

public struct Tag: MatchingObject, Hashable {
    public static let databaseTableName = "tags"
    public static let objectType = "tag"
    /// Maximum nesting depth (root = 1), as in Paperless-ngx.
    public static let maxNestingDepth = 5
    public var id: Int?
    public var name: String
    public var color: String = "#a6cee3"
    public var isInboxTag: Bool = false
    public var parentId: Int?
    public var match: String = ""
    public var matchingAlgorithm: MatchingAlgorithm = .any
    public var isInsensitive: Bool = true
    public var ownerId: Int?

    public init(id: Int? = nil, name: String, color: String = "#a6cee3", isInboxTag: Bool = false, parentId: Int? = nil, match: String = "", matchingAlgorithm: MatchingAlgorithm = .any, isInsensitive: Bool = true, ownerId: Int? = nil) {
        self.id = id; self.name = name; self.color = color; self.isInboxTag = isInboxTag; self.parentId = parentId
        self.match = match; self.matchingAlgorithm = matchingAlgorithm; self.isInsensitive = isInsensitive; self.ownerId = ownerId
    }

    /// Black or white, whichever reads better on `color` (Paperless-ngx `text_color`).
    public var textColor: String {
        let hex = color.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return "#000000" }
        let r = Double((value >> 16) & 0xFF) / 255, g = Double((value >> 8) & 0xFF) / 255, b = Double(value & 0xFF) / 255
        let luminance = sqrt(0.299 * r * r + 0.587 * g * g + 0.114 * b * b)
        return luminance > 0.53 ? "#000000" : "#ffffff"
    }
}

// MARK: - Documents

public struct Document: IdentifiedRecord, Hashable {
    public static let databaseTableName = "documents"
    public static let objectType = "document"

    public var id: Int?
    public var title: String
    public var content: String
    public var correspondentId: Int?
    public var documentTypeId: Int?
    public var storagePathId: Int?
    public var ownerId: Int?
    public var created: CalendarDate
    public var modified: Date
    public var added: Date
    public var mimeType: String
    public var checksum: String
    public var archiveChecksum: String?
    public var filename: String?
    public var archiveFilename: String?
    public var originalFilename: String?
    public var archiveSerialNumber: Int?
    public var pageCount: Int?
    public var language: String?
    public var originalMetadata: [MetadataEntry]?
    public var archiveMetadata: [MetadataEntry]?
    public var deletedAt: Date?
    public var restoredAt: Date?
    public var rootDocumentId: Int?
    public var versionIndex: Int?
    public var versionLabel: String?

    public init(
        id: Int? = nil, title: String, content: String = "", correspondentId: Int? = nil,
        documentTypeId: Int? = nil, storagePathId: Int? = nil, ownerId: Int? = nil,
        created: CalendarDate, modified: Date = Date(), added: Date = Date(), mimeType: String,
        checksum: String, archiveChecksum: String? = nil, filename: String? = nil,
        archiveFilename: String? = nil, originalFilename: String? = nil,
        archiveSerialNumber: Int? = nil, pageCount: Int? = nil, language: String? = nil,
        originalMetadata: [MetadataEntry]? = nil, archiveMetadata: [MetadataEntry]? = nil,
        deletedAt: Date? = nil, restoredAt: Date? = nil, rootDocumentId: Int? = nil,
        versionIndex: Int? = nil, versionLabel: String? = nil
    ) {
        self.id = id; self.title = title; self.content = content; self.correspondentId = correspondentId
        self.documentTypeId = documentTypeId; self.storagePathId = storagePathId; self.ownerId = ownerId
        self.created = created; self.modified = modified; self.added = added; self.mimeType = mimeType
        self.checksum = checksum; self.archiveChecksum = archiveChecksum; self.filename = filename
        self.archiveFilename = archiveFilename; self.originalFilename = originalFilename
        self.archiveSerialNumber = archiveSerialNumber; self.pageCount = pageCount; self.language = language
        self.originalMetadata = originalMetadata; self.archiveMetadata = archiveMetadata
        self.deletedAt = deletedAt; self.restoredAt = restoredAt; self.rootDocumentId = rootDocumentId
        self.versionIndex = versionIndex; self.versionLabel = versionLabel
    }

    public var hasArchiveVersion: Bool { archiveFilename != nil }

    /// File extension of the original (with dot), from the stored file name or the MIME type.
    public var fileExtension: String {
        if let filename, let dot = filename.lastIndex(of: ".") {
            return String(filename[dot...]).lowercased()
        }
        return UTType(mimeType: mimeType)?.preferredFilenameExtension.map { ".\($0)" } ?? ""
    }
}

public struct DocumentTag: FolioRecord, PersistableRecord, Hashable {
    public static let databaseTableName = "document_tags"
    public var documentId: Int
    public var tagId: Int

    public init(documentId: Int, tagId: Int) {
        self.documentId = documentId
        self.tagId = tagId
    }
}

public struct DocumentBarcode: IdentifiedRecord, Hashable {
    public static let databaseTableName = "document_barcodes"
    public var id: Int?
    public var documentId: Int
    public var page: Int
    public var value: String
    public var format: String

    public init(id: Int? = nil, documentId: Int, page: Int, value: String, format: String) {
        self.id = id; self.documentId = documentId; self.page = page; self.value = value; self.format = format
    }
}

public struct Note: IdentifiedRecord, Hashable {
    public static let databaseTableName = "notes"
    public static let objectType = "note"
    public var id: Int?
    public var documentId: Int
    public var note: String
    public var created: Date
    public var userId: Int?
    public var deletedAt: Date?

    public init(id: Int? = nil, documentId: Int, note: String, created: Date = Date(), userId: Int? = nil, deletedAt: Date? = nil) {
        self.id = id; self.documentId = documentId; self.note = note; self.created = created
        self.userId = userId; self.deletedAt = deletedAt
    }
}

// MARK: - Custom fields

public enum CustomFieldDataType: String, Sendable, Codable, CaseIterable, DatabaseValueConvertible {
    case string, url, date, boolean, integer, float, monetary, documentlink, select, longtext
}

public struct CustomField: IdentifiedRecord, Hashable {
    public static let databaseTableName = "custom_fields"
    public static let objectType = "customfield"

    /// `extra_data` for select fields: `{"select_options": [{"id": "...", "label": "..."}]}`;
    /// for monetary fields: `{"default_currency": "ZAR"}`.
    public struct ExtraData: Codable, Sendable, Hashable {
        public struct SelectOption: Codable, Sendable, Hashable {
            public var id: String
            public var label: String
            public init(id: String, label: String) { self.id = id; self.label = label }
        }
        public var selectOptions: [SelectOption]?
        public var defaultCurrency: String?

        enum CodingKeys: String, CodingKey {
            case selectOptions = "select_options"
            case defaultCurrency = "default_currency"
        }

        public init(selectOptions: [SelectOption]? = nil, defaultCurrency: String? = nil) {
            self.selectOptions = selectOptions
            self.defaultCurrency = defaultCurrency
        }
    }

    public var id: Int?
    public var name: String
    public var dataType: CustomFieldDataType
    public var extraData: ExtraData?
    public var created: Date

    public init(id: Int? = nil, name: String, dataType: CustomFieldDataType, extraData: ExtraData? = nil, created: Date = Date()) {
        self.id = id; self.name = name; self.dataType = dataType; self.extraData = extraData; self.created = created
    }
}

public struct CustomFieldInstance: IdentifiedRecord, Hashable {
    public static let databaseTableName = "custom_field_instances"
    public var id: Int?
    public var documentId: Int
    public var fieldId: Int
    public var created: Date
    public var valueText: String?
    public var valueBool: Bool?
    public var valueUrl: String?
    public var valueDate: CalendarDate?
    public var valueInt: Int?
    public var valueFloat: Double?
    public var valueMonetary: String?
    public var valueDocumentIds: [Int]?
    public var valueSelect: String?
    public var valueLongText: String?
    public var deletedAt: Date?

    public init(id: Int? = nil, documentId: Int, fieldId: Int, created: Date = Date()) {
        self.id = id; self.documentId = documentId; self.fieldId = fieldId; self.created = created
    }
}

// MARK: - Users and auth

public struct User: IdentifiedRecord, Hashable {
    public static let databaseTableName = "users"
    public static let objectType = "user"
    public var id: Int?
    public var username: String
    /// Django-format password hash. Empty means no usable password.
    public var password: String
    public var email: String = ""
    public var firstName: String = ""
    public var lastName: String = ""
    public var isSuperuser: Bool = false
    public var isStaff: Bool = false
    public var isActive: Bool = true
    public var dateJoined: Date = Date()
    public var lastLogin: Date?

    public init(id: Int? = nil, username: String, password: String = "", email: String = "", firstName: String = "", lastName: String = "", isSuperuser: Bool = false, isStaff: Bool = false, isActive: Bool = true, dateJoined: Date = Date(), lastLogin: Date? = nil) {
        self.id = id; self.username = username; self.password = password; self.email = email
        self.firstName = firstName; self.lastName = lastName; self.isSuperuser = isSuperuser
        self.isStaff = isStaff; self.isActive = isActive; self.dateJoined = dateJoined; self.lastLogin = lastLogin
    }
}

public struct Group: IdentifiedRecord, Hashable {
    public static let databaseTableName = "groups"
    public static let objectType = "group"
    public var id: Int?
    public var name: String

    public init(id: Int? = nil, name: String) {
        self.id = id
        self.name = name
    }
}

public struct AuthToken: FolioRecord, PersistableRecord, Hashable {
    public static let databaseTableName = "auth_tokens"
    public var key: String
    public var userId: Int
    public var created: Date

    public init(key: String, userId: Int, created: Date = Date()) {
        self.key = key; self.userId = userId; self.created = created
    }
}

public struct Session: FolioRecord, PersistableRecord, Hashable {
    public static let databaseTableName = "sessions"
    public var key: String
    public var userId: Int
    public var csrfToken: String
    public var created: Date
    public var expires: Date

    public init(key: String, userId: Int, csrfToken: String, created: Date = Date(), expires: Date) {
        self.key = key; self.userId = userId; self.csrfToken = csrfToken; self.created = created; self.expires = expires
    }
}

public struct ObjectPermission: IdentifiedRecord, Hashable {
    public static let databaseTableName = "object_permissions"
    public enum Kind: String, Codable, Sendable, DatabaseValueConvertible { case view, change }
    public var id: Int?
    public var objectType: String
    public var objectId: Int
    public var permission: Kind
    public var userId: Int?
    public var groupId: Int?

    public init(id: Int? = nil, objectType: String, objectId: Int, permission: Kind, userId: Int? = nil, groupId: Int? = nil) {
        self.id = id; self.objectType = objectType; self.objectId = objectId
        self.permission = permission; self.userId = userId; self.groupId = groupId
    }
}

// MARK: - Views and sharing

public struct SavedView: IdentifiedRecord, Hashable {
    public static let databaseTableName = "saved_views"
    public static let objectType = "savedview"
    public var id: Int?
    public var name: String
    public var icon: String?
    public var sortField: String?
    public var sortReverse: Bool = false
    public var pageSize: Int?
    public var displayMode: String?
    public var displayFields: [String]?
    public var showOnDashboard: Bool = false
    public var showInSidebar: Bool = false
    public var ownerId: Int?

    public init(id: Int? = nil, name: String, ownerId: Int? = nil) {
        self.id = id; self.name = name; self.ownerId = ownerId
    }
}

public struct SavedViewFilterRule: IdentifiedRecord, Hashable {
    public static let databaseTableName = "saved_view_filter_rules"
    public var id: Int?
    public var savedViewId: Int
    public var ruleType: Int
    public var value: String?

    public init(id: Int? = nil, savedViewId: Int, ruleType: Int, value: String?) {
        self.id = id; self.savedViewId = savedViewId; self.ruleType = ruleType; self.value = value
    }
}

public struct ShareLink: IdentifiedRecord, Hashable {
    public static let databaseTableName = "share_links"
    public static let objectType = "sharelink"
    public enum FileVersion: String, Codable, Sendable, DatabaseValueConvertible { case archive, original }
    public var id: Int?
    public var slug: String
    public var documentId: Int
    public var created: Date
    public var expiration: Date?
    public var fileVersion: FileVersion
    public var ownerId: Int?
    public var deletedAt: Date?

    public init(id: Int? = nil, slug: String, documentId: Int, created: Date = Date(), expiration: Date? = nil, fileVersion: FileVersion = .archive, ownerId: Int? = nil) {
        self.id = id; self.slug = slug; self.documentId = documentId; self.created = created
        self.expiration = expiration; self.fileVersion = fileVersion; self.ownerId = ownerId
    }
}

// MARK: - Tasks and audit

public struct TaskRecord: IdentifiedRecord, Hashable {
    public static let databaseTableName = "tasks"

    public enum Status: String, Codable, Sendable, DatabaseValueConvertible {
        case pending, started, success, failure, revoked
    }

    public enum TaskType: String, Codable, Sendable, DatabaseValueConvertible {
        case consumeFile = "consume_file"
        case trainClassifier = "train_classifier"
        case sanityCheck = "sanity_check"
        case indexOptimize = "index_optimize"
        case mailFetch = "mail_fetch"
        case emptyTrash = "empty_trash"
        case checkWorkflows = "check_workflows"
        case bulkUpdate = "bulk_update"
        case reprocessDocument = "reprocess_document"
        case buildShareLink = "build_share_link"
        case bulkDelete = "bulk_delete"
        case llmIndex = "llm_index"
        case applyAISuggestions = "apply_ai_suggestions"
    }

    public enum TriggerSource: String, Codable, Sendable, DatabaseValueConvertible {
        case scheduled
        case webUI = "web_ui"
        case apiUpload = "api_upload"
        case folderConsume = "folder_consume"
        case emailConsume = "email_consume"
        case system
        case manual
    }

    public var id: Int?
    public var taskId: String
    public var taskType: TaskType
    public var triggerSource: TriggerSource
    public var status: Status
    public var dateCreated: Date
    public var dateStarted: Date?
    public var dateDone: Date?
    public var durationSeconds: Double?
    public var waitTimeSeconds: Double?
    public var inputData: [String: String]?
    public var resultData: [String: String]?
    public var resultMessage: String?
    public var relatedDocumentId: Int?
    public var acknowledged: Bool = false
    public var ownerId: Int?

    public init(taskId: String = UUID().uuidString.lowercased(), taskType: TaskType, triggerSource: TriggerSource, status: Status = .pending, dateCreated: Date = Date(), inputData: [String: String]? = nil, ownerId: Int? = nil) {
        self.taskId = taskId; self.taskType = taskType; self.triggerSource = triggerSource
        self.status = status; self.dateCreated = dateCreated; self.inputData = inputData; self.ownerId = ownerId
    }
}

public struct AuditLogEntry: IdentifiedRecord, Hashable {
    public static let databaseTableName = "audit_log"
    public enum Action: String, Codable, Sendable, DatabaseValueConvertible { case create, update, delete }
    public var id: Int?
    public var timestamp: Date
    public var actorId: Int?
    public var action: Action
    public var objectType: String
    public var objectId: Int
    public var objectRepr: String
    /// Field name mapped to `[old, new]` rendered as strings.
    public var changes: [String: [String?]]?
    public var remoteAddr: String?

    public init(timestamp: Date = Date(), actorId: Int?, action: Action, objectType: String, objectId: Int, objectRepr: String, changes: [String: [String?]]? = nil, remoteAddr: String? = nil) {
        self.timestamp = timestamp; self.actorId = actorId; self.action = action; self.objectType = objectType
        self.objectId = objectId; self.objectRepr = objectRepr; self.changes = changes; self.remoteAddr = remoteAddr
    }
}
