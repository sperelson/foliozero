import CoreGraphics
import CoreText
import Foundation
import GRDB
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import FolioCore

// MARK: - Crypto

@Suite struct TransferCryptoTests {
    /// https://github.com/fernet/spec/blob/master/generate.json
    @Test func fernetSpecVector() throws {
        let fernet = try Fernet(base64URLKey: "cw_0x689RpI-jtRR7oE8h_eQsKImvJapLeSbXpwF4e4=")
        let token = "gAAAAAAdwJ6wAAECAwQFBgcICQoLDA0ODy021cpGVWKZ_eEwCGM4BLLF_5CV9dOPmrhuVUPgJobwOz7JcbmrR64jVmpU4IwqDA=="
        #expect(String(data: try fernet.decrypt(token: token), encoding: .utf8) == "hello")
        let made = try fernet.encrypt(Data("hello".utf8), iv: Data(0..<16), timestamp: Date(timeIntervalSince1970: 499_162_800))
        #expect(made == token)
        // A changed byte fails the HMAC.
        var tampered = Array(token)
        tampered[20] = tampered[20] == "A" ? "B" : "A"
        #expect(throws: FernetError.invalidToken) { try fernet.decrypt(token: String(tampered)) }
    }

    /// Value produced the way Paperless-ngx's CryptMixin does (PBKDF2-SHA256 key, Fernet, hex),
    /// computed independently with Python hashlib/hmac and openssl.
    @Test func paperlessEncryptedField() throws {
        let crypto = try ExportCrypto(passphrase: "correct horse", saltHex: "00112233445566778899aabbccddeeff", iterations: 1000)
        #expect(try crypto.decrypt(TransferFixture.encryptedPassword) == "imap-sëcret")
        #expect(try crypto.decrypt(TransferFixture.encryptedRefreshToken) == "refresh-tok")
        // Round trip with a fresh salt.
        let fresh = try ExportCrypto.generate(passphrase: "pw", iterations: 1000)
        #expect(try fresh.decrypt(try fresh.encrypt("x y z")) == "x y z")
        let wrong = try ExportCrypto(passphrase: "wrong", saltHex: "00112233445566778899aabbccddeeff", iterations: 1000)
        #expect(throws: (any Error).self) { try wrong.decrypt(TransferFixture.encryptedPassword) }
    }

    @Test func djangoDates() {
        let expected = Date(timeIntervalSince1970: 1_710_411_630.123)
        #expect(abs(DjangoTime.parseDateTime("2024-03-14T10:20:30.123Z")!.timeIntervalSince(expected)) < 0.001)
        #expect(abs(DjangoTime.parseDateTime("2024-03-14T12:20:30.123456+02:00")!.timeIntervalSince(expected)) < 0.001)
        #expect(DjangoTime.parseDateTime("2024-03-14T10:20:30Z") == Date(timeIntervalSince1970: 1_710_411_630))
        #expect(DjangoTime.parseDateTime("2024-03-14") == Date(timeIntervalSince1970: 1_710_374_400))
        #expect(DjangoTime.parseDateTime("garbage") == nil)
        #expect(DjangoTime.format(expected) == "2024-03-14T10:20:30.123Z")
        #expect(DjangoTime.format(Date(timeIntervalSince1970: 1_710_411_630)) == "2024-03-14T10:20:30Z")
        let johannesburg = TimeZone(identifier: "Africa/Johannesburg")!
        #expect(DjangoTime.parseCalendarDate("2023-06-30T22:30:00Z", timeZone: johannesburg) == CalendarDate(year: 2023, month: 7, day: 1))
        #expect(DjangoTime.parseCalendarDate("2023-06-30", timeZone: johannesburg) == CalendarDate(year: 2023, month: 6, day: 30))
    }

    @Test func catalogCoversFolioZeroPermissions() {
        let tables = PaperlessCatalog.tables()
        let missing = Permission.all.filter { tables.permissionByCodename[$0] == nil }
        #expect(missing == [])
    }
}

// MARK: - Import and export

@Suite(.serialized) struct TransferTests {
    func makeApp(_ dir: TempDir, _ name: String = "home", overrides: [String: String] = [:]) throws -> FolioApp {
        var values = ["TIME_ZONE": "UTC"]
        values.merge(overrides) { _, new in new }
        let settings = try SettingsLoader.load(home: dir.url.appendingPathComponent(name).path, environment: [:], overrides: values)
        return try FolioApp.open(settings: settings)
    }

