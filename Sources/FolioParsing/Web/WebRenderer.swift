import AppKit
import Foundation
import Logging
import WebKit

/// Renders web content with WebKit (offscreen `WKWebView`) and returns the
/// DOM text, metadata and a single tall vector PDF of the whole page.
/// `WebPaginator` then cuts that PDF into A4 pages.
///
/// WebKit needs the main thread and a running main run loop. A Swift `async`
/// main (and `swift test`) run one; `foliozero serve` drives `RunLoop.main`.
/// Callers stay off the main actor: `render` hops there itself.
public enum WebRenderer {
    static let logger = Logger(label: "foliozero.parsing.web")

    /// What to load.
    public enum Source: Sendable {
        /// A local HTML file. `readAccess` is the directory WebKit may read (for images and CSS).
        case file(URL, readAccess: URL)
        /// A remote page.
        case url(URL)
        /// An HTML string.
        case html(String, baseURL: URL?)
        /// Raw data with a MIME type, for example a `.webarchive`.
        case data(Data, mimeType: String, baseURL: URL)
    }

    public struct Options: Sendable {
        /// Maximum time for loading, rendering and exporting.
        public var timeout: Duration
        /// Run the page's own JavaScript. Off for email bodies.
        public var allowsJavaScript: Bool
        /// Viewport width in CSS pixels. 794 px is the width of A4 at 96 DPI.
        public var viewportWidth: CGFloat
        /// Apply `@media print` style sheets, as browsers do when printing.
        public var printMediaType: Bool
        /// Also export a `.webarchive` of the page.
        public var createsWebArchive: Bool
        /// Extra wait after the page reports it has loaded, for late images.
        public var settleTime: Duration
        public var userAgent: String?

        public init(
            timeout: Duration = .seconds(60),
            allowsJavaScript: Bool = true,
            viewportWidth: CGFloat = 794,
            printMediaType: Bool = true,
            createsWebArchive: Bool = false,
            settleTime: Duration = .milliseconds(250),
            userAgent: String? = nil
        ) {
            self.timeout = timeout
            self.allowsJavaScript = allowsJavaScript
            self.viewportWidth = viewportWidth
            self.printMediaType = printMediaType
            self.createsWebArchive = createsWebArchive
            self.settleTime = settleTime
            self.userAgent = userAgent
        }
    }

    /// Rendered page.
    public struct Page: Sendable {
        /// One-page PDF of the whole document, 1 pt per CSS pixel.
        public var pdf: Data
        /// `document.body.innerText`.
        public var text: String
        public var title: String?
        /// `<meta>` values keyed by lower-cased name, property or itemprop.
        public var meta: [String: String]
        /// `datetime` attributes of `<time>` elements, in document order (at most 5).
        public var times: [String]
        /// Document size in CSS pixels.
        public var contentSize: CGSize
        /// Vertical extents (top, bottom) of text lines, images and table rows,
        /// in CSS pixels from the top. Used to avoid cutting lines at page breaks.
        public var blockExtents: [ClosedRange<Double>]
        /// Final URL after redirects.
        public var finalURL: URL?
        public var webArchive: Data?
        /// `<html lang>`.
        public var language: String?
    }

    public enum RenderError: Error, Sendable, CustomStringConvertible {
        case timedOut
        case loadFailed(String)
        case contentProcessTerminated
        case exportFailed(String)

        public var description: String {
            switch self {
            case .timedOut: "WebKit rendering timed out"
            case .loadFailed(let why): "WebKit could not load the page: \(why)"
            case .contentProcessTerminated: "The WebKit content process terminated"
            case .exportFailed(let why): "WebKit could not export the page: \(why)"
            }
        }
    }

    /// Loads and renders `source`. Throws `RenderError.timedOut` after `options.timeout`.
    public static func render(_ source: Source, options: Options = Options()) async throws -> Page {
        try await withDeadline(options.timeout) {
            try await renderOnMain(source, options: options)
        }
    }

    @MainActor
    static func renderOnMain(_ source: Source, options: Options) async throws -> Page {
        let session = WebSession(options: options)
        return try await session.run(source)
    }
}

