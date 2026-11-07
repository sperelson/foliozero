import Foundation
import UniformTypeIdentifiers
import ZIPFoundation

/// Detects the MIME type of a file: magic bytes first, then the content of
/// container formats (ZIP, OLE2, plists), then text heuristics, then the file
/// extension through UTType.
public enum FileTypeDetector {
    public static let octetStream = "application/octet-stream"
    /// `.webloc` and `.url` files.
    public static let urlShortcut = "application/x-foliozero-url-shortcut"
    public static let webArchive = "application/x-webarchive"

    /// Bytes read from the start of a file for sniffing.
    static let headLength = 64 * 1024

    /// MIME type of the file at `url`. Throws when the file cannot be read.
    public static func mimeType(of url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ParserError.unreadable(url, error.localizedDescription)
        }
        defer { try? handle.close() }
        let head = (try handle.read(upToCount: headLength)) ?? Data()
        return detect(
            head: head,
            fileName: url.lastPathComponent,
            zip: { try? Archive(url: url, accessMode: .read, pathEncoding: nil) },
            whole: {
                try? handle.seek(toOffset: 0)
                return try? handle.read(upToCount: 1 << 20)
            }
        )
    }

    /// MIME type of in-memory file content. `fileName` supplies the extension used as a hint.
    public static func mimeType(of data: Data, fileName: String) -> String {
        detect(
            head: data.prefix(headLength),
            fileName: fileName,
            zip: { try? Archive(data: data, accessMode: .read, pathEncoding: nil) },
            whole: { data.prefix(1 << 20) }
        )
    }

    // MARK: - Detection

    static func detect(head: Data, fileName: String, zip: () -> Archive?, whole: () -> Data?) -> String {
        let ext = (fileName as NSString).pathExtension.lowercased()
        let b = [UInt8](head.prefix(64))

        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            b.count >= offset + bytes.count && Array(b[offset..<(offset + bytes.count)]) == bytes
        }
        func ascii(_ s: String, at offset: Int = 0) -> Bool { starts(Array(s.utf8), at: offset) }

        if head.prefix(1024).range(of: Data("%PDF-".utf8)) != nil { return "application/pdf" }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if starts([0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if ascii("GIF87a") || ascii("GIF89a") { return "image/gif" }
        if starts([0x49, 0x49, 0x2A, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2A])
            || starts([0x49, 0x49, 0x2B, 0x00]) || starts([0x4D, 0x4D, 0x00, 0x2B]) {
            return "image/tiff"
        }
        if ascii("BM"), b.count >= 18 {
            let dibSize = UInt32(b[14]) | UInt32(b[15]) << 8 | UInt32(b[16]) << 16 | UInt32(b[17]) << 24
            if [12, 16, 40, 52, 56, 64, 108, 124].contains(dibSize) { return "image/bmp" }
        }
        if ascii("RIFF"), ascii("WEBP", at: 8) { return "image/webp" }
        if ascii("ftyp", at: 4), let heif = heifType(head) { return heif }
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) || starts([0x50, 0x4B, 0x07, 0x08]) {
            return zipType(zip(), ext: ext)
        }
        if starts([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            return oleType(ext: ext, content: whole)
        }
        if ascii("{\\rtf") { return "text/rtf" }
        if ascii("bplist00") {
            if ext == "webarchive" || head.range(of: Data("WebMainResource".utf8)) != nil { return webArchive }
            if ext == "webloc" { return urlShortcut }
            return byExtension(ext) ?? octetStream
        }
        if TextEncodingDetector.looksLikeText(head) {
            let text = TextEncodingDetector.decode(Data(head.prefix(16 * 1024))).text
            return textType(text, ext: ext)
        }
        return byExtension(ext) ?? octetStream
    }

    /// HEIF family from the `ftyp` box: major brand, then compatible brands.
    static func heifType(_ head: Data) -> String? {
        let bytes = [UInt8](head.prefix(256))
        guard bytes.count >= 16 else { return nil }
        let boxSize = Int(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
        var brands: [String] = []
        func brand(at offset: Int) -> String { String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self) }
        brands.append(brand(at: 8))
        var offset = 16
        while offset + 4 <= min(boxSize, bytes.count) {
            brands.append(brand(at: offset))
            offset += 4
        }
        let heic: Set = ["heic", "heix", "hevc", "hevx", "heim", "heis"]
        let heif: Set = ["mif1", "msf1"]
        if heic.contains(brands[0]) { return "image/heic" }
        if brands[0] == "avif" || brands[0] == "avis" { return "image/avif" }
        if heif.contains(brands[0]) {
            if brands.dropFirst().contains(where: heic.contains) { return "image/heic" }
            if brands.dropFirst().contains("avif") { return "image/avif" }
            return "image/heif"
        }
        if brands.contains(where: heic.contains) { return "image/heic" }
        return nil
    }

    /// Main-part content types of OOXML packages, in match order.
    static let ooxmlContentTypes: [(contentType: String, mime: String)] = [
        ("application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
         "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
        ("application/vnd.ms-word.document.macroEnabled.main+xml", "application/vnd.ms-word.document.macroEnabled.12"),
        ("application/vnd.openxmlformats-officedocument.wordprocessingml.template.main+xml",
         "application/vnd.openxmlformats-officedocument.wordprocessingml.template"),
        ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml",
         "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
        ("application/vnd.ms-excel.sheet.macroEnabled.main+xml", "application/vnd.ms-excel.sheet.macroEnabled.12"),
        ("application/vnd.openxmlformats-officedocument.spreadsheetml.template.main+xml",
         "application/vnd.openxmlformats-officedocument.spreadsheetml.template"),
        ("application/vnd.openxmlformats-officedocument.presentationml.slideshow.main+xml",
         "application/vnd.openxmlformats-officedocument.presentationml.slideshow"),
        ("application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml",
         "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
        ("application/vnd.ms-powerpoint.presentation.macroEnabled.main+xml",
         "application/vnd.ms-powerpoint.presentation.macroEnabled.12"),
        ("application/vnd.openxmlformats-officedocument.presentationml.template.main+xml",
         "application/vnd.openxmlformats-officedocument.presentationml.template"),
    ]

    static func zipType(_ archive: Archive?, ext: String) -> String {
        guard let archive else { return "application/zip" }
        if let entry = archive["mimetype"], entry.uncompressedSize < 256,
           let data = ZipReader.data(of: entry, in: archive, limit: 256) {
            let mime = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if mime.hasPrefix("application/"), !mime.contains(" ") { return mime }
        }
        if let entry = archive["[Content_Types].xml"],
           let data = ZipReader.data(of: entry, in: archive, limit: 1 << 20) {
            let xml = String(decoding: data, as: UTF8.self)
            for (contentType, mime) in ooxmlContentTypes where xml.contains(contentType) {
                return mime
            }
            if archive["word/document.xml"] != nil {
                return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
            }
            if archive["xl/workbook.xml"] != nil {
                return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
            }
            if archive["ppt/presentation.xml"] != nil {
                return ext == "ppsx"
                    ? "application/vnd.openxmlformats-officedocument.presentationml.slideshow"
                    : "application/vnd.openxmlformats-officedocument.presentationml.presentation"
            }
        }
        return "application/zip"
    }

    static func oleType(ext: String, content: () -> Data?) -> String {
        switch ext {
        case "doc", "dot": return "application/msword"
        case "xls", "xlt", "xla": return "application/vnd.ms-excel"
        case "ppt", "pps", "pot": return "application/vnd.ms-powerpoint"
        case "msg": return "application/vnd.ms-outlook"
        default: break
        }
        // Look for the main stream names in the OLE directory (UTF-16LE).
        guard let data = content() else { return "application/x-ole-storage" }
        func utf16(_ s: String) -> Data { Data(s.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }) }
        if data.range(of: utf16("WordDocument")) != nil { return "application/msword" }
        if data.range(of: utf16("Workbook")) != nil || data.range(of: utf16("Book\u{0}")) != nil {
            return "application/vnd.ms-excel"
        }
        if data.range(of: utf16("PowerPoint Document")) != nil { return "application/vnd.ms-powerpoint" }
        return "application/x-ole-storage"
    }

    static let emailHeaders: Set<String> = [
        "from", "to", "cc", "subject", "date", "received", "return-path", "message-id",
        "mime-version", "delivered-to", "reply-to", "content-type", "x-mailer", "sender",
        "dkim-signature", "authentication-results", "x-received", "arc-seal", "in-reply-to", "references",
    ]

    static func textType(_ text: String, ext: String) -> String {
        let trimmed = text.drop { $0 == "\u{FEFF}" || $0.isWhitespace || $0.isNewline }
        let lower = String(trimmed.prefix(2048)).lowercased()

        if lower.hasPrefix("[internetshortcut]") || (ext == "url" && lower.contains("[internetshortcut]")) {
            return urlShortcut
        }
        if ext == "webloc", lower.contains("<plist") { return urlShortcut }
        if lower.hasPrefix("<!doctype html") || lower.hasPrefix("<html") { return "text/html" }
        if lower.hasPrefix("<?xml") {
            if lower.contains("<html") || ["html", "htm", "xhtml"].contains(ext) { return "text/html" }
            return byExtension(ext).flatMap { $0.contains("xml") || $0.hasPrefix("image/") ? $0 : nil } ?? "application/xml"
        }
        if lower.hasPrefix("<"), ["<head", "<body", "<meta", "<title", "<!--"].contains(where: lower.hasPrefix),
           lower.contains("<html") || lower.contains("<body") || lower.contains("<head") {
            return "text/html"
        }
        if ["html", "htm", "xhtml", "shtml"].contains(ext) { return "text/html" }
        if ext == "eml" || looksLikeEmail(String(trimmed.prefix(8192))) { return "message/rfc822" }
        if ["md", "markdown", "mdown", "mkd", "mkdn"].contains(ext) { return "text/markdown" }
        if ext == "csv" { return "text/csv" }
        if ext == "rtf" { return "text/rtf" }
        if ext == "url", lower.contains("url=") { return urlShortcut }
        return "text/plain"
    }

    /// RFC 5322 header block: the first lines are `Name: value` (with folded
    /// continuation lines), at least two known mail headers, and one of
    /// From/Received/Message-ID/Return-Path.
    static func looksLikeEmail(_ text: String) -> Bool {
        var known = Set<String>()
        var sawHeader = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false).prefix(60) {
            let line = line.hasSuffix("\r") ? line.dropLast() : line
            if line.isEmpty { break }
            if line.first == " " || line.first == "\t" {
                if !sawHeader { return false }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { return false }
            let name = line[..<colon]
            guard !name.isEmpty, name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else {
                return false
            }
            sawHeader = true
            let lower = name.lowercased()
            if emailHeaders.contains(lower) { known.insert(lower) }
        }
        let anchors: Set<String> = ["from", "received", "message-id", "return-path", "delivered-to"]
        return known.count >= 2 && !known.isDisjoint(with: anchors)
    }

    static func byExtension(_ ext: String) -> String? {
        guard !ext.isEmpty else { return nil }
        switch ext {
        case "webloc", "url": return urlShortcut
        case "webarchive": return webArchive
        case "eml": return "message/rfc822"
        case "md", "markdown": return "text/markdown"
        default: break
        }
        return UTType(filenameExtension: ext)?.preferredMIMEType
    }

    // MARK: - Extensions

    static let extensions: [String: String] = [
        "application/pdf": ".pdf",
        "image/png": ".png",
        "image/jpeg": ".jpg",
        "image/gif": ".gif",
        "image/tiff": ".tif",
        "image/bmp": ".bmp",
        "image/webp": ".webp",
        "image/heic": ".heic",
        "image/heif": ".heif",
        "image/avif": ".avif",
        "text/plain": ".txt",
        "text/csv": ".csv",
        "application/csv": ".csv",
        "text/markdown": ".md",
        "text/html": ".html",
        "text/rtf": ".rtf",
        "application/rtf": ".rtf",
        "application/xml": ".xml",
        "message/rfc822": ".eml",
        "application/zip": ".zip",
        "application/msword": ".doc",
        "application/vnd.ms-excel": ".xls",
        "application/vnd.ms-powerpoint": ".ppt",
        "application/vnd.ms-outlook": ".msg",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": ".docx",
        "application/vnd.ms-word.document.macroEnabled.12": ".docm",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.template": ".dotx",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": ".xlsx",
        "application/vnd.ms-excel.sheet.macroEnabled.12": ".xlsm",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.template": ".xltx",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": ".pptx",
        "application/vnd.openxmlformats-officedocument.presentationml.slideshow": ".ppsx",
        "application/vnd.openxmlformats-officedocument.presentationml.template": ".potx",
        "application/vnd.ms-powerpoint.presentation.macroEnabled.12": ".pptm",
        "application/vnd.oasis.opendocument.text": ".odt",
        "application/vnd.oasis.opendocument.spreadsheet": ".ods",
        "application/vnd.oasis.opendocument.presentation": ".odp",
        "application/vnd.oasis.opendocument.graphics": ".odg",
        "application/epub+zip": ".epub",
        urlShortcut: ".webloc",
        webArchive: ".webarchive",
    ]

    /// Default file extension for a MIME type, with the leading dot (".pdf"),
    /// matching `DocumentParser.supportedMIMETypes`. Empty when unknown.
    public static func defaultExtension(for mimeType: String) -> String {
        let mime = mimeType.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        if let ext = extensions[mime] { return ext }
        if mime == octetStream { return ".bin" }
        if let ext = UTType(mimeType: mime)?.preferredFilenameExtension { return "." + ext }
        return ""
    }
}

/// Small ZIPFoundation helpers.
public enum ZipReader {
    /// Uncompressed content of `entry`, or nil when it is larger than `limit` bytes or unreadable.
    public static func data(of entry: Entry, in archive: Archive, limit: Int = 64 << 20) -> Data? {
        guard entry.uncompressedSize <= UInt64(limit) else { return nil }
        var data = Data()
        do {
            _ = try archive.extract(entry, skipCRC32: true) { chunk in data.append(chunk) }
        } catch {
            return nil
        }
        return data
    }

    /// Uncompressed content of the entry at `path`.
    public static func data(at path: String, in archive: Archive, limit: Int = 64 << 20) -> Data? {
        guard let entry = archive[path] else { return nil }
        return data(of: entry, in: archive, limit: limit)
    }
}
