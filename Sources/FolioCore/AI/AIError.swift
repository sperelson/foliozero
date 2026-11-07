import Foundation

/// Errors from the AI features. `httpStatus` gives the status the REST API answers with,
/// matching Paperless-ngx (`LLMTimeoutError` is 503, `LLMProviderError` is 502).
public enum AIError: Error, CustomStringConvertible, Equatable, Sendable {
    /// `AI_ENABLED` is false.
    case disabled
    /// A setting is invalid (Paperless-ngx raises `ValueError`).
    case invalidConfiguration(String)
    /// The backend did not answer within `AI_LLM_REQUEST_TIMEOUT` (`LLMTimeoutError`).
    case timeout
    /// The backend answered with an error (`LLMProviderError`). `status` is the HTTP status, 0 for non-HTTP backends.
    case providerRejected(status: Int, message: String)
    /// The backend could not be reached (connection refused, DNS failure, ...).
    case unreachable(String)
    /// The endpoint resolves to an internal address and `AI_LLM_ALLOW_INTERNAL_ENDPOINTS` is false.
    case blockedEndpoint(String)
    /// The on-device model cannot be used right now.
    case modelUnavailable(String)
    /// The on-device model does not support the language of the request.
    case unsupportedLanguage(String)
    /// The prompt does not fit the model's context window, even after truncation.
    case contextWindowExceeded
    /// The backend answered, but not in the expected shape.
    case invalidResponse(String)
    /// No document with this id.
    case documentNotFound(Int)
    /// The user may not view or change the document.
    case permissionDenied
    /// The request itself is invalid (for example an empty or too long chat question).
    case invalidRequest(String)

    public var description: String {
        switch self {
        case .disabled: "AI is required for this feature"
        case .invalidConfiguration(let why): "Invalid AI configuration: \(why)"
        case .timeout: "AI backend request timed out."
        case .providerRejected(let status, let message):
            status > 0 ? "AI backend rejected the request (HTTP \(status)): \(message)" : "AI backend rejected the request: \(message)"
        case .unreachable(let why): "AI backend is unreachable: \(why)"
        case .blockedEndpoint(let host): "AI endpoint \(host) resolves to an internal address and AI_LLM_ALLOW_INTERNAL_ENDPOINTS is false"
        case .modelUnavailable(let why): "The on-device language model is unavailable: \(why)"
        case .unsupportedLanguage(let why): "The on-device language model does not support this language: \(why)"
        case .contextWindowExceeded: "The document does not fit the model's context window"
        case .invalidResponse(let why): "AI backend returned an invalid response: \(why)"
        case .documentNotFound(let id): "Document \(id) not found"
        case .permissionDenied: "Insufficient permissions"
        case .invalidRequest(let why): why
        }
    }

    /// The HTTP status the REST API answers with.
    public var httpStatus: Int {
        switch self {
        case .disabled, .invalidConfiguration, .blockedEndpoint, .invalidRequest: 400
        case .permissionDenied: 403
        case .documentNotFound: 404
        case .timeout, .modelUnavailable: 503
        case .providerRejected, .unreachable, .invalidResponse, .unsupportedLanguage, .contextWindowExceeded: 502
        }
    }

    /// The JSON body Paperless-ngx sends for this error from `ai_suggestions`
    /// (`{"ai": ["..."]}` for backend failures). nil means a plain-text body.
    public var paperlessErrorBody: [String: [String]]? {
        switch self {
        case .timeout: ["ai": ["AI backend request timed out."]]
        case .providerRejected, .unreachable, .invalidResponse, .unsupportedLanguage, .contextWindowExceeded:
            ["ai": ["AI backend rejected the request. Check logs for details."]]
        case .modelUnavailable(let why): ["ai": [why]]
        case .invalidConfiguration, .blockedEndpoint: ["ai": ["Invalid AI configuration."]]
        case .disabled, .documentNotFound, .permissionDenied, .invalidRequest: nil
        }
    }

    /// True for failures worth retrying later (a queued workflow action backs off on these).
    public var isTransient: Bool {
        switch self {
        case .timeout, .unreachable, .modelUnavailable: true
        case .providerRejected(let status, _): status == 429 || status >= 500
        default: false
        }
    }
}