    @Test func importsPaperlessExport() async throws {
        let dir = TempDir()
        let fixture = try TransferFixture.write(to: dir.url.appendingPathComponent("export"))
        let app = try makeApp(dir)
        let report = try await PaperlessImporter.run(app: app, source: fixture.root, options: .init(passphrase: "correct horse"))

        #expect(report.sourceVersion == "3.4.2")
        #expect(report.count("users") == 3)
        #expect(report.count("documents") == 3)
        #expect(report.count("document versions") == 1)
        #expect(report.count("notes") == 2)
        #expect(report.count("object permissions") == 2)
        #expect(report.count("audit log entries") == 3)
        #expect(report.skippedCount("auth.user AnonymousUser") == 1)
        #expect(report.skippedCount("documents.foo") == 1)
        #expect(report.skippedCount("documents.sharelinkbundle") == 1)
        #expect(report.skippedCount("socialaccount.socialtoken") == 1)
        #expect(report.skippedCount("auditlog.logentry (access entries)") == 1)
        #expect(report.warnings.contains { $0.contains("legacy") && $0.contains("argon2") })

        try await app.database.write { db in
            // Users, passwords, groups, permissions.
            #expect(try UserStore.authenticate(username: "thandi", password: "thandi-pass", in: db)?.id == 2)
            #expect(try UserStore.authenticate(username: "thandi", password: "wrong", in: db) == nil)
            #expect(try UserStore.user(named: "AnonymousUser", in: db) == nil)
            let context = try #require(try AccessContext.load(userId: 2, in: db))
            #expect(context.groupIds == [1])
            #expect(context.permissions == ["view_document", "change_document", "view_global_statistics", "change_applicationconfiguration", "view_tag"])
            #expect(try Set(String.fetchAll(db, sql: "SELECT codename FROM group_permissions WHERE group_id = 1")) == ["view_document", "view_tag"])
            let permissions = try PermissionSet.load(objectType: "document", objectId: 1, in: db)
            #expect(permissions.view.users == [3])
            #expect(permissions.change.groups == [1])
            #expect(try String.fetchOne(db, sql: "SELECT settings FROM ui_settings WHERE user_id = 2")?.contains("en-ZA") == true)

            // Classification objects.
            #expect(try Tag.fetchOne(db, key: 2)?.parentId == 1)
            #expect(try Tag.fetchOne(db, key: 3)?.isInboxTag == true)
            #expect(try Correspondent.fetchOne(db, key: 1)?.ownerId == 2)
            #expect(try StoragePath.fetchOne(db, key: 1)?.path == "{{ correspondent }}/{{ title }}")

            // Documents and files.
            let doc1 = try #require(try Document.fetchOne(db, key: 1))
            #expect(doc1.filename == "0000001.pdf")
            #expect(doc1.archiveFilename == "0000001.pdf")
            #expect(doc1.archiveSerialNumber == 42)
            #expect(doc1.created == CalendarDate(year: 2024, month: 3, day: 14))
            #expect(doc1.checksum == fixture.checksums["doc1"])
            #expect(doc1.archiveChecksum == fixture.checksums["doc1-archive"])
            #expect(doc1.originalMetadata != nil)
            #expect(try DocumentStore.tagIds(of: 1, in: db) == [1, 2])
            let original = app.storage.originalsDir.appendingPathComponent("0000001.pdf")
            #expect(try Checksum.sha256(of: original) == doc1.checksum)
            #expect(FileManager.default.fileExists(atPath: app.storage.archiveDir.appendingPathComponent("0000001.pdf").path))

            let doc2 = try #require(try Document.fetchOne(db, key: 2))
            #expect(doc2.filename == "City of Cape Town/Rates notice.txt")
            #expect(doc2.checksum == fixture.checksums["doc2"]) // recomputed SHA-256; the manifest had MD5
            #expect(doc2.created == CalendarDate(year: 2023, month: 6, day: 30))
            #expect(doc2.archiveFilename == nil)

            let version = try #require(try Document.fetchOne(db, key: 3))
            #expect(version.rootDocumentId == 1 && version.versionIndex == 1 && version.versionLabel == "signed")
            #expect(version.filename == "0000001_v1.pdf")

            let trashed = try #require(try Document.fetchOne(db, key: 4))
            #expect(trashed.deletedAt != nil)
            #expect(try Note.fetchOne(db, key: 2)?.documentId == 4) // from the split manifest

            // Custom fields, including pre-2.12 select options.
            let priority = try #require(try CustomField.fetchOne(db, key: 2))
            let options = try #require(priority.extraData?.selectOptions)
            #expect(options.map(\.label) == ["Low", "High"])
            let selected = try CustomFieldInstance.fetchOne(db, key: 2)
            #expect(selected?.valueSelect == options[1].id)
            #expect(try CustomFieldInstance.fetchOne(db, key: 1)?.valueMonetary == "ZAR123.45")
            #expect(try CustomFieldInstance.fetchOne(db, key: 3)?.valueDocumentIds == [2])
            #expect(try CustomFieldInstance.fetchOne(db, key: 5)?.valueDate == CalendarDate(year: 2024, month: 4, day: 1))
            #expect(try CustomField.fetchOne(db, key: 1)?.extraData?.defaultCurrency == "ZAR")
            #expect(try DocumentBarcode.fetchOne(db, key: 1)?.value == "ASN00042")

            // Views and sharing.
            let view = try #require(try SavedView.fetchOne(db, key: 1))
            #expect(view.showOnDashboard && !view.showInSidebar)
            #expect(view.displayFields == ["title", "created"])
            #expect(try SavedViewFilterRule.fetchOne(db, key: 1)?.value == "1")
            #expect(try ShareLink.fetchOne(db, key: 1)?.fileVersion == .original)

            // Workflows.
            let trigger = try #require(try WorkflowTrigger.fetchOne(db, key: 1))
            #expect(trigger.workflowId == 1 && trigger.config.sources == [1, 2, 3] && trigger.config.filterFilename == "*.pdf")
            #expect(trigger.config.filterHasTags == [1])
            let actions = try WorkflowAction.filter(Column("workflow_id") == 1).order(Column("order")).fetchAll(db)
            #expect(actions.map(\.type) == [.assignment, .email, .webhook])
            #expect(actions[0].config.assignTitle == "Bill {{ correspondent }}")
            #expect(actions[0].config.assignOwner == 2)
            #expect(actions[1].config.email?.subject == "New bill")
            #expect(actions[2].config.webhook?.params == ["a": "b", "n": "1"])
            #expect(actions[2].config.webhook?.headers == ["X-Key": "v"])

            // Mail, with decrypted secrets.
            let account = try #require(try MailAccount.fetchOne(db, key: 1))
            #expect(account.config.password == "imap-sëcret")
            #expect(account.config.refreshToken == "refresh-tok")
            #expect(account.config.imapSecurity == .ssl)
            #expect(account.config.expiration == DjangoTime.parseDateTime("2026-01-01T00:00:00Z"))
            let rule = try #require(try MailRule.fetchOne(db, key: 1))
            #expect(rule.config.filterFrom == "billing@eskom.co.za" && rule.config.assignCorrespondentFrom == .custom && rule.config.assignTags == [1])
            #expect(try ProcessedMail.fetchOne(db, key: 1)?.uid == "123")

            // History, tasks, config.
            let history = try AuditLog.entries(objectType: "document", objectId: 1, in: db)
            #expect(history.count == 3)
            #expect(history.first { $0.id == 2 }?.changes?["title"] == ["Old", "Electricity March"])
            #expect(history.first { $0.id == 3 }?.changes?["tags"] == [nil, "Finance"])
            #expect(try TaskRecord.fetchOne(db, key: 1)?.relatedDocumentId == 1)
            #expect(try String.fetchOne(db, sql: "SELECT config FROM app_config WHERE id = 1")?.contains("pdfa") == true)

            // Search index.
            let hits = try SearchIndex.search(SearchIndex.simpleQuery("electricity", titleOnly: false), in: db)
            #expect(hits.map(\.documentId) == [1])
            #expect(try SearchIndex.search(SearchQueryParser().parse("notes:paid"), in: db).map(\.documentId) == [1])
        }

        // Thumbnails: converted from the export (PNG content) and generated where missing.
        for id in [1, 2] {
            let data = try Data(contentsOf: app.storage.thumbnailURL(documentId: id))
            #expect(data.prefix(2) == Data([0xFF, 0xD8]), "thumbnail \(id) is not a JPEG")
        }
        #expect(report.count("thumbnails") == 1)
        #expect(report.count("thumbnails generated") == 3)
        #expect(report.messages.contains { $0.contains("Classifier") || $0.contains("automatic matching") })
    }

