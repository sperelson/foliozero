import Foundation
import GRDB

/// A workflow: triggers plus ordered actions (Paperless-ngx `Workflow`).
public struct Workflow: IdentifiedRecord, Hashable {
    public static let databaseTableName = "workflows"
    public var id: Int?
    public var name: String
    public var order: Int
    public var enabled: Bool

    public init(id: Int? = nil, name: String, order: Int = 0, enabled: Bool = true) {
        self.id = id; self.name = name; self.order = order; self.enabled = enabled
    }
}

public enum WorkflowTriggerType: Int, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case consumption = 1
    case documentAdded = 2
    case documentUpdated = 3
    case scheduled = 4
}

public enum WorkflowActionType: Int, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case assignment = 1
    case removal = 2
    case email = 3
    case webhook = 4
    case passwordRemoval = 5
    case moveToTrash = 6
    case remoteOCR = 7
    case applyAISuggestions = 8
}

/// Trigger options with Paperless-ngx field names, stored as JSON.
public struct WorkflowTriggerConfig: Codable, Sendable, Hashable {
    public var sources: [Int] = [1, 2, 3, 4]
    public var filterPath: String?
    public var filterFilename: String?
    public var filterMailrule: Int?
    public var match: String = ""
    public var matchingAlgorithm: Int = 0
    public var isInsensitive: Bool = true
    public var filterHasTags: [Int] = []
    public var filterHasAllTags: [Int] = []
    public var filterHasNotTags: [Int] = []
    public var filterHasCorrespondent: Int?
    public var filterHasAnyCorrespondents: [Int] = []
    public var filterHasNotCorrespondents: [Int] = []
    public var filterHasDocumentType: Int?
    public var filterHasAnyDocumentTypes: [Int] = []
    public var filterHasNotDocumentTypes: [Int] = []
    public var filterHasStoragePath: Int?
    public var filterHasAnyStoragePaths: [Int] = []
    public var filterHasNotStoragePaths: [Int] = []
    public var filterCustomFieldQuery: String?
    public var scheduleOffsetDays: Int = 0
    public var scheduleIsRecurring: Bool = false
    public var scheduleRecurringIntervalDays: Int = 1
    public var scheduleDateField: String = "added"
    public var scheduleDateCustomField: Int?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case sources, match
        case filterPath = "filter_path", filterFilename = "filter_filename", filterMailrule = "filter_mailrule"
        case matchingAlgorithm = "matching_algorithm", isInsensitive = "is_insensitive"
        case filterHasTags = "filter_has_tags", filterHasAllTags = "filter_has_all_tags", filterHasNotTags = "filter_has_not_tags"
        case filterHasCorrespondent = "filter_has_correspondent", filterHasAnyCorrespondents = "filter_has_any_correspondents"
        case filterHasNotCorrespondents = "filter_has_not_correspondents"
        case filterHasDocumentType = "filter_has_document_type", filterHasAnyDocumentTypes = "filter_has_any_document_types"
        case filterHasNotDocumentTypes = "filter_has_not_document_types"
        case filterHasStoragePath = "filter_has_storage_path", filterHasAnyStoragePaths = "filter_has_any_storage_paths"
        case filterHasNotStoragePaths = "filter_has_not_storage_paths"
        case filterCustomFieldQuery = "filter_custom_field_query"
        case scheduleOffsetDays = "schedule_offset_days", scheduleIsRecurring = "schedule_is_recurring"
        case scheduleRecurringIntervalDays = "schedule_recurring_interval_days"
        case scheduleDateField = "schedule_date_field", scheduleDateCustomField = "schedule_date_custom_field"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = WorkflowTriggerConfig()
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) throws -> T { try c.decodeIfPresent(T.self, forKey: key) ?? fallback }
        sources = try value(.sources, defaults.sources)
        filterPath = try c.decodeIfPresent(String.self, forKey: .filterPath)
        filterFilename = try c.decodeIfPresent(String.self, forKey: .filterFilename)
        filterMailrule = try c.decodeIfPresent(Int.self, forKey: .filterMailrule)
        match = try value(.match, "")
        matchingAlgorithm = try value(.matchingAlgorithm, 0)
        isInsensitive = try value(.isInsensitive, true)
        filterHasTags = try value(.filterHasTags, [])
        filterHasAllTags = try value(.filterHasAllTags, [])
        filterHasNotTags = try value(.filterHasNotTags, [])
        filterHasCorrespondent = try c.decodeIfPresent(Int.self, forKey: .filterHasCorrespondent)
        filterHasAnyCorrespondents = try value(.filterHasAnyCorrespondents, [])
        filterHasNotCorrespondents = try value(.filterHasNotCorrespondents, [])
        filterHasDocumentType = try c.decodeIfPresent(Int.self, forKey: .filterHasDocumentType)
        filterHasAnyDocumentTypes = try value(.filterHasAnyDocumentTypes, [])
        filterHasNotDocumentTypes = try value(.filterHasNotDocumentTypes, [])
        filterHasStoragePath = try c.decodeIfPresent(Int.self, forKey: .filterHasStoragePath)
        filterHasAnyStoragePaths = try value(.filterHasAnyStoragePaths, [])
        filterHasNotStoragePaths = try value(.filterHasNotStoragePaths, [])
        filterCustomFieldQuery = try c.decodeIfPresent(String.self, forKey: .filterCustomFieldQuery)
        scheduleOffsetDays = try value(.scheduleOffsetDays, 0)
        scheduleIsRecurring = try value(.scheduleIsRecurring, false)
        scheduleRecurringIntervalDays = try value(.scheduleRecurringIntervalDays, 1)
        scheduleDateField = try value(.scheduleDateField, "added")
        scheduleDateCustomField = try c.decodeIfPresent(Int.self, forKey: .scheduleDateCustomField)
    }
}

