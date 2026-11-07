import Foundation
import FolioCore
import Hummingbird
import HummingbirdWebSocket
import Logging

/// The FolioZero HTTP server: the Paperless-ngx compatible REST API, share links
/// and a minimal browser login.
public struct FolioHTTPServer: Sendable {
    public let app: FolioApp
    public let queue: TaskQueue
    /// Replaces the HTTP calls to the Gmail and Outlook token endpoints (tests).
    let mailOAuthTransport: MailOAuth.Transport?
    /// Replaces the HTTP client for OpenID Connect providers (tests).
    var oidcTransport: OIDCTransport?

    public init(app: FolioApp, queue: TaskQueue) {
        self.init(app: app, queue: queue, mailOAuthTransport: nil)
    }

    init(app: FolioApp, queue: TaskQueue, mailOAuthTransport: MailOAuth.Transport?) {
        self.app = app
        self.queue = queue
        self.mailOAuthTransport = mailOAuthTransport
    }

    /// Serves on `BIND_ADDR`:`PORT` until SIGINT or SIGTERM, then shuts down gracefully and returns.
    public func run() async throws {
        let application = makeApplication()
        app.logger.info("Listening on \(app.settings.bindAddress) port \(app.settings.port)")
        try await application.runService(gracefulShutdownSignals: [.sigterm, .sigint])
    }

    /// The Hummingbird application without running it (tests use `app.test(.router)`).
    public func makeApplication() -> some ApplicationProtocol {
        let api = API(app: app, queue: queue, mailOAuthTransport: mailOAuthTransport, oidcTransport: oidcTransport)
        var logger = app.logger
        logger[metadataKey: "component"] = "http"
        return Application(
            responder: APIResponder(api: api),
            server: .http1WebSocketUpgrade { head, _, _ in await api.statusSocketUpgrade(head) },
            configuration: ApplicationConfiguration(
                address: .hostname(app.settings.bindAddress, port: app.settings.port),
                serverName: nil
            ),
            logger: logger
        )
    }
}

/// Request context: the client address. Authentication is resolved by `API`.
public struct APIRequestContext: RequestContext {
    public var coreContext: CoreRequestContextStorage
    public let remoteAddress: String?

    public init(source: ApplicationRequestContextSource) {
        coreContext = CoreRequestContextStorage(source: source)
        remoteAddress = source.channel.remoteAddress?.ipAddress
    }

    /// Bodies are collected by the API with route-specific limits.
    public var maxUploadSize: Int { 500 * 1024 * 1024 }
}

struct APIResponder: HTTPResponder {
    let api: API

    func respond(to request: Request, context: APIRequestContext) async throws -> Response {
        await api.respond(to: request, context: context)
    }
}
