import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import FolioCore
@testable import FolioServer

@Suite struct DocumentTests {
    @Test func privateDocumentsNeverLeak() async throws {
        let env = try TestEnvironment()
        let perms = TestEnvironment.permissions(TestEnvironment.regularModels) + ["view_logentry"]
        let alice = try env.user("alice", permissions: perms)
        let bob = try env.user("bob", permissions: perms)
        let tag = try env.tag("Shared tag")
        let secret = try env.document("Alice secret contract", content: "confidential zebra merger", owner: alice.id, tags: [tag])
        let open = try env.document("Public notice", content: "everyone may read this", tags: [tag])
        try await env.app.database.write { db in
            var note = Note(documentId: secret, note: "secret note", userId: alice.id)
            try note.insert(db)
            try SearchIndex.update(documentId: secret, in: db)
        }
        try await env.run { client async throws in
            // List, detail, search, selection data and files.
            let list = try await client.get("/api/documents/", as: bob)
            #expect(list.json.results.ids == [open])
            #expect(try await client.get("/api/documents/\(secret)/", as: bob).status == .notFound)
            let search = try await client.get("/api/documents/?query=zebra", as: bob)
            #expect(search.json["count"] == 0)
            let text = try await client.get("/api/documents/?text=confidential", as: bob)
            #expect(text.json["count"] == 0)
            #expect(try await client.get("/api/documents/\(secret)/download/", as: bob).status == .forbidden)
            #expect(try await client.get("/api/documents/\(secret)/preview/", as: bob).status == .forbidden)
            #expect(try await client.get("/api/documents/\(secret)/thumb/", as: bob).status == .forbidden)
            #expect(try await client.get("/api/documents/\(secret)/metadata/", as: bob).status == .forbidden)
            #expect(try await client.get("/api/documents/\(secret)/notes/", as: bob).status == .forbidden)
            #expect(try await client.get("/api/documents/\(secret)/history/", as: bob).status == .forbidden)
            #expect(try await client.get("/api/documents/\(secret)/suggestions/", as: bob).status == .forbidden)
            #expect(try await client.call(.patch, "/api/documents/\(secret)/", as: bob, json: ["title": "x"]).status == .notFound)
            #expect(try await client.call(.delete, "/api/documents/\(secret)/", as: bob).status == .notFound)
            let selection = try await client.call(.post, "/api/documents/selection_data/", as: bob, json: ["documents": [.int(secret)]])
            #expect(selection.status == .forbidden)
            let moreLike = try await client.get("/api/documents/?more_like_id=\(secret)", as: bob)
            #expect(moreLike.status == .forbidden)
            let bulk = try await client.call(.post, "/api/documents/bulk_edit/", as: bob, json: [
                "documents": [.int(secret)], "method": "add_tag", "parameters": ["tag": .int(tag)],
            ])
            #expect(bulk.status == .forbidden)

            // Counts, statistics, autocomplete and global search.
            let tags = try await client.get("/api/tags/\(tag)/", as: bob)
            #expect(tags.json["document_count"] == 1)
            let stats = try await client.get("/api/statistics/", as: bob)
            #expect(stats.json["documents_total"] == 1)
            let words = try await client.get("/api/search/autocomplete/?term=zeb", as: bob)
            #expect(words.json == [])
            let aliceWords = try await client.get("/api/search/autocomplete/?term=zeb", as: alice)
            #expect(aliceWords.json.array?.isEmpty == false)
            let global = try await client.get("/api/search/?query=Alice", as: bob)
            #expect(global.json["documents"] == [])

            // Alice sees everything of hers, including the note and history.
            let mine = try await client.get("/api/documents/?ordering=id", as: alice)
            #expect(mine.json.results.ids == [secret, open])
            let notes = try await client.get("/api/documents/\(secret)/notes/", as: alice)
            #expect(notes.json[0]?["note"] == "secret note")
            #expect(notes.json[0]?["user"]?["username"] == "alice")
            let hits = try await client.get("/api/documents/?query=zebra", as: alice)
            #expect(hits.json.results.ids == [secret])
            #expect(hits.json.results[0]["__search_hit__"]?["rank"] == 1)
            #expect(hits.json.results[0]["__search_hit__"]?["highlights"]?.string?.contains("<span class=\"match\">zebra</span>") == true)

            // Sharing with bob makes it visible to him.
            let shared = try await client.call(.patch, "/api/documents/\(secret)/", as: alice,
                                               json: ["set_permissions": ["view": ["users": [.int(bob.id)], "groups": []]]])
            #expect(shared.status == .ok)
            #expect(shared.json["permissions"]?["view"]?["users"] == [.int(bob.id)])
            let nowVisible = try await client.get("/api/documents/\(secret)/", as: bob)
            #expect(nowVisible.status == .ok)
            #expect(nowVisible.json["user_can_change"] == false)
            #expect(nowVisible.json["is_shared_by_requester"] == false)
            let aliceView = try await client.get("/api/documents/\(secret)/", as: alice)
            #expect(aliceView.json["is_shared_by_requester"] == true)
            #expect(try await client.call(.patch, "/api/documents/\(secret)/", as: bob, json: ["title": "x"]).status == .forbidden)
        }
    }

