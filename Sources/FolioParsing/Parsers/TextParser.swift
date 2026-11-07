import Foundation

/// Plain text, CSV and Markdown. Reads the file directly; no OCR, no archive.
/// Mirrors Paperless-ngx `TextDocumentParser`.
public struct TextParser: DocumentParser {
    public let name = "text"
    public let supportedMIMETypes: [String: String] = [
        "text/plain": ".txt",
        "text/csv": ".csv",
        "application/csv": ".csv",
        "text/markdown": ".md",
    ]

    /// Files larger than this get a placeholder thumbnail instead of rendered text.
    public var thumbnailFileSizeLimit = 50 * 1024 * 1024

    public init() {}

    public func parse(file: URL, mimeType: String, options: ParseOptions) async throws -> ParseResult {
        let data: Data
        do {
            data = try Data(contentsOf: file, options: .mappedIfSafe)
        } catch {
            throw ParserError.unreadable(file, error.localizedDescription)
        }
        let (text, encoding) = TextEncodingDetector.decode(data)

        try FileManager.default.createDirectory(at: options.scratchDirectory, withIntermediateDirectories: true)
        let preview = data.count > thumbnailFileSizeLimit ? "[File too large to preview]" : String(text.prefix(100_000))
        let image = ThumbnailRenderer.image(fromText: preview, maxPixels: options.thumbnailMaxPixels)
            ?? ThumbnailRenderer.placeholder(label: "TXT", maxPixels: options.thumbnailMaxPixels)
        let thumbnail = try ThumbnailRenderer.write(image, to: options.scratchDirectory)

        let encodingName = CFStringConvertEncodingToIANACharSetName(
            CFStringConvertNSStringEncodingToEncoding(encoding.rawValue)
        ) as String? ?? "unknown"

        return ParseResult(
            text: text,
            archiveFile: nil,
            thumbnailFile: thumbnail,
            pageCount: nil,
            metadata: [MetadataEntry(MetadataNamespace.folio, "encoding", encodingName)],
            metadataDate: nil,
            suggestedTitle: mimeType == "text/markdown" ? Self.markdownTitle(text) : nil,
            language: LanguageDetector.detect(text)
        )
    }

    /// The first level-1 ATX heading ("# Title") in the first 50 lines.
    static func markdownTitle(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline).prefix(50) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                let title = trimmed.dropFirst(2).trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
                return title.isEmpty ? nil : title
            }
        }
        return nil
    }
}
