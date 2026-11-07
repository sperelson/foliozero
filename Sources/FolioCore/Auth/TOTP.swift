import CoreImage
import CryptoKit
import Foundation
import GRDB
import Security

/// Time-based one-time passwords (RFC 6238, HMAC-SHA1, 6 digits, 30 s), as django-allauth's
/// MFA module uses for Paperless-ngx two-factor login.
public enum TOTP {
    public static let digits = 6
    public static let period: TimeInterval = 30

    /// A new random secret, base32 encoded (160 bits).
    public static func newSecret() -> String {
        var bytes = [UInt8](repeating: 0, count: 20)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Base32.encode(Data(bytes))
    }

    /// The code for a given time.
    public static func code(secret: String, at date: Date = Date()) -> String? {
        code(secret: secret, counter: UInt64(date.timeIntervalSince1970 / period))
    }

    static func code(secret: String, counter: UInt64) -> String? {
        guard let key = Base32.decode(secret) else { return nil }
        var bigEndian = counter.bigEndian
        let message = Data(bytes: &bigEndian, count: 8)
        let mac = Array(HMAC<Insecure.SHA1>.authenticationCode(for: message, using: SymmetricKey(data: key)))
        let offset = Int(mac[mac.count - 1] & 0x0F)
        let value = (UInt32(mac[offset] & 0x7F) << 24) | (UInt32(mac[offset + 1]) << 16) | (UInt32(mac[offset + 2]) << 8) | UInt32(mac[offset + 3])
        let modulo = UInt32(pow(10, Double(digits)))
        return String(format: "%0\(digits)u", value % modulo)
    }

    /// The time step a code is valid for, checking one step either side for clock drift.
    /// Returns nil when the code does not match.
    public static func matchingCounter(code: String, secret: String, at date: Date = Date()) -> UInt64? {
        let cleaned = code.filter(\.isNumber)
        guard cleaned.count == digits else { return nil }
        let now = UInt64(date.timeIntervalSince1970 / period)
        for counter in [now, now - 1, now + 1] where Self.code(secret: secret, counter: counter) == cleaned {
            return counter
        }
        return nil
    }

    /// `otpauth://` URL for authenticator apps.
    public static func url(secret: String, username: String, issuer: String = "FolioZero") -> String {
        let allowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: ":/"))
        let label = (issuer.addingPercentEncoding(withAllowedCharacters: allowed) ?? issuer) + ":" + (username.addingPercentEncoding(withAllowedCharacters: allowed) ?? username)
        let issuerParam = issuer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? issuer
        return "otpauth://totp/\(label)?secret=\(secret)&issuer=\(issuerParam)&digits=\(digits)&period=\(Int(period))"
    }

    /// The URL as an SVG QR code (one rect per dark module).
    public static func qrSVG(for text: String) -> String? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage else { return nil }
        let context = CIContext(options: [.useSoftwareRenderer: true])
        let width = Int(image.extent.width), height = Int(image.extent.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        context.render(image, toBitmap: &pixels, rowBytes: width * 4, bounds: image.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        let quiet = 4
        let size = width + 2 * quiet
        var rects = ""
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4] < 128 {
                rects += "<rect x=\"\(x + quiet)\" y=\"\(y + quiet)\" width=\"1\" height=\"1\"/>"
            }
        }
        return "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 \(size) \(size)\" shape-rendering=\"crispEdges\"><rect width=\"100%\" height=\"100%\" fill=\"#fff\"/><g fill=\"#000\">\(rects)</g></svg>"
    }
}

/// RFC 4648 base32 without padding.
enum Base32 {
    static let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")

    static func encode(_ data: Data) -> String {
        var result = ""
        var buffer: UInt32 = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | UInt32(byte)
            bits += 8
            while bits >= 5 {
                result.append(alphabet[Int((buffer >> UInt32(bits - 5)) & 31)])
                bits -= 5
            }
        }
        if bits > 0 { result.append(alphabet[Int((buffer << UInt32(5 - bits)) & 31)]) }
        return result
    }

    static func decode(_ string: String) -> Data? {
        var result = Data()
        var buffer: UInt32 = 0
        var bits = 0
        for char in string.uppercased() where char != "=" && char != " " {
            guard let value = alphabet.firstIndex(of: char) else { return nil }
            buffer = (buffer << 5) | UInt32(value)
            bits += 5
            if bits >= 8 {
                result.append(UInt8((buffer >> UInt32(bits - 8)) & 0xFF))
                bits -= 8
            }
        }
        return result
    }
}

/// Stored two-factor authenticators (allauth `Authenticator`: TOTP and recovery codes).
public enum MFAStore {
    public enum Kind: String, Sendable { case totp, recoveryCodes = "recovery_codes" }

    public enum MFAError: Error, CustomStringConvertible, Equatable {
        case invalidCode
        case alreadyActive

        public var description: String {
            switch self {
            case .invalidCode: "Incorrect code"
            case .alreadyActive: "Two-factor authentication is already active"
            }
        }
    }

