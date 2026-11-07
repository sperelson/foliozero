import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import Testing
import ZIPFoundation
@testable import FolioCore
@testable import FolioServer

/// `/api/share_link_bundles/` and bundle downloads through `/share/<slug>`
/// (Paperless-ngx `test_share_link_bundles.py`).
@Suite struct ShareLinkBundleTests {
    static let endpoint = "/api/share_link_bundles/"

    /// A bundle row written directly, without queueing a build.
    @discardableResult
    func insertBundle(_ env: TestEnvironment, slug: String, status: ShareLinkBundle.Status, documents: [Int], owner: Int? = nil,
                      expiration: Date? = nil, filePath: String = "", created: Date = Date(),
                      configure: @Sendable (inout ShareLinkBundle) -> Void = { _ in }) throws -> Int {
        try env.app.database.write { db in
            var bundle = ShareLinkBundle(slug: slug, created: created, expiration: expiration, ownerId: owner, status: status, filePath: filePath)
            configure(&bundle)
            try bundle.insert(db)
            try ShareLinkBundleStore.setDocuments(documents, bundleId: bundle.id!, in: db)
            return bundle.id!
        }
    }

    func writeBundleFile(_ env: TestEnvironment, _ relative: String, _ contents: String) throws -> URL {
        let url = env.app.settings.shareLinkBundleDir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func zipEntries(_ url: URL) throws -> [String: String] {
        let archive = try Archive(url: url, accessMode: .read)
        var result: [String: String] = [:]
        for entry in archive {
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            result[entry.path] = String(decoding: data, as: UTF8.self)
        }
        return result
    }

    @Test func createBuildsZipAndServesItAnonymously() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let invoice = try env.document("Invoice")
        let receipt = try env.document("Receipt")
        let archiveName = String(format: "%07d.pdf", receipt)
        try await env.app.database.write { db in
            var document = try #require(try Document.fetchOne(db, key: receipt))
            document.archiveFilename = archiveName
            try document.update(db)
        }
        try FileManager.default.createDirectory(at: env.app.settings.archiveDir, withIntermediateDirectories: true)
        try Data("%PDF-1.4 archived receipt".utf8).write(to: env.app.settings.archiveDir.appendingPathComponent(archiveName))

        try await env.run { client async throws in
            let created = try await client.call(.post, Self.endpoint, as: admin, json: [
                "document_ids": [.int(invoice), .int(receipt)], "file_version": "archive", "expiration_days": 7,
            ])
            #expect(created.status == .created)
            // The serializer's field order (the test JSON parser does not keep key order).
            let fields = ["id", "created", "expiration", "slug", "file_version", "status", "size_bytes", "last_error", "built_at",
                          "documents", "document_count"]
            let body = created.text
            let offsets = fields.compactMap { body.range(of: "\"\($0)\":")?.lowerBound.utf16Offset(in: body) }
            #expect(offsets.count == fields.count && offsets == offsets.sorted())
            #expect(Set(created.json.object?.keys ?? []) == Set(fields))
            #expect(created.json["status"] == "pending")
            #expect(created.json["file_version"] == "archive")
            #expect(created.json["document_count"] == 2)
            #expect(Set(created.json["documents"]?.array?.compactMap(\.int) ?? []) == [invoice, receipt])
            #expect(created.json["size_bytes"] == .null)
            #expect(created.json["built_at"] == .null)
            let id = try #require(created.json["id"]?.int)
            let slug = try #require(created.json["slug"]?.string)
            #expect(slug.count == 50)
            #expect(created.json["expiration"]?.string != nil)
            let expiration = try #require(try await env.app.database.read { db in try ShareLinkBundle.fetchOne(db, key: id)?.expiration })
            #expect(abs(expiration.timeIntervalSinceNow - 7 * 86_400) < 60)

            await env.queue.waitUntilIdle()
            let ready = try await client.get("\(Self.endpoint)\(id)/", as: admin)
            #expect(ready.status == .ok)
            #expect(ready.json["status"] == "ready")
            #expect(ready.json["last_error"] == .null)
            #expect(ready.json["built_at"] != .null)
            let size = try #require(ready.json["size_bytes"]?.int)
            #expect(size > 0)

            let zipURL = env.app.settings.shareLinkBundleDir.appendingPathComponent("\(slug).zip")
            let stored = try await env.app.database.read { db in try ShareLinkBundle.fetchOne(db, key: id) }
            #expect(stored?.filePath == "\(slug).zip")
            #expect((try FileManager.default.attributesOfItem(atPath: zipURL.path)[.size] as? NSNumber)?.intValue == size)
            #expect(try zipEntries(zipURL) == [
                "2024-03-14 Invoice.pdf": "%PDF-1.4 Invoice",
                "2024-03-14 Receipt.pdf": "%PDF-1.4 archived receipt",
            ])