/// Action options with Paperless-ngx field names, stored as JSON.
public struct WorkflowActionConfig: Codable, Sendable, Hashable {
    public struct Email: Codable, Sendable, Hashable {
        public var subject: String = ""
        public var body: String = ""
        public var to: String = ""
        public var includeDocument: Bool = false
        enum CodingKeys: String, CodingKey { case subject, body, to, includeDocument = "include_document" }
        public init(subject: String = "", body: String = "", to: String = "", includeDocument: Bool = false) {
            self.subject = subject; self.body = body; self.to = to; self.includeDocument = includeDocument
        }
    }

    public struct Webhook: Codable, Sendable, Hashable {
        public var url: String = ""
        public var useParams: Bool = true
        public var asJSON: Bool = false
        public var params: [String: String]?
        public var body: String?
        public var headers: [String: String]?
        public var includeDocument: Bool = false
        enum CodingKeys: String, CodingKey {
            case url, params, body, headers
            case useParams = "use_params", asJSON = "as_json", includeDocument = "include_document"
        }
        public init(url: String = "", useParams: Bool = true, asJSON: Bool = false, params: [String: String]? = nil, body: String? = nil, headers: [String: String]? = nil, includeDocument: Bool = false) {
            self.url = url; self.useParams = useParams; self.asJSON = asJSON; self.params = params
            self.body = body; self.headers = headers; self.includeDocument = includeDocument
        }
    }

    public var assignTitle: String?
    public var assignTags: [Int] = []
    public var assignCorrespondent: Int?
    public var assignDocumentType: Int?
    public var assignStoragePath: Int?
    public var assignOwner: Int?
    public var assignViewUsers: [Int] = []
    public var assignViewGroups: [Int] = []
    public var assignChangeUsers: [Int] = []
    public var assignChangeGroups: [Int] = []
    public var assignCustomFields: [Int] = []
    /// Field id (as string) to value.
    public var assignCustomFieldsValues: [String: JSONValue] = [:]
    public var removeTags: [Int] = []
    public var removeAllTags: Bool = false
    public var removeDocumentTypes: [Int] = []
    public var removeAllDocumentTypes: Bool = false
    public var removeCorrespondents: [Int] = []
    public var removeAllCorrespondents: Bool = false
    public var removeStoragePaths: [Int] = []
    public var removeAllStoragePaths: Bool = false
    public var removeOwners: [Int] = []
    public var removeAllOwners: Bool = false
    public var removeViewUsers: [Int] = []
    public var removeViewGroups: [Int] = []
    public var removeChangeUsers: [Int] = []
    public var removeChangeGroups: [Int] = []
    public var removeAllPermissions: Bool = false
    public var removeCustomFields: [Int] = []
    public var removeAllCustomFields: Bool = false
    public var email: Email?
    public var webhook: Webhook?
    public var passwords: [String] = []
    /// "Apply AI suggestions": which fields (title, tags, correspondent, document_type, storage_path, created).
    public var aiSuggestionFields: [String] = []
    public var aiCreateMissing: Bool = false
    public var aiOverwriteExisting: Bool = false

    public init() {}

