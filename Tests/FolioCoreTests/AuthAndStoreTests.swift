import Foundation
import GRDB
import Testing
@testable import FolioCore

@Suite struct PasswordHasherTests {
    @Test func pbkdf2MatchesRFCVector() {
        // RFC 7914 / common PBKDF2-HMAC-SHA256 vector: P="password", S="salt", c=1, dkLen=32.
        let digest = PasswordHasher.pbkdf2(password: "password", salt: "salt", iterations: 1)
        #expect(digest.map { String(format: "%02x", $0) }.joined() == "120fb6cffcf8b32c43e7225256c4f837a86548c92ccc35480805987cb70be17b")
    }

    @Test func hashAndVerify() {
        let encoded = PasswordHasher.hash("lètmein", iterations: 1000, salt: "seasalt")
        #expect(encoded.hasPrefix("pbkdf2_sha256$1000$seasalt$"))
        #expect(PasswordHasher.verify("lètmein", encoded: encoded))
        #expect(!PasswordHasher.verify("letmein", encoded: encoded))
        #expect(!PasswordHasher.verify("lètmein", encoded: "md5$x$y"))
        #expect(PasswordHasher.needsRehash(encoded))
    }

    @Test func tokensAreRandomHex() {
        let a = PasswordHasher.newToken(), b = PasswordHasher.newToken()
        #expect(a.count == 40 && a != b)
        #expect(a.allSatisfy { $0.isHexDigit })
    }
}

@Suite struct UserStoreTests {
    @Test func createAuthenticateAndTokens() throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        let user = try db.write { db in try UserStore.createUser(username: "alice", password: "secret", in: db) }
        #expect(throws: UserStoreError.usernameTaken("ALICE")) {
            try db.write { db in try UserStore.createUser(username: "ALICE", password: "x", in: db) }
        }
        #expect(try db.write { db in try UserStore.authenticate(username: "alice", password: "secret", in: db) }?.id == user.id)
        #expect(try db.write { db in try UserStore.authenticate(username: "alice", password: "wrong", in: db) } == nil)
        #expect(try db.write { db in try UserStore.authenticate(username: "bob", password: "secret", in: db) } == nil)

        let token = try db.write { db in try UserStore.token(for: user.id!, in: db) }
        #expect(try db.write { db in try UserStore.token(for: user.id!, in: db) } == token)
        #expect(try db.read { db in try UserStore.user(forToken: token, in: db) }?.username == "alice")
        let fresh = try db.write { db in try UserStore.regenerateToken(for: user.id!, in: db) }
        #expect(fresh != token)
        #expect(try db.read { db in try UserStore.user(forToken: token, in: db) } == nil)
    }

    @Test func sessionsExpire() throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        let user = try db.write { db in try UserStore.createUser(username: "alice", password: "secret", in: db) }
        let live = try db.write { db in try UserStore.createSession(userId: user.id!, lifetime: 60, in: db) }
        let dead = try db.write { db in try UserStore.createSession(userId: user.id!, lifetime: -60, in: db) }
        #expect(try db.write { db in try UserStore.session(key: live.key, in: db) } != nil)
        #expect(try db.write { db in try UserStore.session(key: dead.key, in: db) } == nil)
    }
}

@Suite struct PermissionTests {
    @Test func visibilityFollowsOwnerAndGrants() throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        let (alice, bob, carol) = try db.write { db in
            (try UserStore.createUser(username: "alice", password: "a", in: db),
             try UserStore.createUser(username: "bob", password: "b", in: db),
             try UserStore.createUser(username: "carol", password: "c", in: db))
        }
        let (ownedByAlice, shared, public_) = try db.write { db -> (Int, Int, Int) in
            var a = Document.fixture("alice private"); a.ownerId = alice.id
            var s = Document.fixture("alice shared"); s.ownerId = alice.id
            let p = Document.fixture("no owner")
            let ids = (try DocumentStore.insert(a, in: db).id!, try DocumentStore.insert(s, in: db).id!, try DocumentStore.insert(p, in: db).id!)
            var group = Group(name: "family")
            try group.insert(db)
            try db.execute(sql: "INSERT INTO user_groups(user_id, group_id) VALUES (?, ?)", arguments: [carol.id, group.id])
            try PermissionSet(view: .init(users: [bob.id!]), change: .init(groups: [group.id!]))
                .apply(objectType: "document", objectId: ids.1, in: db)
            return ids
        }

