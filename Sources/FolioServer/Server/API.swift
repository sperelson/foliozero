import Foundation
import FolioCore
import GRDB
import HTTPTypes
import Hummingbird
import Logging

typealias Handler = @Sendable (API, APIRequest) async throws -> Response

struct Route: Sendable {
    enum Segment: Sendable, Equatable {
        case literal(String)
        case param(String)
        /// `{name...}`: one or more remaining components, joined with `/`.
        case rest(String)
    }

    struct Options: OptionSet, Sendable {
        let rawValue: Int
        /// No authentication required.
        static let anonymous = Options(rawValue: 1 << 0)
        /// The handler reads `rawBody` itself (uploads).
        static let streamingBody = Options(rawValue: 1 << 1)
        /// No CSRF check for session cookies (login forms).
        static let csrfExempt = Options(rawValue: 1 << 2)
        /// The single-page app fallback; never used for reserved prefixes such as `/api/`.
        static let spa = Options(rawValue: 1 << 3)
    }

    let method: HTTPRequest.Method
    let segments: [Segment]
    let options: Options
    let handler: Handler

    init(_ method: HTTPRequest.Method, _ pattern: String, _ options: Options = [], _ handler: @escaping Handler) {
        self.method = method
        self.segments = pattern.split(separator: "/").map { piece in
            if piece.hasPrefix("{"), piece.hasSuffix("...}") { return .rest(String(piece.dropFirst().dropLast(4))) }
            if piece.hasPrefix("{"), piece.hasSuffix("}") { return .param(String(piece.dropFirst().dropLast())) }
            return .literal(String(piece))
        }
        self.options = options
        self.handler = handler
    }

    var literalCount: Int {
        segments.filter { if case .literal = $0 { return true } else { return false } }.count
    }

    func match(_ path: [String]) -> [String: String]? {
        let hasRest: Bool = if case .rest = segments.last { true } else { false }
        guard hasRest ? path.count >= segments.count : path.count == segments.count else { return nil }
        var params: [String: String] = [:]
        for (index, segment) in segments.enumerated() {
            switch segment {
            case .literal(let literal): if literal != path[index] { return nil }
            case .param(let name): params[name] = path[index]
            case .rest(let name): params[name] = path[index...].joined(separator: "/")
            }
        }
        return params
    }
}

/// The REST API: routing, authentication, versioning, CORS and error rendering.
final class API: Sendable {
    static let supportedVersions = [9, 10]
    static let defaultVersion = 10
    static let jsonBodyLimit = 32 * 1024 * 1024

    let app: FolioApp
    let queue: TaskQueue
    let settings: Settings
    let logger: Logger
    let reportedVersion: String
    let maxUploadSize: Int
    let tokenThrottle: RateLimiter
    let credentialCache = CredentialCache()
    let formatter: DateFormatter
    let routes: [Route]
    let startedAt = Date()
    /// The Paperless-ngx release's static folder: `FRONTEND_DIR`, else `<home>/static`. Looked up
    /// on each use, so a frontend that `serve` installs in the background appears without a restart.
    var frontendDir: URL? { FrontendInstaller.frontendDirectory(settings: settings) }
    let statusHub = StatusHub()
    /// TOTP secrets shown by `GET /api/profile/totp/`, by user id, until activated.
    let pendingTOTPSecrets = ExpiringStore<String>(lifetime: 15 * 60)
    /// Logins waiting for the second factor, by one-time token.
    let pendingLogins = ExpiringStore<PendingLogin>(lifetime: 5 * 60)
    /// Gmail and Outlook OAuth for mail accounts.
    let mailOAuth: MailOAuth
    /// The OAuth state of the last `GET /api/ui_settings/`, by session (Django keeps it in the session).
    let mailOAuthStates: ExpiringStore<String>
    /// OpenID Connect providers and the Paperless-ngx social login settings.
    let social: SocialAccountSettings
    let oidc: OIDCClient
    /// Sign-ins waiting for the provider's callback, by `state`.
    let pendingSocialLogins = ExpiringStore<PendingSocialLogin>(lifetime: 10 * 60)
    /// Social signups waiting for the signup form, by one-time token.
    let pendingSocialSignups = ExpiringStore<PendingSocialSignup>(lifetime: 10 * 60)
    /// Django messages for the frontend (`window.DJANGO_MESSAGES`), by session key.
    let flashMessages = ExpiringStore<[FlashMessage]>(lifetime: 10 * 60)