    enum CodingKeys: String, CodingKey {
        case email, webhook, passwords
        case assignTitle = "assign_title", assignTags = "assign_tags", assignCorrespondent = "assign_correspondent"
        case assignDocumentType = "assign_document_type", assignStoragePath = "assign_storage_path", assignOwner = "assign_owner"
        case assignViewUsers = "assign_view_users", assignViewGroups = "assign_view_groups"
        case assignChangeUsers = "assign_change_users", assignChangeGroups = "assign_change_groups"
        case assignCustomFields = "assign_custom_fields", assignCustomFieldsValues = "assign_custom_fields_values"
        case removeTags = "remove_tags", removeAllTags = "remove_all_tags"
        case removeDocumentTypes = "remove_document_types", removeAllDocumentTypes = "remove_all_document_types"
        case removeCorrespondents = "remove_correspondents", removeAllCorrespondents = "remove_all_correspondents"
        case removeStoragePaths = "remove_storage_paths", removeAllStoragePaths = "remove_all_storage_paths"
        case removeOwners = "remove_owners", removeAllOwners = "remove_all_owners"
        case removeViewUsers = "remove_view_users", removeViewGroups = "remove_view_groups"
        case removeChangeUsers = "remove_change_users", removeChangeGroups = "remove_change_groups"
        case removeAllPermissions = "remove_all_permissions"
        case removeCustomFields = "remove_custom_fields", removeAllCustomFields = "remove_all_custom_fields"
        case aiSuggestionFields = "ai_suggestion_fields", aiCreateMissing = "ai_create_missing", aiOverwriteExisting = "ai_overwrite_existing"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func list(_ key: CodingKeys) throws -> [Int] { try c.decodeIfPresent([Int].self, forKey: key) ?? [] }
        func flag(_ key: CodingKeys) throws -> Bool { try c.decodeIfPresent(Bool.self, forKey: key) ?? false }
        assignTitle = try c.decodeIfPresent(String.self, forKey: .assignTitle)
        assignTags = try list(.assignTags)
        assignCorrespondent = try c.decodeIfPresent(Int.self, forKey: .assignCorrespondent)
        assignDocumentType = try c.decodeIfPresent(Int.self, forKey: .assignDocumentType)
        assignStoragePath = try c.decodeIfPresent(Int.self, forKey: .assignStoragePath)
        assignOwner = try c.decodeIfPresent(Int.self, forKey: .assignOwner)
        assignViewUsers = try list(.assignViewUsers); assignViewGroups = try list(.assignViewGroups)
        assignChangeUsers = try list(.assignChangeUsers); assignChangeGroups = try list(.assignChangeGroups)
        assignCustomFields = try list(.assignCustomFields)
        assignCustomFieldsValues = try c.decodeIfPresent([String: JSONValue].self, forKey: .assignCustomFieldsValues) ?? [:]
        removeTags = try list(.removeTags); removeAllTags = try flag(.removeAllTags)
        removeDocumentTypes = try list(.removeDocumentTypes); removeAllDocumentTypes = try flag(.removeAllDocumentTypes)
        removeCorrespondents = try list(.removeCorrespondents); removeAllCorrespondents = try flag(.removeAllCorrespondents)
        removeStoragePaths = try list(.removeStoragePaths); removeAllStoragePaths = try flag(.removeAllStoragePaths)
        removeOwners = try list(.removeOwners); removeAllOwners = try flag(.removeAllOwners)
        removeViewUsers = try list(.removeViewUsers); removeViewGroups = try list(.removeViewGroups)
        removeChangeUsers = try list(.removeChangeUsers); removeChangeGroups = try list(.removeChangeGroups)
        removeAllPermissions = try flag(.removeAllPermissions)
        removeCustomFields = try list(.removeCustomFields); removeAllCustomFields = try flag(.removeAllCustomFields)
        email = try c.decodeIfPresent(Email.self, forKey: .email)
        webhook = try c.decodeIfPresent(Webhook.self, forKey: .webhook)
        passwords = try c.decodeIfPresent([String].self, forKey: .passwords) ?? []
        aiSuggestionFields = try c.decodeIfPresent([String].self, forKey: .aiSuggestionFields) ?? []
        aiCreateMissing = try flag(.aiCreateMissing)
        aiOverwriteExisting = try flag(.aiOverwriteExisting)
    }
}

public struct WorkflowTrigger: IdentifiedRecord, Hashable {
    public static let databaseTableName = "workflow_triggers"
    public var id: Int?
    public var workflowId: Int
    public var type: WorkflowTriggerType
    public var config: WorkflowTriggerConfig

    public init(id: Int? = nil, workflowId: Int, type: WorkflowTriggerType, config: WorkflowTriggerConfig = .init()) {
        self.id = id; self.workflowId = workflowId; self.type = type; self.config = config
    }
}

public struct WorkflowAction: IdentifiedRecord, Hashable {
    public static let databaseTableName = "workflow_actions"
    public var id: Int?
    public var workflowId: Int
    public var type: WorkflowActionType
    public var order: Int
    public var config: WorkflowActionConfig

    public init(id: Int? = nil, workflowId: Int, type: WorkflowActionType, order: Int = 0, config: WorkflowActionConfig = .init()) {
        self.id = id; self.workflowId = workflowId; self.type = type; self.order = order; self.config = config
    }
}

public struct WorkflowRun: IdentifiedRecord, Hashable {
    public static let databaseTableName = "workflow_runs"
    public var id: Int?
    public var workflowId: Int
    public var type: WorkflowTriggerType
    public var documentId: Int?
    public var runAt: Date

    public init(id: Int? = nil, workflowId: Int, type: WorkflowTriggerType, documentId: Int?, runAt: Date = Date()) {
        self.id = id; self.workflowId = workflowId; self.type = type; self.documentId = documentId; self.runAt = runAt
    }
}
