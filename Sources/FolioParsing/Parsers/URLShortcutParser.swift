import Foundation
import Logging

/// `.webloc` (property list with a `URL` key) and `.url` (Windows
/// `[InternetShortcut]` INI) files. The target is captured with `WebCapture`.
/// When the capture fails, the document still gets the URL as its text, a
/// placeholder thumbnail and no archive, so a dead link does not block consumption.
public struct URLShortcutParser: DocumentParser {
    static let parserName = "url-shortcut"
    public let name = URLShortcutParser.parserName
    public let supportedMIMETypes: [String: String] = [FileTypeDetector.urlShortcut: ".webloc"]

    static let logger = Logger(label: "foliozero.parsing.shortcut")

    public init() {}

    public func parse(file: URL, mimeType: String, options: ParseOptions) async throws -> ParseResult {
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            throw ParserError.unreadable(file, error.localizedDescription)
        }
        guard let target = Self.targetURL(in: data) else {
            throw ParserError.unreadable(file, "no URL in shortcut")
        }
        let urlEntry = MetadataEntry(MetadataNamespace.folio, "sourceURL", target.absoluteString)
        do {
            var result = try await WebCapture.capture(url: target, options: options)
            if !result.metadata.contains(urlEntry) { result.metadata.append(urlEntry) }
            return result
        } catch {
            Self.logger.warning("Cannot capture \(target.absoluteString) from \(file.lastPathComponent): \(error)")
            try FileManager.default.createDirectory(at: options.scratchDirectory, withIntermediateDirectories: true)
            let thumbnail = try ThumbnailRenderer.write(
                ThumbnailRenderer.placeholder(label: "LINK", maxPixels: options.thumbnailMaxPixels),
                to: options.scratchDirectory
            )
            return ParseResult(
                text: target.absoluteString,
                archiveFile: nil,
                thumbnailFile: thumbnail,
                pageCount: nil,
                metadata: [urlEntry, MetadataEntry(MetadataNamespace.folio, "captureError", String(describing: error))],
                suggestedTitle: TitleHeuristics.meaningfulTitle(file.deletingPathExtension().lastPathComponent)
            )
        }
    }

    /// The URL in a `.webloc` property list or a `.url` INI file.
    public static func targetURL(in data: Data) -> URL? {
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let string = plist["URL"] as? String {
            return URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let text = TextEncodingDetector.decode(data).text
        var inShortcutSection = !text.lowercased().contains("[internetshortcut]")
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") {
                inShortcutSection = trimmed.lowercased() == "[internetshortcut]"
                continue
            }
            guard inShortcutSection, trimmed.lowercased().hasPrefix("url=") else { continue }
            return URL(string: String(trimmed.dropFirst(4)).trimmingCharacters(in: .whitespaces))
        }
        return nil
    }
}
