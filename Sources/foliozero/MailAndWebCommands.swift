import ArgumentParser
import FolioCore
import Foundation
import GRDB

struct AddURLCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "add-url",
        abstract: "Capture web pages (rendered to PDF with WebKit) or files behind URLs."
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "One or more http(s) URLs.") var urls: [String]
    @Option(name: .customLong("tag"), help: "Tag name or id. Repeat for several.") var tags: [String] = []
    @Option(help: "Title (single URL only).") var title: String?
    @Flag(help: "Create missing tags.") var create = false

    func run() async throws {
        let app = try global.openApp()
        if urls.count > 1 && title != nil { throw ValidationError("--title needs a single URL.") }
        let tagIds = try await app.database.write { [tags, create] db in
            try tags.map { try Lookup.resolve($0, Tag.self, create: create, in: db) { Tag(name: $0) } }
        }
        var failures = 0
        for text in urls {
            guard let url = URL(string: text), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                FileHandle.standardError.write(Data("✗ \(text): not an http(s) URL\n".utf8))
                failures += 1
                continue
            }
            do {
                let document = try await URLCapture.consume(url: url, app: app, overrides: DocumentOverrides(title: title, tagIds: tagIds))
                print("#\(document.id ?? 0)  \(document.title)  (\(document.mimeType), \(document.pageCount.map { "\($0) pages" } ?? "-"))")
            } catch {
                failures += 1
                FileHandle.standardError.write(Data("✗ \(text): \(error)\n".utf8))
            }
        }
        if failures > 0 { throw ExitCode(1) }
    }
}

