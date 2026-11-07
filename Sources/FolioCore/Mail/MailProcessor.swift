import Darwin
import Foundation
import FolioParsing
import GRDB
import Logging

/// Fetches mail for every account and applies the rules (Paperless-ngx `paperless_mail/mail.py`).
public struct MailProcessor: Sendable {
    public typealias Parse = @Sendable (Data) throws -> MailContent
    /// Connects to an account's server; replaced in tests.
    public typealias Connect = @Sendable (MailAccount.Config) async throws -> IMAPClient

    public let app: FolioApp
    public let queue: TaskQueue
    public let parse: Parse
    public let connect: Connect
    /// Refreshes expired Gmail and Outlook access tokens.
    public let oauth: MailOAuth

    public init(app: FolioApp, queue: TaskQueue, parse: @escaping Parse, connect: Connect? = nil, oauth: MailOAuth? = nil) {
        self.app = app
        self.queue = queue
        self.parse = parse
        self.oauth = oauth ?? MailOAuth(settings: app.settings)
        self.connect = connect ?? { config in
            let client = IMAPClient(host: config.imapServer, port: config.effectivePort, security: config.imapSecurity)
            try await client.connect()
            try await client.login(account: config)
            return client
        }
    }

    var logger: Logger { app.logger }

    public struct Summary: Sendable, Equatable {
        public var messages = 0
        public var documents = 0
        public var errors: [String] = []
    }

    /// Processes every account. Errors in one account do not stop the others.
    public func processAll() async -> Summary {
        var total = Summary()
        let accounts = (try? await app.database.read { db in try MailAccount.order(Column("name")).fetchAll(db) }) ?? []
        for account in accounts {
            let summary = await process(account: account)
            total.messages += summary.messages
            total.documents += summary.documents
            total.errors += summary.errors
        }
        return total
    }

    public func process(account: MailAccount) async -> Summary {
        var account = account
        var summary = Summary()
        guard let accountId = account.id else { return summary }
        let rules: [MailRule]
        do {
            rules = try await app.database.read { db in
                try MailRule.filter(Column("account_id") == accountId && Column("enabled") == true)
                    .order(Column("order"), Column("id")).fetchAll(db)
            }
        } catch {
            summary.errors.append("\(account.name): \(error)")
            return summary
        }
        guard !rules.isEmpty else { return summary }

        if !app.settings.emailAllowInternalHosts, NetworkPolicy.isInternal(host: account.config.imapServer) {
            let message = "\(account.name): mail server \(account.config.imapServer) is an internal address and EMAIL_ALLOW_INTERNAL_HOSTS is off"
            logger.error("\(message)")
            summary.errors.append(message)
            return summary
        }

        if account.config.needsTokenRefresh() {
            do {
                account = try await oauth.refreshAccessToken(of: account, in: app.database)
            } catch {
                let message = "Failed to refresh oauth token for account \(account.name): \(error)"
                logger.error("\(message)")
                summary.errors.append(message)
                return summary
            }
        }

        let client: IMAPClient
        do {
            client = try await connect(account.config)
        } catch {
            logger.error("Mail account \(account.name): \(error)")
            summary.errors.append("\(account.name): \(error)")
            return summary
        }
        for rule in rules {
            do {
                let processed = try await process(rule: rule, client: client, summary: &summary)
                if processed > 0 && rule.config.stopProcessing {
                    logger.info("Rule \(rule.name): stopping rule processing (stop_processing)")
                    break
                }
            } catch {
                logger.error("Rule \(rule.name): \(error)")
                summary.errors.append("\(rule.name): \(error)")
            }
        }
        await client.logout()
        return summary
    }

