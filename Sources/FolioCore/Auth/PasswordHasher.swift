import CommonCrypto
import Foundation
import Security

/// Django-compatible PBKDF2-SHA256 password hashes: `pbkdf2_sha256$<iterations>$<salt>$<base64 hash>`.
/// Paperless-ngx user rows can therefore be imported with their passwords intact.
public enum PasswordHasher {
    public static let algorithm = "pbkdf2_sha256"
    /// Django 5.1 default.
    public static let defaultIterations = 870_000

    public static func hash(_ password: String, iterations: Int = defaultIterations, salt: String? = nil) -> String {
        let salt = salt ?? randomString(length: 22)
        let digest = pbkdf2(password: password, salt: salt, iterations: iterations)
        return "\(algorithm)$\(iterations)$\(salt)$\(digest.base64EncodedString())"
    }

    /// Constant-time check of `password` against an encoded hash. Unknown formats fail.
    public static func verify(_ password: String, encoded: String) -> Bool {
        let parts = encoded.split(separator: "$", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == algorithm, let iterations = Int(parts[1]), iterations > 0,
              let expected = Data(base64Encoded: String(parts[3])) else { return false }
        let actual = pbkdf2(password: password, salt: String(parts[2]), iterations: iterations, length: expected.count)
        return constantTimeEqual(actual, expected)
    }

    /// True when the hash should be upgraded (fewer iterations than the default).
    public static func needsRehash(_ encoded: String) -> Bool {
        let parts = encoded.split(separator: "$")
        guard parts.count == 4, let iterations = Int(parts[1]) else { return true }
        return parts[0] != algorithm || iterations < defaultIterations
    }

    static func pbkdf2(password: String, salt: String, iterations: Int, length: Int = 32) -> Data {
        let passwordBytes = Array(password.utf8)
        let saltBytes = Array(salt.utf8)
        var derived = [UInt8](repeating: 0, count: length)
        let status = passwordBytes.withUnsafeBufferPointer { pw in
            CCKeyDerivationPBKDF(
                CCPBKDFAlgorithm(kCCPBKDF2),
                pw.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) }, passwordBytes.count,
                saltBytes, saltBytes.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                &derived, length
            )
        }
        precondition(status == kCCSuccess, "PBKDF2 failed with status \(status)")
        return Data(derived)
    }

    static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var difference: UInt8 = 0
        for (x, y) in zip(a, b) { difference |= x ^ y }
        return difference == 0
    }

    /// Random alphanumeric string from the system CSPRNG.
    public static func randomString(length: Int, alphabet: String = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") -> String {
        let characters = Array(alphabet)
        var bytes = [UInt8](repeating: 0, count: length)
        let status = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        // Rejection sampling avoids modulo bias.
        let limit = 256 - 256 % characters.count // up to 256, so compare as Int
        var result = ""
        var index = 0
        while result.count < length {
            if index == bytes.count {
                _ = SecRandomCopyBytes(kSecRandomDefault, length, &bytes)
                index = 0
            }
            let byte = bytes[index]
            index += 1
            if Int(byte) < limit { result.append(characters[Int(byte) % characters.count]) }
        }
        return result
    }

    /// 40 hex characters, like Django REST framework tokens.
    public static func newToken() -> String {
        randomString(length: 40, alphabet: "0123456789abcdef")
    }
}