struct MailCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mail",
        abstract: "Manage mail accounts and rules, and fetch mail.",
        subcommands: [Fetch.self, AddAccount.self, AddRule.self, List.self, Remove.self]
    )

    struct Fetch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check all accounts now and consume matching attachments.")
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let app = try global.openApp()
            let queue = TaskQueue(database: app.database, workers: app.settings.taskWorkers, logger: app.logger)
            let summary = await MailProcessor(app: app, queue: queue, parse: MailProcessor.mimeParser).processAll()
            await queue.waitUntilIdle()
            print("\(summary.messages) messages checked, \(summary.documents) documents queued.")
            summary.errors.forEach { FileHandle.standardError.write(Data("✗ \($0)\n".utf8)) }
            let failed = try await app.database.read { db in
                try TaskRecord.filter(Column("task_type") == "consume_file" && Column("status") == "failure").fetchCount(db)
            }
            if !summary.errors.isEmpty || failed > 0 { throw ExitCode(1) }
        }
    }

    struct AddAccount: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "add-account", abstract: "Add an IMAP account. Prompts for the password.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Account name.") var name: String
        @Option(help: "IMAP server host.") var server: String
        @Option(help: "Port (default 993 for ssl, 143 otherwise).") var port: Int?
        @Option(help: "none, ssl or starttls.") var security = "ssl"
        @Option(help: "Login name.") var username: String

        func run() async throws {
            let mode: IMAPClient.Security
            switch security.lowercased() {
            case "none": mode = .none
            case "ssl", "tls": mode = .ssl
            case "starttls": mode = .starttls
            default: throw ValidationError("--security must be none, ssl or starttls")
            }
            guard let password = Prompt.readSecret("Password for \(username): "), !password.isEmpty else {
                throw ValidationError("No password given")
            }
            let app = try global.openApp()
            // Check the login before saving.
            let client = IMAPClient(host: server, port: port ?? (mode == .ssl ? 993 : 143), security: mode)
            try await client.connect()
            try await client.login(username: username, password: password)
            let folders = try await client.listFolders()
            await client.logout()
            let account = try await app.database.write { [name, server, port, username] db in
                var account = MailAccount(name: name, config: .init(imapServer: server, imapPort: port, imapSecurity: mode, username: username, password: password))
                try account.insert(db)
                return account
            }
            print("Added account #\(account.id ?? 0) \(name). Folders: \(folders.joined(separator: ", "))")
        }
    }

    struct AddRule: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "add-rule", abstract: "Add a mail rule to an account.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Rule name.") var name: String
        @Option(help: "Account name or id.") var account: String
        @Option(help: "Folder to check.") var folder = "INBOX"
        @Option(help: "Only mail from this sender (IMAP FROM search).") var from: String?
        @Option(help: "Only mail whose subject contains this.") var subject: String?
        @Option(help: "Attachment filename patterns to include, e.g. '*.pdf'.") var include: String?
        @Option(help: "Maximum age in days (0 = any).") var maxAge = 30
        @Option(help: "After consuming: read, flag, move:<folder>, tag:<keyword>, delete.") var action = "read"
        @Option(help: "Title from: subject, filename, none.") var title = "subject"
        @Option(help: "Correspondent from: none, email, name, or a correspondent name/id.") var correspondent = "none"
        @Option(name: .customLong("tag"), help: "Tag name or id. Repeat for several.") var tags: [String] = []
        @Flag(help: "Consume the whole message as .eml (plus its attachments).") var wholeMessage = false
        @Flag(help: "Create missing tags and correspondents.") var create = false

        func run() async throws {
            let app = try global.openApp()
            let rule = try await app.database.write { [self] db -> MailRule in
                let accounts = try MailAccount.fetchAll(db)
                guard let target = accounts.first(where: { $0.name.caseInsensitiveCompare(account) == .orderedSame || String($0.id ?? -1) == account }) else {
                    throw ValidationError("No mail account \(account)")
                }
                var config = MailRule.Config()
                config.folder = folder
                config.filterFrom = from
                config.filterSubject = subject
                config.filterAttachmentFilenameInclude = include
                config.maximumAge = maxAge
                let parts = action.split(separator: ":", maxSplits: 1).map(String.init)
                switch parts[0].lowercased() {
                case "read": config.action = .markRead
                case "flag": config.action = .flag
                case "delete": config.action = .delete
                case "move": config.action = .move; config.actionParameter = parts.count > 1 ? parts[1] : nil
                case "tag": config.action = .tag; config.actionParameter = parts.count > 1 ? parts[1] : nil
                default: throw ValidationError("Unknown --action \(action)")
                }
                if (config.action == .move || config.action == .tag) && (config.actionParameter ?? "").isEmpty {
                    throw ValidationError("--action \(parts[0]) needs a value, e.g. \(parts[0]):Paperless")
                }
                switch title.lowercased() {
                case "subject": config.assignTitleFrom = .subject
                case "filename": config.assignTitleFrom = .filename
                case "none": config.assignTitleFrom = .none
                default: throw ValidationError("--title must be subject, filename or none")
                }
                switch correspondent.lowercased() {
                case "none": config.assignCorrespondentFrom = .nothing
                case "email": config.assignCorrespondentFrom = .email
                case "name": config.assignCorrespondentFrom = .name
                default:
                    config.assignCorrespondentFrom = .custom
                    config.assignCorrespondent = try Lookup.resolve(correspondent, Correspondent.self, create: create, in: db) { Correspondent(name: $0) }
                }
                config.assignTags = try tags.map { try Lookup.resolve($0, Tag.self, create: create, in: db) { Tag(name: $0) } }
                config.consumptionScope = wholeMessage ? .everything : .attachmentsOnly
                let order = (try Int.fetchOne(db, sql: "SELECT MAX(\"order\") FROM mail_rules WHERE account_id = ?", arguments: [target.id]) ?? -1) + 1
                var rule = MailRule(name: name, accountId: target.id!, order: order, config: config)
                try rule.insert(db)
                return rule
            }
            print("Added rule #\(rule.id ?? 0) \(rule.name).")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List mail accounts and rules.")
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let app = try global.openApp()
            let (accounts, rules) = try await app.database.read { db in (try MailAccount.fetchAll(db), try MailRule.order(Column("order")).fetchAll(db)) }
            if accounts.isEmpty { print("No mail accounts."); return }
            for account in accounts {
                print("Account #\(account.id ?? 0) \(account.name): \(account.config.username)@\(account.config.imapServer):\(account.config.effectivePort)")
                for rule in rules where rule.accountId == account.id {
                    let c = rule.config
                    print("  Rule #\(rule.id ?? 0) \(rule.name)\(rule.enabled ? "" : " (disabled)"): folder \(c.folder), action \(c.action)\(c.actionParameter.map { ":\($0)" } ?? ""), max age \(c.maximumAge) days")
                }
            }
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove a mail account (with its rules) or a single rule.")
        @OptionGroup var global: GlobalOptions
        @Option(help: "Account id.") var account: Int?
        @Option(help: "Rule id.") var rule: Int?

        func run() async throws {
            guard (account == nil) != (rule == nil) else { throw ValidationError("Give exactly one of --account or --rule.") }
            let app = try global.openApp()
            let removed = try await app.database.write { [account, rule] db in
                if let account { return try MailAccount.deleteOne(db, key: account) }
                return try MailRule.deleteOne(db, key: rule!)
            }
            print(removed ? "Removed." : "Not found.")
        }
    }
}
