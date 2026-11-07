import Foundation
import FolioParsing
import GRDB

/// Which documents go to the remote OCR engine (Paperless-ngx `RemoteOCRMode`,
/// `PAPERLESS_REMOTE_OCR_MODE`).
public enum RemoteOCRMode: String, Sendable, Codable, CaseIterable {
    /// Every document of a supported type, instead of local OCR.
    case always
    /// Only documents a "Consumption Started" workflow marks, or a reprocess asks for.
    case workflowOnly = "workflow_only"
}

/// Remote OCR settings (Paperless-ngx `RemoteOCRConfig`).
///
/// Built from `Settings`; values stored in the database application configuration
/// (`/api/config/`) take precedence where they are set, as in Paperless-ngx.
public struct RemoteOCRConfig: Sendable, Equatable {
    /// `REMOTE_OCR_ENGINE` / `remote_ocr_engine`.
    public var engine: String?
    /// `REMOTE_OCR_API_KEY` / `remote_ocr_api_key`.
    public var apiKey: String?
    /// `REMOTE_OCR_ENDPOINT` / `remote_ocr_endpoint`.
    public var endpoint: String?
    /// `REMOTE_OCR_MODE` / `remote_ocr_mode`.
    public var mode: RemoteOCRMode = .always
    /// `REMOTE_OCR_ALLOW_INTERNAL_ENDPOINTS`. Environment only, as in Paperless-ngx.
    public var allowInternalEndpoints = true

    public init(engine: String? = nil, apiKey: String? = nil, endpoint: String? = nil, mode: RemoteOCRMode = .always, allowInternalEndpoints: Bool = true) {
        self.engine = engine
        self.apiKey = apiKey
        self.endpoint = endpoint
        self.mode = mode
        self.allowInternalEndpoints = allowInternalEndpoints
    }

    public init(settings: Settings) {
        engine = settings.remoteOCREngine
        apiKey = settings.remoteOCRAPIKey
        endpoint = settings.remoteOCREndpoint
        mode = settings.remoteOCRMode
        allowInternalEndpoints = settings.remoteOCRAllowInternalEndpoints
    }

    /// Settings plus the database application configuration.
    public static func load(settings: Settings, database: FolioDatabase) throws -> RemoteOCRConfig {
        var config = RemoteOCRConfig(settings: settings)
        let stored = try database.read { db in
            try String.fetchOne(db, sql: "SELECT config FROM app_config WHERE id = 1")
        }
        if let stored, let data = stored.data(using: .utf8),
           let object = try? JSONDecoder().decode([String: JSONValue].self, from: data) {
            config.applyApplicationConfiguration(object)
        }
        return config
    }

    /// Overlays `remote_ocr_engine`, `remote_ocr_api_key`, `remote_ocr_endpoint` and
    /// `remote_ocr_mode`. Null, empty and unknown mode values leave the setting unchanged.
    public mutating func applyApplicationConfiguration(_ object: [String: JSONValue]) {
        func string(_ key: String) -> String? {
            guard let v = object[key]?.stringValue?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
            return v
        }
        if let v = string("remote_ocr_engine") { engine = v }
        if let v = string("remote_ocr_api_key") { apiKey = v }
        if let v = string("remote_ocr_endpoint") { endpoint = v }
        if let v = string("remote_ocr_mode"), let parsed = RemoteOCRMode(rawValue: v) { mode = parsed }
    }

    /// The parser's view of this configuration.
    public var engineConfig: RemoteOCREngineConfig {
        RemoteOCREngineConfig(engine: engine, apiKey: apiKey, endpoint: endpoint, allowInternalEndpoints: allowInternalEndpoints)
    }

    /// True when the engine is known and fully configured (Paperless-ngx `engine_is_valid`).
    public var isConfigured: Bool { engineConfig.engineIsValid }

    /// Whether every supported document goes to the remote engine (Paperless-ngx
    /// `remote_ocr_by_default`). When false, only documents that asked for it do.
    public var remoteOCRByDefault: Bool { mode == .always }
}
