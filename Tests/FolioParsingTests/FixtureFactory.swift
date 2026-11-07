import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import ZIPFoundation
@testable import FolioParsing

/// Builds test fixtures at runtime, so no binaries are committed.
enum FixtureFactory {
    static let sampleLines = [
        "FOLIOZERO INVOICE 4711",
        "Payment due on Friday",
        "Total amount 1234.56",
    ]

    /// A fresh directory under the temporary directory.
    static func makeDirectory(_ label: String = #function) throws -> URL {
        let safe = label.filter { $0.isLetter || $0.isNumber }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FolioParsingTests", isDirectory: true)
            .appendingPathComponent("\(safe)-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func options(
        _ directory: URL,
        ocrMode: OCRMode = .auto,
        archiveMode: ArchiveMode = .auto,
        engine: OCREngineKind = .vision,
        languages: [String] = ["en-US"],
        ocrPages: Int = 0,
        rotatePages: Bool = true,
        passwords: [String] = [],
        pdfA: Bool = false
    ) -> ParseOptions {
        ParseOptions(
            ocrMode: ocrMode,
            archiveMode: archiveMode,
            ocrEngine: engine,
            languages: languages,
            ocrPages: ocrPages,
            rotatePages: rotatePages,
            scratchDirectory: directory.appendingPathComponent("scratch-\(UUID().uuidString.prefix(6))", isDirectory: true),
            pdfPasswords: passwords,
            pdfA: pdfA
        )
    }

    // MARK: Images

    /// Black text on white, large and clear. Lines start near the top.
    static func textImage(
        _ lines: [String] = sampleLines,
        width: Int = 1700,
        height: Int = 2200,
        fontSize: CGFloat = 72
    ) -> CGImage {
        let context = ImageUtilities.makeContext(width: width, height: height)!
        let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        var y = CGFloat(height) - fontSize * 2
        for text in lines {
            let attributed = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 0, alpha: 1),
            ])
            context.textPosition = CGPoint(x: fontSize * 1.5, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
            y -= fontSize * 1.8
        }
        return context.makeImage()!
    }

    /// `image` rotated clockwise by `degrees` (pixels actually moved).
    static func rotate(_ image: CGImage, clockwise degrees: Int) -> CGImage {
        ImageUtilities.renderUpright(image, orientation: ImageOrientation(rotation: degrees))!
    }

    static func writeImage(_ image: CGImage, type: UTType, to url: URL, properties: [CFString: Any] = [:]) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw ParserError.conversionFailed("no destination for \(type)")
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ParserError.conversionFailed("finalize \(type)") }
    }

    static func writeMultiPageTIFF(_ images: [CGImage], to url: URL, dpi: Double = 200) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.tiff.identifier as CFString, images.count, nil) else {
            throw ParserError.conversionFailed("no TIFF destination")
        }
        for image in images {
            CGImageDestinationAddImage(destination, image, [
                kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi,
            ] as CFDictionary)
        }
        guard CGImageDestinationFinalize(destination) else { throw ParserError.conversionFailed("finalize TIFF") }
    }

    // MARK: PDFs

    /// A born-digital PDF: real text drawn with Core Text, one array of lines per page.
    static func bornDigitalPDF(
        pages: [[String]],
        to url: URL,
        title: String? = "Quarterly Report",
        author: String? = "Jane Example",
        userPassword: String? = nil,
        ownerPassword: String? = nil
    ) throws {
        var info: [CFString: Any] = [kCGPDFContextCreator: "FolioParsingTests"]
        if let title { info[kCGPDFContextTitle] = title }
        if let author { info[kCGPDFContextAuthor] = author }
        if let userPassword {
            info[kCGPDFContextUserPassword] = userPassword
            info[kCGPDFContextOwnerPassword] = ownerPassword ?? userPassword + "-owner"
        }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else {
            throw ParserError.conversionFailed("cannot create PDF")
        }
        let font = CTFontCreateWithName("Helvetica" as CFString, 18, nil)
        for lines in pages {
            context.beginPDFPage(nil)
            var y: CGFloat = 720
            for text in lines {
                let attributed = NSAttributedString(string: text, attributes: [
                    NSAttributedString.Key(kCTFontAttributeName as String): font,
                ])
                context.textPosition = CGPoint(x: 72, y: y)
                CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
                y -= 28
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// A "scanned" PDF: every page is only a JPEG image of text, no text layer.
    static func scannedPDF(images: [CGImage], to url: URL, pageSize: CGSize = CGSize(width: 612, height: 792)) throws {
        var box = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw ParserError.conversionFailed("cannot create PDF")
        }
        for image in images {
            let data = ImageUtilities.jpegData(image, quality: 0.85)!
            let jpeg = CGImage(
                jpegDataProviderSource: CGDataProvider(data: data as CFData)!,
                decode: nil, shouldInterpolate: true, intent: .defaultIntent
            )!
            var pageBox = CGRect(
                origin: .zero,
                size: image.width > image.height ? CGSize(width: pageSize.height, height: pageSize.width) : pageSize
            )
            context.beginPage(mediaBox: &pageBox)
            context.draw(jpeg, in: pageBox)
            context.endPage()
        }
        context.closePDF()
    }

    // MARK: ZIP containers

    static func zip(_ entries: [(String, String)], to url: URL) throws {
        let archive = try ZIPArchiveWriter(url: url)
        for (path, content) in entries {
            try archive.add(path: path, data: Data(content.utf8))
        }
    }
}

/// Minimal ZIP writer for fixtures.
struct ZIPArchiveWriter {
    let archive: Archive

    init(url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
    }

    func add(path: String, data: Data) throws {
        try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(data.count), compressionMethod: .none) {
            position, size in
            data.subdata(in: Int(position)..<Int(position) + size)
        }
    }
}