    @Test func importsZipWithoutPassphrase() async throws {
        let dir = TempDir()
        let fixture = try TransferFixture.write(to: dir.url.appendingPathComponent("export"))
        let zip = dir.url.appendingPathComponent("export-2026-11-07.zip")
        let sink = try ZipExportSink(target: dir.url, name: "export-2026-11-07", delete: false)
        for path in TransferPaths.files(under: fixture.root) {
            try sink.addFile(fixture.root.appendingPathComponent(path), as: path)
        }
        try sink.finish()
        let app = try makeApp(dir)
        let report = try await PaperlessImporter.run(app: app, source: zip)
        #expect(report.count("documents") == 3)
        #expect(report.warnings.contains { $0.contains("no passphrase") })
        let account = try await app.database.read { db in try MailAccount.fetchOne(db, key: 1) }
        #expect(account?.config.password == "")
        #expect(account?.config.refreshToken == nil)
        #expect(FileManager.default.fileExists(atPath: app.storage.originalsDir.appendingPathComponent("0000001.pdf").path))
        // The temporary extraction is gone.
        let scratch = try FileManager.default.contentsOfDirectory(atPath: app.settings.scratchDir.path)
        #expect(scratch.filter { $0.hasPrefix("import") }.isEmpty)
    }

    @Test func refusesNonEmptyDatabase() async throws {
        let dir = TempDir()
        let fixture = try TransferFixture.write(to: dir.url.appendingPathComponent("export"))
        let app = try makeApp(dir)
        try await app.database.write { db in _ = try UserStore.createUser(username: "admin", password: "x", in: db) }
        await #expect(throws: TransferError.self) {
            try await PaperlessImporter.run(app: app, source: fixture.root, options: .init(passphrase: "correct horse"))
        }
    }

    @Test func failedImportLeavesNothingBehind() async throws {
        let dir = TempDir()
        let fixture = try TransferFixture.write(to: dir.url.appendingPathComponent("export"), corruptDocument2: true)
        let app = try makeApp(dir)
        do {
            _ = try await PaperlessImporter.run(app: app, source: fixture.root, options: .init(passphrase: "correct horse"))
            Issue.record("import should fail on the checksum mismatch")
        } catch let error as TransferError {
            #expect("\(error)".contains("Checksum mismatch for document 2"))
        }
        let counts = try await app.database.read { db in
            (try Document.fetchCount(db), try User.fetchCount(db), try Tag.fetchCount(db))
        }
        #expect(counts.0 == 0 && counts.1 == 0 && counts.2 == 0)
        #expect(TransferPaths.files(under: app.storage.originalsDir).isEmpty)
        #expect(TransferPaths.files(under: app.storage.archiveDir).isEmpty)
        #expect(TransferPaths.files(under: app.storage.thumbnailDir).isEmpty)

        // The same export imports with checksum verification off.
        let report = try await PaperlessImporter.run(app: app, source: fixture.root, options: .init(passphrase: "correct horse", verifyChecksums: false))
        #expect(report.warnings.contains { $0.contains("does not match its checksum") })
    }

    @Test func exportIsPaperlessCompatible() async throws {
        let dir = TempDir()
        let fixture = try TransferFixture.write(to: dir.url.appendingPathComponent("export"))
        let app = try makeApp(dir)
        _ = try await PaperlessImporter.run(app: app, source: fixture.root, options: .init(passphrase: "correct horse"))
        try await app.database.write { db in
            try db.execute(sql: "UPDATE app_config SET config = json_set(config, '$.foliozero_only', 1) WHERE id = 1")
        }

        let target = dir.url.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: target.appendingPathComponent("stale.pdf"))
        let report = try await PaperlessExporter.run(app: app, target: target, options: .init(delete: true))
        #expect(report.count("documents.document") == 4)
        #expect(report.warnings.contains { $0.contains("foliozero_only") })
        #expect(!FileManager.default.fileExists(atPath: target.appendingPathComponent("stale.pdf").path))

        let metadata = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: target.appendingPathComponent("metadata.json")))
        #expect(metadata.manifestObject?["version"]?.stringValue == "3.4.2")
        #expect(metadata.manifestObject?[ExportCrypto.metadataKey] == nil)

        let records = try PaperlessImporter.decodeManifest(target.appendingPathComponent("manifest.json"))
        let byModel = Dictionary(grouping: records, by: \.model)
        func pks(_ model: String) -> Set<Int> { Set(byModel[model, default: []].compactMap(\.id)) }

        // Every foreign key resolves, as Paperless-ngx's check_constraints requires.
        let references: [(model: String, field: String, target: String)] = [
            ("documents.document", "owner", "auth.user"), ("documents.document", "correspondent", "documents.correspondent"),
            ("documents.document", "document_type", "documents.documenttype"), ("documents.document", "storage_path", "documents.storagepath"),
            ("documents.document", "root_document", "documents.document"), ("documents.document", "tags", "documents.tag"),
            ("documents.tag", "tn_parent", "documents.tag"), ("auth.user", "groups", "auth.group"),
            ("auth.user", "user_permissions", "auth.permission"), ("auth.group", "permissions", "auth.permission"),
            ("auth.permission", "content_type", "contenttypes.contenttype"),
            ("guardian.userobjectpermission", "permission", "auth.permission"), ("guardian.userobjectpermission", "user", "auth.user"),
            ("guardian.userobjectpermission", "content_type", "contenttypes.contenttype"),
            ("guardian.groupobjectpermission", "group", "auth.group"), ("documents.note", "document", "documents.document"),
            ("documents.customfieldinstance", "field", "documents.customfield"), ("documents.sharelink", "document", "documents.document"),
            ("documents.savedviewfilterrule", "saved_view", "documents.savedview"), ("documents.uisettings", "user", "auth.user"),
            ("documents.workflow", "triggers", "documents.workflowtrigger"), ("documents.workflow", "actions", "documents.workflowaction"),
            ("documents.workflowaction", "email", "documents.workflowactionemail"), ("documents.workflowaction", "webhook", "documents.workflowactionwebhook"),
            ("documents.workflowaction", "assign_tags", "documents.tag"), ("documents.workflowtrigger", "filter_has_tags", "documents.tag"),
            ("paperless_mail.mailrule", "account", "paperless_mail.mailaccount"), ("paperless_mail.mailrule", "assign_tags", "documents.tag"),
            ("paperless_mail.processedmail", "rule", "paperless_mail.mailrule"), ("auditlog.logentry", "content_type", "contenttypes.contenttype"),
            ("auditlog.logentry", "actor", "auth.user"),
        ]
        for reference in references {
            for record in byModel[reference.model, default: []] {
                let values: [Int]
                switch record.fields[reference.field] {
                case .array(let items)?: values = items.compactMap(\.intValue)
                case let value?: values = value.intValue.map { [$0] } ?? []
                case nil: values = []
                }
                for value in values {
                    #expect(pks(reference.target).contains(value), "\(reference.model) \(record.pk.manifestJSONText).\(reference.field) = \(value) is missing")
                }
            }
        }

        // Shape details the Paperless-ngx importer depends on.
        let thandi = try #require(byModel["auth.user"]?.first { $0.string("username") == "Thandi" })
        let permissionCodenames = Dictionary(uniqueKeysWithValues: byModel["auth.permission", default: []].map { ($0.id!, $0.string("codename")!) })
        #expect(Set(thandi.intList("user_permissions").compactMap { permissionCodenames[$0] })
                == ["view_document", "change_document", "view_global_statistics", "change_applicationconfiguration"])
        #expect(thandi.string("password")?.hasPrefix("pbkdf2_sha256$1000$") == true)
        #expect(byModel["documents.workflowtrigger"]?.first?.string("sources") == "1,2,3")
        let doc1 = try #require(byModel["documents.document"]?.first { $0.id == 1 })
        #expect(doc1.exportedFileName == "2024-03-14 Eskom Electricity March.pdf")
        #expect(doc1.exportedArchiveName == "2024-03-14 Eskom Electricity March-archive.pdf")
        #expect(doc1.exportedThumbnailName == "2024-03-14 Eskom Electricity March-thumbnail.jpg")
        #expect(doc1.string("created") == "2024-03-14")
        let version = try #require(byModel["documents.document"]?.first { $0.id == 3 })
        #expect(version.exportedFileName == "2024-03-14 Eskom Electricity March_01.pdf")
        for record in byModel["documents.document", default: []] {
            let file = target.appendingPathComponent(record.exportedFileName!)
            #expect(try Checksum.sha256(of: file) == record.string("checksum"))
        }
        let account = try #require(byModel["paperless_mail.mailaccount"]?.first)
        #expect(account.string("password") == "imap-sëcret")
        let config = try #require(byModel["paperless.applicationconfiguration"]?.first)
        #expect(config.fields["foliozero_only"] == nil)
        #expect(byModel["documents.sharelinkbundle"] == nil)
    }

    @Test func roundTripsThroughOwnExport() async throws {
        let dir = TempDir()
        let fixture = try TransferFixture.write(to: dir.url.appendingPathComponent("export"))
        let first = try makeApp(dir, "first")
        _ = try await PaperlessImporter.run(app: first, source: fixture.root, options: .init(passphrase: "correct horse"))

        let out = dir.url.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let exported = try await PaperlessExporter.run(app: first, target: out, options: .init(zip: true, zipName: "backup", passphrase: "s3cret", keyIterations: 1000))
        let zip = out.appendingPathComponent("backup.zip")
        #expect(exported.outputPath == zip.path)
        #expect(FileManager.default.fileExists(atPath: zip.path))
        #expect(!FileManager.default.fileExists(atPath: zip.path + ".tmp"))

        let second = try makeApp(dir, "second")
        let report = try await PaperlessImporter.run(app: second, source: zip, options: .init(passphrase: "s3cret"))
        #expect(report.skipped.isEmpty, "\(report.skipped)")

        let tables: [(String, String, Set<String>)] = [
            ("users", "id", []), ("groups", "id", []), ("user_groups", "user_id, group_id", []),
            ("user_permissions", "user_id, codename", []), ("group_permissions", "group_id, codename", []),
            ("ui_settings", "user_id", ["settings"]), ("correspondents", "id", []), ("document_types", "id", []),
            ("storage_paths", "id", []), ("tags", "id", []), ("custom_fields", "id", []), ("custom_field_instances", "id", []),
            ("documents", "id", []), ("document_tags", "document_id, tag_id", []), ("document_barcodes", "id", []),
            ("notes", "id", []), ("saved_views", "id", []), ("saved_view_filter_rules", "id", []), ("share_links", "id", []),
            ("object_permissions", "object_type, object_id, permission, user_id, group_id", ["id"]),
            ("workflows", "id", []), ("workflow_triggers", "id", []), ("workflow_actions", "id", []),
            ("mail_accounts", "id", []), ("mail_rules", "id", []), ("processed_mail", "id", []),
            ("audit_log", "id", []), ("app_config", "id", []),
        ]
        for (table, order, ignored) in tables {
            let a = try await dump(first, table, order: order, ignoring: ignored)
            let b = try await dump(second, table, order: order, ignoring: ignored)
            #expect(!a.isEmpty, "\(table) is empty")
            #expect(a == b, "\(table) differs after the round trip")
        }
        // UI settings gain saved view visibility on export; the rest is unchanged.
        let settings = try await second.database.read { db in try String.fetchOne(db, sql: "SELECT settings FROM ui_settings WHERE user_id = 2") }
        #expect(settings?.contains("en-ZA") == true)
        for id in [1, 2, 3, 4] {
            #expect(FileManager.default.fileExists(atPath: second.storage.thumbnailURL(documentId: id).path))
        }
        let hits = try await second.database.read { db in try SearchIndex.search(SearchIndex.simpleQuery("electricity", titleOnly: false), in: db) }
        #expect(hits.map(\.documentId) == [1])
    }

    @Test func exportWithFilenameFormatAndNoExtras() async throws {
        let dir = TempDir()
        let fixture = try TransferFixture.write(to: dir.url.appendingPathComponent("export"))
        let app = try makeApp(dir, overrides: ["FILENAME_FORMAT": "{{ created_year }}/{{ title }}"])
        _ = try await PaperlessImporter.run(app: app, source: fixture.root, options: .init(passphrase: "correct horse"))
        let doc1 = try await app.database.read { db in try Document.fetchOne(db, key: 1) }
        #expect(doc1?.filename == "2024/Electricity March.pdf")

        let target = dir.url.appendingPathComponent("out")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        _ = try await PaperlessExporter.run(app: app, target: target, options: .init(noArchive: true, noThumbnails: true, useFilenameFormat: true, passphrase: "pw", keyIterations: 1000))
        let records = try PaperlessImporter.decodeManifest(target.appendingPathComponent("manifest.json"))
        let exported = try #require(records.first { $0.model == "documents.document" && $0.id == 1 })
        #expect(exported.exportedFileName == "2024/Electricity March.pdf")
        #expect(exported.exportedArchiveName == nil && exported.exportedThumbnailName == nil)
        let account = try #require(records.first { $0.model == "paperless_mail.mailaccount" })
        let (_, crypto) = try PaperlessImporter.readMetadata(in: target)
        let params = try #require(crypto)
        #expect(try ExportCrypto(passphrase: "pw", metadata: params).decrypt(account.string("password")!) == "imap-sëcret")
    }

    private func dump(_ app: FolioApp, _ table: String, order: String, ignoring: Set<String>) async throws -> [[String: String]] {
        try await app.database.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM \(table) ORDER BY \(order)").map { row in
                var result: [String: String] = [:]
                for column in row.columnNames where !ignoring.contains(column) {
                    let value: DatabaseValue = row[column]
                    result[column] = value.description
                }
                return result
            }
        }
    }
}