        func visible(_ user: User) throws -> Set<Int> {
            try db.read { db in
                let context = try AccessContext.load(userId: user.id!, in: db)!
                let predicate = context.visibilityPredicate(objectType: "document", alias: "d")
                return Set(try Int.fetchAll(db, SQLRequest<Int>(literal: "SELECT d.id FROM documents d WHERE \(predicate)")))
            }
        }
        #expect(try visible(alice) == [ownedByAlice, shared, public_])
        #expect(try visible(bob) == [shared, public_])
        #expect(try visible(carol) == [shared, public_])

        try db.read { db in
            let bobContext = try AccessContext.load(userId: bob.id!, in: db)!
            let carolContext = try AccessContext.load(userId: carol.id!, in: db)!
            #expect(try bobContext.can(.view, objectType: "document", objectId: shared, ownerId: alice.id, in: db))
            #expect(try !bobContext.can(.change, objectType: "document", objectId: shared, ownerId: alice.id, in: db))
            #expect(try carolContext.can(.change, objectType: "document", objectId: shared, ownerId: alice.id, in: db))
            #expect(try PermissionSet.load(objectType: "document", objectId: shared, in: db).view.users == [bob.id!])
        }
    }
}

@Suite struct DocumentStoreTests {
    @Test func nestedTagsAddAncestorsAndRemoveDescendants() throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        try db.write { db in
            var finance = Tag(name: "Finance"); try finance.insert(db)
            var bank = Tag(name: "Bank", parentId: finance.id); try bank.insert(db)
            var fnb = Tag(name: "FNB", parentId: bank.id); try fnb.insert(db)
            let doc = try DocumentStore.insert(.fixture("Statement"), tagIds: [fnb.id!], in: db)
            #expect(Set(try DocumentStore.tagIds(of: doc.id!, in: db)) == [finance.id!, bank.id!, fnb.id!])
            try DocumentStore.removeTags(documentId: doc.id!, tagIds: [bank.id!], in: db)
            #expect(try DocumentStore.tagIds(of: doc.id!, in: db) == [finance.id!])
        }
    }

    @Test func tagParentValidation() throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        try db.write { db in
            var ids: [Int] = []
            var parent: Int?
            for level in 1...5 {
                var tag = Tag(name: "L\(level)", parentId: parent)
                try tag.insert(db)
                ids.append(tag.id!)
                parent = tag.id
            }
            var extra = Tag(name: "L6"); try extra.insert(db)
            #expect(throws: DocumentStoreError.tagTooDeep("L6")) { try DocumentStore.setParent(tagId: extra.id!, parentId: ids[4], in: db) }
            #expect(throws: DocumentStoreError.tagCycle("L1")) { try DocumentStore.setParent(tagId: ids[0], parentId: ids[2], in: db) }
            try DocumentStore.setParent(tagId: extra.id!, parentId: ids[3], in: db)
        }
    }

    @Test func asnUniquenessAndDuplicates() throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        try db.write { db in
            let first = try DocumentStore.insert(.fixture("One", checksum: "abc", asn: 7), in: db)
            #expect(throws: DocumentStoreError.asnInUse(7)) { try DocumentStore.insert(.fixture("Two", asn: 7), in: db) }
            #expect(try DocumentStore.nextArchiveSerialNumber(in: db) == 8)
            #expect(try DocumentStore.duplicates(of: "abc", in: db).map(\.id) == [first.id])
            #expect(try DocumentStore.duplicates(of: "abc", excluding: first.id, in: db).isEmpty)
        }
    }

    @Test func updateRecordsHistoryAndTrashHidesFromSearch() throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        try db.write { db in
            var doc = try DocumentStore.insert(.fixture("Old title", content: "electricity"), in: db)
            doc.title = "New title"
            try DocumentStore.update(doc, in: db)
            let history = try AuditLog.entries(objectType: "document", objectId: doc.id!, in: db)
            #expect(history.map(\.action) == [.update, .create])
            #expect(history.first?.changes?["title"] == ["Old title", "New title"])

            try DocumentStore.moveToTrash(doc.id!, in: db)
            #expect(try SearchIndex.search(.term("electricity", field: .default), in: db).isEmpty)
            try DocumentStore.restoreFromTrash(doc.id!, in: db)
            #expect(try SearchIndex.search(.term("electricity", field: .default), in: db).count == 1)
            try DocumentStore.purge(doc.id!, in: db)
            #expect(try Document.fetchCount(db) == 0)
        }
    }
}
