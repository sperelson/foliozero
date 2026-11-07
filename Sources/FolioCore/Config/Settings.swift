import Foundation
import FolioParsing

/// Date component order used when parsing dates from content or file names.
public enum DateOrder: String, Sendable, Codable, CaseIterable {
    case DMY, MDY, YMD, YDM, DYM, MYD
}

/// All FolioZero settings. Names follow Paperless-ngx (`PAPERLESS_X` becomes `X`).
///
/// Build with `SettingsLoader.load(...)`. Every property has the Paperless-ngx
/// default unless noted.
public struct Settings: Sendable {
    // MARK: Paths
    public var home: URL
    public var dataDir: URL
    public var mediaRoot: URL
    public var consumptionDir: URL
    public var scratchDir: URL
    public var loggingDir: URL
    public var emptyTrashDir: URL?
    public var databaseFile: URL { dataDir.appendingPathComponent("foliozero.sqlite") }
    public var classifierFile: URL { dataDir.appendingPathComponent("classifier.json") }
    public var originalsDir: URL { mediaRoot.appendingPathComponent("documents/originals", isDirectory: true) }
    public var archiveDir: URL { mediaRoot.appendingPathComponent("documents/archive", isDirectory: true) }
    public var thumbnailDir: URL { mediaRoot.appendingPathComponent("documents/thumbnails", isDirectory: true) }
    /// Built share link bundle zips (Paperless-ngx `SHARE_LINK_BUNDLE_DIR`). Created on first use.
    public var shareLinkBundleDir: URL { mediaRoot.appendingPathComponent("documents/share_link_bundles", isDirectory: true) }

    // MARK: File naming
    public var filenameFormat: String?
    public var filenameFormatRemoveNone: Bool

    // MARK: Web server
    public var secretKey: String
    public var url: String?
    public var bindAddress: String
    public var port: Int
    public var allowedHosts: [String]
    public var corsAllowedHosts: [String]
    public var csrfTrustedOrigins: [String]
    public var trustedProxies: [String]
    public var autoLoginUsername: String?
    public var adminUser: String?
    public var adminMail: String?
    public var adminPassword: String?
    public var cookiePrefix: String
    public var sessionCookieAge: Int
    public var enableHTTPRemoteUser: Bool
    public var enableHTTPRemoteUserAPI: Bool
    public var httpRemoteUserHeaderName: String
    public var appTitle: String?
    public var appLogo: String?

    // MARK: OCR and parsing
    public var ocrLanguage: [String]
    public var ocrMode: OCRMode
    public var archiveFileGeneration: ArchiveMode
    public var ocrEngine: OCREngineKind
    public var ocrPages: Int
    public var ocrImageDPI: Int?
    public var ocrRotatePages: Bool
    public var ocrOutputPDFA: Bool
    public var tesseractPath: String?
    public var libreOfficePath: String?
    public var ghostscriptPath: String?
    public var thumbnailMaxPixels: Int

    // MARK: Remote OCR
    /// `REMOTE_OCR_ENGINE`. Only `azureai` is known. nil leaves remote OCR off.
    public var remoteOCREngine: String?
    public var remoteOCRAPIKey: String?
    /// `REMOTE_OCR_ENDPOINT`. Required for Azure AI.
    public var remoteOCREndpoint: String?
    /// `REMOTE_OCR_MODE`: `always` (default) or `workflow_only`.
    public var remoteOCRMode: RemoteOCRMode
    /// `REMOTE_OCR_ALLOW_INTERNAL_ENDPOINTS`. Default true.
    public var remoteOCRAllowInternalEndpoints: Bool

    // MARK: Tasks and scheduling
    public var taskWorkers: Int
    public var workerTimeout: TimeInterval
    public var timeZone: TimeZone
    public var emailTaskCron: String
    public var trainTaskCron: String
    public var indexTaskCron: String
    public var sanityTaskCron: String
    public var workflowScheduledTaskCron: String
    public var emptyTrashTaskCron: String
    public var shareLinkBundleCleanupCron: String

    // MARK: Matching, dates, search
    public var matchRegexTimeout: TimeInterval
    public var dateParserLanguages: [String]
    public var dateOrder: DateOrder
    public var filenameDateOrder: DateOrder?
    public var numberOfSuggestedDates: Int
    public var ignoreDates: [String]
    public var searchLanguage: String?
    public var advancedFuzzySearchThreshold: Double?