// MARK: - Fixture

/// A Paperless-ngx 3.4 style export with every model the importer handles, a few
/// older-format variants, files, a split manifest and encrypted mail secrets.
enum TransferFixture {
    static let encryptedPassword = "674141414141426c555f45416f4b47696f36536c7071656f71617172724b327572387a68526664663358512d4e477034476235424f58747a6b736f5371594e6a2d57775665356e4f34713547414c71354a50494961615746627a33414253653333773d3d"
    static let encryptedRefreshToken = "674141414141426c555f45416f4b47696f36536c7071656f71617172724b3275722d77773032734574513668766f615066624a4d2d4b48476f436f49586266477743627a534875543653446b694649544c37346d754c515a6d305157734e515434673d3d"

    struct Written {
        var root: URL
        var checksums: [String: String]
    }

    static func write(to root: URL, corruptDocument2: Bool = false) throws -> Written {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("json"), withIntermediateDirectories: true)
        let doc1 = "2024-03-14 Eskom Electricity March.pdf"
        let doc1Archive = "2024-03-14 Eskom Electricity March-archive.pdf"
        let doc1Thumb = "2024-03-14 Eskom Electricity March-thumbnail.webp"
        let doc2 = "2023-06-30 City of Cape Town Rates notice.txt"
        let doc3 = "2024-03-14 Eskom Electricity March_01.pdf"
        let doc4 = "2024-01-02 Trash me.txt"
        try writePDF(root.appendingPathComponent(doc1), text: "Electricity account March")
        try writePDF(root.appendingPathComponent(doc1Archive), text: "Electricity account March (archive)")
        try writePNG(root.appendingPathComponent(doc1Thumb))
        try Data("Rates notice for erf 1234".utf8).write(to: root.appendingPathComponent(doc2))
        try writePDF(root.appendingPathComponent(doc3), text: "Electricity account March signed")
        try Data("Delete me".utf8).write(to: root.appendingPathComponent(doc4))