    struct TOTPData: Codable {
        var secret: String
        var lastCounter: UInt64?
    }

    struct RecoveryData: Codable {
        /// SHA-256 hashes of unused codes.
        var unused: [String]
    }

    /// Schema for migration "v3-mfa".
    static func createTable(_ db: Database) throws {
        try db.create(table: "mfa_authenticators") { t in
            t.autoIncrementedPrimaryKey("id")
            t.column("user_id", .integer).notNull().indexed().references("users", onDelete: .cascade)
            t.column("type", .text).notNull()
            t.column("data", .jsonText).notNull()
            t.column("created", .datetime).notNull()
            t.column("last_used", .datetime)
            t.uniqueKey(["user_id", "type"])
        }
    }

    public static func isActive(userId: Int, in db: Database) throws -> Bool {
        return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mfa_authenticators WHERE user_id = ? AND type = 'totp'", arguments: [userId]) ?? 0 > 0
    }

    /// Activates TOTP with a secret the user confirmed with `code`. Returns ten recovery codes, shown once.
    public static func activate(userId: Int, secret: String, code: String, in db: Database) throws -> [String] {
        guard try !isActive(userId: userId, in: db) else { throw MFAError.alreadyActive }
        guard let counter = TOTP.matchingCounter(code: code, secret: secret) else { throw MFAError.invalidCode }
        let data = String(decoding: try JSONEncoder().encode(TOTPData(secret: secret, lastCounter: counter)), as: UTF8.self)
        let now = FolioDateFormat.database.string(from: Date())
        try db.execute(sql: "INSERT INTO mfa_authenticators(user_id, type, data, created) VALUES (?, 'totp', ?, ?)", arguments: [userId, data, now])
        return try regenerateRecoveryCodes(userId: userId, in: db)
    }

    public static func deactivate(userId: Int, in db: Database) throws {
        try db.execute(sql: "DELETE FROM mfa_authenticators WHERE user_id = ?", arguments: [userId])
    }

    @discardableResult
    public static func regenerateRecoveryCodes(userId: Int, in db: Database) throws -> [String] {
        let codes = (0..<10).map { _ in PasswordHasher.randomString(length: 8, alphabet: "abcdefghjkmnpqrstuvwxyz23456789") }
        let data = String(decoding: try JSONEncoder().encode(RecoveryData(unused: codes.map(hash))), as: UTF8.self)
        try db.execute(sql: "DELETE FROM mfa_authenticators WHERE user_id = ? AND type = 'recovery_codes'", arguments: [userId])
        try db.execute(sql: "INSERT INTO mfa_authenticators(user_id, type, data, created) VALUES (?, 'recovery_codes', ?, ?)",
                       arguments: [userId, data, FolioDateFormat.database.string(from: Date())])
        return codes
    }

    /// Checks a TOTP code (each time step only once) or an unused recovery code (consumed).
    public static func verify(userId: Int, code: String, at date: Date = Date(), in db: Database) throws -> Bool {
        let now = FolioDateFormat.database.string(from: date)
        if let raw = try String.fetchOne(db, sql: "SELECT data FROM mfa_authenticators WHERE user_id = ? AND type = 'totp'", arguments: [userId]),
           var totp = try? JSONDecoder().decode(TOTPData.self, from: Data(raw.utf8)),
           let counter = TOTP.matchingCounter(code: code, secret: totp.secret, at: date) {
            if let last = totp.lastCounter, counter <= last { return false } // replayed code
            totp.lastCounter = counter
            try db.execute(sql: "UPDATE mfa_authenticators SET data = ?, last_used = ? WHERE user_id = ? AND type = 'totp'",
                           arguments: [String(decoding: try JSONEncoder().encode(totp), as: UTF8.self), now, userId])
            return true
        }
        let normalized = code.lowercased().filter { $0.isLetter || $0.isNumber }
        if let raw = try String.fetchOne(db, sql: "SELECT data FROM mfa_authenticators WHERE user_id = ? AND type = 'recovery_codes'", arguments: [userId]),
           var recovery = try? JSONDecoder().decode(RecoveryData.self, from: Data(raw.utf8)),
           let index = recovery.unused.firstIndex(of: hash(normalized)) {
            recovery.unused.remove(at: index)
            try db.execute(sql: "UPDATE mfa_authenticators SET data = ?, last_used = ? WHERE user_id = ? AND type = 'recovery_codes'",
                           arguments: [String(decoding: try JSONEncoder().encode(recovery), as: UTF8.self), now, userId])
            return true
        }
        return false
    }

    public static func remainingRecoveryCodes(userId: Int, in db: Database) throws -> Int {
        guard let raw = try String.fetchOne(db, sql: "SELECT data FROM mfa_authenticators WHERE user_id = ? AND type = 'recovery_codes'", arguments: [userId]),
              let recovery = try? JSONDecoder().decode(RecoveryData.self, from: Data(raw.utf8)) else { return 0 }
        return recovery.unused.count
    }

    static func hash(_ code: String) -> String {
        SHA256.hash(data: Data(code.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
