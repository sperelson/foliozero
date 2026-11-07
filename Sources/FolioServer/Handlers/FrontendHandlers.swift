import Foundation
import FolioCore
import GRDB
import HTTPTypes
import Hummingbird
import UniformTypeIdentifiers

/// Serves the official Paperless-ngx web frontend: a release's static folder with
/// `frontend/<lang>/`, from `FRONTEND_DIR` or `<home>/static` (see `FrontendInstaller`).
extension API {
    /// First path components that never fall through to the single-page app.
    static let reservedPrefixes: Set<String> = ["api", "static", "assets", "share", "accounts", "ws", "favicon.ico", "fetch", "logo"]

    // MARK: - Static files

    /// `GET /static/<path>`: files under `FRONTEND_DIR`, precompressed variants when the client accepts them.
    func staticFile(_ request: APIRequest) async throws -> Response {
        guard let root = frontendDir, let relative = request.params["path"] else { throw APIError.notFound() }
        return try await serveStatic(relative, root: root, request: request)
    }

    func favicon(_ request: APIRequest) async throws -> Response {
        guard let root = frontendDir else { throw APIError.notFound() }
        return try await serveStatic("paperless/img/favicon.ico", root: root, request: request)
    }

    /// `GET /assets/<path>`: the PDF viewer loads its worker from here. Paperless-ngx redirects
    /// to the en-US build (`paperless/urls.py`), whatever the user's language.
    func frontendAsset(_ request: APIRequest) async throws -> Response {
        guard let relative = request.params["path"], !relative.isEmpty else { throw APIError.notFound() }
        let encoded = relative.split(separator: "/", omittingEmptySubsequences: false)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(["/"])) ?? String($0) }
            .joined(separator: "/")
        return .redirect("/static/frontend/en-US/assets/" + encoded)
    }

    func serveStatic(_ relative: String, root: URL, request: APIRequest) async throws -> Response {
        let file = try safeFile(relative, root: root)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory), !isDirectory.boolValue else { throw APIError.notFound() }
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let modified = (attributes[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let seconds = modified.timeIntervalSince1970.rounded(.down)
        let etag = "\"\(String(size, radix: 16))-\(String(Int(seconds), radix: 16))\""

        var headers: HTTPFields = [:]
        headers[.contentType] = Self.staticContentType(file)
        headers[.cacheControl] = "max-age=60, public"
        headers[.lastModified] = Self.httpDate(Date(timeIntervalSince1970: seconds))
        headers[.eTag] = etag
        headers[.vary] = "Accept-Encoding"

        let notModified: Bool
        if let match = request.header("If-None-Match") {
            notModified = match.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.contains { $0 == etag || $0 == "W/" + etag || $0 == "*" }
        } else if let since = request.header("If-Modified-Since").flatMap(Self.parseHTTPDate) {
            notModified = seconds <= since.timeIntervalSince1970
        } else {
            notModified = false
        }
        if notModified { return Response(status: .notModified, headers: headers) }

        var served = file
        let accepted = Set((request.header("Accept-Encoding") ?? "").lowercased().split(separator: ",").map {
            $0.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        })
        for (encoding, suffix) in [("br", ".br"), ("gzip", ".gz")] where accepted.contains(encoding) {
            let candidate = URL(fileURLWithPath: file.path + suffix)
            if FileManager.default.fileExists(atPath: candidate.path) {
                served = candidate
                headers[.contentEncoding] = encoding
                break
            }
        }
        let servedSize = ((try? FileManager.default.attributesOfItem(atPath: served.path))?[.size] as? NSNumber)?.intValue
        if let servedSize { headers[.contentLength] = String(servedSize) }
        let body = try await FileIO().loadFile(path: served.path, context: request.context)
        return Response(status: .ok, headers: headers, body: body)
    }

    static func staticContentType(_ url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "html", "htm": return "text/html; charset=utf-8"
        case "json", "map": return "application/json"
        case "webmanifest": return "application/manifest+json"
        case "svg": return "image/svg+xml"
        case "ico": return "image/x-icon"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "wasm": return "application/wasm"
        case "txt": return "text/plain; charset=utf-8"
        case "xml": return "application/xml"
        case "pdf": return "application/pdf"
        default:
            return UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    static func httpDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return formatter.string(from: date)
    }

    static func parseHTTPDate(_ text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: text)
    }

    // MARK: - Single-page app

    /// Any other GET path: the frontend's index page (sign-in required, as Django's `login_required`).
    func singlePageApp(_ request: APIRequest) async throws -> Response {
        let first = request.path.split(separator: "/").first.map(String.init) ?? ""
        guard frontendDir != nil, !Self.reservedPrefixes.contains(first) else { throw APIError.notFound() }
        return try await frontendIndex(request)
    }

    func frontendIndex(_ request: APIRequest) async throws -> Response {
        guard let root = frontendDir else { throw APIError.notFound() }
        guard let auth = request.auth else {
            let next = request.path + (request.query.items.isEmpty ? "" : "?" + request.query.encoded)
            return .redirect("/accounts/login/?next=" + (next.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "/"))
        }
        let userId = auth.access.userId
        let stored = try await read { db in try self.storedUISettings(userId: userId, in: db) }
        let language = Self.frontendLanguage(
            preferred: [stored["language"]?.string, request.cookieValue("\(settings.cookiePrefix)django_language")],
            acceptLanguage: request.header("Accept-Language"), root: root)
        var response = Response.text(renderIndex(language: language, messages: takeFlashMessages(auth.session)))
        response.headers[.cacheControl] = "no-cache"
        if let session = auth.session {
            // Django's ensure_csrf_cookie: the frontend reads it for X-CSRFToken.
            response.setCookie(Cookie(name: csrfCookieName, value: session.csrfToken, maxAge: settings.sessionCookieAge, path: "/", httpOnly: false, sameSite: .lax))
        }
        return response
    }

    /// The frontend language folder: ui setting, then the language cookie, then Accept-Language, then en-US.
    static func frontendLanguage(preferred: [String?], acceptLanguage: String?, root: URL) -> String {
        let available = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("frontend").path)) ?? []
        func resolve(_ code: String) -> String? {
            let normalized = code.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-").lowercased()
            guard !normalized.isEmpty else { return nil }
            if let exact = available.first(where: { $0.lowercased() == normalized }) { return exact }
            let base = normalized.split(separator: "-").first.map(String.init) ?? normalized
            if base == "en" { return available.contains("en-US") ? "en-US" : nil }
            return available.sorted().first { $0.lowercased().hasPrefix(base + "-") }
        }
        for code in preferred.compactMap({ $0 }) where !code.isEmpty {
            if let found = resolve(code) { return found }
        }
        let ranked = (acceptLanguage ?? "").split(separator: ",").compactMap { part -> (String, Double)? in
            let pieces = part.split(separator: ";")
            guard let code = pieces.first?.trimmingCharacters(in: .whitespaces), code != "*" else { return nil }
            let quality = pieces.dropFirst().compactMap { p -> Double? in
                let kv = p.split(separator: "=")
                return kv.count == 2 && kv[0].trimmingCharacters(in: .whitespaces) == "q" ? Double(kv[1]) : nil
            }.first ?? 1
            return (code, quality)
        }.sorted { $0.1 > $1.1 }
        for (code, _) in ranked {
            if let found = resolve(code) { return found }
        }
        return "en-US"
    }

    /// Style rules added to the frontend's index page; the frontend files stay unchanged.
    /// FolioZero has no update check, so the rules hide the sidebar prompt (`.version-check`)
    /// and the Settings section (`#update-checking` and its row). They also add a credit line
    /// under the version in the sidebar footer. The selectors match the Paperless-ngx v3.4.2 markup.
    static let frontendStyleOverrides = """
        .version-check, #update-checking, #update-checking + .row { display: none !important; }
        .nav-label > .me-2:has(> a[href^="https://github.com/paperless-ngx/paperless-ngx"])::after \
        { content: "Powered by FolioZero \(FolioApp.version)"; display: block; }
        """

    /// Paperless-ngx `templates/index.html` with FolioZero's loading text and style overrides.
    func renderIndex(language: String, messages: [FlashMessage] = []) -> String {
        // Django `escapejs`-safe: JSON strings with `<`, `>` and `&` escaped.
        let djangoMessages = messages.map { message -> String in
            let level = JSON.string(message.level).serialized(), text = JSON.string(message.message).serialized()
            return "{ level: \(level), message: \(text) },".replacingOccurrences(of: "<", with: "\\u003C")
                .replacingOccurrences(of: ">", with: "\\u003E").replacingOccurrences(of: "&", with: "\\u0026")
        }.joined()
        let prefix = Self.htmlEscape(settings.cookiePrefix)
        let base = "/static/frontend/\(language)/"
        let title = Self.htmlEscape(displayTitle)
        return """
            <!doctype html>
            <html lang="en" data-bs-theme="auto">
            <head>
            \t<meta charset="utf-8">
            \t<title>\(title)</title>
            \t<base href="/">
            \t<meta name="viewport" content="width=device-width, initial-scale=1">
            \t<meta name="cookie_prefix" content="\(prefix)">
            \t<meta name="robots" content="noindex,nofollow">
            \t<link rel="icon" type="image/x-icon" href="favicon.ico">
            \t<link rel="manifest" href="\(base)manifest.webmanifest" crossorigin="use-credentials">
            \t<link rel="stylesheet" href="\(base)styles.css">
            \t<style>\(Self.frontendStyleOverrides)</style>
            \t<link rel="apple-touch-icon" href="\(base)apple-touch-icon.png">
            </head>
            <body>
            \t<pngx-root>
            \t\t<style type="text/css">
            \t\t\thtml, body { width: 100%; height: 100%; }
            \t\t\t@keyframes pulsate { 0% { opacity: 0.1; } 50% { opacity: 0.3; } 100% { opacity: 0.1; } }
            \t\t\t.app-loader h6 { opacity: 0.1; animation: pulsate 2s ease-out; animation-iteration-count: infinite; }
            \t\t</style>
            \t\t<div class="bg-light w-100 h-100 d-flex align-items-center">
            \t\t\t<div class="app-loader align-self-center text-center mx-auto">
            \t\t\t\t<h6 class="m-auto">\(title) is loading...</h6>
            \t\t\t</div>
            \t\t</div>
            \t\t<script type="text/javascript">
            \t\t\twindow.DJANGO_MESSAGES = [\(djangoMessages)]
            \t\t</script>
            \t</pngx-root>
            \t<script src="\(base)polyfills.js" type="module"></script>
            \t<script src="\(base)main.js" type="module"></script>
            </body>
            </html>
            """
    }

    /// The sign-in page in the frontend's look (Bootstrap and base.css from `FRONTEND_DIR`).
    func styledLoginPage(_ request: APIRequest, error: String?) -> String {
        let title = Self.htmlEscape(displayTitle)
        let next = Self.htmlEscape(Self.safeRedirect(request.query["next"]) ?? "/")
        var alert = ""
        if let error {
            alert = "<div class=\"alert alert-danger\" role=\"alert\">\(Self.htmlEscape(error))</div>"
        } else if request.query.contains("sharelink_notfound") {
            alert = "<div class=\"alert alert-danger\" role=\"alert\">Share link was not found.</div>"
        } else if request.query.contains("sharelink_expired") {
            alert = "<div class=\"alert alert-danger\" role=\"alert\">Share link has expired.</div>"
        }
        // PAPERLESS_DISABLE_REGULAR_LOGIN hides the password fields; the provider buttons stay.
        let fields = social.disableRegularLogin ? "" : """
            <div class="form-floating form-stacked-top">
            <input type="text" name="login" id="inputUsername" placeholder="Username" class="form-control" autocorrect="off" autocapitalize="none" autocomplete="username" required autofocus>
            <label for="inputUsername">Username</label>
            </div>
            <div class="form-floating form-stacked-bottom">
            <input type="password" name="password" id="inputPassword" placeholder="Password" class="form-control" autocomplete="current-password" required>
            <label for="inputPassword">Password</label>
            </div>
            <div class="d-grid mt-3">
            <button class="btn btn-lg btn-primary" type="submit">Sign in</button>
            </div>
            """
        return """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1, shrink-to-fit=no">
            <meta name="robots" content="noindex,nofollow">
            <title>\(title) sign in</title>
            <link href="/static/bootstrap.min.css" rel="stylesheet">
            <link href="/static/base.css" rel="stylesheet">
            </head>
            <body class="text-center">
            <div class="position-absolute top-50 start-50 translate-middle">
            <form class="form-accounts" id="form-account" method="post" action="/accounts/login/">
            <h1 class="font-weight-normal text-primary mb-4">\(title)</h1>
            \(alert)
            <p>Please sign in.</p>
            <input type="hidden" name="next" value="\(next)">
            \(fields)
            </form>
            \(socialLoginButtons(request))
            </div>
            </body>
            </html>
            """
    }
}

extension APIRequest {
    func cookieValue(_ name: String) -> String? {
        Cookies(from: head.headerFields[values: .cookie])[name]?.value
    }
}
