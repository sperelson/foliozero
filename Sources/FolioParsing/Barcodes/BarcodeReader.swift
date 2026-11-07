import CoreGraphics
import Foundation
import ImageIO
import Logging
import PDFKit
import UniformTypeIdentifiers
import Vision

/// A barcode found on a page.
public struct DetectedBarcode: Sendable, Hashable {
    /// Zero-based page (PDF page or image frame) index.
    public var page: Int
    public var value: String
    /// Format name as zxing-cpp reports it and Paperless-ngx stores it ("QRCode", "Code128", "EAN13", ...).
    public var format: String

    public init(page: Int, value: String, format: String) {
        self.page = page
        self.value = value
        self.format = format
    }
}

/// Finds barcodes with Vision on rendered PDF pages, TIFF frames and images.
public enum BarcodeReader {
    static let logger = Logger(label: "foliozero.parsing.barcodes")

    /// Detects barcodes in `file`.
    ///
    /// - Parameters:
    ///   - maxPages: Scan at most this many pages. 0 scans every page.
    ///   - dpi: Resolution for rendering PDF pages (Paperless default 300).
    ///   - upscale: When greater than 1, images are enlarged by this factor first.
    /// - Returns: Barcodes in page order, then top to bottom. Empty values are dropped.
    public static func detect(
        file: URL,
        mimeType: String,
        maxPages: Int = 0,
        dpi: Int = 300,
        upscale: Double = 0,
        passwords: [String] = []
    ) async throws -> [DetectedBarcode] {
        var results: [DetectedBarcode] = []
        if mimeType == "application/pdf" {
            guard let opened = PDFUtilities.open(file, passwords: passwords), !opened.isLocked else {
                throw ParserError.unreadable(file, "PDF is unreadable or encrypted")
            }
            let count = maxPages > 0 ? min(maxPages, opened.document.pageCount) : opened.document.pageCount
            for index in 0..<count {
                let image: CGImage? = autoreleasepool {
                    guard let page = opened.document.page(at: index) else { return nil }
                    return PDFUtilities.render(page, dpi: CGFloat(dpi), maxPixels: 10_000, gray: true)
                }
                guard let image else { continue }
                results += try await scan(image, page: index, orientation: .up, upscale: upscale)
            }
        } else if mimeType.hasPrefix("image/") {
            guard let source = CGImageSourceCreateWithURL(file as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw ParserError.unreadable(file, "not a readable image")
            }
            let frames = mimeType == "image/tiff" ? CGImageSourceGetCount(source) : 1
            let count = maxPages > 0 ? min(maxPages, frames) : frames
            for index in 0..<count {
                let frameIndex = mimeType == "image/tiff" ? index : CGImageSourceGetPrimaryImageIndex(source)
                guard let image = CGImageSourceCreateImageAtIndex(source, frameIndex, nil) else { continue }
                let orientation = ImageOrientation(properties: ImageUtilities.properties(of: source, at: frameIndex))
                results += try await scan(image, page: index, orientation: orientation, upscale: upscale)
            }
        } else {
            throw ParserError.unsupportedType(mimeType)
        }
        return results
    }

    /// Barcodes in one image.
    public static func scan(_ image: CGImage, page: Int, orientation: ImageOrientation = .up, upscale: Double = 0) async throws -> [DetectedBarcode] {
        var input = image
        if upscale > 1, let scaled = scaled(image, by: upscale) { input = scaled }
        let request = DetectBarcodesRequest()
        let observations: [BarcodeObservation]
        do {
            observations = try await request.perform(on: input, orientation: orientation.exifOrientation)
        } catch {
            throw ParserError.conversionFailed("Vision barcode detection: \(error)")
        }
        var seen = Set<String>()
        return observations
            // Vision's origin is bottom-left: higher y means nearer the top.
            .sorted { $0.boundingBox.origin.y + $0.boundingBox.height > $1.boundingBox.origin.y + $1.boundingBox.height }
            .compactMap { observation -> DetectedBarcode? in
                guard let value = observation.payloadString, !value.isEmpty else { return nil }
                let format = formatName(observation.symbology)
                // Vision can report one code twice (for example normal and colour-inverted passes).
                guard seen.insert("\(format)|\(value)|\(Int(observation.boundingBox.origin.x * 100))").inserted else { return nil }
                return DetectedBarcode(page: page, value: value, format: format)
            }
    }

    /// zxing-cpp `BarcodeFormat` names, which Paperless-ngx stores.
    public static func formatName(_ symbology: BarcodeSymbology) -> String {
        switch symbology {
        case .aztec: "Aztec"
        case .codabar: "Codabar"
        case .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum: "Code39"
        case .code93, .code93i: "Code93"
        case .code128: "Code128"
        case .dataMatrix: "DataMatrix"
        case .ean8: "EAN8"
        case .ean13: "EAN13"
        case .i2of5, .i2of5Checksum, .itf14: "ITF"
        case .pdf417, .microPDF417: "PDF417"
        case .qr: "QRCode"
        case .microQR: "MicroQRCode"
        case .upce: "UPCE"
        case .gs1DataBar: "DataBar"
        case .gs1DataBarExpanded: "DataBarExpanded"
        case .gs1DataBarLimited: "DataBarLimited"
        case .msiPlessey: "MSIPlessey"
        @unknown default: String(describing: symbology)
        }
    }

    static func scaled(_ image: CGImage, by factor: Double) -> CGImage? {
        let width = Int((Double(image.width) * factor).rounded())
        let height = Int((Double(image.height) * factor).rounded())
        guard width < 30_000, height < 30_000,
              let context = ImageUtilities.makeContext(width: width, height: height, gray: true) else { return nil }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
