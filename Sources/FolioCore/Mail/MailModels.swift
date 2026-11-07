import Foundation
import GRDB

/// An IMAP account (Paperless-ngx `MailAccount`). Connection options are JSON in `config`.
public struct MailAccount: IdentifiedRecord, Hashable {
    public static let databaseTableName = "mail_accounts"
    public static let objectType = "mailaccount"

    public enum AccountType: Int, Codable, Sendable { case imap = 1, gmailOAuth = 2, outlookOAuth = 3 }

    public struct Config: Codable, Sendable, Hashable {
        public var imapServer: String = ""
        public var imapPort: Int?
        public var imapSecurity: IMAPClient.Security = .ssl
        public var username: String = ""
        public var password: String = ""
        public var characterSet: String = "UTF-8"
        public var isToken: Bool = false
        public var accountType: AccountType = .imap
        public var refreshToken: String?
        public var expiration: Date?

        enum CodingKeys: String, CodingKey {
            case username, password, expiration
            case imapServer = "imap_server", imapPort = "imap_port", imapSecurity = "imap_security"
            case characterSet = "character_set", isToken = "is_token", accountType = "account_type", refreshToken = "refresh_token"
        }

        public init(imapServer: String = "", imapPort: Int? = nil, imapSecurity: IMAPClient.Security = .ssl, username: String = "", password: String = "") {
            self.imapServer = imapServer; self.imapPort = imapPort; self.imapSecurity = imapSecurity
            self.username = username; self.password = password
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            imapServer = try c.decodeIfPresent(String.self, forKey: .imapServer) ?? ""
            imapPort = try c.decodeIfPresent(Int.self, forKey: .imapPort)
            imapSecurity = try c.decodeIfPresent(IMAPClient.Security.self, forKey: .imapSecurity) ?? .ssl
            username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
            password = try c.decodeIfPresent(String.self, forKey: .password) ?? ""
            characterSet = try c.decodeIfPresent(String.self, forKey: .characterSet) ?? "UTF-8"
            isToken = try c.decodeIfPresent(Bool.self, forKey: .isToken) ?? false
            accountType = try c.decodeIfPresent(AccountType.self, forKey: .accountType) ?? .imap
            refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
            expiration = try c.decodeIfPresent(Date.self, forKey: .expiration)
        }

        /// Port, defaulting by security mode (993 for SSL, 143 otherwise).
        public var effectivePort: Int { imapPort ?? (imapSecurity == .ssl ? 993 : 143) }
    }

    public var id: Int?
    public var name: String
    public var ownerId: Int?
    public var config: Config

    public init(id: Int? = nil, name: String, ownerId: Int? = nil, config: Config) {
        self.id = id; self.name = name; self.ownerId = ownerId; self.config = config
    }
}

/// A mail rule (Paperless-ngx `MailRule`). Options are JSON in `config`.
public struct MailRule: IdentifiedRecord, Hashable {
    public static let databaseTableName = "mail_rules"
    public static let objectType = "mailrule"

    public enum Action: Int, Codable, Sendable { case delete = 1, move = 2, markRead = 3, flag = 4, tag = 5 }
    public enum TitleSource: Int, Codable, Sendable { case subject = 1, filename = 2, none = 3 }
    public enum CorrespondentSource: Int, Codable, Sendable { case nothing = 1, email = 2, name = 3, custom = 4 }
    public enum AttachmentProcessing: Int, Codable, Sendable { case attachmentsOnly = 1, everything = 2 }
    public enum ConsumptionScope: Int, Codable, Sendable { case attachmentsOnly = 1, emlOnly = 2, everything = 3 }

    public struct Config: Codable, Sendable, Hashable {
        public var folder: String = "INBOX"
        public var filterFrom: String?
        public var filterTo: String?
        public var filterSubject: String?
        public var filterBody: String?
        public var filterAttachmentFilenameInclude: String?
        public var filterAttachmentFilenameExclude: String?
        public var maximumAge: Int = 30
        public var action: Action = .markRead
        public var actionParameter: String?
        public var assignTitleFrom: TitleSource = .subject
        public var assignTags: [Int] = []
        public var assignDocumentType: Int?
        public var assignCorrespondentFrom: CorrespondentSource = .nothing
        public var assignCorrespondent: Int?
        public var assignOwnerFromRule: Bool = true
        public var attachmentType: AttachmentProcessing = .attachmentsOnly
        public var consumptionScope: ConsumptionScope = .attachmentsOnly
        public var pdfLayout: Int = 0
        public var stopProcessing: Bool = false