    /// The title on server-rendered pages: the stored `app_title`, else `APP_TITLE`, else
    /// FolioZero (Paperless-ngx `documents.context_processors.settings`).
    var displayTitle: String { app.effectiveSettings().appTitle ?? "FolioZero" }

    var sessionCookieName: String { "\(settings.cookiePrefix)sessionid" }
    var csrfCookieName: String { "\(settings.cookiePrefix)csrftoken" }

    init(app: FolioApp, queue: TaskQueue, mailOAuthTransport: MailOAuth.Transport? = nil, oidcTransport: OIDCTransport? = nil) {
        self.app = app
        self.queue = queue
        self.settings = app.settings
        self.mailOAuth = MailOAuth(settings: app.settings, transport: mailOAuthTransport)
        self.mailOAuthStates = ExpiringStore<String>(lifetime: TimeInterval(max(app.settings.sessionCookieAge, 300)))
        self.logger = app.logger
        self.reportedVersion = API.extraSetting("REPORTED_VERSION", settings: app.settings) ?? "3.4.2"
        self.maxUploadSize = API.extraSetting("MAX_UPLOAD_SIZE", settings: app.settings).flatMap { Int($0) } ?? 500 * 1024 * 1024
        let rate = API.extraSetting("TOKEN_THROTTLE_RATE", settings: app.settings) ?? "5/min"
        self.tokenThrottle = RateLimiter(rate: rate)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = app.settings.timeZone
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"
        self.formatter = formatter
        self.routes = API.makeRoutes()
        self.social = SocialAccountSettings(raw: app.settings.raw)
        self.oidc = OIDCClient(transport: oidcTransport)
        for warning in social.warnings { app.logger.warning("\(warning)") }
        if !social.providers.isEmpty {
            app.logger.info("OpenID Connect sign-in: \(social.providers.map(\.id).joined(separator: ", "))")
        }
    }