        var checksums: [String: String] = [:]
        checksums["doc1"] = try Checksum.sha256(of: root.appendingPathComponent(doc1))
        checksums["doc1-archive"] = try Checksum.sha256(of: root.appendingPathComponent(doc1Archive))
        checksums["doc2"] = try Checksum.sha256(of: root.appendingPathComponent(doc2))
        let doc2MD5 = corruptDocument2 ? String(repeating: "0", count: 32) : try TransferChecksum.md5(of: root.appendingPathComponent(doc2))
        checksums["doc3"] = try Checksum.sha256(of: root.appendingPathComponent(doc3))
        checksums["doc4"] = try Checksum.sha256(of: root.appendingPathComponent(doc4))

        let null = NSNull()
        func rec(_ model: String, _ pk: Any, _ fields: [String: Any], _ extra: [String: Any] = [:]) -> [String: Any] {
            var record: [String: Any] = ["model": model, "pk": pk, "fields": fields]
            record.merge(extra) { _, new in new }
            return record
        }
        let thandiHash = PasswordHasher.hash("thandi-pass", iterations: 1000, salt: "salty")
        let adminHash = PasswordHasher.hash("admin-pass", iterations: 1000, salt: "peppery")

        let manifest: [[String: Any]] = [
            rec("documents.correspondent", 1, ["owner": 2, "name": "Eskom", "match": "eskom", "matching_algorithm": 1, "is_insensitive": true]),
            rec("documents.correspondent", 2, ["owner": null, "name": "City of Cape Town", "match": "", "matching_algorithm": 6, "is_insensitive": true]),
            rec("documents.tag", 1, ["owner": null, "name": "Finance", "match": "", "matching_algorithm": 0, "is_insensitive": true, "tn_parent": null, "color": "#ff0000", "is_inbox_tag": false]),
            rec("documents.tag", 2, ["owner": null, "name": "Utilities", "match": "", "matching_algorithm": 0, "is_insensitive": true, "tn_parent": 1, "color": "#00ff00", "is_inbox_tag": false, "tn_level": 2, "tn_ancestors_pks": "1"]),
            rec("documents.tag", 3, ["owner": null, "name": "Inbox", "match": "", "matching_algorithm": 0, "is_insensitive": true, "tn_parent": null, "color": "#a6cee3", "is_inbox_tag": true]),
            rec("documents.documenttype", 1, ["owner": null, "name": "Invoice", "match": "invoice", "matching_algorithm": 1, "is_insensitive": true]),
            rec("documents.storagepath", 1, ["owner": null, "name": "Bills", "path": "{{ correspondent }}/{{ title }}", "match": "", "matching_algorithm": 0, "is_insensitive": true]),
            rec("paperless_mail.mailaccount", 1, ["owner": 2, "name": "Gmail", "imap_server": "imap.gmail.com", "imap_port": 993, "imap_security": 2,
                                                  "username": "thandi@example.com", "password": encryptedPassword, "is_token": false, "character_set": "UTF-8",
                                                  "account_type": 1, "refresh_token": encryptedRefreshToken, "expiration": "2026-01-01T00:00:00Z"]),
            rec("paperless_mail.mailrule", 1, ["owner": 2, "name": "Invoices", "order": 0, "account": 1, "enabled": true, "folder": "INBOX",
                                               "filter_from": "billing@eskom.co.za", "filter_to": null, "filter_subject": null, "filter_body": null,
                                               "filter_attachment_filename_include": "*.pdf", "filter_attachment_filename_exclude": null, "maximum_age": 30,
                                               "attachment_type": 1, "consumption_scope": 1, "pdf_layout": 0, "action": 3, "action_parameter": null,
                                               "assign_title_from": 1, "assign_tags": [1], "assign_document_type": 1, "assign_correspondent_from": 4,
                                               "assign_correspondent": 1, "assign_owner_from_rule": true, "stop_processing": false]),
            rec("documents.savedview", 1, ["owner": 2, "name": "Bills", "icon": "funnel", "sort_field": "created", "sort_reverse": true, "page_size": 25,
                                           "display_mode": "table", "display_fields": ["title", "created"]]),
            rec("documents.savedviewfilterrule", 1, ["saved_view": 1, "rule_type": 6, "value": "1"]),
            rec("auth.group", 1, ["name": "Accounts", "permissions": [1, 4]]),
            rec("auth.user", 1, ["password": adminHash, "last_login": null, "is_superuser": true, "username": "admin", "first_name": "", "last_name": "",
                                 "email": "admin@example.com", "is_staff": true, "is_active": true, "date_joined": "2023-01-01T08:00:00.250Z", "groups": [], "user_permissions": []]),
            rec("auth.user", 2, ["password": thandiHash, "last_login": "2024-05-01T10:00:00Z", "is_superuser": false, "username": "Thandi", "first_name": "Thandi",
                                 "last_name": "Nkosi", "email": "thandi@example.com", "is_staff": false, "is_active": true, "date_joined": "2023-02-01T08:00:00Z",
                                 "groups": [1], "user_permissions": [1, 2, 5, 6]]),
            rec("auth.user", 3, ["password": "argon2$argon2id$v=19$m=102400,t=2,p=8$c2FsdA$aGFzaA", "last_login": null, "is_superuser": false, "username": "legacy",
                                 "first_name": "", "last_name": "", "email": "", "is_staff": false, "is_active": true, "date_joined": "2022-01-01T00:00:00Z",
                                 "groups": [], "user_permissions": []]),
            rec("auth.user", 4, ["password": "!unusable", "last_login": null, "is_superuser": false, "username": "AnonymousUser", "first_name": "", "last_name": "",
                                 "email": "", "is_staff": false, "is_active": true, "date_joined": "2022-01-01T00:00:00Z", "groups": [], "user_permissions": []]),
            rec("documents.uisettings", 1, ["user": 2, "settings": ["language": "en-ZA", "saved_views": ["dashboard_views_visible_ids": [1], "sidebar_views_visible_ids": []]]]),
            rec("contenttypes.contenttype", 1, ["app_label": "documents", "model": "document"]),
            rec("contenttypes.contenttype", 2, ["app_label": "documents", "model": "tag"]),
            rec("contenttypes.contenttype", 3, ["app_label": "documents", "model": "correspondent"]),
            rec("contenttypes.contenttype", 4, ["app_label": "auth", "model": "user"]),
            rec("contenttypes.contenttype", 5, ["app_label": "documents", "model": "note"]),
            rec("contenttypes.contenttype", 6, ["app_label": "paperless", "model": "applicationconfiguration"]),
            rec("auth.permission", 1, ["name": "Can view document", "content_type": 1, "codename": "view_document"]),
            rec("auth.permission", 2, ["name": "Can change document", "content_type": 1, "codename": "change_document"]),
            rec("auth.permission", 3, ["name": "Can add document", "content_type": 1, "codename": "add_document"]),
            rec("auth.permission", 4, ["name": "Can view tag", "content_type": 2, "codename": "view_tag"]),
            rec("auth.permission", 5, ["name": "Can view global object counts", "content_type": 6, "codename": "view_global_statistics"]),
            rec("auth.permission", 6, ["name": "Can change paperless application settings", "content_type": 6, "codename": "change_applicationconfiguration"]),
            rec("auth.permission", 8, ["name": "Can delete document", "content_type": 1, "codename": "delete_document"]),
            rec("guardian.userobjectpermission", 1, ["permission": 1, "content_type": 1, "object_pk": "1", "user": 3]),
            rec("guardian.userobjectpermission", 2, ["permission": 8, "content_type": 1, "object_pk": "1", "user": 3]),
            rec("guardian.groupobjectpermission", 1, ["permission": 2, "content_type": 1, "object_pk": "1", "group": 1]),
            rec("documents.workflowtrigger", 1, ["type": 1, "sources": "1,2,3", "filter_path": null, "filter_filename": "*.pdf", "filter_mailrule": null,
                                                 "match": "", "matching_algorithm": 0, "is_insensitive": true, "filter_has_tags": [1], "filter_has_all_tags": [],
                                                 "filter_has_not_tags": [], "filter_has_document_type": null, "filter_has_any_document_types": [],
                                                 "filter_has_not_document_types": [], "filter_has_correspondent": null, "filter_has_not_correspondents": [],
                                                 "filter_has_any_correspondents": [], "filter_has_storage_path": null, "filter_has_any_storage_paths": [],
                                                 "filter_has_not_storage_paths": [], "filter_custom_field_query": null, "schedule_offset_days": 0,
                                                 "schedule_is_recurring": false, "schedule_recurring_interval_days": 1, "schedule_date_field": "added",
                                                 "schedule_date_custom_field": null]),
            rec("documents.workflowaction", 1, ["type": 1, "order": 0, "assign_title": "Bill {{ correspondent }}", "assign_tags": [3], "assign_document_type": 1,
                                                "assign_correspondent": null, "assign_storage_path": null, "assign_owner": 2, "assign_view_users": [3],
                                                "assign_view_groups": [], "assign_change_users": [], "assign_change_groups": [1], "assign_custom_fields": [1],
                                                "assign_custom_fields_values": ["1": "ZAR10.00"], "remove_tags": [], "remove_all_tags": false,
                                                "email": null, "webhook": null, "passwords": null, "ai_suggestion_fields": null]),
            rec("documents.workflowaction", 2, ["type": 3, "order": 1, "email": 1, "webhook": null]),
            rec("documents.workflowaction", 3, ["type": 4, "order": 2, "email": null, "webhook": 1]),
            rec("documents.workflowactionemail", 1, ["subject": "New bill", "body": "{{ doc_url }}", "to": "me@example.com", "include_document": true]),
            rec("documents.workflowactionwebhook", 1, ["url": "https://hooks.example.com/x", "use_params": true, "as_json": false,
                                                       "params": ["a": "b", "n": 1], "body": null, "headers": ["X-Key": "v"], "include_document": false]),
            rec("documents.workflow", 1, ["name": "Bills", "order": 0, "triggers": [1], "actions": [1, 2, 3], "enabled": true]),
            rec("documents.customfield", 1, ["created": "2024-01-01T00:00:00Z", "name": "Amount", "data_type": "monetary", "extra_data": ["default_currency": "ZAR"]]),
            rec("documents.customfield", 2, ["created": "2024-01-01T00:00:00Z", "name": "Priority", "data_type": "select", "extra_data": ["select_options": ["Low", "High"]]]),
            rec("documents.customfield", 3, ["created": "2024-01-01T00:00:00Z", "name": "Related", "data_type": "documentlink", "extra_data": null]),
            rec("documents.customfield", 4, ["created": "2024-01-01T00:00:00Z", "name": "Due", "data_type": "date", "extra_data": null]),
            rec("documents.customfieldinstance", 1, ["created": "2024-03-14T10:00:00Z", "document": 1, "field": 1, "value_monetary": "ZAR123.45", "deleted_at": null]),
            rec("documents.customfieldinstance", 2, ["created": "2024-03-14T10:00:00Z", "document": 1, "field": 2, "value_select": 1]),
            rec("documents.customfieldinstance", 3, ["created": "2024-03-14T10:00:00Z", "document": 1, "field": 3, "value_document_ids": [2]]),
            rec("documents.customfieldinstance", 4, ["created": "2024-03-14T10:00:00Z", "document": 2, "field": 3, "value_document_ids": [1]]),
            rec("documents.customfieldinstance", 5, ["created": "2024-03-14T10:00:00Z", "document": 2, "field": 4, "value_date": "2024-04-01"]),
            rec("documents.documentbarcode", 1, ["document": 1, "page": 1, "value": "ASN00042", "format": "CODE128"]),
            rec("paperless.applicationconfiguration", 1, ["output_type": "pdfa", "app_title": "Thandi's Docs", "barcodes_enabled": true, "user_args": null]),
            rec("documents.note", 1, ["deleted_at": null, "restored_at": null, "transaction_id": null, "note": "Paid on time", "created": "2024-03-20T09:00:00Z", "document": 1, "user": 2]),
            rec("documents.document", 1, [
                "owner": 2, "deleted_at": null, "restored_at": null, "transaction_id": null, "correspondent": 1, "storage_path": null,
                "title": "Electricity March", "document_type": 1, "content": "Electricity account March", "mime_type": "application/pdf",
                "tags": [1, 2], "checksum": checksums["doc1"]!, "archive_checksum": checksums["doc1-archive"]!, "page_count": 1,
                "created": "2024-03-14", "modified": "2024-03-15T10:20:30.123Z", "added": "2024-03-14T10:20:30.500Z",
                "filename": "Eskom/Electricity March.pdf", "archive_filename": "Eskom/Electricity March.pdf", "original_filename": "scan.pdf",
                "archive_serial_number": 42, "root_document": null, "version_index": null, "version_label": null,
            ], [ManifestRecord.fileNameKey: doc1, ManifestRecord.archiveNameKey: doc1Archive, ManifestRecord.thumbnailNameKey: doc1Thumb]),
            rec("documents.document", 2, [
                "owner": null, "correspondent": 2, "storage_path": 1, "title": "Rates notice", "document_type": null,
                "content": "Rates notice for erf 1234", "mime_type": "text/plain", "tags": [], "checksum": doc2MD5, "archive_checksum": null,
                "page_count": null, "created": "2023-06-30T22:30:00Z", "modified": "2023-07-01T00:00:00Z", "added": "2023-07-01T00:00:00Z",
                "filename": "0000002.txt", "archive_filename": null, "original_filename": "rates.txt", "archive_serial_number": null,
            ], [ManifestRecord.fileNameKey: doc2, ManifestRecord.thumbnailNameKey: null]),
            rec("documents.document", 3, [
                "owner": 2, "correspondent": null, "storage_path": null, "title": "Electricity March", "document_type": null,
                "content": "Electricity account March signed", "mime_type": "application/pdf", "tags": [], "checksum": checksums["doc3"]!,
                "archive_checksum": null, "page_count": 1, "created": "2024-03-14", "modified": "2024-03-16T00:00:00Z", "added": "2024-03-16T00:00:00Z",
                "filename": "0000001_v1.pdf", "archive_filename": null, "original_filename": "signed.pdf", "archive_serial_number": null,
                "root_document": 1, "version_index": 1, "version_label": "signed",
            ], [ManifestRecord.fileNameKey: doc3]),
            rec("documents.sharelink", 1, ["deleted_at": null, "created": "2024-03-21T00:00:00Z", "expiration": null, "slug": "abc123",
                                           "document": 1, "file_version": "original", "owner": 2]),
            rec("paperless_mail.processedmail", 1, ["owner": 2, "rule": 1, "folder": "INBOX", "uid": "123", "uid_validity": "77", "subject": "March bill",
                                                    "received": "2024-03-14T07:00:00Z", "processed": "2024-03-14T07:05:00Z", "status": "SUCCESS", "error": null]),
            rec("auditlog.logentry", 1, ["content_type": 1, "object_pk": "1", "object_id": 1, "object_repr": "2024-03-14 Eskom Electricity March",
                                         "action": 0, "changes": ["title": ["None", "Electricity March"]], "actor": 2, "timestamp": "2024-03-14T10:20:31Z"]),
            rec("auditlog.logentry", 2, ["content_type": 1, "object_pk": "1", "object_id": 1, "object_repr": "2024-03-14 Eskom Electricity March",
                                         "action": 1, "changes": "{\"title\": [\"Old\", \"Electricity March\"]}", "actor": 2, "timestamp": "2024-03-15T10:20:30Z"]),
            rec("auditlog.logentry", 3, ["content_type": 1, "object_pk": "1", "object_id": 1, "object_repr": "2024-03-14 Eskom Electricity March",
                                         "action": 1, "changes": ["tags": ["type": "m2m", "operation": "add", "objects": ["Finance"]]], "actor": null,
                                         "timestamp": "2024-03-15T10:20:31Z"]),
            rec("auditlog.logentry", 4, ["content_type": 1, "object_pk": "1", "object_id": 1, "object_repr": "x", "action": 3, "changes": null, "actor": 2,
                                         "timestamp": "2024-03-15T10:20:32Z"]),
            rec("documents.paperlesstask", 1, ["owner": 2, "task_id": "t-1", "task_type": "consume_file", "trigger_source": "folder_consume",
                                               "status": "success", "date_created": "2024-03-14T10:20:00Z", "date_done": "2024-03-14T10:20:30Z",
                                               "input_data": ["filename": "scan.pdf"], "result_data": ["document_id": 1], "acknowledged": false]),
            rec("documents.sharelinkbundle", 1, ["slug": "bundle", "file_path": "x.zip"]),
            rec("socialaccount.socialtoken", 1, ["token": "abc", "token_secret": "", "app": 1, "account": 1]),
            rec("documents.foo", 1, ["bar": 1]),
        ]