    // MARK: Consumer
    public var consumerDisable: Bool
    public var consumerDeleteDuplicates: Bool
    public var consumerRecursive: Bool
    public var consumerSubdirsAsTags: Bool
    public var consumerIgnorePatterns: [String]
    public var consumerIgnoreDirs: [String]
    public var consumerPollingInterval: TimeInterval
    public var consumerStabilityDelay: TimeInterval
    public var preConsumeScript: String?
    public var postConsumeScript: String?

    // MARK: Barcodes and collation
    public var consumerEnableBarcodes: Bool
    public var consumerBarcodeTIFFSupport: Bool
    public var consumerBarcodeString: String
    public var consumerBarcodeRetainSplitPages: Bool
    public var consumerEnableASNBarcode: Bool
    public var consumerASNBarcodePrefix: String
    public var consumerBarcodeUpscale: Double
    public var consumerBarcodeDPI: Int
    public var consumerBarcodeMaxPages: Int
    public var consumerEnableTagBarcode: Bool
    public var consumerTagBarcodeMapping: [String: String]
    public var consumerTagBarcodeSplit: Bool
    public var consumerStoreBarcodeValues: Bool
    public var consumerEnableCollateDoubleSided: Bool
    public var consumerCollateDoubleSidedSubdirName: String
    public var consumerCollateDoubleSidedTIFFSupport: Bool

    // MARK: Housekeeping
    public var auditLogEnabled: Bool
    public var emptyTrashDelayDays: Int
    public var logRotateMaxSize: Int
    public var logRotateMaxBackups: Int
    public var logLevel: String

    // MARK: Email sending
    public var emailHost: String?
    public var emailPort: Int
    public var emailHostUser: String?
    public var emailHostPassword: String?
    public var emailFrom: String?
    public var emailUseTLS: Bool
    public var emailUseSSL: Bool

    // MARK: Webhooks
    public var webhooksAllowedSchemes: [String]
    public var webhooksAllowedPorts: [Int]
    public var webhooksAllowInternalRequests: Bool
    public var emailAllowInternalHosts: Bool

    /// Every FOLIOZERO_/PAPERLESS_ setting from overrides, environment and config file,
    /// prefix removed. Holds settings without a typed property, such as REPORTED_VERSION.
    public var raw: [String: String]

    /// Options for the parsers, derived from these settings.
    public func parseOptions(scratchDirectory: URL) -> ParseOptions {
        ParseOptions(
            ocrMode: ocrMode,
            archiveMode: archiveFileGeneration,
            ocrEngine: ocrEngine,
            languages: ocrLanguage,
            ocrPages: ocrPages,
            imageDPI: ocrImageDPI,
            rotatePages: ocrRotatePages,
            scratchDirectory: scratchDirectory,
            thumbnailMaxPixels: thumbnailMaxPixels,
            pdfPasswords: [],
            tesseractPath: tesseractPath,
            libreOfficePath: libreOfficePath,
            ghostscriptPath: ghostscriptPath,
            pdfA: ocrOutputPDFA
        )
    }

    /// Create every directory FolioZero writes to.
    public func createDirectories() throws {
        let fm = FileManager.default
        for dir in [dataDir, mediaRoot, consumptionDir, scratchDir, loggingDir, originalsDir, archiveDir, thumbnailDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let emptyTrashDir {
            try fm.createDirectory(at: emptyTrashDir, withIntermediateDirectories: true)
        }
    }
}

public enum SettingsError: Error, CustomStringConvertible {
    case invalidValue(key: String, value: String, expected: String)
    case unreadableConfig(URL, String)

    public var description: String {
        switch self {
        case let .invalidValue(key, value, expected):
            "Invalid value for \(key): \"\(value)\" (expected \(expected))"
        case let .unreadableConfig(url, why):
            "Cannot read config file \(url.path): \(why)"
        }
    }
}

/// Loads settings from CLI overrides, the environment, and a config file.
///
/// Precedence, highest first: `overrides`, environment `FOLIOZERO_X`,
/// environment `PAPERLESS_X`, config file `FOLIOZERO_X`, config file
/// `PAPERLESS_X`, built-in default.
public struct SettingsLoader {
    public static let defaultHome = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/FolioZero", isDirectory: true)

