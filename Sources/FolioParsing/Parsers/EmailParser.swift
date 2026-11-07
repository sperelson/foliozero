import Foundation
import Logging
import PDFKit

/// `.eml` files, modelled on Paperless-ngx's mail parser.
///
/// Text: Subject, From, To, CC, BCC and attachment lines, then the plain-text
/// body (or the HTML body as text when there is no plain-text part).
/// Archive: always produced. A header block (From, To, Cc, Subject, Date,
/// attachments) above the body; HTML bodies are rendered with WebKit with
/// scripts and remote content blocked and `cid:` images inlined. Without
/// WebKit the archive is laid out as plain text.
public struct EmailParser: DocumentParser {
    public let name = "email"
    public let supportedMIMETypes: [String: String] = ["message/rfc822": ".eml"]

    public var renderTimeout: Duration = .seconds(60)

    static let logger = Logger(label: "foliozero.parsing.email")

    public init() {}

    public func parse(file: URL, mimeType: String, options: ParseOptions) async throws -> ParseResult {
        try FileManager.default.createDirectory(at: options.scratchDirectory, withIntermediateDirectories: true)
        let message: MIMEMessage
        do {
            message = try MIMEMessage.parse(Data(contentsOf: file))
        } catch {
            throw ParserError.unreadable(file, String(describing: error))
        }

        let text = Self.formattedText(message)
        let archive = options.scratchDirectory.appendingPathComponent("archive.pdf")
        var pageCount: Int
        do {
            let page = try await WebRenderer.render(
                .html(EmailHTML.document(for: message), baseURL: nil),
                options: WebRenderer.Options(timeout: renderTimeout, allowsJavaScript: false)
            )
            pageCount = try WebPaginator.paginate(page, to: archive, title: message.subject)
        } catch {
            Self.logger.warning("WebKit could not render \(file.lastPathComponent): \(error). Laying out plain text instead.")
            let heading = EmailHTML.headerRows(for: message)
            let body = message.textBody ?? message.htmlBody.map(HTMLText.plainText) ?? ""
            let subject = message.subject
            pageCount = try await MainActor.run {
                try AttributedTextPDF.write(AttributedTextPDF.plainDocument(heading: heading, body: body), to: archive, title: subject)
            }
        }
        await PDFAConverter.applyIfRequested(to: archive, options: options)

        let image = autoreleasepool { () -> CGImage? in
            guard let document = PDFDocument(url: archive), let first = document.page(at: 0) else { return nil }
            return ThumbnailRenderer.image(fromPDFPage: first, maxPixels: options.thumbnailMaxPixels)
        }
        let thumbnail = try ThumbnailRenderer.write(
            image ?? ThumbnailRenderer.placeholder(label: "EML", maxPixels: options.thumbnailMaxPixels),
            to: options.scratchDirectory
        )

        return ParseResult(
            text: text,
            archiveFile: archive,
            thumbnailFile: thumbnail,
            pageCount: pageCount,
            metadata: Self.metadata(message),
            metadataDate: message.date,
            suggestedTitle: message.subject.flatMap { $0.isEmpty ? nil : $0 },
            language: LanguageDetector.detect(message.textBody ?? text)
        )
    }

