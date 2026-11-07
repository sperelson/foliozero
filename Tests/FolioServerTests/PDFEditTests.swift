import Foundation
import GRDB
import HTTPTypes
import Hummingbird
import HummingbirdTesting
import PDFKit
import Testing
@testable import FolioCore
@testable import FolioServer

@Suite struct PDFEditTests {
    func pageCount(_ response: TestResponse) -> Int {
        PDFDocument(data: Data(response.body.readableBytesView))?.pageCount ?? -1
    }

    @Test func rotateMergeSplitEditAndVersions() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let twoPages = env.dir.file("two.pdf"), onePage = env.dir.file("one.pdf")
        makeMultiPagePDF(["Alpha page one", "Alpha page two"], at: twoPages)
        makeMultiPagePDF(["Beta single page"], at: onePage)
        try await env.run { client async throws in
            let a = try await client.upload(twoPages, as: admin, env: env, title: "Alpha")
            let b = try await client.upload(onePage, as: admin, env: env, title: "Beta")
            #expect(try await client.call(.patch, "/api/documents/\(a)/", as: admin, json: ["archive_serial_number": 5]).status == .ok)

            // Rotation adds a version of the root.
            let rotate = try await client.call(.post, "/api/documents/rotate/", as: admin, json: ["documents": [.int(a)], "degrees": 90])
            #expect(rotate.json["result"] == "OK")
            await env.queue.waitUntilIdle()
            #expect(try await client.get("/api/documents/\(a)/", as: admin).json["versions"]?.array?.count == 2)
            let badDegrees = try await client.call(.post, "/api/documents/rotate/", as: admin, json: ["documents": [.int(a)], "degrees": 45])
            #expect(badDegrees.json["degrees"] == ["degrees must be a multiple of 90"])

            // Merge creates a new document from both.
            let merge = try await client.call(.post, "/api/documents/merge/", as: admin, json: [
                "documents": [.int(a), .int(b)], "metadata_document_id": .int(b),
            ])
            #expect(merge.json["result"] == "OK")
            await env.queue.waitUntilIdle()
            let merged = try await client.get("/api/documents/?title__iexact=Beta%20(merged)", as: admin).json.results
            #expect(merged.count == 1)
            let mergedId = try #require(merged.first?["id"]?.int)
            #expect(pageCount(try await client.get("/api/documents/\(mergedId)/download/?original=true", as: admin)) == 3)

            // Legacy split with delete_originals: two new documents, the original goes to the trash and gives up its ASN.
            let split = try await client.call(.post, "/api/documents/bulk_edit/", as: admin, json: [
                "documents": [.int(a)], "method": "split", "parameters": ["pages": "1,2", "delete_originals": true],
            ])
            #expect(split.json["result"] == "OK")
            await env.queue.waitUntilIdle()
            let parts = try await client.get("/api/documents/?title__istartswith=Alpha%20(split", as: admin).json.results
            #expect(parts.count == 2)
            #expect(try await client.get("/api/trash/", as: admin).json.results.ids == [a])
            let badPages = try await client.call(.post, "/api/documents/bulk_edit/", as: admin, json: [
                "documents": [.int(b)], "method": "split", "parameters": ["pages": "1-9"],
            ])
            #expect(badPages.json["non_field_errors"] == ["invalid pages specified"])

            // edit_pdf into two documents.
            let edit = try await client.call(.post, "/api/documents/edit_pdf/", as: admin, json: [
                "documents": [.int(mergedId)], "operations": [["page": 3, "rotate": 180], ["page": 1, "doc": 1]],
            ])
            #expect(edit.json["result"] == "OK")
            await env.queue.waitUntilIdle()
            #expect(try await client.get("/api/documents/?title__iexact=Beta%20(merged)", as: admin).json["count"] == 3)
            let outOfRange = try await client.call(.post, "/api/documents/edit_pdf/", as: admin, json: [
                "documents": [.int(mergedId)], "operations": [["page": 9]],
            ])
            #expect(outOfRange.json["non_field_errors"] == ["Page 9 is out of bounds for document with 3 pages."])

            // Legacy delete_pages makes a version without the page.
            let deletePages = try await client.call(.post, "/api/documents/bulk_edit/", as: admin, json: [
                "documents": [.int(mergedId)], "method": "delete_pages", "parameters": ["pages": [2]],
            ])
            #expect(deletePages.json["result"] == "OK")
            await env.queue.waitUntilIdle()
            #expect(pageCount(try await client.get("/api/documents/\(mergedId)/download/?original=true", as: admin)) == 2)

            // merge_as_versions turns b into a version of the merged document.
            let asVersions = try await client.call(.post, "/api/documents/merge_as_versions/", as: admin, json: [
                "documents": [.int(mergedId), .int(b)], "root_document_id": .int(mergedId), "version_label": "scan",
            ])
            #expect(asVersions.json["result"] == "OK")
            #expect(try await client.get("/api/documents/\(b)/", as: admin).status == .notFound)
            let versions = try await client.get("/api/documents/\(mergedId)/", as: admin).json["versions"]?.array ?? []
            #expect(versions.contains { $0["id"]?.int == b && $0["version_label"] == "scan" })
            let notMember = try await client.call(.post, "/api/documents/merge_as_versions/", as: admin, json: [
                "documents": [.int(mergedId), .int(b)], "root_document_id": 999,
            ])
            #expect(notMember.status == .badRequest)

            // remove_password on an unencrypted PDF is a no-op.
            let unlock = try await client.call(.post, "/api/documents/remove_password/", as: admin, json: ["documents": [.int(mergedId)], "password": "x"])
            #expect(unlock.json["result"] == "OK")
        }
    }

    @Test func bulkDownloadAndEmail() async throws {
        let env = try TestEnvironment()
        let admin = try env.user("admin", superuser: true)
        let owner = try env.user("owner", permissions: ["view_document"])
        let a = try env.document("Same name"), b = try env.document("Same name")
        let secret = try env.document("Secret", owner: owner.id)
        let other = try env.user("other", permissions: ["view_document"])
        try await env.run { client async throws in
            let zip = try await client.call(.post, "/api/documents/bulk_download/", as: admin, json: [
                "documents": [.int(a), .int(b)], "content": "both", "compression": "deflated",
            ])
            #expect(zip.status == .ok)
            #expect(zip.headers[.contentType] == "application/zip")
            #expect(zip.headers[.contentDisposition]?.hasPrefix("attachment; filename=\"documents.zip\"") == true)
            let bytes = Data(zip.body.readableBytesView)
            #expect(bytes.prefix(2) == Data("PK".utf8))
            let listing = String(decoding: bytes, as: UTF8.self)
            #expect(listing.contains("originals/2024-03-14 Same name.pdf"))
            #expect(listing.contains("originals/2024-03-14 Same name_01.pdf"))

            let forbidden = try await client.call(.post, "/api/documents/bulk_download/", as: other, json: ["documents": [.int(secret)]])
            #expect(forbidden.status == .forbidden)

            let badAddress = try await client.call(.post, "/api/documents/email/", as: admin, json: [
                "documents": [.int(a)], "addresses": "nope", "subject": "S", "message": "M",
            ])
            #expect(badAddress.json["addresses"] == ["Invalid email address: nope"])
            let unconfigured = try await client.call(.post, "/api/documents/email/", as: admin, json: [
                "documents": [.int(a)], "addresses": "a@example.com", "subject": "S", "message": "M",
            ])
            #expect(unconfigured.status == .internalServerError)
            #expect(unconfigured.text == "Error emailing documents, check logs for more detail.")
        }
    }
}