/// Runs `operation` and returns its result, or throws `WebRenderer.RenderError.timedOut`
/// when `timeout` passes first. The operation is cancelled but not awaited, so
/// a hung WebKit call cannot block the caller.
func withDeadline<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let result: Result<T, any Error> = await withCheckedContinuation { continuation in
        let once = OnceContinuation(continuation)
        let work = Task {
            do {
                once.resume(.success(try await operation()))
            } catch {
                once.resume(.failure(error))
            }
        }
        Task {
            try? await Task.sleep(for: timeout)
            once.resume(.failure(WebRenderer.RenderError.timedOut))
            work.cancel()
        }
    }
    return try result.get()
}

/// One page load. Lives on the main actor for its whole life.
@MainActor
final class WebSession: NSObject, WKNavigationDelegate {
    private let options: WebRenderer.Options
    private let webView: WKWebView
    private var navigationResult: Result<Void, any Error>?
    private var navigationContinuation: CheckedContinuation<Void, any Error>?

    init(options: WebRenderer.Options) {
        self.options = options
        // WebKit expects an application object; a CLI process has none until this call.
        _ = NSApplication.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.suppressesIncrementalRendering = true
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        configuration.defaultWebpagePreferences.allowsContentJavaScript = options.allowsJavaScript
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: options.viewportWidth, height: options.viewportWidth * 1.4142),
            configuration: configuration
        )
        super.init()
        webView.navigationDelegate = self
        if options.printMediaType { webView.mediaType = "print" }
        webView.customUserAgent = options.userAgent
    }

    func run(_ source: WebRenderer.Source) async throws -> WebRenderer.Page {
        defer {
            webView.stopLoading()
            webView.navigationDelegate = nil
        }
        switch source {
        case .file(let url, let readAccess):
            webView.loadFileURL(url, allowingReadAccessTo: readAccess)
        case .url(let url):
            webView.load(URLRequest(url: url, timeoutInterval: 60))
        case .html(let html, let baseURL):
            webView.loadHTMLString(html, baseURL: baseURL)
        case .data(let data, let mimeType, let baseURL):
            webView.load(data, mimeType: mimeType, characterEncodingName: "utf-8", baseURL: baseURL)
        }
        try await waitForNavigation()
        try await waitUntilSettled()

        var info = try await pageInfo()
        // Wide fixed layouts: widen the viewport so nothing is cut off on the right.
        if info.width > options.viewportWidth + 8 {
            let width = min(info.width, 2400)
            webView.frame = CGRect(x: 0, y: 0, width: width, height: webView.frame.height)
            try? await Task.sleep(for: .milliseconds(100))
            info = try await pageInfo()
        }

        let configuration = WKPDFConfiguration()
        var pdf: Data
        do {
            pdf = try await webView.pdf(configuration: configuration)
        } catch {
            throw WebRenderer.RenderError.exportFailed(String(describing: error))
        }
        // If WebKit exported only the viewport, grow the view to the document and export again.
        if let height = PDFPageHeight.of(pdf), height + 10 < info.height {
            webView.frame = CGRect(x: 0, y: 0, width: webView.frame.width, height: min(info.height, 200_000))
            try? await Task.sleep(for: .milliseconds(100))
            pdf = try await webView.pdf(configuration: configuration)
        }

        var archive: Data?
        if options.createsWebArchive {
            archive = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                webView.createWebArchiveData { result in continuation.resume(with: result) }
            }
        }

        return WebRenderer.Page(
            pdf: pdf,
            text: info.text,
            title: info.title.isEmpty ? (webView.title?.isEmpty == false ? webView.title : nil) : info.title,
            meta: info.meta,
            times: info.times,
            contentSize: CGSize(width: max(info.width, webView.frame.width), height: info.height),
            blockExtents: info.extents,
            finalURL: webView.url,
            webArchive: archive,
            language: info.language
        )
    }

    // MARK: Navigation

    private func waitForNavigation() async throws {
        if let navigationResult { return try navigationResult.get() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                if let navigationResult {
                    continuation.resume(with: navigationResult)
                } else {
                    navigationContinuation = continuation
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishNavigation(.failure(CancellationError())) }
        }
    }

    private func finishNavigation(_ result: Result<Void, any Error>) {
        guard navigationResult == nil else { return }
        navigationResult = result
        navigationContinuation?.resume(with: result)
        navigationContinuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishNavigation(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        finishNavigation(.failure(WebRenderer.RenderError.loadFailed(error.localizedDescription)))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        finishNavigation(.failure(WebRenderer.RenderError.loadFailed(error.localizedDescription)))
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        finishNavigation(.failure(WebRenderer.RenderError.contentProcessTerminated))
    }

    /// Waits until `document.readyState` is complete, images have loaded and
    /// fonts are ready (at most 10 seconds), then for `settleTime`.
    private func waitUntilSettled() async throws {
        let script = """
        const deadline = Date.now() + 10000;
        while (Date.now() < deadline) {
          const imagesDone = Array.from(document.images).every(i => i.complete);
          if (document.readyState === 'complete' && imagesDone) break;
          await new Promise(r => setTimeout(r, 100));
        }
        if (document.fonts && document.fonts.ready) { await document.fonts.ready; }
        return true;
        """
        _ = try? await webView.callAsyncJavaScript(script, contentWorld: .defaultClient)
        try await Task.sleep(for: options.settleTime)
    }

    // MARK: Page information

    struct Info {
        var title: String
        var text: String
        var meta: [String: String]
        var times: [String]
        var width: CGFloat
        var height: CGFloat
        var extents: [ClosedRange<Double>]
        var language: String?
    }

    private func pageInfo() async throws -> Info {
        let script = """
        const meta = {};
        for (const m of document.querySelectorAll('meta')) {
          const key = (m.getAttribute('property') || m.getAttribute('name') || m.getAttribute('itemprop') || m.getAttribute('http-equiv') || '').toLowerCase();
          const value = m.getAttribute('content');
          if (key && value && !(key in meta)) meta[key] = value;
        }
        const times = Array.from(document.querySelectorAll('time[datetime]')).slice(0, 5).map(t => t.getAttribute('datetime'));
        const root = document.documentElement;
        const body = document.body;
        const text = body ? body.innerText : (root ? root.innerText : '');
        const width = Math.max(root ? root.scrollWidth : 0, body ? body.scrollWidth : 0);
        const height = Math.max(root ? root.scrollHeight : 0, body ? body.scrollHeight : 0);
        const extents = [];
        if (body) {
          const sy = window.scrollY;
          const walker = document.createTreeWalker(body, NodeFilter.SHOW_TEXT);
          const range = document.createRange();
          let node;
          while ((node = walker.nextNode()) && extents.length < 100000) {
            if (!node.textContent.trim()) continue;
            range.selectNodeContents(node);
            for (const r of range.getClientRects()) {
              if (r.height > 0 && r.width > 0) extents.push(r.top + sy, r.bottom + sy);
            }
          }
          for (const el of document.querySelectorAll('img, svg, video, canvas, tr, pre')) {
            const r = el.getBoundingClientRect();
            if (r.height > 0 && r.width > 0) extents.push(r.top + sy, r.bottom + sy);
          }
        }
        return JSON.stringify({
          title: document.title || '', text: text || '', meta, times, width, height, extents,
          lang: root ? (root.getAttribute('lang') || '') : ''
        });
        """
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(script, contentWorld: .defaultClient)
        } catch {
            throw WebRenderer.RenderError.exportFailed("page script: \(error)")
        }
        guard let json = raw as? String, let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebRenderer.RenderError.exportFailed("page script returned no data")
        }
        let numbers = (object["extents"] as? [NSNumber])?.map(\.doubleValue) ?? []
        var extents: [ClosedRange<Double>] = []
        extents.reserveCapacity(numbers.count / 2)
        var index = 0
        while index + 1 < numbers.count {
            let top = numbers[index]
            let bottom = numbers[index + 1]
            if bottom > top { extents.append(top...bottom) }
            index += 2
        }
        let language = (object["lang"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return Info(
            title: (object["title"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            text: object["text"] as? String ?? "",
            meta: object["meta"] as? [String: String] ?? [:],
            times: object["times"] as? [String] ?? [],
            width: CGFloat((object["width"] as? NSNumber)?.doubleValue ?? 0),
            height: CGFloat((object["height"] as? NSNumber)?.doubleValue ?? 0),
            extents: extents,
            language: language
        )
    }
}

enum PDFPageHeight {
    /// Height of the first page of a PDF in points.
    static func of(_ data: Data) -> CGFloat? {
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { return nil }
        return page.getBoxRect(.mediaBox).height
    }
}
