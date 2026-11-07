import CoreGraphics
import Foundation

/// Runs an `OCREngine` on one page, orders the lines and, when asked, finds
/// the upright orientation of pages that were scanned sideways or upside down.
///
/// Vision reads text in any orientation and reports its direction, so the
/// rotation comes from the first pass (majority of characters) and costs one
/// extra pass only for rotated pages. For engines without direction (Tesseract),
/// a page with little text is tried at 90, 180 and 270 degrees and the best
/// confidence-weighted result wins.
public struct PageRecognizer: Sendable {
    public var engine: any OCREngine
    public var detectRotation: Bool
    /// For engines without text direction, "little text" means fewer
    /// non-whitespace characters than this, or a mean confidence below `minimumConfidence`.
    public var rotationCharacterThreshold: Int
    public var minimumConfidence: Double

    public init(
        engine: any OCREngine,
        detectRotation: Bool = true,
        rotationCharacterThreshold: Int = 40,
        minimumConfidence: Double = 0.5
    ) {
        self.engine = engine
        self.detectRotation = detectRotation
        self.rotationCharacterThreshold = rotationCharacterThreshold
        self.minimumConfidence = minimumConfidence
    }

    public init(options: ParseOptions) {
        self.init(engine: OCREngines.make(for: options), detectRotation: options.rotatePages)
    }

    /// Recognises `image` displayed with `orientation` (for example its EXIF orientation).
    /// The result's `rotation` is the extra clockwise rotation, on top of `orientation`,
    /// that made the text upright; its boxes are normalised to that upright page.
    public func recognize(_ image: CGImage, orientation: ImageOrientation = .up) async throws -> OCRPageResult {
        let first = try await engine.recognizeLines(in: image, orientation: orientation)
        var best = (rotation: 0, lines: first, score: Self.score(first))

        if detectRotation, engine.detectsTextDirection {
            // One corrective pass, so boxes are measured on the upright page.
            if let rotation = Self.dominantTextRotation(first), rotation != 0 {
                let corrected = try await engine.recognizeLines(in: image, orientation: orientation.rotated(byClockwise: rotation))
                let score = Self.score(corrected)
                if score >= best.score * 0.8 {
                    best = (rotation, corrected, score)
                }
            }
        } else if detectRotation, needsRotationCheck(first) {
            async let r90 = try? engine.recognizeLines(in: image, orientation: orientation.rotated(byClockwise: 90))
            async let r180 = try? engine.recognizeLines(in: image, orientation: orientation.rotated(byClockwise: 180))
            async let r270 = try? engine.recognizeLines(in: image, orientation: orientation.rotated(byClockwise: 270))
            let candidates = await [(90, r90), (180, r180), (270, r270)]
            for (rotation, lines) in candidates {
                guard let lines else { continue }
                let score = Self.score(lines)
                // Switch only for a clear win, so sparse upright pages stay as they are.
                if score > max(best.score * 1.5, best.score + 10) {
                    best = (rotation, lines, score)
                }
            }
        }

        let ordered = ReadingOrder.sorted(best.lines)
        return OCRPageResult(
            lines: ordered,
            text: ReadingOrder.text(best.lines),
            rotation: best.rotation,
            engine: engine.name
        )
    }

    /// The rotation shared by most recognised characters, when at least 60 % of
    /// them agree. Nil when lines carry no direction or there is no clear majority.
    static func dominantTextRotation(_ lines: [OCRLine]) -> Int? {
        var weights: [Int: Int] = [:]
        var total = 0
        for line in lines {
            guard let rotation = line.textRotation else { continue }
            let characters = TextNormalizer.nonWhitespaceCount(line.text)
            weights[rotation, default: 0] += characters
            total += characters
        }
        guard total > 0, let top = weights.max(by: { $0.value < $1.value }),
              Double(top.value) >= Double(total) * 0.6 else { return nil }
        return top.key
    }

    func needsRotationCheck(_ lines: [OCRLine]) -> Bool {
        let characters = lines.reduce(0) { $0 + TextNormalizer.nonWhitespaceCount($1.text) }
        if characters < rotationCharacterThreshold { return true }
        let mean = lines.map(\.confidence).reduce(0, +) / Double(max(1, lines.count))
        return mean < minimumConfidence
    }

    /// Confidence-weighted count of recognised characters. Upright text gives
    /// many characters at high confidence; sideways text gives few or none.
    static func score(_ lines: [OCRLine]) -> Double {
        lines.reduce(0) { total, line in
            total + line.confidence * Double(TextNormalizer.nonWhitespaceCount(line.text))
        }
    }
}

/// Runs OCR on several pages at once with a fixed number in flight, so memory
/// stays bounded: the caller renders the next page only when a slot is free.
public enum ConcurrentOCR {
    /// Default number of pages recognised at once.
    public static var defaultConcurrency: Int {
        max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    }
}