        let split: [[String: Any]] = [
            rec("documents.document", 4, [
                "owner": 2, "deleted_at": "2024-02-01T00:00:00Z", "correspondent": null, "storage_path": null, "title": "Trash me",
                "document_type": null, "content": "Delete me", "mime_type": "text/plain", "tags": [3], "checksum": checksums["doc4"]!,
                "archive_checksum": null, "page_count": null, "created": "2024-01-02", "modified": "2024-01-02T00:00:00Z",
                "added": "2024-01-02T00:00:00Z", "filename": "0000004.txt", "archive_filename": null, "original_filename": "trash.txt",
                "archive_serial_number": null,
            ], [ManifestRecord.fileNameKey: doc4]),
            rec("documents.note", 2, ["deleted_at": null, "note": "Old note", "created": "2024-01-03T00:00:00Z", "document": 4, "user": null]),
        ]
        let metadata: [String: Any] = [
            "version": "3.4.2",
            "__crypto__": ["__key_algo__": "pbkdf2_sha256", "__key_iters__": 1000, "__key_size__": 32, "__salt_hex__": "00112233445566778899aabbccddeeff"],
        ]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted]).write(to: root.appendingPathComponent("manifest.json"))
        try JSONSerialization.data(withJSONObject: split, options: [.prettyPrinted]).write(to: root.appendingPathComponent("json/2024-01-02 Trash me-manifest.json"))
        try JSONSerialization.data(withJSONObject: metadata).write(to: root.appendingPathComponent("metadata.json"))
        return Written(root: root, checksums: checksums)
    }

    static func writePDF(_ url: URL, text: String) throws {
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw CocoaError(.fileWriteUnknown) }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
        ]))
        context.textPosition = CGPoint(x: 20, y: 300)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
    }

    static func writePNG(_ url: URL) throws {
        guard let context = CGContext(data: nil, width: 40, height: 60, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 60))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    }
}