            let download = try await client.get("/share/\(slug)", as: nil)
            #expect(download.status == .ok)
            #expect(download.headers[.contentType] == "application/zip")
            let name = "paperless-share-\(slug.prefix(12)).zip"
            #expect(download.headers[.contentDisposition] == "attachment; filename=\"\(name)\"; filename*=utf-8''\(name)")
            #expect(Data(download.body.readableBytesView) == (try Data(contentsOf: zipURL)))
            #expect(try await client.get("/share/\(slug)/", as: nil).status == .ok)

            let list = try await client.get(Self.endpoint, as: admin)
            #expect(list.json["count"] == 1)
            #expect(list.json.results.ids == [id])
            #expect(list.json.results.first?["status"] == "ready")
        }
        let tasks = try await env.app.database.read { db in try TaskRecord.filter(Column("task_type") == "build_share_link").fetchAll(db) }
        #expect(tasks.count == 1)
        #expect(tasks.first?.status == .success)
        #expect(tasks.first?.triggerSource == .manual)
    }

    @Test func originalsBundleWithoutExpiration() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let document = try env.document("Letter")
        try await env.app.database.write { db in
            var stored = try #require(try Document.fetchOne(db, key: document))
            stored.archiveFilename = String(format: "%07d.pdf", document)
            try stored.update(db)
        }
        try FileManager.default.createDirectory(at: env.app.settings.archiveDir, withIntermediateDirectories: true)
        try Data("archive".utf8).write(to: env.app.settings.archiveDir.appendingPathComponent(String(format: "%07d.pdf", document)))
        try await env.run { client async throws in
            let created = try await client.call(.post, Self.endpoint, as: admin, json: [
                "document_ids": [.int(document)], "file_version": "original", "expiration_days": nil,
            ])
            #expect(created.status == .created)
            #expect(created.json["expiration"] == .null)
            #expect(created.json["file_version"] == "original")
            let slug = try #require(created.json["slug"]?.string)
            await env.queue.waitUntilIdle()
            let zipURL = env.app.settings.shareLinkBundleDir.appendingPathComponent("\(slug).zip")
            #expect(try zipEntries(zipURL) == ["2024-03-14 Letter.pdf": "%PDF-1.4 Letter"])
        }
    }

    @Test func createValidatesInput() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let document = try env.document("Doc")
        let trashed = try env.document("Trashed")
        try await env.app.database.write { db in
            try db.execute(sql: "UPDATE documents SET deleted_at = ? WHERE id = ?", arguments: [FolioDateFormat.database.string(from: Date()), trashed])
        }
        try await env.run { client async throws in
            func post(_ json: JSON) async throws -> TestResponse {
                try await client.call(.post, Self.endpoint, as: admin, json: json)
            }
            let missingField = try await post(["file_version": "archive"])
            #expect(missingField.status == .badRequest)
            #expect(missingField.json == ["document_ids": ["This field is required."]])
            #expect(try await post(["document_ids": []]).json == ["document_ids": ["This list may not be empty."]])
            #expect(try await post(["document_ids": "1"]).json == ["document_ids": ["Expected a list of items but got type \"str\"."]])
            #expect(try await post(["document_ids": [.int(document), .int(document)]]).json
                == ["document_ids": ["Duplicate document identifiers are not allowed."]])
            #expect(try await post(["document_ids": ["x", 0]]).json
                == ["document_ids": ["0": ["A valid integer is required."], "1": ["Ensure this value is greater than or equal to 1."]]])
            let badOptions = try await post(["document_ids": [.int(document)], "file_version": "both", "expiration_days": 0])
            #expect(badOptions.json == [
                "expiration_days": ["Ensure this value is greater than or equal to 1."],
                "file_version": ["\"both\" is not a valid choice."],
            ])
            let missing = try await post(["document_ids": [.int(document), 9999, .int(trashed)]])
            #expect(missing.status == .badRequest)
            #expect(missing.json == ["document_ids": .string("Documents not found: \(min(9999, trashed)), \(max(9999, trashed))")])
        }
        let count = try await env.app.database.read { db in try ShareLinkBundle.fetchCount(db) }
        #expect(count == 0)
    }

    @Test func permissionsAndVisibility() async throws {
        let env = try TestEnvironment()
        let bundlePerms = TestEnvironment.permissions(["sharelinkbundle"])
        let alice = try env.user("alice", permissions: bundlePerms + ["view_document"])
        let bob = try env.user("bob", permissions: bundlePerms + ["view_document"])
        let noDocumentView = try env.user("carol", permissions: bundlePerms)
        let noAdd = try env.user("dave", permissions: ["view_document", "view_sharelinkbundle"])
        let nothing = try env.user("erin", permissions: ["view_document"])
        let private_ = try env.document("Alice private", owner: alice.id)
        let open = try env.document("Unowned")
        try await env.run { client async throws in
            let payload: JSON = ["document_ids": [.int(open)]]
            #expect(try await client.call(.post, Self.endpoint, as: noAdd, json: payload).status == .forbidden)
            #expect(try await client.call(.post, Self.endpoint, as: noDocumentView, json: payload).status == .forbidden)
            #expect(try await client.get(Self.endpoint, as: nothing).status == .forbidden)
            #expect(try await client.call(.post, Self.endpoint, as: nil, json: payload).status == .unauthorized)

            let denied = try await client.call(.post, Self.endpoint, as: bob, json: ["document_ids": [.int(open), .int(private_)]])
            #expect(denied.status == .badRequest)
            #expect(denied.json == ["document_ids": .string("Insufficient permissions to share document \(private_).")])
            #expect(try await env.app.database.read { db in try ShareLinkBundle.fetchCount(db) } == 0)

            let created = try await client.call(.post, Self.endpoint, as: alice, json: ["document_ids": [.int(private_)]])
            #expect(created.status == .created)
            let id = try #require(created.json["id"]?.int)
            await env.queue.waitUntilIdle()
            #expect(try await env.app.database.read { db in try ShareLinkBundle.fetchOne(db, key: id)?.ownerId } == alice.id)

            #expect(try await client.get(Self.endpoint, as: alice).json.results.ids == [id])
            #expect(try await client.get(Self.endpoint, as: bob).json["count"] == 0)
            #expect(try await client.get("\(Self.endpoint)\(id)/", as: bob).status == .notFound)
            #expect(try await client.call(.post, "\(Self.endpoint)\(id)/rebuild/", as: bob).status == .notFound)
            #expect(try await client.call(.delete, "\(Self.endpoint)\(id)/", as: bob).status == .notFound)

            // A view grant shows the bundle, but only the owner may rebuild or delete it.
            try await env.app.database.write { db in
                var grant = ObjectPermission(objectType: ShareLinkBundle.objectType, objectId: id, permission: .view, userId: bob.id)
                try grant.insert(db)
            }
            #expect(try await client.get(Self.endpoint, as: bob).json.results.ids == [id])
            #expect(try await client.get("\(Self.endpoint)\(id)/", as: bob).status == .ok)
            #expect(try await client.call(.post, "\(Self.endpoint)\(id)/rebuild/", as: bob).status == .forbidden)
            #expect(try await client.call(.delete, "\(Self.endpoint)\(id)/", as: bob).status == .forbidden)
            #expect(try await client.call(.delete, "\(Self.endpoint)\(id)/", as: alice).status == .noContent)
        }
    }

    @Test func rebuildResetsStateAndRejectsProcessing() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let document = try env.document("Doc")
        let failed = try insertBundle(env, slug: "rebuildslug", status: .failed, documents: [document], filePath: "path/to/file.zip") { bundle in
            bundle.lastError = ["message": .string("Something went wrong")]
            bundle.sizeBytes = 100
        }
        let processing = try insertBundle(env, slug: "processingslug", status: .processing, documents: [document])
        try await env.run { client async throws in
            let rebuilt = try await client.call(.post, "\(Self.endpoint)\(failed)/rebuild/", as: admin)
            #expect(rebuilt.status == .ok)
            #expect(rebuilt.json["status"] == "pending")
            #expect(rebuilt.json["last_error"] == .null)
            #expect(rebuilt.json["size_bytes"] == .null)
            #expect(rebuilt.json["built_at"] == .null)
            await env.queue.waitUntilIdle()
            let after = try await client.get("\(Self.endpoint)\(failed)/", as: admin)
            #expect(after.json["status"] == "ready")
            #expect((after.json["size_bytes"]?.int ?? 0) > 0)
            #expect(try await env.app.database.read { db in try ShareLinkBundle.fetchOne(db, key: failed)?.filePath } == "rebuildslug.zip")

            let busy = try await client.call(.post, "\(Self.endpoint)\(processing)/rebuild/", as: admin)
            #expect(busy.status == .badRequest)
            #expect(busy.json == ["detail": "Bundle is already being processed."])

            // Bundles are immutable: no PUT or PATCH.
            #expect(try await client.call(.put, "\(Self.endpoint)\(failed)/", as: admin, json: [:]).status == .methodNotAllowed)
            #expect(try await client.call(.patch, "\(Self.endpoint)\(failed)/", as: admin, json: [:]).status == .methodNotAllowed)
            #expect(try await client.call(.post, "\(Self.endpoint)999/rebuild/", as: admin).status == .notFound)
        }
    }

    @Test func deleteRemovesTheZip() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let document = try env.document("Doc")
        let file = try writeBundleFile(env, "delete.zip", "remove-me")
        let id = try insertBundle(env, slug: "deletebundle", status: .ready, documents: [document], filePath: "delete.zip")
        try await env.run { client async throws in
            #expect(try await client.call(.delete, "\(Self.endpoint)\(id)/", as: admin).status == .noContent)
            #expect(try await client.get("\(Self.endpoint)\(id)/", as: admin).status == .notFound)
            #expect(try await client.get("\(Self.endpoint)\(id)/", as: admin).json == ["detail": "No ShareLinkBundle matches the given query."])
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
        let links = try await env.app.database.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(ShareLinkBundle.documentsTable)") ?? -1
        }
        #expect(links == 0)
    }

    @Test func publicViewReportsBundleState() async throws {
        let env = try TestEnvironment()
        let document = try env.document("Doc")
        _ = try writeBundleFile(env, "bundles/ready.zip", "binary-zip-content")
        try insertBundle(env, slug: "readyslug", status: .ready, documents: [document], filePath: "bundles/ready.zip")
        try insertBundle(env, slug: "pendingslug", status: .pending, documents: [document])
        try insertBundle(env, slug: "processingslug", status: .processing, documents: [document])
        try insertBundle(env, slug: "failedslug", status: .failed, documents: [document])
        try insertBundle(env, slug: "missingbundlefile", status: .ready, documents: [document], filePath: "bundles/gone.zip")
        try insertBundle(env, slug: "escapingslug", status: .ready, documents: [document], filePath: "../escaped.zip")
        try insertBundle(env, slug: "expiredslug", status: .ready, documents: [document], expiration: Date().addingTimeInterval(-3600),
                         filePath: "bundles/ready.zip")
        try await env.run { client async throws in
            let ready = try await client.get("/share/readyslug/", as: nil)
            #expect(ready.status == .ok)
            #expect(ready.headers[.contentType] == "application/zip")
            #expect(ready.headers[.contentDisposition]?.hasPrefix("attachment;") == true)
            #expect(ready.text == "binary-zip-content")

            let pending = try await client.get("/share/pendingslug/", as: nil)
            #expect(pending.status == .accepted)
            #expect(pending.text == "The share link bundle is still being prepared. Please try again later.")
            #expect(try await client.get("/share/processingslug/", as: nil).status == .accepted)

            let failed = try await client.get("/share/failedslug/", as: nil)
            #expect(failed.status == .serviceUnavailable)
            #expect(failed.text == "The share link bundle is unavailable.")
            #expect(try await client.get("/share/missingbundlefile/", as: nil).status == .serviceUnavailable)
            #expect(try await client.get("/share/escapingslug/", as: nil).status == .serviceUnavailable)

            let expired = try await client.get("/share/expiredslug/", as: nil)
            #expect(expired.status == .found)
            #expect(expired.headers[.location] == "/accounts/login/?sharelink_expired=1")
            let unknown = try await client.get("/share/unknownsharelink/", as: nil)
            #expect(unknown.headers[.location] == "/accounts/login/?sharelink_notfound=1")
        }
    }

    @Test func failedBuildRecordsTheError() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let document = try env.document("Missing file")
        try FileManager.default.removeItem(at: env.app.settings.originalsDir.appendingPathComponent(String(format: "%07d.pdf", document)))
        try await env.run { client async throws in
            let created = try await client.call(.post, Self.endpoint, as: admin, json: ["document_ids": [.int(document)], "file_version": "original"])
            let id = try #require(created.json["id"]?.int)
            let slug = try #require(created.json["slug"]?.string)
            await env.queue.waitUntilIdle()
            let failed = try await client.get("\(Self.endpoint)\(id)/", as: admin)
            #expect(failed.json["status"] == "failed")
            let error = try #require(failed.json["last_error"]?.object)
            #expect(Set(error.keys) == ["bundle_id", "exception_type", "message", "timestamp"])
            #expect(error["bundle_id"] == .int(id))
            #expect(error["exception_type"] == "FileNotFoundError")
            #expect(error["message"]?.string?.hasPrefix("[Errno 2] No such file or directory: ") == true)
            #expect(failed.json["size_bytes"] == .null)
            #expect(try await client.get("/share/\(slug)", as: nil).status == .serviceUnavailable)
        }
        let task = try await env.app.database.read { db in try TaskRecord.filter(Column("task_type") == "build_share_link").fetchOne(db) }
        #expect(task?.status == .failure)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: env.app.settings.scratchDir.path).filter { $0.hasPrefix("share-link-bundle-") }
        #expect(leftovers.isEmpty)
    }

    @Test func listFiltersAndOrdering() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let a = try env.document("A", created: CalendarDate(year: 2024, month: 1, day: 1))
        let b = try env.document("B", created: CalendarDate(year: 2024, month: 2, day: 1))
        let older = try insertBundle(env, slug: "olderbundle", status: .ready, documents: [a, b], created: Date().addingTimeInterval(-7200))
        let newer = try insertBundle(env, slug: "newerbundle", status: .failed, documents: [b], created: Date().addingTimeInterval(-60))
        try await env.app.database.write { db in
            try db.execute(sql: "UPDATE documents SET deleted_at = ? WHERE id = ?", arguments: [FolioDateFormat.database.string(from: Date()), a])
        }
        try await env.run { client async throws in
            func ids(_ query: String) async throws -> [Int] {
                try await client.get("\(Self.endpoint)\(query)", as: admin).json.results.ids
            }
            #expect(try await ids("") == [newer, older])
            #expect(try await ids("?ordering=created") == [older, newer])
            #expect(try await ids("?ordering=-status") == [older, newer])
            #expect(try await ids("?status=ready") == [older])
            #expect(try await ids("?documents=\(a)") == [older])
            #expect(try await ids("?documents=\(a),\(b)") == [newer, older])
            #expect(try await ids("?documents=,") == [newer, older])
            #expect(try await ids("?documents=invalid") == [])
            let cutoff = ISO8601DateFormatter().string(from: Date().addingTimeInterval(-3600))
            #expect(try await ids("?created__gt=\(cutoff)") == [newer])
            #expect(try await ids("?created__lt=\(cutoff)") == [older])
            let badStatus = try await client.get("\(Self.endpoint)?status=bogus", as: admin)
            #expect(badStatus.status == .badRequest)
            #expect(badStatus.json == ["status": ["Select a valid choice. bogus is not one of the available choices."]])

            // Trashed documents leave the list but still count, as in Paperless-ngx.
            let detail = try await client.get("\(Self.endpoint)\(older)/", as: admin)
            #expect(detail.json["documents"] == [.int(b)])
            #expect(detail.json["document_count"] == 2)

            var v9: HTTPFields = [:]
            v9[.accept] = "application/json; version=9"
            let legacy = try await client.call(.get, "\(Self.endpoint)?page_size=1", as: admin, headers: v9)
            #expect(legacy.json["all"] == [.int(newer), .int(older)])
            #expect(legacy.json["next"] != .null)
            #expect(legacy.json.results.ids == [newer])
        }
    }

    @Test func cleanupAndRecovery() async throws {
        let env = try TestEnvironment()
        let document = try env.document("Doc")
        let expiredFile = try writeBundleFile(env, "expired.zip", "expired")
        let activeFile = try writeBundleFile(env, "active.zip", "active")
        let expired = try insertBundle(env, slug: "expiredbundle", status: .ready, documents: [document],
                                       expiration: Date().addingTimeInterval(-86_400), filePath: "expired.zip")
        let active = try insertBundle(env, slug: "activebundle", status: .ready, documents: [document],
                                      expiration: Date().addingTimeInterval(86_400), filePath: "active.zip")
        let pending = try insertBundle(env, slug: "pendingbundle", status: .pending, documents: [document])
        let processing = try insertBundle(env, slug: "processingbundle", status: .processing, documents: [document])

        #expect(await ShareLinkBundleStore.cleanupExpired(app: env.app) == 1)
        #expect(!FileManager.default.fileExists(atPath: expiredFile.path))
        #expect(FileManager.default.fileExists(atPath: activeFile.path))

        await ShareLinkBundleStore.recoverInterrupted(app: env.app)
        let bundles = try await env.app.database.read { db in
            try Dictionary(uniqueKeysWithValues: ShareLinkBundle.fetchAll(db).map { ($0.id!, $0) })
        }
        #expect(bundles[expired] == nil)
        #expect(bundles[active]?.status == .ready)
        for id in [pending, processing] {
            #expect(bundles[id]?.status == .failed)
            #expect(bundles[id]?.lastError?["bundle_id"] == .int(id))
            #expect(bundles[id]?.lastError?["exception_type"] == .string("Interrupted"))
        }
    }

    @Test func lastErrorKeepsTheBuildTaskKeyOrder() {
        let json = API.lastErrorJSON([
            "timestamp": .string("t"), "message": .string("m"), "extra": .bool(true), "exception_type": .string("E"), "bundle_id": .int(1),
        ])
        #expect(json.serialized() == #"{"bundle_id":1,"exception_type":"E","message":"m","timestamp":"t","extra":true}"#)
        #expect(API.lastErrorJSON(nil) == .null)
    }

    @Test func fileURLStaysInsideTheBundleDirectory() {
        let directory = URL(fileURLWithPath: "/tmp/bundles", isDirectory: true)
        func url(_ path: String) -> URL? {
            ShareLinkBundleStore.fileURL(ShareLinkBundle(slug: "x", filePath: path), in: directory)
        }
        #expect(url("relative.zip")?.path == "/tmp/bundles/relative.zip")
        #expect(url("bundles/ready.zip")?.path == "/tmp/bundles/bundles/ready.zip")
        #expect(url("") == nil)
        #expect(url("/tmp/bundles/absolute.zip") == nil)
        #expect(url("../escaped.zip") == nil)
        #expect(url("a/../../escaped.zip") == nil)
    }
}