    /// A setting FolioCore does not model, from `settings.raw` (overrides, environment, config file).
    static func extraSetting(_ key: String, settings: Settings) -> String? {
        guard let value = settings.raw[key]?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Dispatch

    func respond(to request: Request, context: APIRequestContext) async -> Response {
        let rawPath = request.uri.path
        let components = rawPath.split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        let isAPI = components.first == "api"
        let origin = request.headers[.origin]
        var explicitVersion: Int?
        var authenticated = false
        var newSession: Session?
        var response: Response

        do {
            if request.method == .options, origin != nil,
               request.headers[HTTPField.Name("Access-Control-Request-Method")!] != nil {
                var preflight = Response(status: .ok)
                preflight.headers[.contentLength] = "0"
                addCORSHeaders(&preflight, origin: origin, preflight: true)
                return preflight
            }
            if isAPI {
                explicitVersion = try negotiateVersion(request.headers[.accept])
            }
            let reserved = components.first.map { Self.reservedPrefixes.contains($0) } ?? false
            let allCandidates = routes.compactMap { route -> (Route, [String: String])? in
                if route.options.contains(.spa) && reserved { return nil }
                return route.match(components).map { (route, $0) }
            }
            guard let specificity = allCandidates.map({ $0.0.literalCount }).max() else { throw APIError.notFound() }
            let candidates = allCandidates.filter { $0.0.literalCount == specificity }

            let auth = try await authenticate(request, context: context, isAPI: isAPI)
            authenticated = auth != nil
            if let auth, auth.isNewSession { newSession = auth.session }

            var match = candidates.first { $0.0.method == request.method }
            if match == nil, request.method == .head {
                match = candidates.first { $0.0.method == .get }
            }
            guard let (route, params) = match else {
                if auth == nil, candidates.allSatisfy({ !$0.0.options.contains(.anonymous) }) {
                    throw notAuthenticatedError(request)
                }
                throw APIError.methodNotAllowed(request.method)
            }
            if !route.options.contains(.anonymous) && auth == nil {
                throw notAuthenticatedError(request)
            }

            var apiRequest = APIRequest(
                head: request.head, rawBody: request.body, context: context, path: rawPath,
                params: params, query: QueryItems(request.uri.query), auth: auth,
                version: explicitVersion ?? Self.defaultVersion, body: nil
            )
            if !route.options.contains(.streamingBody), !Self.isSafe(request.method) || request.headers[.contentLength] != nil {
                var mutable = request
                do {
                    apiRequest.body = try await mutable.collectBody(upTo: Self.jsonBodyLimit)
                } catch let error as HTTPError where error.status == .contentTooLarge {
                    throw APIError.detail(.contentTooLarge, "Request body too large")
                }
            }
            if let auth, auth.method == .session, !Self.isSafe(request.method), !route.options.contains(.csrfExempt) {
                var formToken: String?
                if let body = apiRequest.body, (apiRequest.contentType ?? "").lowercased().hasPrefix("application/x-www-form-urlencoded") {
                    formToken = QueryItems(String(decoding: body.readableBytesView, as: UTF8.self))["csrfmiddlewaretoken"]
                }
                try checkCSRF(request, session: auth.session, formToken: formToken)
            }
            response = try await route.handler(self, apiRequest)
            if request.method == .head { response.body = ResponseBody() }
        } catch let error as APIError {
            response = error.response(version: nil)
        } catch let error as HTTPError {
            response = APIError.detail(error.status, error.body ?? error.status.reasonPhrase).response(version: nil)
        } catch {
            logger.error("Unhandled error for \(request.method) \(rawPath): \(error)")
            response = APIError.detail(.internalServerError, "A server error occurred.").response(version: nil)
        }

        // Auto-login created a session: send its cookies unless the handler set its own (login, logout).
        if let newSession, !response.headers[values: .setCookie].contains(where: { $0.hasPrefix(sessionCookieName + "=") }) {
            response = sessionResponse(response, session: newSession)
        }
        if let explicitVersion, response.headers[.contentType] == "application/json" {
            response.headers[.contentType] = "application/json; version=\(explicitVersion)"
        }
        if authenticated {
            response.headers[HTTPField.Name("X-Api-Version")!] = String(Self.supportedVersions.last!)
            response.headers[HTTPField.Name("X-Version")!] = reportedVersion
        }
        addCORSHeaders(&response, origin: origin, preflight: false)
        return response
    }

    static func isSafe(_ method: HTTPRequest.Method) -> Bool {
        [.get, .head, .options, .trace].contains(method)
    }

    /// DRF `AcceptHeaderVersioning`.
    func negotiateVersion(_ accept: String?) throws -> Int? {
        guard let accept else { return nil }
        for mediaRange in accept.split(separator: ",") {
            for parameter in mediaRange.split(separator: ";").dropFirst() {
                let pair = parameter.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                guard pair.count == 2, pair[0].lowercased() == "version" else { continue }
                let value = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                guard let version = Int(value), Self.supportedVersions.contains(version) else {
                    throw APIError.detail(.notAcceptable, "Invalid version in \"Accept\" header.")
                }
                return version
            }
        }
        return nil
    }

    private func notAuthenticatedError(_ request: Request) -> APIError {
        var error = APIError.notAuthenticated
        let header = request.headers[.authorization] ?? ""
        error.headers[.wwwAuthenticate] = header.lowercased().hasPrefix("basic ") ? "Basic realm=\"api\"" : "Token"
        return error
    }

    // MARK: - CORS

    func addCORSHeaders(_ response: inout Response, origin: String?, preflight: Bool) {
        guard let origin, isAllowedCORSOrigin(origin) else { return }
        response.headers[HTTPField.Name("Access-Control-Allow-Origin")!] = origin
        response.headers[HTTPField.Name("Access-Control-Allow-Credentials")!] = "true"
        response.headers[HTTPField.Name("Access-Control-Expose-Headers")!] = "Content-Disposition, X-Api-Version, X-Version"
        response.headers.append(HTTPField(name: .vary, value: "Origin"))
        if preflight {
            response.headers[HTTPField.Name("Access-Control-Allow-Methods")!] = "DELETE, GET, OPTIONS, PATCH, POST, PUT"
            response.headers[HTTPField.Name("Access-Control-Allow-Headers")!] =
                "accept, accept-encoding, authorization, content-type, dnt, origin, user-agent, x-csrftoken, x-requested-with"
            response.headers[HTTPField.Name("Access-Control-Max-Age")!] = "86400"
        }
    }

    func isAllowedCORSOrigin(_ origin: String) -> Bool {
        let allowed = settings.corsAllowedHosts
        if allowed.contains("*") { return true }
        let normalized = origin.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return allowed.contains { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/")) == normalized }
    }

    // MARK: - Database

    func read<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await app.database.read(block)
    }

    func write<T: Sendable>(_ block: @Sendable @escaping (Database) throws -> T) async throws -> T {
        try await app.database.write(block)
    }

    // MARK: - Formatting

    /// DRF `DateTimeField`: ISO 8601 in the configured zone, `Z` for UTC, microseconds when non-zero.
    func datetime(_ date: Date?) -> JSON {
        guard let date else { return .null }
        var text = formatter.string(from: date)
        let fraction = date.timeIntervalSince1970 - date.timeIntervalSince1970.rounded(.down)
        if fraction < 0.0000005, let dot = text.firstIndex(of: ".") {
            let zoneStart = text[dot...].firstIndex { $0 == "+" || $0 == "-" || $0 == "Z" } ?? text.endIndex
            text.removeSubrange(dot..<zoneStart)
        }
        return .string(text)
    }

    func date(_ date: CalendarDate?) -> JSON {
        date.map { .string($0.iso) } ?? .null
    }

    /// Absolute URL of this request with a different query (pagination links).
    func absoluteURL(_ request: APIRequest, query: QueryItems) -> String {
        var base: String
        if let configured = settings.url, let url = URL(string: configured), let scheme = url.scheme, let host = url.host {
            base = "\(scheme)://\(host)"
            if let port = url.port { base += ":\(port)" }
        } else {
            let host = request.host ?? "localhost"
            base = "http://\(host)"
        }
        let encoded = query.encoded
        return base + request.path + (encoded.isEmpty ? "" : "?" + encoded)
    }
}

// MARK: - Rate limiting

/// Fixed-window request counting per key (DRF `ScopedRateThrottle`).
final class RateLimiter: @unchecked Sendable {
    private let lock = NSLock()
    private var hits: [String: [Date]] = [:]
    let limit: Int
    let window: TimeInterval

    init(rate: String) {
        let parts = rate.split(separator: "/")
        limit = parts.first.flatMap { Int($0) } ?? 5
        let unit = parts.count > 1 ? parts[1].lowercased() : "min"
        switch unit.first {
        case "s": window = 1
        case "h": window = 3600
        case "d": window = 86_400
        default: window = 60
        }
    }

    /// nil when allowed; otherwise seconds until the next request is allowed.
    func check(_ key: String, now: Date = Date()) -> Int? {
        lock.withLock {
            var recent = (hits[key] ?? []).filter { now.timeIntervalSince($0) < window }
            if recent.count >= limit {
                let wait = window - now.timeIntervalSince(recent[0])
                hits[key] = recent
                return max(1, Int(wait.rounded(.up)))
            }
            recent.append(now)
            hits[key] = recent
            if hits.count > 10_000 { hits = hits.filter { !$0.value.isEmpty } }
            return nil
        }
    }
}
