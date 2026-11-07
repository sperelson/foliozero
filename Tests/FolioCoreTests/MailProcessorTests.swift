import Foundation
import GRDB
import Testing
@testable import FolioCore

@Suite(.serialized) struct MailProcessorTests {
    func makeApp(_ dir: TempDir) throws -> FolioApp {
        let settings = try SettingsLoader.load(home: dir.url.path, environment: [:], overrides: ["TIME_ZONE": "UTC"])
        return try FolioApp.open(settings: settings)
    }

    @Test func criteriaFollowActionAndFilters() {
        var config = MailRule.Config()
        config.filterFrom = "bank"
        config.maximumAge = 0
        #expect(MailProcessor.criteria(for: config).map(\.keyword) == ["UNSEEN", "FROM"])
        config.action = .tag
        config.actionParameter = "paperless"
        #expect(MailProcessor.criteria(for: config).first?.keyword == "UNKEYWORD paperless")
        config.action = .move
        config.maximumAge = 30
        #expect(MailProcessor.criteria(for: config).first?.keyword.hasPrefix("SINCE") == true)
        #expect(MailProcessor.flagsForTag("apple:green") == ["\\Flagged", "$MailFlagBit0", "$MailFlagBit1"])
        #expect(MailProcessor.flagsForTag("archived") == ["archived"])
    }

    @Test func attachmentFilters() {
        #expect(MailProcessor.filenameIncluded(nil, "a.pdf"))
        #expect(MailProcessor.filenameIncluded("*.pdf, *.jpg", "SCAN.PDF"))
        #expect(!MailProcessor.filenameIncluded("*.pdf", "logo.png"))
        #expect(MailProcessor.filenameExcluded("logo*", "logo.png"))
        #expect(!MailProcessor.filenameExcluded(nil, "logo.png"))
    }

    @Test func consumesAttachmentsAndMarksMessages() async throws {
        let dir = TempDir()
        let app = try makeApp(dir)
        let pdfURL = dir.file("statement.pdf")
        makeTextPDF("Mail statement 4711", at: pdfURL)
        let pdf = try Data(contentsOf: pdfURL)

        let server = try FakeIMAPServer(message: Data("raw".utf8))
        defer { server.stop() }

        let (accountId, tagId) = try await app.database.write { db -> (Int, Int) in
            var tag = Tag(name: "Mail"); try tag.insert(db)
            var account = MailAccount(name: "Test", config: .init(imapServer: "127.0.0.1", imapPort: server.port, imapSecurity: .none, username: "me", password: "secret"))
            try account.insert(db)
            var config = MailRule.Config()
            config.assignTags = [tag.id!]
            config.assignCorrespondentFrom = .name
            config.filterAttachmentFilenameExclude = "logo*"
            var rule = MailRule(name: "Statements", accountId: account.id!, config: config)
            try rule.insert(db)
            return (account.id!, tag.id!)
        }

        let queue = TaskQueue(database: app.database, workers: 1, logger: app.logger)
        let processor = MailProcessor(app: app, queue: queue, parse: { _ in
            MailContent(subject: "Your statement", fromAddress: "noreply@bank.example", fromName: "First Bank", date: Date(), attachments: [
                .init(filename: "statement.pdf", contentType: "application/pdf", isAttachment: true, data: pdf),
                .init(filename: "logo.png", contentType: "image/png", isAttachment: true, data: Data([0x89, 0x50, 0x4E, 0x47])),
                .init(filename: "inline.pdf", contentType: "application/pdf", isAttachment: false, data: pdf),
            ])
        }, connect: { config in
            let client = IMAPClient(host: config.imapServer, port: config.effectivePort, security: .none, timeout: 5)
            try await client.connect()
            try await client.login(username: config.username, password: config.password)
            return client
        })

        let account = try await app.database.read { db in try MailAccount.fetchOne(db, key: accountId)! }
        let summary = await processor.process(account: account)
        await queue.waitUntilIdle()

        // The fake server returns UIDs 7 and 9; each yields one attachment.
        #expect(summary.messages == 2)
        #expect(summary.documents == 2)
        #expect(summary.errors.isEmpty)
        let documents = try await app.database.read { db in try Document.fetchAll(db) }
        #expect(documents.count == 2)
        #expect(documents.allSatisfy { $0.title == "Your statement" })
        let correspondent = try await app.database.read { db in try Correspondent.fetchOne(db, key: documents[0].correspondentId!)?.name }
        #expect(correspondent == "First Bank")
        let tags = try await app.database.read { db in try DocumentStore.tagIds(of: documents[0].id!, in: db) }
        #expect(tags == [tagId])
        #expect(server.commands.contains { $0.hasSuffix("UID STORE 7 +FLAGS (\\Seen)") })

        // A second run skips the processed UIDs.
        let again = await processor.process(account: account)
        #expect(again.messages == 0)
    }
}
