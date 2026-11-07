import CommonCrypto
import CryptoKit
import Foundation
import Security

public enum FernetError: Error, CustomStringConvertible, Equatable {
    case invalidKey
    case invalidToken
    case cryptoFailure(Int32)

    public var description: String {
        switch self {
        case .invalidKey: "Invalid Fernet key (expected 32 bytes, URL-safe base64)"
        case .invalidToken: "Invalid or tampered Fernet token (wrong passphrase?)"
        case .cryptoFailure(let status): "AES operation failed (status \(status))"
        }
    }
}

/// Fernet symmetric tokens (https://github.com/fernet/spec), compatible with
/// Python's `cryptography.fernet.Fernet`: AES-128-CBC with PKCS7 padding plus
/// HMAC-SHA256, URL-safe base64 with padding.
public struct Fernet: Sendable {
    let signingKey: Data
    let encryptionKey: Data

    /// `key` is the 32 raw key bytes: signing key, then encryption key.
    public init(key: Data) throws {
        guard key.count == 32 else { throw FernetError.invalidKey }
        signingKey = key.prefix(16)
        encryptionKey = key.suffix(16)
    }

    /// `key` in the form Python's `Fernet(key)` takes: 32 bytes, URL-safe base64.
    public init(base64URLKey key: String) throws {
        guard let data = Self.base64URLDecode(key) else { throw FernetError.invalidKey }
        try self.init(key: data)
    }

