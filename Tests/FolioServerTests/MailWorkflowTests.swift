import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import FolioCore
@testable import FolioServer

@Suite struct MailWorkflowTests {
    @Test func mailAccountsRulesAndProcessedMail() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let other = try env.user("other", permissions: TestEnvironment.permissions(["mailaccount", "mailrule", "processedmail"]))
        let tag = try env.tag("Mail")
        try await env.run { client async throws in
            let created = try await client.call(.post, "/api/mail_accounts/", as: admin, json: [
                "name": "Work", "imap_server": "127.0.0.1", "imap_port": 1, "imap_security": 1, "username": "me", "password": "secret",
            ])
            #expect(created.status == .created)
            #expect(created.json["password"] == "**********")
            #expect(created.json["character_set"] == "UTF-8")
            #expect(created.json["account_type"] == 1)
            let accountId = try #require(created.json["id"]?.int)
            let missing = try await client.call(.post, "/api/mail_accounts/", as: admin, json: ["name": "X"])
            #expect(missing.json["imap_server"] == ["This field is required."])

            let kept = try await client.call(.patch, "/api/mail_accounts/\(accountId)/", as: admin, json: ["password": "**********", "username": "me2"])
            #expect(kept.json["username"] == "me2")
            let stored = try await env.app.database.read { db in try MailAccount.fetchOne(db, key: accountId) }
            #expect(stored?.config.password == "secret")

            #expect(try await client.get("/api/mail_accounts/", as: other).json["count"] == 0)
            #expect(try await client.get("/api/mail_accounts/\(accountId)/", as: other).status == .notFound)

            let test = try await client.call(.post, "/api/mail_accounts/test/", as: admin, json: [
                "imap_server": "127.0.0.1", "imap_port": 1, "imap_security": 1, "username": "me", "password": "**********", "id": .int(accountId),
            ])
            #expect(test.status == .badRequest)
            #expect(test.text == "Unable to connect to server")

            let noParameter = try await client.call(.post, "/api/mail_rules/", as: admin, json: [
                "name": "Move", "account": .int(accountId), "action": 2,
            ])
            #expect(noParameter.json["non_field_errors"] == ["An action parameter is required."])
            let rule = try await client.call(.post, "/api/mail_rules/", as: admin, json: [
                "name": "Invoices", "account": .int(accountId), "filter_subject": "invoice", "action": 3, "assign_tags": [.int(tag)],
                "maximum_age": 60,
            ])
            #expect(rule.status == .created)
            #expect(rule.json["folder"] == "INBOX")
            #expect(rule.json["assign_tags"] == [.int(tag)])
            #expect(rule.json["action_parameter"] == .null)
            let ruleId = try #require(rule.json["id"]?.int)
            let foreignAccount = try await client.call(.post, "/api/mail_rules/", as: other, json: ["name": "Steal", "account": .int(accountId)])
            #expect(foreignAccount.status == .badRequest)

            try await env.app.database.write { db in
                var mail = ProcessedMail(ruleId: ruleId, folder: "INBOX", uid: "42", subject: "Invoice", received: Date(), status: "SUCCESS", ownerId: admin.id)
                try mail.insert(db)
            }
            let processed = try await client.get("/api/processed_mail/?rule=\(ruleId)", as: admin)
            #expect(processed.json["count"] == 1)
            #expect(processed.json.results[0]["uid"] == "42")
            let mailId = try #require(processed.json.results[0]["id"]?.int)
            let deleted = try await client.call(.post, "/api/processed_mail/bulk_delete/", as: admin, json: ["mail_ids": [.int(mailId)]])
            #expect(deleted.json["deleted_mail_ids"] == [.int(mailId)])

            #expect(try await client.call(.delete, "/api/mail_accounts/\(accountId)/", as: admin).status == .noContent)
            #expect(try await client.get("/api/mail_rules/\(ruleId)/", as: admin).status == .notFound)
        }
    }

    @Test func workflowsWithNestedTriggersAndActions() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let tag = try env.tag("Updated")
        let id = try env.document("Plain")
        try await env.run { client async throws in
            let invalid = try await client.call(.post, "/api/workflows/", as: admin, json: [
                "name": "Bad", "triggers": [["type": 1]], "actions": [],
            ])
            #expect(invalid.status == .badRequest)
            #expect(invalid.json["triggers"]?[0]?["non_field_errors"] == ["File name, path or mail rule filter are required"])

            // Paperless-ngx only checks that the `filter_mailrule` key is present. The web UI always sends it.
            let fromWebUI = try await client.call(.post, "/api/workflows/", as: admin, json: [
                "name": "From the web UI", "triggers": [["type": 1, "filter_mailrule": .null, "filter_filename": .null]], "actions": [],
            ])
            #expect(fromWebUI.status == .created)
            let fromWebUIId = try #require(fromWebUI.json["id"]?.int)
            #expect(try await client.call(.delete, "/api/workflows/\(fromWebUIId)/", as: admin).status == .noContent)

            let badQuery = try await client.call(.post, "/api/workflows/", as: admin, json: [
                "name": "Bad query", "triggers": [["type": 3, "filter_custom_field_query": "[nope"]], "actions": [],
            ])
            #expect(badQuery.json["triggers"]?[0]?["filter_custom_field_query"] == ["Value must be valid JSON."])

            let created = try await client.call(.post, "/api/workflows/", as: admin, json: [
                "name": "Tag on update", "order": 1, "enabled": true,
                "triggers": [["type": 3, "sources": [1, 2], "filter_has_tags": []]],
                "actions": [
                    ["type": 1, "assign_tags": [.int(tag)], "assign_title": ""],
                    ["type": 3, "email": ["subject": "Hi", "body": "Body", "to": "a@example.com", "include_document": false]],
                ],
            ])
            #expect(created.status == .created)
            let workflowId = try #require(created.json["id"]?.int)
            #expect(created.json["triggers"]?[0]?["type"] == 3)
            #expect(created.json["triggers"]?[0]?["sources"] == [1, 2])
            #expect(created.json["triggers"]?[0]?["schedule_date_field"] == "added")
            #expect(created.json["actions"]?[0]?["assign_tags"] == [.int(tag)])
            #expect(created.json["actions"]?[0]?["assign_title"] == .null)
            #expect(created.json["actions"]?[1]?["email"]?["subject"] == "Hi")
            #expect(created.json["actions"]?[1]?["webhook"] == .null)
            let emailWithoutData = try await client.call(.patch, "/api/workflows/\(workflowId)/", as: admin, json: ["actions": [["type": 3]]])
            #expect(emailWithoutData.json["actions"]?[0]?["non_field_errors"] == ["Email data is required for email actions"])

            let triggers = try await client.get("/api/workflow_triggers/", as: admin)
            #expect(triggers.json["count"] == 1)
            let actions = try await client.get("/api/workflow_actions/", as: admin)
            #expect(actions.json["count"] == 2)

            // "Document Updated" workflows run after an edit through the API.
            let patched = try await client.call(.patch, "/api/documents/\(id)/", as: admin, json: ["title": "Edited"])
            #expect(patched.status == .ok)
            let tags = try await env.app.database.read { db in try DocumentStore.tagIds(of: id, in: db) }
            #expect(tags.contains(tag))

            let renamed = try await client.call(.patch, "/api/workflows/\(workflowId)/", as: admin, json: [
                "name": "Renamed", "actions": [["type": 6]],
            ])
            #expect(renamed.json["name"] == "Renamed")
            #expect(renamed.json["actions"]?.array?.count == 1)
            #expect(try await client.get("/api/workflow_actions/", as: admin).json["count"] == 1)
            #expect(try await client.call(.delete, "/api/workflows/\(workflowId)/", as: admin).status == .noContent)
            #expect(try await client.get("/api/workflow_triggers/", as: admin).json["count"] == 0)
        }
    }

    @Test func documentVersionsAndPostURLValidation() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        try await env.run { client async throws in
            var first = MultipartBody()
            first.file("document", filename: "notes.txt", contentType: "text/plain", contents: Data("First draft of the minutes".utf8))
            let (body, headers) = first.finished()
            #expect(try await client.call(.post, "/api/documents/post_document/", as: admin, headers: headers, body: body).status == .ok)
            await env.queue.waitUntilIdle()
            let id = try #require(try await client.get("/api/documents/", as: admin).json.results.first?["id"]?.int)

            var second = MultipartBody()
            second.file("document", filename: "notes-v2.txt", contentType: "text/plain", contents: Data("Final version of the minutes".utf8))
            second.field("version_label", "final")
            let (versionBody, versionHeaders) = second.finished()
            let upload = try await client.call(.post, "/api/documents/\(id)/update_version/", as: admin, headers: versionHeaders, body: versionBody)
            #expect(upload.status == .ok)
            #expect(upload.json.string != nil)
            await env.queue.waitUntilIdle()

            let document = try await client.get("/api/documents/\(id)/", as: admin)
            let versions = document.json["versions"]?.array ?? []
            #expect(versions.count == 2)
            #expect(document.json["content"]?.string?.contains("Final version") == true)
            let versionId = try #require(versions.first { $0["is_root"] == false }?["id"]?.int)
            #expect(versions.first { $0["is_root"] == false }?["version_label"] == "final")

            let newest = try await client.get("/api/documents/\(id)/download/", as: admin)
            #expect(newest.text.contains("Final version"))
            let original = try await client.get("/api/documents/\(id)/download/?version=\(id)", as: admin)
            #expect(original.text.contains("First draft"))
            let invalid = try await client.get("/api/documents/\(id)/download/?version=999", as: admin)
            #expect(invalid.status == .notFound)
            let oldContent = try await client.get("/api/documents/\(id)/?version=\(id)", as: admin)
            #expect(oldContent.json["content"]?.string?.contains("First draft") == true)

            let labelled = try await client.call(.patch, "/api/documents/\(id)/versions/\(versionId)/", as: admin, json: ["version_label": "v2"])
            #expect(labelled.json["version_label"] == "v2")
            let removed = try await client.call(.delete, "/api/documents/\(id)/versions/\(versionId)/", as: admin)
            #expect(removed.json["result"] == "OK")
            #expect(try await client.get("/api/documents/\(id)/", as: admin).json["versions"]?.array?.count == 1)

            let badURL = try await client.call(.post, "/api/documents/post_url/", as: admin, json: ["url": "file:///etc/passwd"])
            #expect(badURL.json["url"] == ["Enter a valid URL."])
            let noURL = try await client.call(.post, "/api/documents/post_url/", as: admin, json: ["title": "x"])
            #expect(noURL.json["url"] == ["This field is required."])
        }
    }

    @Test func customStatisticsAndConfigPermissions() async throws {
        let env = try TestEnvironment()
        let viewer = try env.user("viewer", permissions: ["view_document", Permission.viewGlobalStatistics])
        let plain = try env.user("plain", permissions: ["view_document"])
        let owner = try env.user("owner", permissions: ["view_document"])
        try env.document("Private", owner: owner.id)
        let configEditor = try env.user("editor", permissions: ["change_applicationconfiguration"])
        try await env.run { client async throws in
            #expect(try await client.get("/api/statistics/", as: viewer).json["documents_total"] == 1)
            #expect(try await client.get("/api/statistics/", as: plain).json["documents_total"] == 0)
            #expect(try await client.call(.patch, "/api/config/1/", as: configEditor, json: ["app_title": "T"]).status == .ok)
            #expect(try await client.call(.patch, "/api/config/1/", as: plain, json: ["app_title": "T"]).status == .forbidden)
        }
    }
}
