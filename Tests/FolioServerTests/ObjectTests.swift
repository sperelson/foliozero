import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
@testable import FolioCore
@testable import FolioServer

@Suite struct ObjectTests {
    @Test func tagCRUDWithHierarchyAndCounts() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        try await env.run { client async throws in
            let parent = try await client.call(.post, "/api/tags/", as: admin, json: ["name": "Finance", "color": "#000000", "is_inbox_tag": false])
            #expect(parent.status == .created)
            #expect(parent.json["slug"] == "finance")
            #expect(parent.json["text_color"] == "#ffffff")
            #expect(parent.json["owner"]?.int == admin.id)
            #expect(parent.json["user_can_change"] == true)
            let parentId = try #require(parent.json["id"]?.int)

            let child = try await client.call(.post, "/api/tags/", as: admin, json: ["name": "Tax Returns", "parent": .int(parentId)])
            #expect(child.status == .created)
            #expect(child.json["parent"]?.int == parentId)
            let childId = try #require(child.json["id"]?.int)

            let doc = try env.document("Return 2023", tags: [childId])
            let detail = try await client.get("/api/tags/\(parentId)/", as: admin)
            #expect(detail.json["document_count"] == 1) // ancestors are added to documents
            #expect(detail.json["children"]?[0]?["id"]?.int == childId)
            #expect(detail.json["children"]?[0]?["slug"] == "tax-returns")

            let duplicate = try await client.call(.post, "/api/tags/", as: admin, json: ["name": "Finance"])
            #expect(duplicate.status == .badRequest)
            #expect(duplicate.json["error"] == ["Object violates owner / name unique constraint"])

            let badColor = try await client.call(.post, "/api/tags/", as: admin, json: ["name": "Bad", "color": "red"])
            #expect(badColor.json["color"] == ["Invalid color."])

            let badRegex = try await client.call(.post, "/api/tags/", as: admin, json: ["name": "Re", "matching_algorithm": 4, "match": "("])
            #expect(badRegex.json["match"] == ["Invalid regular expression, see log for details."])

            let cycle = try await client.call(.patch, "/api/tags/\(parentId)/", as: admin, json: ["parent": .int(childId)])
            #expect(cycle.status == .badRequest)
            #expect(cycle.json["parent"] != nil)

            let renamed = try await client.call(.patch, "/api/tags/\(childId)/", as: admin, json: ["name": "Taxes", "matching_algorithm": 3, "match": "tax"])
            #expect(renamed.json["name"] == "Taxes")
            #expect(renamed.json["matching_algorithm"] == 3)

            let filtered = try await client.get("/api/tags/?name__icontains=tax&full_perms=true", as: admin)
            #expect(filtered.json["count"] == 1)
            #expect(filtered.json.results[0]["permissions"]?["view"]?["users"] == [])
            #expect(filtered.json.results[0]["user_can_change"] == nil)

            let roots = try await client.get("/api/tags/?is_root=true", as: admin)
            #expect(roots.json.results.ids == [parentId])
            #expect(roots.json["display_count"] == 2)

            let deleted = try await client.call(.delete, "/api/tags/\(parentId)/", as: admin)
            #expect(deleted.status == .noContent)
            #expect(try await client.get("/api/tags/\(childId)/", as: admin).status == .notFound)
            let tags = try await env.app.database.read { db in try DocumentStore.tagIds(of: doc, in: db) }
            #expect(tags.isEmpty)
        }
    }

    @Test func paginationEnvelope() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        for index in 1...7 { _ = try env.correspondent(String(format: "Corr %02d", index)) }
        try await env.run { client async throws in
            let first = try await client.get("/api/correspondents/?page_size=3", as: admin)
            #expect(first.json["count"] == 7)
            #expect(first.json["previous"] == .null)
            #expect(first.json["next"]?.string == "http://localhost/api/correspondents/?page=2&page_size=3")
            #expect(first.json.results.count == 3)
            #expect(first.json.results[0]["name"] == "Corr 01")

            let second = try await client.get("/api/correspondents/?page_size=3&page=2", as: admin)
            #expect(second.json["previous"]?.string == "http://localhost/api/correspondents/?page_size=3")
            let last = try await client.get("/api/correspondents/?page_size=3&page=3", as: admin)
            #expect(last.json["next"] == .null)
            #expect(last.json.results.count == 1)

            let invalid = try await client.get("/api/correspondents/?page=9", as: admin)
            #expect(invalid.status == .notFound)
            #expect(invalid.json["detail"] == "Invalid page.")

            let ordered = try await client.get("/api/correspondents/?ordering=-name&page_size=1", as: admin)
            #expect(ordered.json.results[0]["name"] == "Corr 07")
            let byIds = try await client.get("/api/correspondents/?id__in=1,2", as: admin)
            #expect(byIds.json["count"] == 2)
        }
    }

    @Test func objectsRespectOwnershipAndCountsRespectDocumentPermissions() async throws {
        let env = try TestEnvironment()
        let perms = TestEnvironment.permissions(TestEnvironment.regularModels)
        let alice = try env.user("alice", permissions: perms)
        let bob = try env.user("bob", permissions: perms)
        let shared = try env.tag("Shared")
        let privateTag = try env.tag("Alice only", owner: alice.id)
        try env.document("Alice private", owner: alice.id, tags: [shared])
        try env.document("Public", tags: [shared])
        try await env.run { client async throws in
            let forBob = try await client.get("/api/tags/", as: bob)
            #expect(forBob.json.results.ids == [shared])
            #expect(forBob.json.results[0]["document_count"] == 1)
            let forAlice = try await client.get("/api/tags/", as: alice)
            #expect(Set(forAlice.json.results.ids) == [shared, privateTag])
            #expect(forAlice.json.results.first { $0["id"]?.int == shared }?["document_count"] == 2)

            #expect(try await client.get("/api/tags/\(privateTag)/", as: bob).status == .notFound)
            #expect(try await client.call(.delete, "/api/tags/\(privateTag)/", as: bob).status == .notFound)

            // Grant bob view: visible but not changeable.
            let granted = try await client.call(.patch, "/api/tags/\(privateTag)/", as: alice,
                                                json: ["set_permissions": ["view": ["users": [.int(bob.id)]], "change": ["users": []]]])
            #expect(granted.status == .ok)
            let viewable = try await client.get("/api/tags/\(privateTag)/", as: bob)
            #expect(viewable.status == .ok)
            #expect(viewable.json["user_can_change"] == false)
            let change = try await client.call(.patch, "/api/tags/\(privateTag)/", as: bob, json: ["name": "Hijacked"])
            #expect(change.status == .forbidden)

            // Only owners may change permissions.
            try await client.call(.patch, "/api/tags/\(privateTag)/", as: alice, json: ["set_permissions": ["change": ["users": [.int(bob.id)]]]])
            let stealOwner = try await client.call(.patch, "/api/tags/\(privateTag)/", as: bob, json: ["owner": .int(bob.id)])
            #expect(stealOwner.status == .forbidden)
            #expect(stealOwner.json["detail"] == "Insufficient permissions.")
            let rename = try await client.call(.patch, "/api/tags/\(privateTag)/", as: bob, json: ["name": "Renamed"])
            #expect(rename.status == .ok)
        }
    }

    @Test func correspondentsDocumentTypesAndStoragePaths() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let acme = try env.correspondent("ACME")
        let first = try env.document("Invoice 1", created: CalendarDate(year: 2023, month: 1, day: 5), correspondent: acme)
        try env.document("Invoice 2", created: CalendarDate(year: 2024, month: 2, day: 9), correspondent: acme)
        try await env.run { client async throws in
            let detail = try await client.get("/api/correspondents/\(acme)/", as: admin)
            #expect(detail.json["last_correspondence"] == "2024-02-09")
            #expect(detail.json["document_count"] == 2)
            let list = try await client.get("/api/correspondents/", as: admin)
            #expect(list.json.results[0]["last_correspondence"] == nil)
            let withLast = try await client.get("/api/correspondents/?last_correspondence=true", as: admin)
            #expect(withLast.json.results[0]["last_correspondence"] == "2024-02-09")

            let type = try await client.call(.post, "/api/document_types/", as: admin, json: ["name": "Invoice", "matching_algorithm": 1, "match": "invoice"])
            #expect(type.status == .created)
            #expect(type.json["document_count"] == 0)
            let badAlgorithm = try await client.call(.post, "/api/document_types/", as: admin, json: ["name": "X", "matching_algorithm": 9])
            #expect(badAlgorithm.json["matching_algorithm"] == ["\"9\" is not a valid choice."])

            let path = try await client.call(.post, "/api/storage_paths/", as: admin, json: ["name": "By year", "path": "{created_year}/{title}"])
            #expect(path.status == .created)
            #expect(path.json["path"] == "{{ created_year }}/{{ title }}")
            let test = try await client.call(.post, "/api/storage_paths/test/", as: admin, json: ["path": "{{ correspondent }}/{{ title }}", "document": .int(first)])
            #expect(test.json == "ACME/Invoice 1.pdf")
            let missing = try await client.call(.post, "/api/storage_paths/test/", as: admin, json: ["path": "x", "document": 999])
            #expect(missing.status == .badRequest)
        }
    }

    @Test func customFieldsAndSavedViews() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        try await env.run { client async throws in
            let select = try await client.call(.post, "/api/custom_fields/", as: admin, json: [
                "name": "Priority", "data_type": "select",
                "extra_data": ["select_options": [["label": "High"], ["label": "Low", "id": "low"]]],
            ])
            #expect(select.status == .created)
            #expect(select.json["extra_data"]?["select_options"]?[1]?["id"] == "low")
            #expect(select.json["extra_data"]?["select_options"]?[0]?["id"]?.string?.count == 16)
            let invalid = try await client.call(.post, "/api/custom_fields/", as: admin, json: ["name": "Bad", "data_type": "select"])
            #expect(invalid.json["error"] == ["extra_data.select_options must be a valid list"])
            let money = try await client.call(.post, "/api/custom_fields/", as: admin, json: [
                "name": "Amount", "data_type": "monetary", "extra_data": ["default_currency": "ZAR"],
            ])
            #expect(money.json["extra_data"]?["default_currency"] == "ZAR")
            let list = try await client.get("/api/custom_fields/", as: admin)
            #expect(list.json.results.map { $0["name"] } == ["Amount", "Priority"])

            var v9: HTTPFields = [:]
            v9[.accept] = "application/json; version=9"
            let view = try await client.call(.post, "/api/saved_views/", as: admin, json: [
                "name": "Inbox", "sort_field": "created", "sort_reverse": true, "show_on_dashboard": true,
                "filter_rules": [["rule_type": 6, "value": "1"]], "display_fields": ["title", "tag"],
            ], headers: v9)
            #expect(view.status == .created)
            #expect(view.json["show_on_dashboard"] == true)
            #expect(view.json["show_in_sidebar"] == false)
            #expect(view.json["filter_rules"] == [["rule_type": 6, "value": "1"]])
            let viewId = try #require(view.json["id"]?.int)
            let v10 = try await client.get("/api/saved_views/\(viewId)/", as: admin)
            #expect(v10.json["show_on_dashboard"] == nil)
            let badField = try await client.call(.patch, "/api/saved_views/\(viewId)/", as: admin, json: ["display_fields": ["nonsense"]])
            #expect(badField.status == .badRequest)
            let settings = try await client.get("/api/ui_settings/", as: admin)
            #expect(settings.json["settings"]?["saved_views"]?["dashboard_views_visible_ids"] == [.int(viewId)])
        }
    }

    @Test func bulkEditObjects() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let other = try env.user("other", permissions: TestEnvironment.permissions(TestEnvironment.regularModels))
        let a = try env.tag("A"), b = try env.tag("B"), child = try env.tag("B child", parent: b)
        try await env.run { client async throws in
            let permissions = try await client.call(.post, "/api/bulk_edit_objects/", as: admin, json: [
                "objects": [.int(a)], "object_type": "tags", "operation": "set_permissions", "owner": .int(admin.id),
                "permissions": ["view": ["users": [.int(other.id)]]],
            ])
            #expect(permissions.json["result"] == "OK")
            let tag = try await client.get("/api/tags/\(a)/?full_perms=true", as: admin)
            #expect(tag.json["owner"]?.int == admin.id)
            #expect(tag.json["permissions"]?["view"]?["users"] == [.int(other.id)])

            let forbidden = try await client.call(.post, "/api/bulk_edit_objects/", as: other, json: [
                "objects": [.int(a)], "object_type": "tags", "operation": "delete",
            ])
            #expect(forbidden.status == .forbidden)

            let deleted = try await client.call(.post, "/api/bulk_edit_objects/", as: admin, json: [
                "objects": [.int(b)], "object_type": "tags", "operation": "delete",
            ])
            #expect(deleted.json["result"] == "OK")
            #expect(try await client.get("/api/tags/\(child)/", as: admin).status == .notFound)
        }
    }

    @Test func usersAndGroups() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let manager = try env.user("manager", permissions: TestEnvironment.permissions(["user", "group"]))
        try await env.run { client async throws in
            let group = try await client.call(.post, "/api/groups/", as: admin, json: ["name": "Accounting", "permissions": ["view_document", "change_tag"]])
            #expect(group.status == .created)
            #expect(group.json["permissions"] == ["change_tag", "view_document"])
            let groupId = try #require(group.json["id"]?.int)
            let badPermission = try await client.call(.post, "/api/groups/", as: admin, json: ["name": "X", "permissions": ["fly"]])
            #expect(badPermission.status == .badRequest)

            let user = try await client.call(.post, "/api/users/", as: admin, json: [
                "username": "eve", "email": "eve@example.com", "groups": [.int(groupId)], "user_permissions": ["add_document"],
            ])
            #expect(user.status == .created)
            #expect(user.json["inherited_permissions"] == ["documents.change_tag", "documents.view_document"])
            #expect(user.json["password"] == "**********")
            #expect(user.json["is_mfa_enabled"] == false)
            let duplicate = try await client.call(.post, "/api/users/", as: admin, json: ["username": "EVE"])
            #expect(duplicate.json["username"] == ["A user with that username already exists."])

            let escalate = try await client.call(.post, "/api/users/", as: manager, json: ["username": "root2", "is_superuser": true])
            #expect(escalate.status == .forbidden)
            let modifyAdmin = try await client.call(.patch, "/api/users/\(admin.id)/", as: manager, json: ["first_name": "x"])
            #expect(modifyAdmin.status == .forbidden)

            let list = try await client.get("/api/users/?username__icontains=ev", as: manager)
            #expect(list.json.results.map { $0["username"] } == ["eve"])
            let eveId = try #require(user.json["id"]?.int)
            #expect(try await client.call(.delete, "/api/users/\(eveId)/", as: manager).status == .noContent)
            #expect(try await client.call(.delete, "/api/groups/\(groupId)/", as: manager).status == .noContent)
        }
    }

    @Test func unimplementedListsAreEmptyAndUnknownPathsAre404() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        try await env.run { client async throws in
            let mail = try await client.get("/api/mail_accounts/", as: admin)
            #expect(mail.json["count"] == 0)
            #expect(try await client.get("/api/nothing/", as: admin).status == .notFound)
            let wrongMethod = try await client.call(.put, "/api/documents/next_asn/", as: admin)
            #expect(wrongMethod.status == .methodNotAllowed)
            let index = try await client.get("/api/", as: admin)
            #expect(index.json["documents"] == "http://localhost/api/documents/")
        }
    }
}
