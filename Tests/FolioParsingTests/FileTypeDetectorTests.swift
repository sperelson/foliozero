import Foundation
import Testing
import UniformTypeIdentifiers
@testable import FolioParsing

@Suite("File type detection")
struct FileTypeDetectorTests {
    let dir: URL

    init() throws {
        dir = try FixtureFactory.makeDirectory("filetype")
    }

    func write(_ bytes: [UInt8], _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func write(_ text: String, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func image(_ type: UTType, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try FixtureFactory.writeImage(FixtureFactory.textImage(["X"], width: 64, height: 48, fontSize: 20), type: type, to: url)
        return url
    }

    @Test func rasterImagesFromImageIO() throws {
        #expect(try FileTypeDetector.mimeType(of: image(.png, "a.dat")) == "image/png")
        #expect(try FileTypeDetector.mimeType(of: image(.jpeg, "a.png")) == "image/jpeg")
        #expect(try FileTypeDetector.mimeType(of: image(.gif, "a")) == "image/gif")
        #expect(try FileTypeDetector.mimeType(of: image(.tiff, "a.jpg")) == "image/tiff")
        #expect(try FileTypeDetector.mimeType(of: image(.bmp, "a.bin")) == "image/bmp")
        #expect(try FileTypeDetector.mimeType(of: image(.heic, "photo")) == "image/heic")
    }

    @Test func syntheticMagicNumbers() throws {
        #expect(try FileTypeDetector.mimeType(of: write([0x4D, 0x4D, 0x00, 0x2A, 0, 0, 0, 8, 1, 2], "big")) == "image/tiff")
        #expect(try FileTypeDetector.mimeType(of: write([0x49, 0x49, 0x2A, 0x00, 8, 0, 0, 0, 1, 2], "little")) == "image/tiff")
        let webp = Array("RIFF".utf8) + [0x24, 0, 0, 0] + Array("WEBPVP8 ".utf8) + [UInt8](repeating: 1, count: 20)
        #expect(try FileTypeDetector.mimeType(of: write(webp, "x")) == "image/webp")
        let heif = [0, 0, 0, 0x18] + Array("ftypmif1".utf8) + [0, 0, 0, 0] + Array("mif1miaf".utf8) + [0, 0, 0, 0]
        #expect(try FileTypeDetector.mimeType(of: write(heif, "x.bin")) == "image/heif")
        let heix = [0, 0, 0, 0x14] + Array("ftypheix".utf8) + [0, 0, 0, 0] + Array("mif1".utf8) + [0, 0, 0, 0]
        #expect(try FileTypeDetector.mimeType(of: write(heix, "x.bin")) == "image/heic")
        let msf1 = [0, 0, 0, 0x18] + Array("ftypmsf1".utf8) + [0, 0, 0, 0] + Array("msf1hevc".utf8) + [0, 0, 0, 0]
        #expect(try FileTypeDetector.mimeType(of: write(msf1, "x.bin")) == "image/heic")
        #expect(try FileTypeDetector.mimeType(of: write(Array("{\\rtf1\\ansi Hello}".utf8), "doc.txt")) == "text/rtf")
    }

    @Test func pdfIncludingJunkBeforeHeader() throws {
        let url = dir.appendingPathComponent("d.bin")
        try FixtureFactory.bornDigitalPDF(pages: [["Hello"]], to: url)
        #expect(try FileTypeDetector.mimeType(of: url) == "application/pdf")
        var junk = Data(repeating: 0x20, count: 100)
        junk.append(try Data(contentsOf: url))
        let junkURL = dir.appendingPathComponent("junk")
        try junk.write(to: junkURL)
        #expect(try FileTypeDetector.mimeType(of: junkURL) == "application/pdf")
    }

    static let ooxml: [(String, String)] = [
        ("application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml",
         "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
        ("application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml",
         "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"),
        ("application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml",
         "application/vnd.openxmlformats-officedocument.presentationml.presentation"),
        ("application/vnd.openxmlformats-officedocument.presentationml.slideshow.main+xml",
         "application/vnd.openxmlformats-officedocument.presentationml.slideshow"),
    ]

    @Test(arguments: ooxml)
    func officeOpenXML(contentType: String, expected: String) throws {
        let url = dir.appendingPathComponent("office-\(UUID().uuidString.prefix(4)).zip")
        let types = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="xml" ContentType="application/xml"/>
        <Override PartName="/main.xml" ContentType="\(contentType)"/>
        </Types>
        """
        try FixtureFactory.zip([("[Content_Types].xml", types), ("_rels/.rels", "<Relationships/>")], to: url)
        #expect(try FileTypeDetector.mimeType(of: url) == expected)
        let data = try Data(contentsOf: url)
        #expect(FileTypeDetector.mimeType(of: data, fileName: "upload") == expected)
    }

    @Test(arguments: ["text", "spreadsheet", "presentation", "graphics"])
    func openDocument(kind: String) throws {
        let url = dir.appendingPathComponent("odf-\(kind)")
        let mime = "application/vnd.oasis.opendocument.\(kind)"
        try FixtureFactory.zip([("mimetype", mime), ("content.xml", "<office:document-content/>")], to: url)
        #expect(try FileTypeDetector.mimeType(of: url) == mime)
    }

    @Test func plainZip() throws {
        let url = dir.appendingPathComponent("plain.zip")
        try FixtureFactory.zip([("readme.txt", "hello")], to: url)
        #expect(try FileTypeDetector.mimeType(of: url) == "application/zip")
    }

    @Test func ole2ByExtensionAndStreamName() throws {
        let magic: [UInt8] = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1] + [UInt8](repeating: 0, count: 504)
        #expect(try FileTypeDetector.mimeType(of: write(magic, "a.doc")) == "application/msword")
        #expect(try FileTypeDetector.mimeType(of: write(magic, "a.xls")) == "application/vnd.ms-excel")
        #expect(try FileTypeDetector.mimeType(of: write(magic, "a.ppt")) == "application/vnd.ms-powerpoint")
        let word = magic + Array("WordDocument".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        #expect(try FileTypeDetector.mimeType(of: write(word, "noext")) == "application/msword")
        #expect(try FileTypeDetector.mimeType(of: write(magic, "mystery")) == "application/x-ole-storage")
    }

    @Test func webFormats() throws {
        let archive = try PropertyListSerialization.data(
            fromPropertyList: ["WebMainResource": ["WebResourceData": Data("<html></html>".utf8), "WebResourceMIMEType": "text/html"]],
            format: .binary, options: 0
        )
        let archiveURL = dir.appendingPathComponent("page.bin")
        try archive.write(to: archiveURL)
        #expect(try FileTypeDetector.mimeType(of: archiveURL) == FileTypeDetector.webArchive)

        let webloc = try PropertyListSerialization.data(fromPropertyList: ["URL": "https://example.com"], format: .binary, options: 0)
        let weblocURL = dir.appendingPathComponent("link.webloc")
        try webloc.write(to: weblocURL)
        #expect(try FileTypeDetector.mimeType(of: weblocURL) == FileTypeDetector.urlShortcut)

        let xmlWebloc = try PropertyListSerialization.data(fromPropertyList: ["URL": "https://example.com"], format: .xml, options: 0)
        let xmlWeblocURL = dir.appendingPathComponent("xml.webloc")
        try xmlWebloc.write(to: xmlWeblocURL)
        #expect(try FileTypeDetector.mimeType(of: xmlWeblocURL) == FileTypeDetector.urlShortcut)

        #expect(try FileTypeDetector.mimeType(of: write("[InternetShortcut]\r\nURL=https://example.com\r\n", "link.url"))
            == FileTypeDetector.urlShortcut)
        #expect(try FileTypeDetector.mimeType(of: write("<!DOCTYPE html>\n<html><body>Hi</body></html>", "page")) == "text/html")
        #expect(try FileTypeDetector.mimeType(of: write("<div>fragment</div>", "frag.htm")) == "text/html")
    }

    @Test func emailByContentAndExtension() throws {
        let mail = """
        Return-Path: <a@example.com>
        Received: from mx.example.com by host
        From: Alice <a@example.com>
        To: Bob <b@example.com>
        Subject: Invoice
        Date: Mon, 2 Nov 2026 10:00:00 +0200
        Message-ID: <1@example.com>

        Hello Bob.
        """
        #expect(try FileTypeDetector.mimeType(of: write(mail, "message")) == "message/rfc822")
        #expect(try FileTypeDetector.mimeType(of: write("Hello", "short.eml")) == "message/rfc822")
        #expect(try FileTypeDetector.mimeType(of: write("Note: this is not\nTodo: mail\n\nbody", "notes")) == "text/plain")
    }

    @Test func textVariants() throws {
        #expect(try FileTypeDetector.mimeType(of: write("# Title\n\nSome *text*.", "readme.md")) == "text/markdown")
        #expect(try FileTypeDetector.mimeType(of: write("a,b\n1,2\n", "data.csv")) == "text/csv")
        #expect(try FileTypeDetector.mimeType(of: write("Hello wörld", "note.txt")) == "text/plain")
        #expect(try FileTypeDetector.mimeType(of: write("Hello wörld", "noextension")) == "text/plain")

        let utf16 = [UInt8]([0xFF, 0xFE]) + Array("Hello UTF-16".utf16).flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
        #expect(try FileTypeDetector.mimeType(of: write(utf16, "wide")) == "text/plain")
        let latin1: [UInt8] = Array("Caf".utf8) + [0xE9] + Array(" cr".utf8) + [0xE8] + Array("me br".utf8) + [0xFB] + Array("l".utf8) + [0xE9, 0x0A]
        #expect(try FileTypeDetector.mimeType(of: write(latin1, "latin1")) == "text/plain")
    }

    @Test func unknownBinary() throws {
        let bytes: [UInt8] = (0..<512).map { UInt8(($0 * 37) % 256) }
        #expect(try FileTypeDetector.mimeType(of: write(bytes, "blob")) == FileTypeDetector.octetStream)
    }

    @Test func missingFileThrows() {
        #expect(throws: ParserError.self) {
            try FileTypeDetector.mimeType(of: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)"))
        }
    }

    @Test func defaultExtensions() {
        #expect(FileTypeDetector.defaultExtension(for: "application/pdf") == ".pdf")
        #expect(FileTypeDetector.defaultExtension(for: "image/jpeg") == ".jpg")
        #expect(FileTypeDetector.defaultExtension(for: "text/plain; charset=utf-8") == ".txt")
        #expect(FileTypeDetector.defaultExtension(for: "application/vnd.oasis.opendocument.text") == ".odt")
        #expect(FileTypeDetector.defaultExtension(for: FileTypeDetector.urlShortcut) == ".webloc")
        #expect(FileTypeDetector.defaultExtension(for: "application/octet-stream") == ".bin")
        #expect(FileTypeDetector.defaultExtension(for: "x-unknown/whatever") == "")
    }
}