    /// Decrypts a token (URL-safe base64 text). Does not check the token's age.
    public func decrypt(token: String) throws -> Data {
        guard let raw = Self.base64URLDecode(token.trimmingCharacters(in: .whitespacesAndNewlines)),
              raw.count >= 1 + 8 + 16 + 16 + 32, raw.first == 0x80 else { throw FernetError.invalidToken }
        let body = raw.prefix(raw.count - 32)
        let mac = raw.suffix(32)
        let expected = Data(HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: signingKey)))
        guard PasswordHasher.constantTimeEqual(expected, Data(mac)) else { throw FernetError.invalidToken }
        let iv = body.dropFirst(9).prefix(16)
        let ciphertext = body.dropFirst(25)
        guard !ciphertext.isEmpty, ciphertext.count % 16 == 0 else { throw FernetError.invalidToken }
        return try aes(CCOperation(kCCDecrypt), Data(ciphertext), iv: Data(iv))
    }

    /// A new token for `plaintext`. `iv` and `timestamp` are for tests; the defaults are random and now.
    public func encrypt(_ plaintext: Data, iv: Data? = nil, timestamp: Date = Date()) throws -> String {
        let iv = iv ?? Self.randomBytes(16)
        guard iv.count == 16 else { throw FernetError.invalidKey }
        var body = Data([0x80])
        var seconds = UInt64(max(0, timestamp.timeIntervalSince1970)).bigEndian
        body.append(Data(bytes: &seconds, count: 8))
        body.append(iv)
        body.append(try aes(CCOperation(kCCEncrypt), plaintext, iv: iv))
        let mac = HMAC<SHA256>.authenticationCode(for: body, using: SymmetricKey(data: signingKey))
        body.append(Data(mac))
        return Self.base64URLEncode(body)
    }

    private func aes(_ operation: CCOperation, _ input: Data, iv: Data) throws -> Data {
        var output = Data(count: input.count + kCCBlockSizeAES128)
        let capacity = output.count
        var moved = 0
        let status = output.withUnsafeMutableBytes { out in
            input.withUnsafeBytes { inBytes in
                iv.withUnsafeBytes { ivBytes in
                    encryptionKey.withUnsafeBytes { keyBytes in
                        CCCrypt(operation, CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, encryptionKey.count, ivBytes.baseAddress,
                                inBytes.baseAddress, input.count, out.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw operation == CCOperation(kCCDecrypt) ? FernetError.invalidToken : FernetError.cryptoFailure(status)
        }
        return output.prefix(moved)
    }

    // MARK: Helpers

    static func base64URLDecode(_ text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64.append("=") }
        return Data(base64Encoded: base64)
    }

    static func base64URLEncode(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }

    /// PBKDF2-HMAC-SHA256 with a binary salt.
    static func pbkdf2SHA256(password: String, salt: Data, iterations: Int, length: Int) -> Data {
        let passwordBytes = Array(password.utf8)
        let saltBytes = [UInt8](salt)
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
}

/// The `--passphrase` encryption of the Paperless-ngx exporter (`CryptMixin`):
/// a Fernet key derived with PBKDF2-SHA256 from the passphrase and a hex salt,
/// and each encrypted field stored as the hex of the Fernet token.
public struct ExportCrypto: Sendable {
    /// Key of the crypto parameters in `metadata.json`.
    public static let metadataKey = "__crypto__"
    static let algorithmKey = "__key_algo__"
    static let iterationsKey = "__key_iters__"
    static let keySizeKey = "__key_size__"
    static let saltKey = "__salt_hex__"

    /// Fields that the exporter encrypts, per model.
    public static let encryptedFields: [String: [String]] = [
        "paperless_mail.mailaccount": ["password", "refresh_token"],
        "socialaccount.socialtoken": ["token", "token_secret"],
    ]

    public var algorithm: String
    public var iterations: Int
    public var keySize: Int
    public var saltHex: String
    let fernet: Fernet

    public init(passphrase: String, saltHex: String, iterations: Int = 1_000_000, keySize: Int = 32, algorithm: String = "pbkdf2_sha256") throws {
        guard algorithm == "pbkdf2_sha256" else { throw TransferError.invalidExport("\(algorithm) is an unknown key derivation function") }
        guard let salt = Data(transferHex: saltHex), keySize == 32, iterations > 0 else { throw FernetError.invalidKey }
        self.algorithm = algorithm
        self.iterations = iterations
        self.keySize = keySize
        self.saltHex = saltHex
        let key = Fernet.pbkdf2SHA256(password: passphrase, salt: salt, iterations: iterations, length: keySize)
        fernet = try Fernet(key: key)
    }

    /// New parameters with a random 16-byte salt, as the exporter does.
    public static func generate(passphrase: String, iterations: Int = 1_000_000) throws -> ExportCrypto {
        try ExportCrypto(passphrase: passphrase, saltHex: Fernet.randomBytes(16).transferHex, iterations: iterations)
    }

    /// Parameters from the `__crypto__` object of `metadata.json`.
    public init(passphrase: String, metadata: [String: JSONValue]) throws {
        guard let salt = metadata[Self.saltKey]?.stringValue else {
            throw TransferError.invalidExport("metadata.json has no \(Self.saltKey)")
        }
        try self.init(
            passphrase: passphrase,
            saltHex: salt,
            iterations: metadata[Self.iterationsKey]?.intValue ?? 1_000_000,
            keySize: metadata[Self.keySizeKey]?.intValue ?? 32,
            algorithm: metadata[Self.algorithmKey]?.stringValue ?? "pbkdf2_sha256"
        )
    }

    public var metadata: [String: JSONValue] {
        [
            Self.algorithmKey: .string(algorithm),
            Self.iterationsKey: .int(iterations),
            Self.keySizeKey: .int(keySize),
            Self.saltKey: .string(saltHex),
        ]
    }

    public func encrypt(_ value: String) throws -> String {
        Data(try fernet.encrypt(Data(value.utf8)).utf8).transferHex
    }

    public func decrypt(_ hex: String) throws -> String {
        guard let tokenBytes = Data(transferHex: hex), let token = String(data: tokenBytes, encoding: .ascii) else {
            throw FernetError.invalidToken
        }
        guard let value = String(data: try fernet.decrypt(token: token), encoding: .utf8) else { throw FernetError.invalidToken }
        return value
    }
}

extension Data {
    init?(transferHex hexString: String) {
        let chars = Array(hexString.utf8)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: c - 48
            case 65...70: c - 55
            case 97...102: c - 87
            default: nil
            }
        }
        var index = 0
        while index < chars.count {
            guard let high = nibble(chars[index]), let low = nibble(chars[index + 1]) else { return nil }
            bytes.append(high << 4 | low)
            index += 2
        }
        self.init(bytes)
    }

    var transferHex: String { map { String(format: "%02x", $0) }.joined() }
}