    /// Returns the number of documents queued.
    func process(rule: MailRule, client: IMAPClient, summary: inout Summary) async throws -> Int {
        guard let ruleId = rule.id else { return 0 }
        let config = rule.config
        try await client.select(config.folder)
        let uids = try await client.search(Self.criteria(for: config))
        let alreadyDone = try await app.database.read { db in
            Set(try String.fetchAll(db, sql: "SELECT uid FROM processed_mail WHERE rule_id = ? AND folder = ?", arguments: [ruleId, config.folder]))
        }
        var queued = 0
        for uid in uids where !alreadyDone.contains(String(uid)) {
            summary.messages += 1
            let fetched = try await client.fetch(uid: uid)
            var status = "SUCCESS"
            var errorText: String?
            var subject = ""
            var received: Date?
            do {
                let mail = try parse(fetched.raw)
                subject = mail.subject
                received = mail.date
                let count = try await consume(mail: mail, raw: fetched.raw, rule: rule)
                queued += count
                summary.documents += count
                if count > 0 {
                    try await apply(action: config, uid: uid, client: client)
                } else {
                    status = "PROCESSED_WO_CONSUMPTION"
                }
            } catch {
                status = "FAILED"
                errorText = "\(error)"
                summary.errors.append("\(rule.name) UID \(uid): \(error)")
                logger.error("Rule \(rule.name): message \(uid) failed: \(error)")
            }
            let record = ProcessedMail(ruleId: ruleId, folder: config.folder, uid: String(uid), subject: String(subject.prefix(256)), received: received, status: status, error: errorText, ownerId: rule.ownerId)
            try await app.database.write { db in
                var record = record
                try record.insert(db, onConflict: .ignore)
            }
        }
        return queued
    }

    /// IMAP search keys: the action's "not yet handled" key plus the rule's filters.
    static func criteria(for config: MailRule.Config, now: Date = Date()) -> [IMAPClient.SearchKey] {
        var keys: [IMAPClient.SearchKey] = []
        switch config.action {
        case .markRead: keys.append(.unseen)
        case .flag: keys.append(.unflagged)
        case .tag:
            if let tag = config.actionParameter, !tag.isEmpty {
                keys.append(tag.lowercased().hasPrefix("apple:") ? .unflagged : .unkeyword(tag))
            }
        case .delete, .move: break
        }
        if config.maximumAge > 0 { keys.append(.since(now.addingTimeInterval(-Double(config.maximumAge) * 86_400))) }
        if let v = config.filterFrom, !v.isEmpty { keys.append(.from(v)) }
        if let v = config.filterTo, !v.isEmpty { keys.append(.to(v)) }
        if let v = config.filterSubject, !v.isEmpty { keys.append(.subject(v)) }
        if let v = config.filterBody, !v.isEmpty { keys.append(.body(v)) }
        return keys
    }

    func apply(action config: MailRule.Config, uid: UInt32, client: IMAPClient) async throws {
        switch config.action {
        case .delete: try await client.delete(uid: uid)
        case .markRead: try await client.addFlags(["\\Seen"], uid: uid)
        case .flag: try await client.addFlags(["\\Flagged"], uid: uid)
        case .move:
            guard let folder = config.actionParameter, !folder.isEmpty else { return }
            try await client.move(uid: uid, to: folder)
        case .tag:
            guard let tag = config.actionParameter, !tag.isEmpty else { return }
            try await client.addFlags(Self.flagsForTag(tag), uid: uid)
        }
    }

    /// `apple:<color>` maps to Apple Mail's flag colour bits; anything else is an IMAP keyword.
    static func flagsForTag(_ tag: String) -> [String] {
        guard tag.lowercased().hasPrefix("apple:") else { return [tag] }
        let bits: [String: [Int]] = [
            "red": [], "orange": [0], "yellow": [1], "green": [0, 1], "blue": [2], "violet": [0, 2], "purple": [0, 2], "grey": [1, 2], "gray": [1, 2],
        ]
        let color = String(tag.dropFirst(6)).lowercased()
        return ["\\Flagged"] + (bits[color] ?? []).map { "$MailFlagBit\($0)" }
    }

    // MARK: Consumption