    public static let defaultIgnorePatterns = [
        ".DS_Store", ".DS_STORE", "._*", ".stfolder/*", ".stversions/*", ".localized/*",
        "@eaDir/*", "desktop.ini", "Thumbs.db", ".~lock.*", "*.part", "*.crdownload", "*.download",
    ]

    /// - Parameters:
    ///   - home: `--home` flag. Falls back to `FOLIOZERO_HOME`, then the default.
    ///   - configFile: `--config` flag. Falls back to `FOLIOZERO_CONFIG`, then `<home>/foliozero.conf`, then `/etc/foliozero.conf`.
    ///   - overrides: keys without prefix, e.g. `["PORT": "8001"]`.
    public static func load(
        home: String? = nil,
        configFile: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        overrides: [String: String] = [:]
    ) throws -> Settings {
        let homeURL = URL(fileURLWithPath: expandTilde(
            home ?? environment["FOLIOZERO_HOME"] ?? defaultHome.path
        ), isDirectory: true)

        var fileValues: [String: String] = [:]
        let configCandidates: [String] = {
            if let configFile { return [configFile] }
            if let env = environment["FOLIOZERO_CONFIG"] ?? environment["PAPERLESS_CONFIGURATION_PATH"] { return [env] }
            return [homeURL.appendingPathComponent("foliozero.conf").path, "/etc/foliozero.conf"]
        }()
        for candidate in configCandidates {
            let url = URL(fileURLWithPath: expandTilde(candidate))
            if FileManager.default.fileExists(atPath: url.path) {
                fileValues = try parseConfigFile(url)
                break
            } else if configFile != nil {
                throw SettingsError.unreadableConfig(url, "file does not exist")
            }
        }

        var source = Source(overrides: overrides, environment: environment, file: fileValues)
        return try source.build(home: homeURL)
    }

    /// Parse a `KEY=VALUE` file. `#` starts a comment; values may be quoted.
    public static func parseConfigFile(_ url: URL) throws -> [String: String] {
        let text: String
        do {
            text = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw SettingsError.unreadableConfig(url, error.localizedDescription)
        }
        return parseConfigText(text)
    }

