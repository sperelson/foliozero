import Foundation
import FolioParsing

extension MailContent {
    /// Builds the mail-rule view of a parsed MIME message.
    public init(mime: MIMEMessage) {
        self.init(
            subject: mime.subject ?? "",
            fromAddress: mime.from?.address ?? "",
            fromName: mime.from?.name,
            date: mime.date,
            attachments: mime.attachments.map { part in
                Attachment(
                    filename: part.filename ?? "",
                    contentType: part.contentType,
                    isAttachment: part.disposition == .attachment,
                    data: part.data
                )
            }
        )
    }
}

extension MailProcessor {
    /// The production parser for fetched messages.
    public static let mimeParser: Parse = { data in MailContent(mime: try MIMEMessage.parse(data)) }
}

/// Captures a web page (or a file behind a URL) and consumes it.
public enum URLCapture {
    /// Downloads and renders `url`, then runs the normal consume pipeline on the captured file
    /// (a `.webarchive` for HTML pages, otherwise the downloaded file).
    public static func consume(url: URL, app: FolioApp, overrides: DocumentOverrides = .init(), source: DocumentSource = .apiUpload) async throws -> Document {
        let work = try app.makeScratchDirectory(prefix: "capture")
        defer { try? FileManager.default.removeItem(at: work) }
        let captured = try await WebCapture.captureDocument(url: url, options: app.effectiveSettings().parseOptions(scratchDirectory: work))
        var overrides = overrides
        if overrides.title == nil, let title = captured.result.suggestedTitle, !title.isEmpty {
            overrides.title = title
        }
        let request = ConsumeRequest(file: captured.originalFile, originalFilename: captured.suggestedFileName, source: source, overrides: overrides, deleteSource: true)
        let document = try await app.consumer().consume(request)
        app.logger.info("Captured \(captured.finalURL.absoluteString) as document #\(document.id ?? 0)")
        return document
    }
}