    func consume(mail: MailContent, raw: Data, rule: MailRule) async throws -> Int {
        let config = rule.config
        let workDir = app.settings.scratchDir.appendingPathComponent("mail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let correspondentId = try await correspondent(for: mail, config: config)
        let consumer = app.consumer()
        var count = 0

        func overrides(title: String?) -> DocumentOverrides {
            var o = DocumentOverrides()
            o.title = title
            o.correspondentId = correspondentId
            o.documentTypeId = config.assignDocumentType
            o.tagIds = config.assignTags
            if config.assignOwnerFromRule { o.ownerId = rule.ownerId }
            return o
        }

        if config.consumptionScope == .emlOnly || config.consumptionScope == .everything {
            let url = workDir.appendingPathComponent(FileNamer.sanitize(mail.subject.isEmpty ? "message" : String(mail.subject.prefix(100))) + ".eml")
            try raw.write(to: url)
            let title = config.assignTitleFrom == .none ? nil : mail.subject
            let request = ConsumeRequest(file: url, source: .mailFetch, overrides: overrides(title: title), deleteSource: true, mailRuleId: rule.id)
            try await queue.enqueueConsume(request, consumer: consumer, ownerId: rule.ownerId)
            count += 1
        }

        if config.consumptionScope == .attachmentsOnly || config.consumptionScope == .everything {
            for attachment in mail.attachments {
                if !attachment.isAttachment && config.attachmentType == .attachmentsOnly { continue }
                let name = attachment.filename.isEmpty ? "attachment" : attachment.filename
                guard Self.filenameIncluded(config.filterAttachmentFilenameInclude, name),
                      !Self.filenameExcluded(config.filterAttachmentFilenameExclude, name) else { continue }
                let mime = FileTypeDetector.mimeType(of: attachment.data, fileName: name)
                guard app.parsers.isSupported(mime) else {
                    logger.info("Rule \(rule.name): skipping attachment \(name) (\(mime) not supported)")
                    continue
                }
                let url = workDir.appendingPathComponent(UUID().uuidString, isDirectory: true).appendingPathComponent(FileNamer.sanitize(name))
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try attachment.data.write(to: url)
                let title: String? = switch config.assignTitleFrom {
                case .subject: mail.subject.precomposedStringWithCanonicalMapping
                case .filename: ((name as NSString).deletingPathExtension).precomposedStringWithCanonicalMapping
                case .none: nil
                }
                let request = ConsumeRequest(file: url, originalFilename: name, source: .mailFetch, overrides: overrides(title: title), deleteSource: true, mailRuleId: rule.id)
                try await queue.enqueueConsume(request, consumer: consumer, ownerId: rule.ownerId)
                count += 1
            }
        }
        return count
    }

    func correspondent(for mail: MailContent, config: MailRule.Config) async throws -> Int? {
        let name: String?
        switch config.assignCorrespondentFrom {
        case .nothing: return nil
        case .custom: return config.assignCorrespondent
        case .email: name = mail.fromAddress
        case .name: name = (mail.fromName?.isEmpty == false) ? mail.fromName : mail.fromAddress
        }
        guard let name, !name.isEmpty else { return nil }
        return try await app.database.write { db in
            if let existing = try Correspondent.filter(sql: "name = ? COLLATE NOCASE AND owner_id IS NULL", arguments: [name]).fetchOne(db) {
                return existing.id
            }
            var created = Correspondent(name: name, matchingAlgorithm: .none)
            try created.insert(db)
            return created.id
        }
    }

    static func filenameIncluded(_ patterns: String?, _ name: String) -> Bool {
        guard let patterns, !patterns.isEmpty else { return true }
        return patterns.split(separator: ",").contains { fnmatch($0.trimmingCharacters(in: .whitespaces).lowercased(), name.lowercased(), 0) == 0 }
    }

    static func filenameExcluded(_ patterns: String?, _ name: String) -> Bool {
        guard let patterns, !patterns.isEmpty else { return false }
        return patterns.split(separator: ",").contains { fnmatch($0.trimmingCharacters(in: .whitespaces).lowercased(), name.lowercased(), 0) == 0 }
    }
}
