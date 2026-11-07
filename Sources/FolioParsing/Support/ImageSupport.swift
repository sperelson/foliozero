import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// How a stored raster (or PDF page) is turned upright for display: an optional
/// horizontal mirror, then a clockwise rotation. Equivalent to EXIF orientation.
public struct ImageOrientation: Sendable, Hashable, CustomStringConvertible {
    public var mirrored: Bool
    /// Clockwise rotation in degrees: 0, 90, 180 or 270.
    public var rotation: Int

    public static let up = ImageOrientation(rotation: 0)

    public init(mirrored: Bool = false, rotation: Int) {
        self.mirrored = mirrored
        self.rotation = ImageOrientation.normalize(rotation)
    }

    public init(_ exif: CGImagePropertyOrientation) {
        switch exif {
        case .up: self.init(rotation: 0)
        case .upMirrored: self.init(mirrored: true, rotation: 0)
        case .down: self.init(rotation: 180)
        case .downMirrored: self.init(mirrored: true, rotation: 180)
        case .leftMirrored: self.init(mirrored: true, rotation: 270)
        case .right: self.init(rotation: 90)
        case .rightMirrored: self.init(mirrored: true, rotation: 90)
        case .left: self.init(rotation: 270)
        @unknown default: self.init(rotation: 0)
        }
    }

    /// Reads `kCGImagePropertyOrientation` from ImageIO properties.
    public init(properties: [CFString: Any]) {
        if let raw = (properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value,
           let exif = CGImagePropertyOrientation(rawValue: raw) {
            self.init(exif)
        } else {
            self = .up
        }
    }

    public var exifOrientation: CGImagePropertyOrientation {
        switch (mirrored, rotation) {
        case (false, 90): .right
        case (false, 180): .down
        case (false, 270): .left
        case (true, 0): .upMirrored
        case (true, 90): .rightMirrored
        case (true, 180): .downMirrored
        case (true, 270): .leftMirrored
        default: .up
        }
    }

    /// This orientation followed by a further clockwise rotation.
    public func rotated(byClockwise degrees: Int) -> ImageOrientation {
        ImageOrientation(mirrored: mirrored, rotation: rotation + degrees)
    }

    public var swapsAxes: Bool { rotation == 90 || rotation == 270 }

    /// Size after applying the orientation to content of `size`.
    public func orientedSize(_ size: CGSize) -> CGSize {
        swapsAxes ? CGSize(width: size.height, height: size.width) : size
    }

    /// Transform that maps content drawn in `CGRect(origin: .zero, size: rawSize)`
    /// (y axis up, as in Core Graphics) to its upright position in
    /// `CGRect(origin: .zero, size: orientedSize(rawSize))`.
    public func drawingTransform(rawSize: CGSize) -> CGAffineTransform {
        let w = rawSize.width
        let h = rawSize.height
        let mirror = mirrored ? CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0) : .identity
        let rotate: CGAffineTransform = switch rotation {
        case 90: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 180: CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 270: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: .identity
        }
        return mirror.concatenating(rotate)
    }

    public var description: String { mirrored ? "mirrored+\(rotation)" : "\(rotation)" }

    static func normalize(_ degrees: Int) -> Int {
        let r = ((degrees % 360) + 360) % 360
        return (r / 90) * 90
    }
}

/// Core Graphics and ImageIO helpers shared by parsers, OCR and thumbnails.
public enum ImageUtilities {
    public static var sRGB: CGColorSpace { CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB() }