    /// The text Paperless-ngx builds for an email.
    static func formattedText(_ message: MIMEMessage) -> String {
        var parts: [String] = []
        parts.append("Subject: \(message.subject ?? "")")
        parts.append("From: \(message.from?.formatted ?? "")")
        parts.append("To: \(message.to.map(\.formatted).joined(separator: ", "))")
        if !message.cc.isEmpty { parts.append("CC: \(message.cc.map(\.formatted).joined(separator: ", "))") }
        if !message.bcc.isEmpty { parts.append("BCC: \(message.bcc.map(\.formatted).joined(separator: ", "))") }
        let files = message.attachments.filter { $0.disposition == .attachment || $0.contentId == nil }
        if !files.isEmpty {
            parts.append("Attachments: " + files.map { "\($0.filename ?? "unnamed") (\(byteSize($0.size)))" }.joined(separator: ", "))
        }
        let body = message.textBody ?? message.htmlBody.map(HTMLText.plainText) ?? ""
        parts.append(TextNormalizer.postProcess(body))
        return parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func metadata(_ message: MIMEMessage) -> [MetadataEntry] {
        var entries = message.headers.map { MetadataEntry(namespace: "", prefix: "header", key: $0.name, value: $0.value) }
        // Paperless joins repeated headers; keep one entry per name.
        var seen: [String: Int] = [:]
        var merged: [MetadataEntry] = []
        for entry in entries {
            if let index = seen[entry.key.lowercased()] {
                merged[index].value += ", " + entry.value
            } else {
                seen[entry.key.lowercased()] = merged.count
                merged.append(entry)
            }
        }
        entries = merged
        entries.append(MetadataEntry(
            namespace: "", prefix: "", key: "attachments",
            value: message.attachments.map { "\($0.filename ?? "unnamed")(\(byteSize($0.size)))" }.joined(separator: ", ")
        ))
        if let date = message.date {
            entries.append(MetadataEntry(namespace: "", prefix: "", key: "date", value: iso8601(date)))
        }
        return entries.sorted { ($0.prefix, $0.key) < ($1.prefix, $1.key) }
    }

    /// "1.50 KiB", like humanize.naturalsize(binary=True).
    static func byteSize(_ bytes: Int) -> String {
        let units = ["Bytes", "KiB", "MiB", "GiB", "TiB"]
        var value = Double(bytes)
        var unit = 0
        while value >= 1024, unit < units.count - 1 {
            value /= 1024
            unit += 1
        }
        return unit == 0 ? "\(bytes) Bytes" : String(format: "%.2f %@", value, units[unit])
    }
}

/// The HTML page rendered for an email.
enum EmailHTML {
    static func headerRows(for message: MIMEMessage) -> [(String, String)] {
        var rows: [(String, String)] = []
        rows.append(("From", message.from?.formatted ?? ""))
        if !message.to.isEmpty { rows.append(("To", message.to.map(\.formatted).joined(separator: ", "))) }
        if !message.cc.isEmpty { rows.append(("Cc", message.cc.map(\.formatted).joined(separator: ", "))) }
        rows.append(("Subject", message.subject ?? ""))
        if let date = message.date {
            rows.append(("Date", date.formatted(Date.FormatStyle(date: .complete, time: .standard).locale(Locale(identifier: "en_GB")))))
        }
        let files = message.attachments.filter { $0.disposition == .attachment || $0.contentId == nil }
        if !files.isEmpty {
            rows.append(("Attachments", files.map { "\($0.filename ?? "unnamed") (\(EmailParser.byteSize($0.size)))" }.joined(separator: ", ")))
        }
        return rows
    }

    static func document(for message: MIMEMessage) -> String {
        let rows = headerRows(for: message).map {
            "<tr><th>\(HTMLText.escape($0.0))</th><td>\(HTMLText.escape($0.1))</td></tr>"
        }.joined()

        var bodyHTML: String
        var extraStyles = ""
        if let html = message.htmlBody {
            var cleaned = html.replacingOccurrences(
                of: "<script\\b[^>]*>[\\s\\S]*?</script\\s*>", with: "", options: [.regularExpression, .caseInsensitive]
            )
            extraStyles = matches(of: "<style\\b[^>]*>([\\s\\S]*?)</style\\s*>", in: cleaned).joined(separator: "\n")
            if let body = firstMatch(of: "<body\\b[^>]*>([\\s\\S]*?)(</body\\s*>|$)", in: cleaned) {
                cleaned = body
            }
            cleaned = cleaned.replacingOccurrences(
                of: "<style\\b[^>]*>[\\s\\S]*?</style\\s*>", with: "", options: [.regularExpression, .caseInsensitive]
            )
            bodyHTML = inlineContentIDs(cleaned, attachments: message.attachments)
        } else {
            bodyHTML = "<pre class=\"fz-text\">\(HTMLText.escape(message.textBody ?? ""))</pre>"
        }

        return """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:">
        <style>
        body { font-family: -apple-system, Helvetica, Arial, sans-serif; font-size: 13px; color: #111; margin: 0; }
        .fz-headers { border-bottom: 1px solid #999; margin-bottom: 16px; padding-bottom: 8px; }
        .fz-headers table { border-collapse: collapse; }
        .fz-headers th { text-align: left; vertical-align: top; color: #555; padding: 2px 12px 2px 0; white-space: nowrap; }
        .fz-headers td { padding: 2px 0; word-break: break-word; }
        pre.fz-text { white-space: pre-wrap; word-wrap: break-word; font-family: Menlo, monospace; font-size: 12px; }
        img { max-width: 100%; height: auto; }
        \(extraStyles)
        </style></head><body>
        <div class="fz-headers"><table>\(rows)</table></div>
        <div class="fz-body">\(bodyHTML)</div>
        </body></html>
        """
    }

    /// Replaces `cid:` references with data URLs of the matching inline parts.
    static func inlineContentIDs(_ html: String, attachments: [MIMEAttachment]) -> String {
        var result = html
        for attachment in attachments {
            guard let id = attachment.contentId, attachment.data.count < 10_000_000 else { continue }
            let dataURL = "data:\(attachment.contentType);base64,\(attachment.data.base64EncodedString())"
            result = result.replacingOccurrences(of: "cid:\(id)", with: dataURL)
        }
        return result
    }

    static func matches(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let ns = text as NSString
        return regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            $0.numberOfRanges > 1 && $0.range(at: 1).location != NSNotFound ? ns.substring(with: $0.range(at: 1)) : nil
        }
    }

    static func firstMatch(of pattern: String, in text: String) -> String? {
        matches(of: pattern, in: text).first
    }
}
