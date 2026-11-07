import Foundation

/// The built-in parsers.
public enum StandardParsers {
    /// Every built-in parser: PDF, image, text, HTML and web archives, URL
    /// shortcuts, email and Office documents.
    public static var all: [any DocumentParser] {
        [PDFParser(), ImageParser(), TextParser(), HTMLParser(), URLShortcutParser(), EmailParser(), OfficeParser()]
    }

    public static func makeRegistry() -> ParserRegistry {
        ParserRegistry(parsers: all)
    }
}
