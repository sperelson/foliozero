import Foundation
import FolioParsing
import Logging

/// The assembled application: settings, database, storage and parsers.
/// Create one per process with `FolioApp.open`.
public final class FolioApp: Sendable {
    /// FolioZero's own version (the API reports the Paperless-ngx version it matches).
    public static let version = "0.1.0"

    public let settings: Settings
    public let database: FolioDatabase
    public let storage: MediaStorage
    public let parsers: ParserRegistry
    public let logger: Logger
    /// HTTP transport of the remote OCR engine. Tests inject a stub.
    public let remoteOCRTransport: any RemoteOCRTransport

    public init(settings: Settings, database: FolioDatabase, parsers: ParserRegistry, logger: Logger,
                remoteOCRTransport: any RemoteOCRTransport = URLSessionRemoteOCRTransport.shared) {
        self.settings = settings
        self.database = database
        self.storage = MediaStorage(settings: settings)
        self.parsers = parsers
        self.logger = logger
        self.remoteOCRTransport = remoteOCRTransport
    }

    /// Creates directories, opens and migrates the database, and ensures a secret key exists.
    public static func open(settings: Settings, parsers: ParserRegistry = StandardParsers.makeRegistry(), logger: Logger = Logger(label: "foliozero"),
                            remoteOCRTransport: any RemoteOCRTransport = URLSessionRemoteOCRTransport.shared) throws -> FolioApp {
        try settings.createDirectories()
        var settings = settings
        if settings.secretKey.isEmpty {
            settings.secretKey = try loadOrCreateSecretKey(in: settings.dataDir)
        }
        let database = try FolioDatabase(url: settings.databaseFile)
        return FolioApp(settings: settings, database: database, parsers: parsers, logger: logger, remoteOCRTransport: remoteOCRTransport)
    }

    // MARK: Parser selection

    /// Remote OCR settings with the stored application configuration applied. A database
    /// error leaves the settings alone.
    public func remoteOCRConfig() -> RemoteOCRConfig {
        do {
            return try RemoteOCRConfig.load(settings: settings, database: database)
        } catch {
            logger.warning("Cannot read the remote OCR application configuration: \(error)")
            return RemoteOCRConfig(settings: settings)
        }
    }

    /// The remote OCR parser for `config`, or nil when the engine is not fully configured.
    public func remoteOCRParser(_ config: RemoteOCRConfig) -> RemoteOCRParser? {
        guard config.isConfigured else { return nil }
        var parser = RemoteOCRParser(config: config.engineConfig, transport: remoteOCRTransport, isInternalHost: NetworkPolicy.isInternal)
        parser.timeout = settings.workerTimeout
        return parser
    }

    /// The parser for a file, chosen like the Paperless-ngx parser registry: a configured
    /// remote OCR engine (score 20) wins over the local parsers (10), but only when
    /// `allowRemote` is true.
    public func parser(for mimeType: String, fileName: String, allowRemote: Bool, remoteOCR: RemoteOCRConfig? = nil) -> (any DocumentParser)? {
        var registry = parsers
        if allowRemote, let remote = remoteOCRParser(remoteOCR ?? remoteOCRConfig()) {
            registry.register(remote)
        }
        return registry.parser(for: mimeType, fileName: fileName, allowRemote: allowRemote)
    }

    /// A secret kept in `<data>/secret_key` (mode 0600) when none is configured.
    static func loadOrCreateSecretKey(in dataDir: URL) throws -> String {
        let url = dataDir.appendingPathComponent("secret_key")
        if let existing = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return existing
        }
        let key = PasswordHasher.randomString(length: 50)
        FileManager.default.createFile(atPath: url.path, contents: Data(key.utf8), attributes: [.posixPermissions: 0o600])
        return key
    }

    public var matcher: Matcher { Matcher(regexTimeout: settings.matchRegexTimeout) }

    private let classifierCache = ClassifierCache()

    /// The trained classifier, reloaded when its file changes. nil when none is trained.
    public func classifier() -> DocumentClassifier? {
        classifierCache.load(from: settings.classifierFile)
    }
    public var dateExtractor: DateExtractor { DateExtractor(settings: settings) }

    public func consumer() -> Consumer { Consumer(app: self) }

    /// A new empty working folder under `SCRATCH_DIR`. The caller deletes it.
    public func makeScratchDirectory(prefix: String = "work") throws -> URL {
        let url = settings.scratchDir.appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

/// Keeps the decoded classifier until its file's modification date changes.
final class ClassifierCache: @unchecked Sendable {
    private let lock = NSLock()
    private var loadedAt: Date?
    private var classifier: DocumentClassifier?

    func load(from url: URL) -> DocumentClassifier? {
        lock.withLock {
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            guard let modified else {
                classifier = nil
                loadedAt = nil
                return nil
            }
            if modified != loadedAt {
                classifier = DocumentClassifier.load(from: url)
                loadedAt = modified
            }
            return classifier
        }
    }
}
