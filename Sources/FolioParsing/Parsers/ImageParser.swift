import CoreGraphics
import Foundation
import ImageIO
import Logging
import UniformTypeIdentifiers

/// Raster images: JPEG, PNG, TIFF (every frame is a page), GIF (first frame),
/// BMP, WebP, HEIC/HEIF. EXIF orientation is honoured. Every page is OCR'd
/// unless the OCR mode is `off`. Archive modes `auto` and `always` both write an
/// archive PDF; `never` writes none.
///
/// Page size comes from the image's DPI metadata (values of 72 or less count as
/// absent, see `ImageUtilities.dpi(properties:)`), else `ParseOptions.imageDPI`, else 300.
public struct ImageParser: DocumentParser {
    public let name = "image"
    public let supportedMIMETypes: [String: String] = [
        "image/jpeg": ".jpg",
        "image/png": ".png",
        "image/tiff": ".tif",
        "image/gif": ".gif",
        "image/bmp": ".bmp",
        "image/webp": ".webp",
        "image/heic": ".heic",
        "image/heif": ".heif",
    ]

    public var concurrency = ConcurrentOCR.defaultConcurrency
    public var jpegQuality = 0.8

    static let logger = Logger(label: "foliozero.parsing.image")

    public init() {}

    struct Frame {
        var index: Int
        var properties: [CFString: Any]
        var orientation: ImageOrientation
        var pixelSize: CGSize
        var dpi: (x: Double, y: Double)?
    }

    public func parse(file: URL, mimeType: String, options: ParseOptions) async throws -> ParseResult {
        try FileManager.default.createDirectory(at: options.scratchDirectory, withIntermediateDirectories: true)
        guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw ParserError.unreadable(file, "not a readable image")
        }

        let count = CGImageSourceGetCount(source)
        let sourceType = CGImageSourceGetType(source).map { $0 as String }
        let isTIFF = sourceType == UTType.tiff.identifier || mimeType == "image/tiff"
        let indices = isTIFF ? Array(0..<count) : [CGImageSourceGetPrimaryImageIndex(source)]
        let frames: [Frame] = indices.compactMap { index in
            let properties = ImageUtilities.properties(of: source, at: index)
            guard let size = ImageUtilities.pixelSize(properties: properties) else { return nil }
            return Frame(
                index: index,
                properties: properties,
                orientation: ImageOrientation(properties: properties),
                pixelSize: size,
                dpi: ImageUtilities.dpi(properties: properties)
            )
        }
        guard let primary = frames.first else {
            throw ParserError.unreadable(file, "image has no readable frames")
        }
        let metadata = ImageMetadata.entries(properties: primary.properties, frameCount: frames.count)

        var ocr: [Int: OCRPageResult] = [:]
        if options.ocrMode != .off {
            let positions = frames.indices.filter { options.ocrPages == 0 || $0 < options.ocrPages }
            ocr = try await recognize(positions: positions, frames: frames, source: source, options: options)
            if !positions.isEmpty, ocr.isEmpty {
                throw ParserError.ocrFailed("OCR failed on every page of \(file.lastPathComponent)")
            }
        }
        let text = TextNormalizer.postProcess(
            frames.indices.compactMap { ocr[$0]?.text }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        )

        var archive: URL?
        if options.archiveMode != .never {
            let passthroughJPEG = sourceType == UTType.jpeg.identifier && frames.count == 1
            let fallbackDPI = Double(options.imageDPI ?? 300)
            var pages: [ArchivePDFBuilder.Page] = []
            for (position, frame) in frames.enumerated() {
                let rotation = ocr[position]?.rotation ?? 0
                let orientation = frame.orientation.rotated(byClockwise: rotation)
                let dpi = frame.dpi ?? (fallbackDPI, fallbackDPI)
                let rawPoints = CGSize(width: frame.pixelSize.width / dpi.x * 72, height: frame.pixelSize.height / dpi.y * 72)
                let content: ArchivePDFBuilder.Page.Content
                if passthroughJPEG {
                    content = .jpegFile(file)
                } else if let image = CGImageSourceCreateImageAtIndex(source, frame.index, nil) {
                    content = .image(image, lossless: ImageUtilities.prefersLossless(image))
                } else {
                    continue
                }
                pages.append(ArchivePDFBuilder.Page(
                    content: content,
                    orientation: orientation,
                    size: orientation.orientedSize(rawPoints),
                    lines: ocr[position]?.lines ?? []
                ))
            }
            let builder = ArchivePDFBuilder(title: file.deletingPathExtension().lastPathComponent, jpegQuality: jpegQuality)
            let url = options.scratchDirectory.appendingPathComponent("archive.pdf")
            try builder.write(pages: pages, to: url)
            await PDFAConverter.applyIfRequested(to: url, options: options)
            archive = url
        }

        let thumbnailImage = autoreleasepool {
            ThumbnailRenderer.image(
                fromImageSource: source,
                index: primary.index,
                maxPixels: options.thumbnailMaxPixels,
                extraRotation: ocr[0]?.rotation ?? 0
            )
        }
        let thumbnail = try ThumbnailRenderer.write(
            thumbnailImage ?? ThumbnailRenderer.placeholder(label: "IMAGE", maxPixels: options.thumbnailMaxPixels),
            to: options.scratchDirectory
        )

        return ParseResult(
            text: text,
            archiveFile: archive,
            thumbnailFile: thumbnail,
            pageCount: frames.count,
            metadata: metadata,
            metadataDate: ImageMetadata.creationDate(properties: primary.properties),
            suggestedTitle: nil,
            language: LanguageDetector.detect(text)
        )
    }

    /// Recognises the frames at `positions`, at most `concurrency` at a time.
    func recognize(
        positions: [Int],
        frames: [Frame],
        source: CGImageSource,
        options: ParseOptions
    ) async throws -> [Int: OCRPageResult] {
        guard !positions.isEmpty else { return [:] }
        let recognizer = PageRecognizer(options: options)
        let limit = max(1, concurrency)
        var results: [Int: OCRPageResult] = [:]

        try await withThrowingTaskGroup(of: (Int, OCRPageResult?).self) { group in
            var inFlight = 0
            for position in positions {
                if inFlight >= limit, let next = try await group.next() {
                    if let result = next.1 { results[next.0] = result }
                    inFlight -= 1
                }
                try Task.checkCancellation()
                let frame = frames[position]
                guard let image = CGImageSourceCreateImageAtIndex(source, frame.index, nil) else {
                    Self.logger.warning("Cannot decode frame \(frame.index)")
                    continue
                }
                let orientation = frame.orientation
                group.addTask {
                    do {
                        return (position, try await recognizer.recognize(image, orientation: orientation))
                    } catch {
                        Self.logger.warning("OCR failed on page \(position + 1): \(error)")
                        return (position, nil)
                    }
                }
                inFlight += 1
            }
            for try await (position, result) in group {
                if let result { results[position] = result }
            }
        }
        return results
    }
}