    /// An 8-bit RGB (or grey) bitmap context, filled white.
    public static func makeContext(width: Int, height: Int, gray: Bool = false) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let context: CGContext?
        if gray {
            context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )
        } else {
            context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: sRGB, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            )
        }
        guard let context else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        return context
    }

    /// Pixel size that fits `size` into `maxPixels` on the longest edge (never upscales).
    public static func fittingSize(_ size: CGSize, maxPixels: Int) -> (width: Int, height: Int) {
        let longest = max(size.width, size.height)
        guard longest > 0 else { return (1, 1) }
        let scale = min(1, CGFloat(maxPixels) / longest)
        return (max(1, Int((size.width * scale).rounded())), max(1, Int((size.height * scale).rounded())))
    }

    /// Draws `image` upright onto white, optionally scaled down so the longest edge is at most `maxPixels`.
    public static func renderUpright(
        _ image: CGImage,
        orientation: ImageOrientation,
        maxPixels: Int? = nil,
        gray: Bool = false
    ) -> CGImage? {
        let raw = CGSize(width: image.width, height: image.height)
        let oriented = orientation.orientedSize(raw)
        let (w, h) = fittingSize(oriented, maxPixels: maxPixels ?? Int(max(oriented.width, oriented.height)))
        guard let context = makeContext(width: w, height: h, gray: gray) else { return nil }
        context.scaleBy(x: CGFloat(w) / oriented.width, y: CGFloat(h) / oriented.height)
        context.concatenate(orientation.drawingTransform(rawSize: raw))
        context.draw(image, in: CGRect(origin: .zero, size: raw))
        return context.makeImage()
    }

    /// Encodes `image` with ImageIO. Returns nil on failure.
    public static func encode(_ image: CGImage, type: UTType, properties: [CFString: Any] = [:]) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }

    /// JPEG data for `image`. Transparent areas become white.
    public static func jpegData(_ image: CGImage, quality: Double = 0.8) -> Data? {
        let opaque = hasAlpha(image) ? (renderUpright(image, orientation: .up) ?? image) : image
        return encode(opaque, type: .jpeg, properties: [kCGImageDestinationLossyCompressionQuality: quality])
    }

    public static func pngData(_ image: CGImage) -> Data? {
        encode(image, type: .png)
    }

    /// Writes a JPEG file. Throws `ParserError.conversionFailed` on failure.
    public static func writeJPEG(_ image: CGImage, to url: URL, quality: Double = 0.8) throws {
        guard let data = jpegData(image, quality: quality) else {
            throw ParserError.conversionFailed("JPEG encoding failed for \(url.lastPathComponent)")
        }
        try data.write(to: url, options: .atomic)
    }

    public static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: false
        default: true
        }
    }

    /// Images that compress better without loss: bi-level and palette images.
    public static func prefersLossless(_ image: CGImage) -> Bool {
        if image.bitsPerComponent <= 2 { return true }
        return image.colorSpace?.model == .indexed
    }

    /// ImageIO properties of frame `index`.
    public static func properties(of source: CGImageSource, at index: Int) -> [CFString: Any] {
        (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
    }

    /// Pixel size from ImageIO properties.
    public static func pixelSize(properties: [CFString: Any]) -> CGSize? {
        guard let w = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let h = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              w > 0, h > 0 else { return nil }
        return CGSize(width: w, height: h)
    }

    /// Resolution from ImageIO properties (DPI, or TIFF resolution with its unit).
    /// Values of 72 or less are treated as absent: cameras and screenshots write
    /// 72 as a placeholder, which would give a phone photo a 56-inch page.
    public static func dpi(properties: [CFString: Any]) -> (x: Double, y: Double)? {
        var x = (properties[kCGImagePropertyDPIWidth] as? NSNumber)?.doubleValue
        var y = (properties[kCGImagePropertyDPIHeight] as? NSNumber)?.doubleValue
        if x == nil, let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            let unit = (tiff[kCGImagePropertyTIFFResolutionUnit] as? NSNumber)?.intValue ?? 2
            let factor = unit == 3 ? 2.54 : 1
            x = (tiff[kCGImagePropertyTIFFXResolution] as? NSNumber).map { $0.doubleValue * factor }
            y = (tiff[kCGImagePropertyTIFFYResolution] as? NSNumber).map { $0.doubleValue * factor }
        }
        guard let x, x > 72 else { return nil }
        let yy = (y ?? x) > 72 ? (y ?? x) : x
        return (x, yy)
    }

    /// A downscaled, upright (EXIF orientation applied) image straight from ImageIO.
    /// Fast for large photos because the decoder can subsample.
    public static func uprightThumbnail(source: CGImageSource, index: Int, maxPixels: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }
}