    public static func parseConfigText(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line.removeFirst(7) }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let quote = value.first, quote == "\"" || quote == "'", value.count >= 2, value.last == quote {
                value = String(value.dropFirst().dropLast())
            } else if let hash = value.range(of: " #") {
                value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
            }
            result[key] = value
        }
        return result
    }

    static func expandTilde(_ path: String) -> String {
        (path as NSString).expandingTildeInPath
    }

    /// Looks up a key across all sources and converts it.
    struct Source {
        let overrides: [String: String]
        let environment: [String: String]
        let file: [String: String]

        mutating func string(_ key: String) -> String? {
            let candidates: [String?] = [
                overrides[key],
                environment["FOLIOZERO_\(key)"], environment["PAPERLESS_\(key)"],
                file["FOLIOZERO_\(key)"], file["PAPERLESS_\(key)"],
            ]
            guard let value = candidates.compactMap({ $0 }).first else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }

        mutating func string(_ key: String, default value: String) -> String {
            string(key) ?? value
        }

        mutating func bool(_ key: String, default value: Bool) throws -> Bool {
            guard let raw = string(key) else { return value }
            switch raw.lowercased() {
            case "1", "true", "yes", "y", "on", "t": return true
            case "0", "false", "no", "n", "off", "f": return false
            default: throw SettingsError.invalidValue(key: key, value: raw, expected: "true or false")
            }
        }

        mutating func int(_ key: String, default value: Int) throws -> Int {
            try optionalInt(key) ?? value
        }

        mutating func optionalInt(_ key: String) throws -> Int? {
            guard let raw = string(key) else { return nil }
            guard let number = Int(raw) else {
                throw SettingsError.invalidValue(key: key, value: raw, expected: "an integer")
            }
            return number
        }

        mutating func double(_ key: String, default value: Double) throws -> Double {
            try optionalDouble(key) ?? value
        }

        mutating func optionalDouble(_ key: String) throws -> Double? {
            guard let raw = string(key) else { return nil }
            guard let number = Double(raw) else {
                throw SettingsError.invalidValue(key: key, value: raw, expected: "a number")
            }
            return number
        }

        mutating func list(_ key: String, default value: [String] = [], separator: Character = ",") -> [String] {
            guard let raw = string(key) else { return value }
            if raw.hasPrefix("[") { // JSON list, as Paperless-ngx accepts
                if let data = raw.data(using: .utf8),
                   let array = try? JSONSerialization.jsonObject(with: data) as? [String] {
                    return array
                }
            }
            return raw.split(separator: separator).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }

        mutating func enumValue<E: RawRepresentable>(_ key: String, default value: E) throws -> E where E.RawValue == String {
            guard let raw = string(key) else { return value }
            if let parsed = E(rawValue: raw) ?? E(rawValue: raw.lowercased()) ?? E(rawValue: raw.uppercased()) {
                return parsed
            }
            throw SettingsError.invalidValue(key: key, value: raw, expected: "one of the documented values")
        }

        mutating func path(_ key: String, default value: URL) -> URL {
            guard let raw = string(key) else { return value }
            return URL(fileURLWithPath: SettingsLoader.expandTilde(raw), isDirectory: true)
        }

        /// Every prefixed key from every source, prefix removed, highest precedence winning.
        /// Lets other modules read settings this loader has no property for.
        func allValues() -> [String: String] {
            var result: [String: String] = [:]
            func add(_ source: [String: String]) {
                for prefix in ["PAPERLESS_", "FOLIOZERO_"] {
                    for (key, value) in source where key.hasPrefix(prefix) {
                        result[String(key.dropFirst(prefix.count))] = value
                    }
                }
            }
            add(file)
            add(environment)
            result.merge(overrides) { _, new in new }
            return result
        }

        mutating func build(home: URL) throws -> Settings {
            let dataDir = path("DATA_DIR", default: home.appendingPathComponent("data", isDirectory: true))
            let mediaRoot = path("MEDIA_ROOT", default: home.appendingPathComponent("media", isDirectory: true))
            let consumptionDir = path("CONSUMPTION_DIR", default: home.appendingPathComponent("consume", isDirectory: true))
            let scratchDir = path("SCRATCH_DIR", default: home.appendingPathComponent("scratch", isDirectory: true))
            let loggingDir = path("LOGGING_DIR", default: dataDir.appendingPathComponent("log", isDirectory: true))
            let emptyTrashDir = string("EMPTY_TRASH_DIR").map { URL(fileURLWithPath: SettingsLoader.expandTilde($0), isDirectory: true) }

            let ocrEngine = try enumValue("OCR_ENGINE", default: OCREngineKind.vision)
            let ocrOutputType = string("OCR_OUTPUT_TYPE", default: "pdf").lowercased()

            let timeZoneName = string("TIME_ZONE")
            let timeZone: TimeZone
            if let timeZoneName {
                guard let zone = TimeZone(identifier: timeZoneName) else {
                    throw SettingsError.invalidValue(key: "TIME_ZONE", value: timeZoneName, expected: "an IANA time zone such as Africa/Johannesburg")
                }
                timeZone = zone
            } else {
                timeZone = .current
            }

            var tagMapping: [String: String] = [:]
            if let raw = string("CONSUMER_TAG_BARCODE_MAPPING"),
               let data = raw.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
                tagMapping = object
            } else {
                tagMapping = ["TAG:(.*)": "\\g<1>"]
            }

            let settings = Settings(
                home: home,
                dataDir: dataDir,
                mediaRoot: mediaRoot,
                consumptionDir: consumptionDir,
                scratchDir: scratchDir,
                loggingDir: loggingDir,
                emptyTrashDir: emptyTrashDir,
                filenameFormat: string("FILENAME_FORMAT"),
                filenameFormatRemoveNone: try bool("FILENAME_FORMAT_REMOVE_NONE", default: false),
                secretKey: string("SECRET_KEY", default: ""),
                url: string("URL"),
                bindAddress: string("BIND_ADDR", default: "::"),
                port: try int("PORT", default: 8000),
                allowedHosts: list("ALLOWED_HOSTS", default: ["*"]),
                corsAllowedHosts: list("CORS_ALLOWED_HOSTS"),
                csrfTrustedOrigins: list("CSRF_TRUSTED_ORIGINS"),
                trustedProxies: list("TRUSTED_PROXIES"),
                autoLoginUsername: string("AUTO_LOGIN_USERNAME"),
                adminUser: string("ADMIN_USER"),
                adminMail: string("ADMIN_MAIL"),
                adminPassword: string("ADMIN_PASSWORD"),
                cookiePrefix: string("COOKIE_PREFIX", default: ""),
                sessionCookieAge: try int("SESSION_COOKIE_AGE", default: 1_209_600),
                enableHTTPRemoteUser: try bool("ENABLE_HTTP_REMOTE_USER", default: false),
                enableHTTPRemoteUserAPI: try bool("ENABLE_HTTP_REMOTE_USER_API", default: false),
                httpRemoteUserHeaderName: string("HTTP_REMOTE_USER_HEADER_NAME", default: "HTTP_REMOTE_USER"),
                appTitle: string("APP_TITLE"),
                appLogo: string("APP_LOGO"),
                ocrLanguage: list("OCR_LANGUAGE", default: ["eng"], separator: "+"),
                ocrMode: try enumValue("OCR_MODE", default: OCRMode.auto),
                archiveFileGeneration: try enumValue("ARCHIVE_FILE_GENERATION", default: ArchiveMode.auto),
                ocrEngine: ocrEngine,
                ocrPages: try int("OCR_PAGES", default: 0),
                ocrImageDPI: try optionalInt("OCR_IMAGE_DPI"),
                ocrRotatePages: try bool("OCR_ROTATE_PAGES", default: true),
                ocrOutputPDFA: ocrOutputType.hasPrefix("pdfa"),
                tesseractPath: string("TESSERACT_BINARY"),
                libreOfficePath: string("LIBREOFFICE_BINARY"),
                ghostscriptPath: string("GS_BINARY"),
                thumbnailMaxPixels: try int("THUMBNAIL_MAX_PIXELS", default: 500),
                remoteOCREngine: string("REMOTE_OCR_ENGINE"),
                remoteOCRAPIKey: string("REMOTE_OCR_API_KEY"),
                remoteOCREndpoint: string("REMOTE_OCR_ENDPOINT"),
                remoteOCRMode: try enumValue("REMOTE_OCR_MODE", default: RemoteOCRMode.always),
                remoteOCRAllowInternalEndpoints: try bool("REMOTE_OCR_ALLOW_INTERNAL_ENDPOINTS", default: true),
                taskWorkers: try int("TASK_WORKERS", default: max(1, ProcessInfo.processInfo.activeProcessorCount / 4)),
                workerTimeout: try double("WORKER_TIMEOUT", default: 1800),
                timeZone: timeZone,
                emailTaskCron: string("EMAIL_TASK_CRON", default: "*/10 * * * *"),
                trainTaskCron: string("TRAIN_TASK_CRON", default: "5 */1 * * *"),
                indexTaskCron: string("INDEX_TASK_CRON", default: "0 0 * * *"),
                sanityTaskCron: string("SANITY_TASK_CRON", default: "30 0 * * sun"),
                workflowScheduledTaskCron: string("WORKFLOW_SCHEDULED_TASK_CRON", default: "5 */1 * * *"),
                emptyTrashTaskCron: string("EMPTY_TRASH_TASK_CRON", default: "0 1 * * *"),
                shareLinkBundleCleanupCron: string("SHARE_LINK_BUNDLE_CLEANUP_CRON", default: "0 2 * * *"),
                matchRegexTimeout: try double("MATCH_REGEX_TIMEOUT_SECONDS", default: 1.0),
                dateParserLanguages: list("DATE_PARSER_LANGUAGES", separator: "+"),
                dateOrder: try enumValue("DATE_ORDER", default: DateOrder.DMY),
                filenameDateOrder: try string("FILENAME_DATE_ORDER").map { raw in
                    guard let order = DateOrder(rawValue: raw.uppercased()) else {
                        throw SettingsError.invalidValue(key: "FILENAME_DATE_ORDER", value: raw, expected: "DMY, MDY, YMD, ...")
                    }
                    return order
                },
                numberOfSuggestedDates: try int("NUMBER_OF_SUGGESTED_DATES", default: 3),
                ignoreDates: list("IGNORE_DATES"),
                searchLanguage: string("SEARCH_LANGUAGE"),
                advancedFuzzySearchThreshold: try optionalDouble("ADVANCED_FUZZY_SEARCH_THRESHOLD"),
                consumerDisable: try bool("CONSUMER_DISABLE", default: false),
                consumerDeleteDuplicates: try bool("CONSUMER_DELETE_DUPLICATES", default: false),
                consumerRecursive: try bool("CONSUMER_RECURSIVE", default: false),
                consumerSubdirsAsTags: try bool("CONSUMER_SUBDIRS_AS_TAGS", default: false),
                consumerIgnorePatterns: list("CONSUMER_IGNORE_PATTERNS", default: SettingsLoader.defaultIgnorePatterns),
                consumerIgnoreDirs: list("CONSUMER_IGNORE_DIRS"),
                consumerPollingInterval: try double("CONSUMER_POLLING_INTERVAL", default: 0),
                consumerStabilityDelay: try double("CONSUMER_STABILITY_DELAY", default: 5),
                preConsumeScript: string("PRE_CONSUME_SCRIPT"),
                postConsumeScript: string("POST_CONSUME_SCRIPT"),
                consumerEnableBarcodes: try bool("CONSUMER_ENABLE_BARCODES", default: false),
                consumerBarcodeTIFFSupport: try bool("CONSUMER_BARCODE_TIFF_SUPPORT", default: false),
                consumerBarcodeString: string("CONSUMER_BARCODE_STRING", default: "PATCHT"),
                consumerBarcodeRetainSplitPages: try bool("CONSUMER_BARCODE_RETAIN_SPLIT_PAGES", default: false),
                consumerEnableASNBarcode: try bool("CONSUMER_ENABLE_ASN_BARCODE", default: false),
                consumerASNBarcodePrefix: string("CONSUMER_ASN_BARCODE_PREFIX", default: "ASN"),
                consumerBarcodeUpscale: try double("CONSUMER_BARCODE_UPSCALE", default: 0),
                consumerBarcodeDPI: try int("CONSUMER_BARCODE_DPI", default: 300),
                consumerBarcodeMaxPages: try int("CONSUMER_BARCODE_MAX_PAGES", default: 0),
                consumerEnableTagBarcode: try bool("CONSUMER_ENABLE_TAG_BARCODE", default: false),
                consumerTagBarcodeMapping: tagMapping,
                consumerTagBarcodeSplit: try bool("CONSUMER_TAG_BARCODE_SPLIT", default: false),
                consumerStoreBarcodeValues: try bool("CONSUMER_STORE_BARCODE_VALUES", default: false),
                consumerEnableCollateDoubleSided: try bool("CONSUMER_ENABLE_COLLATE_DOUBLE_SIDED", default: false),
                consumerCollateDoubleSidedSubdirName: string("CONSUMER_COLLATE_DOUBLE_SIDED_SUBDIR_NAME", default: "double-sided"),
                consumerCollateDoubleSidedTIFFSupport: try bool("CONSUMER_COLLATE_DOUBLE_SIDED_TIFF_SUPPORT", default: false),
                auditLogEnabled: try bool("AUDIT_LOG_ENABLED", default: true),
                emptyTrashDelayDays: try int("EMPTY_TRASH_DELAY", default: 30),
                logRotateMaxSize: try int("LOGROTATE_MAX_SIZE", default: 1024 * 1024),
                logRotateMaxBackups: try int("LOGROTATE_MAX_BACKUPS", default: 20),
                logLevel: string("LOGGING_LEVEL", default: "info").lowercased(),
                emailHost: string("EMAIL_HOST"),
                emailPort: try int("EMAIL_PORT", default: 25),
                emailHostUser: string("EMAIL_HOST_USER"),
                emailHostPassword: string("EMAIL_HOST_PASSWORD"),
                emailFrom: string("EMAIL_FROM"),
                emailUseTLS: try bool("EMAIL_USE_TLS", default: false),
                emailUseSSL: try bool("EMAIL_USE_SSL", default: false),
                webhooksAllowedSchemes: list("WEBHOOKS_ALLOWED_SCHEMES", default: ["http", "https"]),
                webhooksAllowedPorts: list("WEBHOOKS_ALLOWED_PORTS").compactMap { Int($0) },
                webhooksAllowInternalRequests: try bool("WEBHOOKS_ALLOW_INTERNAL_REQUESTS", default: true),
                emailAllowInternalHosts: try bool("EMAIL_ALLOW_INTERNAL_HOSTS", default: true),
                raw: allValues()
            )
            return settings
        }
    }
}