    @Test func listFiltersAndOrdering() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let invoices = try env.tag("Invoices")
        let paid = try env.tag("Paid")
        let inbox = try env.tag("Inbox", inbox: true)
        let acme = try env.correspondent("ACME")
        let a = try env.document("ACME invoice March", created: CalendarDate(year: 2024, month: 3, day: 1), tags: [invoices, paid], correspondent: acme, asn: 10)
        let b = try env.document("ACME invoice April", created: CalendarDate(year: 2024, month: 4, day: 1), tags: [invoices, inbox], correspondent: acme, asn: 11)
        let c = try env.document("Letter from bank", created: CalendarDate(year: 2023, month: 12, day: 24))
        try await env.run { client async throws in
            func ids(_ query: String) async throws -> [Int] {
                try await client.get("/api/documents/?ordering=id&\(query)", as: admin).json.results.ids
            }
            #expect(try await ids("title__icontains=invoice") == [a, b])
            #expect(try await ids("tags__id__all=\(invoices),\(paid)") == [a])
            #expect(try await ids("tags__id__in=\(paid),\(inbox)") == [a, b])
            #expect(try await ids("tags__id__none=\(invoices)") == [c])
            #expect(try await ids("is_tagged=false") == [c])
            #expect(try await ids("is_in_inbox=true") == [b])
            #expect(try await ids("correspondent__id=\(acme)") == [a, b])
            #expect(try await ids("correspondent__isnull=true") == [c])
            #expect(try await ids("correspondent__id__none=\(acme)") == [c])
            #expect(try await ids("correspondent__name__iexact=acme") == [a, b])
            #expect(try await ids("created__date__gt=2024-03-01") == [b])
            #expect(try await ids("created__date__lte=2024-03-01") == [a, c])
            #expect(try await ids("created__year=2023") == [c])
            #expect(try await ids("archive_serial_number__gt=10") == [b])
            #expect(try await ids("archive_serial_number__isnull=true") == [c])
            #expect(try await ids("id__in=\(a),\(c)") == [a, c])
            #expect(try await ids("title_content=bank") == [c])
            #expect(try await ids("added__date__gte=2000-01-01") == [a, b, c])
            #expect(try await ids("mime_type=pdf") == [a, b, c])

            let newestFirst = try await client.get("/api/documents/", as: admin).json.results.ids
            #expect(newestFirst == [b, a, c])
            let byTitle = try await client.get("/api/documents/?ordering=title", as: admin).json.results.ids
            #expect(byTitle == [b, a, c])
            let byASN = try await client.get("/api/documents/?ordering=-archive_serial_number", as: admin).json.results.ids
            #expect(byASN.prefix(2) == [b, a])

            let badNumber = try await client.get("/api/documents/?id=abc", as: admin)
            #expect(badNumber.status == .badRequest)
            #expect(badNumber.json["id"] == ["Enter a number."])

            let fields = try await client.get("/api/documents/?fields=id,title&truncate_content=true", as: admin)
            #expect(Set(fields.json.results[0].object?.keys ?? []) == ["id", "title"])

            let selection = try await client.get("/api/documents/?include_selection_data=true&tags__id__all=\(invoices)", as: admin)
            let tagCounts = selection.json["selection_data"]?["selected_tags"]?.array ?? []
            #expect(tagCounts.first { $0["id"]?.int == invoices }?["document_count"] == 2)
            #expect(tagCounts.first { $0["id"]?.int == paid }?["document_count"] == 1)

            let next = try await client.get("/api/documents/next_asn/", as: admin)
            #expect(next.json == 12)
        }
    }

    @Test func customFieldQuery() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let (due, amount, priority) = try await env.app.database.write { db -> (Int, Int, Int) in
            var due = CustomField(name: "due", dataType: .date)
            try due.insert(db)
            var amount = CustomField(name: "amount", dataType: .monetary)
            try amount.insert(db)
            var priority = CustomField(name: "priority", dataType: .select,
                                       extraData: .init(selectOptions: [.init(id: "hi", label: "High"), .init(id: "lo", label: "Low")]))
            try priority.insert(db)
            return (due.id!, amount.id!, priority.id!)
        }
        let a = try env.document("A"), b = try env.document("B"), c = try env.document("C")
        let today = CalendarDate.today(in: TimeZone(identifier: "UTC")!)
        try await env.app.database.write { db in
            try CustomFieldValues.set(fieldId: due, value: .string(today.adding(days: 10).iso), documentId: a, in: db)
            try CustomFieldValues.set(fieldId: due, value: .string("2020-01-01"), documentId: b, in: db)
            try CustomFieldValues.set(fieldId: amount, value: .string("ZAR150.00"), documentId: a, in: db)
            try CustomFieldValues.set(fieldId: amount, value: .string("ZAR20"), documentId: b, in: db)
            try CustomFieldValues.set(fieldId: priority, value: .string("hi"), documentId: c, in: db)
        }
        try await env.run { client async throws in
            func ids(_ expression: String) async throws -> TestResponse {
                let encoded = expression.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
                return try await client.get("/api/documents/?ordering=id&custom_field_query=\(encoded)", as: admin)
            }
            #expect(try await ids(#"["due", "range", ["today", "in 30 days"]]"#).json.results.ids == [a])
            #expect(try await ids(#"["due", "lt", "2021-01-01"]"#).json.results.ids == [b])
            #expect(try await ids(#"["amount", "gt", 100]"#).json.results.ids == [a])
            #expect(try await ids(#"["amount", "gte", "ZAR20"]"#).json.results.ids == [a, b])
            #expect(try await ids(#"["priority", "exact", "High"]"#).json.results.ids == [c])
            #expect(try await ids(#"["due", "exists", false]"#).json.results.ids == [c])
            #expect(try await ids(#"["OR", [["priority", "in", ["hi"]], ["amount", "lt", 50]]]"#).json.results.ids == [b, c])
            #expect(try await ids(#"["NOT", ["due", "exists", true]]"#).json.results.ids == [c])
            #expect(try await ids("[\"due\", \"year__exact\", 2020]").json.results.ids == [b])
            #expect(try await ids("[\(due), \"isnull\", false]").json.results.ids == [a, b])

            let unknown = try await ids(#"["nope", "exact", 1]"#)
            #expect(unknown.status == .badRequest)
            #expect(unknown.json["custom_field_query"]?["0"] == ["'nope' is not a valid custom field."])
            let badOp = try await ids(#"["priority", "gt", 1]"#)
            #expect(badOp.json["custom_field_query"]?["1"] == ["select does not support query expr 'gt'."])
            let invalidJSON = try await ids("[oops")
            #expect(invalidJSON.json["custom_field_query"] == ["Value must be valid JSON."])

            let ordered = try await client.get("/api/documents/?ordering=-custom_field_\(amount)", as: admin)
            #expect(ordered.json.results.ids.prefix(2) == [a, b])
        }
    }

    @Test func updateDeleteRestoreAndHistory() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let parent = try env.tag("Parent")
        let child = try env.tag("Child", parent: parent)
        let inbox = try env.tag("Inbox", inbox: true)
        let acme = try env.correspondent("ACME")
        let field = try await env.app.database.write { db -> Int in
            var field = CustomField(name: "Amount", dataType: .integer)
            try field.insert(db)
            return field.id!
        }
        let id = try env.document("Original", tags: [inbox])
        try env.document("Other", asn: 7)
        try await env.run { client async throws in
            let patched = try await client.call(.patch, "/api/documents/\(id)/", as: admin, json: [
                "title": "Renamed", "correspondent": .int(acme), "tags": [.int(child), .int(inbox)],
                "created": "2022-05-06T23:30:00+02:00", "custom_fields": [["field": .int(field), "value": 42]],
                "remove_inbox_tags": true,
            ])
            #expect(patched.status == .ok)
            #expect(patched.json["title"] == "Renamed")
            #expect(patched.json["created"] == "2022-05-06")
            #expect(Set(patched.json["tags"]?.array?.compactMap(\.int) ?? []) == [parent, child])
            #expect(patched.json["custom_fields"] == [["value": 42, "field": .int(field)]])
            #expect(patched.json["permissions"] != nil) // PATCH responses carry full permissions
            #expect(patched.json["archived_file_name"] == .null)

            let asnTaken = try await client.call(.patch, "/api/documents/\(id)/", as: admin, json: ["archive_serial_number": 7])
            #expect(asnTaken.json["archive_serial_number"] == ["Document with this Archive Serial Number already exists."])
            let badTag = try await client.call(.patch, "/api/documents/\(id)/", as: admin, json: ["tags": [999]])
            #expect(badTag.json["tags"] == ["Invalid pk \"999\" - object does not exist."])
            let badValue = try await client.call(.patch, "/api/documents/\(id)/", as: admin, json: ["custom_fields": [["field": .int(field), "value": "abc"]]])
            #expect(badValue.status == .badRequest)
            let put = try await client.call(.put, "/api/documents/\(id)/", as: admin, json: ["title": "Only title"])
            #expect(put.json["correspondent"] == ["This field is required."])

            // Removing the parent removes the child too.
            let removed = try await client.call(.patch, "/api/documents/\(id)/", as: admin, json: ["tags": [.int(child)]])
            #expect(removed.json["tags"] == [])

            let history = try await client.get("/api/documents/\(id)/history/", as: admin)
            let actions = history.json.array?.compactMap { $0["action"]?.string } ?? []
            #expect(actions.contains("create") && actions.contains("update"))
            #expect(history.json[0]?["actor"]?["username"] == "admin")

            let download = try await client.get("/api/documents/\(id)/download/", as: admin)
            #expect(download.status == .ok)
            #expect(download.headers[.contentType] == "application/pdf")
            #expect(download.headers[.contentDisposition] == "attachment; filename=\"2022-05-06 ACME Renamed.pdf\"; filename*=utf-8''2022-05-06%20ACME%20Renamed.pdf")
            #expect(download.text.hasPrefix("%PDF"))

            #expect(try await client.call(.delete, "/api/documents/\(id)/", as: admin).status == .noContent)
            #expect(try await client.get("/api/documents/\(id)/", as: admin).status == .notFound)
            let trash = try await client.get("/api/trash/", as: admin)
            #expect(trash.json.results.ids == [id])
            #expect(trash.json.results[0]["deleted_at"] != .null)
            let notDeleted = try await client.call(.post, "/api/trash/", as: admin, json: ["documents": [1, 2], "action": "restore"])
            #expect(notDeleted.json["documents"] == ["Some documents in the list have not yet been deleted."])
            let restore = try await client.call(.post, "/api/trash/", as: admin, json: ["documents": [.int(id)], "action": "restore"])
            #expect(restore.json["result"] == "OK")
            #expect(try await client.get("/api/documents/\(id)/", as: admin).status == .ok)

            try await client.call(.delete, "/api/documents/\(id)/", as: admin)
            let empty = try await client.call(.post, "/api/trash/", as: admin, json: ["action": "empty"])
            #expect(empty.json["doc_ids"] == [.int(id)])
            #expect(try await env.app.database.read { db in try Document.fetchOne(db, key: id) } == nil)
        }
    }

    @Test func suggestionsPreviewRootAndHead() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let acme = try await env.app.database.write { db -> Int in
            var object = Correspondent(name: "ACME", match: "acme", matchingAlgorithm: .any)
            try object.insert(db)
            return object.id!
        }
        let id = try env.document("Letter", content: "ACME Trading invoice dated 14.03.2024")
        try await env.run { client async throws in
            let suggestions = try await client.get("/api/documents/\(id)/suggestions/", as: admin)
            #expect(suggestions.json["correspondents"] == [.int(acme)])
            #expect(suggestions.json["dates"] == ["2024-03-14"])
            #expect(suggestions.json["tags"] == [])

            let preview = try await client.get("/api/documents/\(id)/preview/", as: admin)
            #expect(preview.status == .ok)
            #expect(preview.headers[.contentDisposition]?.hasPrefix("inline; filename=\"2024-03-14 Letter.pdf\"") == true)
            let head = try await client.call(.head, "/api/documents/\(id)/download/", as: admin)
            #expect(head.status == .ok)
            #expect(head.body.readableBytes == 0)
            #expect(try await client.get("/api/documents/\(id)/root/", as: admin).json == ["root_id": .int(id)])
            #expect(try await client.get("/api/documents/999/download/", as: admin).status == .notFound)
        }
    }

    @Test func notesAndShareLinks() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let id = try env.document("Shared doc")
        try await env.run { client async throws in
            let added = try await client.call(.post, "/api/documents/\(id)/notes/", as: admin, json: ["note": "Call back"])
            #expect(added.json[0]?["note"] == "Call back")
            let noteId = try #require(added.json[0]?["id"]?.int)
            let document = try await client.get("/api/documents/\(id)/", as: admin)
            #expect(document.json["notes"]?[0]?["id"]?.int == noteId)
            let missingId = try await client.call(.delete, "/api/documents/\(id)/notes/", as: admin)
            #expect(missingId.status == .badRequest)
            let deleted = try await client.call(.delete, "/api/documents/\(id)/notes/?id=\(noteId)", as: admin)
            #expect(deleted.json == [])

            let link = try await client.call(.post, "/api/share_links/", as: admin, json: ["document": .int(id), "file_version": "original"])
            #expect(link.status == .created)
            let slug = try #require(link.json["slug"]?.string)
            #expect(slug.count == 50)
            #expect(link.json["document_title"] == "Shared doc")
            let links = try await client.get("/api/documents/\(id)/share_links/", as: admin)
            #expect(links.json[0]?["slug"]?.string == slug)

            let shared = try await client.get("/share/\(slug)", as: nil)
            #expect(shared.status == .ok)
            #expect(shared.headers[.contentDisposition]?.hasPrefix("inline;") == true)
            let unknown = try await client.get("/share/doesnotexist", as: nil)
            #expect(unknown.status == .found)
            #expect(unknown.headers[.location] == "/accounts/login/?sharelink_notfound=1")

            let expired = try await client.call(.post, "/api/share_links/", as: admin, json: ["document": .int(id), "expiration": "2000-01-01T00:00:00Z"])
            let expiredSlug = try #require(expired.json["slug"]?.string)
            let gone = try await client.get("/share/\(expiredSlug)/", as: nil)
            #expect(gone.headers[.location] == "/accounts/login/?sharelink_expired=1")

            let listed = try await client.get("/api/share_links/", as: admin)
            #expect(listed.json["count"] == 2)
        }
    }

    @Test func bulkEditMethods() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let other = try env.user("other")
        let tag = try env.tag("Bulk")
        let acme = try env.correspondent("ACME")
        let a = try env.document("A"), b = try env.document("B")
        try await env.run { client async throws in
            func bulk(_ method: String, _ parameters: JSON = [:], documents: [Int]? = nil) async throws -> TestResponse {
                try await client.call(.post, "/api/documents/bulk_edit/", as: admin, json: [
                    "documents": JSON(documents ?? [a, b]), "method": .string(method), "parameters": parameters,
                ])
            }
            #expect(try await bulk("add_tag", ["tag": .int(tag)]).json["result"] == "OK")
            #expect(try await client.get("/api/tags/\(tag)/", as: admin).json["document_count"] == 2)
            #expect(try await bulk("modify_tags", ["add_tags": [], "remove_tags": [.int(tag)]]).json["result"] == "OK")
            #expect(try await client.get("/api/tags/\(tag)/", as: admin).json["document_count"] == 0)
            #expect(try await bulk("set_correspondent", ["correspondent": .int(acme)]).json["result"] == "OK")
            #expect(try await client.get("/api/documents/\(a)/", as: admin).json["correspondent"]?.int == acme)
            #expect(try await bulk("set_permissions", ["set_permissions": ["view": ["users": [.int(other.id)]]], "owner": .int(admin.id)]).status == .ok)
            #expect(try await client.get("/api/documents/\(b)/", as: admin).json["owner"]?.int == admin.id)

            let missingTag = try await bulk("add_tag", ["tag": 999])
            #expect(missingTag.json["non_field_errors"] == ["Tag does not exist"])
            let unknownDocument = try await bulk("delete", documents: [a, 999])
            #expect(unknownDocument.json["documents"] == ["Some documents in documents don't exist or were specified twice."])
            // The fixture files are not real PDFs, so merging fails like a broken file in Paperless-ngx.
            let merge = try await bulk("merge")
            #expect(merge.status == .badRequest)
            #expect(merge.text == "Error performing document merge, check logs for more detail.")
            let unknownMethod = try await bulk("explode")
            #expect(unknownMethod.json["method"] == ["\"explode\" is not a valid choice."])

            #expect(try await bulk("delete", documents: [a]).json["result"] == "OK")
            #expect(try await client.get("/api/documents/", as: admin).json.results.ids == [b])
            let viaOperation = try await client.call(.post, "/api/documents/delete/", as: admin, json: ["documents": [.int(b)]])
            #expect(viaOperation.json["result"] == "OK")
            #expect(try await client.get("/api/documents/", as: admin).json["count"] == 0)
        }
    }

    @Test func postDocumentEndToEnd() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let tag = try env.tag("Uploaded")
        let pdf = env.dir.file("upload.pdf")
        makeTextPDF("Uploaded through the API\nInvoice 2024-0042", at: pdf)
        try await env.run { client async throws in
            var form = MultipartBody()
            form.file("document", filename: "scan é.pdf", contentType: "application/pdf", contents: try Data(contentsOf: pdf))
            form.field("title", "API upload")
            form.field("tags", String(tag))
            form.field("created", "2024-02-29")
            form.field("archive_serial_number", "77")
            let (body, headers) = form.finished()
            let response = try await client.call(.post, "/api/documents/post_document/", as: admin, headers: headers, body: body)
            #expect(response.status == .ok)
            let taskId = try #require(response.json.string)

            await env.queue.waitUntilIdle()

            let tasks = try await client.get("/api/tasks/?task_id=\(taskId)", as: admin)
            let task = try #require(tasks.json.results.first)
            #expect(task["status"] == "success")
            #expect(task["task_type"] == "consume_file")
            #expect(task["trigger_source"] == "api_upload")
            #expect(task["input_data"]?["filename"] == "scan é.pdf")
            let documentId = try #require(task["related_document_ids"]?[0]?.int)

            var v9: HTTPFields = [:]
            v9[.accept] = "application/json; version=9"
            let legacy = try await client.call(.get, "/api/tasks/?task_id=\(taskId)", as: admin, headers: v9)
            #expect(legacy.json[0]?["status"] == "SUCCESS")
            #expect(legacy.json[0]?["related_document"]?.int == documentId)
            #expect(legacy.json[0]?["task_file_name"] == "scan é.pdf")
            #expect(legacy.json[0]?["type"] == "manual_task")

            let document = try await client.get("/api/documents/\(documentId)/", as: admin)
            #expect(document.json["title"] == "API upload")
            #expect(document.json["created"] == "2024-02-29")
            #expect(document.json["archive_serial_number"] == 77)
            #expect(document.json["tags"] == [.int(tag)])
            #expect(document.json["owner"]?.int == admin.id)
            #expect(document.json["content"]?.string?.contains("Invoice 2024-0042") == true)
            #expect(document.json["original_file_name"] == "scan é.pdf")
            let file = try await client.get("/api/documents/\(documentId)/download/?original=true", as: admin)
            #expect(file.status == .ok)
            #expect(file.headers[.contentDisposition]?.contains("filename*=utf-8''2024-02-29%20API%20upload.pdf") == true)
            let thumb = try await client.get("/api/documents/\(documentId)/thumb/", as: admin)
            #expect(thumb.headers[.contentType] == "image/jpeg")
            let metadata = try await client.get("/api/documents/\(documentId)/metadata/", as: admin)
            #expect(metadata.json["original_mime_type"] == "application/pdf")
            #expect(metadata.json["original_size"]?.int ?? 0 > 0)

            let acknowledged = try await client.call(.post, "/api/tasks/acknowledge/", as: admin, json: ["tasks": [task["id"] ?? 0]])
            #expect(acknowledged.json["result"] == 1)
            let counts = try await client.get("/api/tasks/status_counts/", as: admin)
            #expect(counts.json["completed"] == 1)

            let reprocess = try await client.call(.post, "/api/documents/reprocess/", as: admin, json: ["documents": [.int(documentId)]])
            #expect(reprocess.json["result"] == "OK")
            await env.queue.waitUntilIdle()
            let reprocessed = try await client.get("/api/tasks/?task_type=reprocess_document", as: admin)
            #expect(reprocessed.json.results.first?["status"] == "success")
            #expect(try await client.get("/api/documents/\(documentId)/", as: admin).json["content"]?.string?.contains("Invoice 2024-0042") == true)
        }
    }

    @Test func postDocumentValidation() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let reader = try env.user("reader", permissions: ["view_document"])
        try await env.run { client async throws in
            var empty = MultipartBody()
            empty.field("title", "No file")
            let (body, headers) = empty.finished()
            let missing = try await client.call(.post, "/api/documents/post_document/", as: admin, headers: headers, body: body)
            #expect(missing.json["document"] == ["No file was submitted."])

            var unsupported = MultipartBody()
            unsupported.file("document", filename: "blob.bin", contentType: "application/octet-stream", contents: Data([0, 1, 2, 255, 254, 0, 9]))
            let (blob, blobHeaders) = unsupported.finished()
            let rejected = try await client.call(.post, "/api/documents/post_document/", as: admin, headers: blobHeaders, body: blob)
            #expect(rejected.status == .badRequest)
            #expect(rejected.json["document"]?[0]?.string?.hasPrefix("File type") == true)

            var badTag = MultipartBody()
            badTag.file("document", filename: "a.txt", contentType: "text/plain", contents: Data("hello".utf8))
            badTag.field("tags", "999")
            let (tagBody, tagHeaders) = badTag.finished()
            let invalidTag = try await client.call(.post, "/api/documents/post_document/", as: admin, headers: tagHeaders, body: tagBody)
            #expect(invalidTag.json["tags"] == ["Invalid pk \"999\" - object does not exist."])

            let (readerBody, readerHeaders) = badTag.finished()
            let forbidden = try await client.call(.post, "/api/documents/post_document/", as: reader, headers: readerHeaders, body: readerBody)
            #expect(forbidden.status == .forbidden)

            let json = try await client.call(.post, "/api/documents/post_document/", as: admin, json: ["document": "x"])
            #expect(json.status == .unsupportedMediaType)
        }
        // Nothing is left behind in the scratch folder.
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: env.app.settings.scratchDir.path)
        #expect(leftovers.isEmpty)
    }
}
