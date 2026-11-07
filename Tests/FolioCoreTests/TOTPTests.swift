import Foundation
import GRDB
import Testing
@testable import FolioCore

@Suite struct TOTPTests {
    // RFC 6238 appendix B, SHA-1 seed "12345678901234567890" (8-digit codes; we use the last 6).
    let rfcSecret = Base32.encode(Data("12345678901234567890".utf8))

    @Test func rfc6238Vectors() {
        let vectors: [(TimeInterval, String)] = [(59, "287082"), (1_111_111_109, "081804"), (1_234_567_890, "005924"), (2_000_000_000, "279037")]
        for (time, expected) in vectors {
            #expect(TOTP.code(secret: rfcSecret, at: Date(timeIntervalSince1970: time)) == expected)
        }
    }

    @Test func base32RoundTrip() {
        let data = Data((0..<37).map { UInt8($0 * 7 % 256) })
        #expect(Base32.decode(Base32.encode(data)) == data)
        #expect(Base32.encode(Data("foobar".utf8)) == "MZXW6YTBOI")
    }

    @Test func driftWindowAndURL() {
        let secret = TOTP.newSecret()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = TOTP.code(secret: secret, at: now.addingTimeInterval(-30))!
        #expect(TOTP.matchingCounter(code: previous, secret: secret, at: now) != nil)
        let old = TOTP.code(secret: secret, at: now.addingTimeInterval(-90))!
        #expect(TOTP.matchingCounter(code: old, secret: secret, at: now) == nil || old == previous)
        #expect(TOTP.url(secret: secret, username: "alice").hasPrefix("otpauth://totp/FolioZero:alice?secret=\(secret)"))
        #expect(TOTP.qrSVG(for: "otpauth://totp/x")?.hasPrefix("<svg") == true)
    }

    @Test func activateVerifyAndRecoveryCodes() throws {
        let (db, _dir) = try makeTestDatabase(); _ = _dir
        let user = try db.write { db in try UserStore.createUser(username: "alice", password: "pw", in: db) }
        let secret = TOTP.newSecret()
        let start = Date()
        try db.write { db in
            #expect(throws: MFAStore.MFAError.invalidCode) { try MFAStore.activate(userId: user.id!, secret: secret, code: "000000x", in: db) }
            let codes = try MFAStore.activate(userId: user.id!, secret: secret, code: TOTP.code(secret: secret, at: start)!, in: db)
            #expect(codes.count == 10)
            #expect(try MFAStore.isActive(userId: user.id!, in: db))
            // The code used for activation cannot be replayed.
            #expect(try !MFAStore.verify(userId: user.id!, code: TOTP.code(secret: secret, at: start)!, at: start, in: db))
            let next = start.addingTimeInterval(30)
            #expect(try MFAStore.verify(userId: user.id!, code: TOTP.code(secret: secret, at: next)!, at: next, in: db))
            // Recovery codes work once.
            #expect(try MFAStore.verify(userId: user.id!, code: codes[0].uppercased(), in: db))
            #expect(try !MFAStore.verify(userId: user.id!, code: codes[0], in: db))
            #expect(try MFAStore.remainingRecoveryCodes(userId: user.id!, in: db) == 9)
            try MFAStore.deactivate(userId: user.id!, in: db)
            #expect(try !MFAStore.isActive(userId: user.id!, in: db))
        }
    }
}