        enum CodingKeys: String, CodingKey {
            case folder, action
            case filterFrom = "filter_from", filterTo = "filter_to", filterSubject = "filter_subject", filterBody = "filter_body"
            case filterAttachmentFilenameInclude = "filter_attachment_filename_include"
            case filterAttachmentFilenameExclude = "filter_attachment_filename_exclude"
            case maximumAge = "maximum_age", actionParameter = "action_parameter", assignTitleFrom = "assign_title_from"
            case assignTags = "assign_tags", assignDocumentType = "assign_document_type"
            case assignCorrespondentFrom = "assign_correspondent_from", assignCorrespondent = "assign_correspondent"
            case assignOwnerFromRule = "assign_owner_from_rule", attachmentType = "attachment_type"
            case consumptionScope = "consumption_scope", pdfLayout = "pdf_layout", stopProcessing = "stop_processing"
        }

        public init() {}

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = Config()
            folder = try c.decodeIfPresent(String.self, forKey: .folder) ?? d.folder
            filterFrom = try c.decodeIfPresent(String.self, forKey: .filterFrom)
            filterTo = try c.decodeIfPresent(String.self, forKey: .filterTo)
            filterSubject = try c.decodeIfPresent(String.self, forKey: .filterSubject)
            filterBody = try c.decodeIfPresent(String.self, forKey: .filterBody)
            filterAttachmentFilenameInclude = try c.decodeIfPresent(String.self, forKey: .filterAttachmentFilenameInclude)
            filterAttachmentFilenameExclude = try c.decodeIfPresent(String.self, forKey: .filterAttachmentFilenameExclude)
            maximumAge = try c.decodeIfPresent(Int.self, forKey: .maximumAge) ?? d.maximumAge
            action = try c.decodeIfPresent(Action.self, forKey: .action) ?? d.action
            actionParameter = try c.decodeIfPresent(String.self, forKey: .actionParameter)
            assignTitleFrom = try c.decodeIfPresent(TitleSource.self, forKey: .assignTitleFrom) ?? d.assignTitleFrom
            assignTags = try c.decodeIfPresent([Int].self, forKey: .assignTags) ?? []
            assignDocumentType = try c.decodeIfPresent(Int.self, forKey: .assignDocumentType)
            assignCorrespondentFrom = try c.decodeIfPresent(CorrespondentSource.self, forKey: .assignCorrespondentFrom) ?? d.assignCorrespondentFrom
            assignCorrespondent = try c.decodeIfPresent(Int.self, forKey: .assignCorrespondent)
            assignOwnerFromRule = try c.decodeIfPresent(Bool.self, forKey: .assignOwnerFromRule) ?? true
            attachmentType = try c.decodeIfPresent(AttachmentProcessing.self, forKey: .attachmentType) ?? d.attachmentType
            consumptionScope = try c.decodeIfPresent(ConsumptionScope.self, forKey: .consumptionScope) ?? d.consumptionScope
            pdfLayout = try c.decodeIfPresent(Int.self, forKey: .pdfLayout) ?? 0
            stopProcessing = try c.decodeIfPresent(Bool.self, forKey: .stopProcessing) ?? false
        }
    }

    public var id: Int?
    public var name: String
    public var accountId: Int
    public var order: Int
    public var enabled: Bool
    public var ownerId: Int?
    public var config: Config

    public init(id: Int? = nil, name: String, accountId: Int, order: Int = 0, enabled: Bool = true, ownerId: Int? = nil, config: Config = .init()) {
        self.id = id; self.name = name; self.accountId = accountId; self.order = order
        self.enabled = enabled; self.ownerId = ownerId; self.config = config
    }
}

public struct ProcessedMail: IdentifiedRecord, Hashable {
    public static let databaseTableName = "processed_mail"
    public var id: Int?
    public var ruleId: Int
    public var folder: String
    public var uid: String
    public var subject: String
    public var received: Date?
    public var processed: Date
    public var status: String
    public var error: String?
    public var ownerId: Int?

    public init(ruleId: Int, folder: String, uid: String, subject: String, received: Date?, status: String, error: String? = nil, ownerId: Int? = nil) {
        self.ruleId = ruleId; self.folder = folder; self.uid = uid; self.subject = subject
        self.received = received; self.processed = Date(); self.status = status; self.error = error; self.ownerId = ownerId
    }
}

/// The parts of a parsed email that mail rules need. Implemented by the MIME parser.
public struct MailContent: Sendable {
    public struct Attachment: Sendable {
        public var filename: String
        public var contentType: String
        /// `Content-Disposition: attachment`. Inline parts (images in HTML mail) are false.
        public var isAttachment: Bool
        public var data: Data

        public init(filename: String, contentType: String, isAttachment: Bool, data: Data) {
            self.filename = filename; self.contentType = contentType; self.isAttachment = isAttachment; self.data = data
        }
    }

    public var subject: String
    public var fromAddress: String
    public var fromName: String?
    public var date: Date?
    public var attachments: [Attachment]

    public init(subject: String, fromAddress: String, fromName: String?, date: Date?, attachments: [Attachment]) {
        self.subject = subject; self.fromAddress = fromAddress; self.fromName = fromName; self.date = date; self.attachments = attachments
    }
}
