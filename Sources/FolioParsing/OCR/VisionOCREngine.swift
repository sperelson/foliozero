import CoreGraphics
import Foundation
import Vision

/// OCR with Apple Vision (`RecognizeTextRequest`, accurate level, language correction on).
public struct VisionOCREngine: OCREngine {
    public let name = "vision"
    /// Vision reads sideways and upside-down text; its corner points follow the text.
    public var detectsTextDirection: Bool { true }
    /// Requested languages as BCP-47 tags or Tesseract codes.
    public var languages: [String]
    public var usesLanguageCorrection: Bool

    public init(languages: [String] = ["en-US"], usesLanguageCorrection: Bool = true) {
        self.languages = languages
        self.usesLanguageCorrection = usesLanguageCorrection
    }

    /// Languages Vision can recognise at the accurate level on this system.
    public static let supportedLanguages: [Locale.Language] = {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        return request.supportedRecognitionLanguages
    }()

    /// Maps requested languages (Tesseract codes or BCP-47 tags) to languages
    /// Vision supports. Empty when none is supported; the engine then lets
    /// Vision detect the language.
    public static func resolveLanguages(_ requested: [String]) -> [Locale.Language] {
        var result: [Locale.Language] = []
        for code in OCRLanguages.split(requested) {
            let wanted = Locale.Language(identifier: OCRLanguages.bcp47(for: code))
            guard let languageCode = wanted.languageCode else { continue }
            let sameLanguage = supportedLanguages.filter { $0.languageCode == languageCode }
            var candidates = sameLanguage
            if let script = wanted.script {
                let sameScript = sameLanguage.filter { $0.script == script }
                if !sameScript.isEmpty { candidates = sameScript }
            }
            if let region = wanted.region, let exact = candidates.first(where: { $0.region == region }) {
                candidates = [exact]
            }
            if let match = candidates.first, !result.contains(match) {
                result.append(match)
            }
        }
        return result
    }

    public func recognizeLines(in image: CGImage, orientation: ImageOrientation) async throws -> [OCRLine] {
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = usesLanguageCorrection
        let resolved = Self.resolveLanguages(languages)
        if resolved.isEmpty {
            request.automaticallyDetectsLanguage = true
        } else {
            request.recognitionLanguages = resolved
            request.automaticallyDetectsLanguage = false
        }

        let observations: [RecognizedTextObservation]
        do {
            observations = try await request.perform(on: image, orientation: orientation.exifOrientation)
        } catch {
            throw ParserError.ocrFailed("Vision: \(error)")
        }

        let size = orientation.orientedSize(CGSize(width: image.width, height: image.height))
        return observations.compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            // Vision boxes are normalised with the origin at the lower-left.
            let box = observation.boundingBox.cgRect
            let topLeft = CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !topLeft.isNull, topLeft.width > 0, topLeft.height > 0 else { return nil }
            return OCRLine(
                text: text,
                boundingBox: topLeft,
                confidence: Double(candidate.confidence),
                textRotation: Self.textRotation(from: observation.topLeft, to: observation.topRight, imageSize: size)
            )
        }
    }

    /// Clockwise rotation that makes a line read left to right, from the
    /// direction of its top edge (corner points in Vision's lower-left-origin space).
    static func textRotation(from start: NormalizedPoint, to end: NormalizedPoint, imageSize: CGSize) -> Int {
        let dx = (end.x - start.x) * imageSize.width
        let dy = (end.y - start.y) * imageSize.height
        if abs(dx) >= abs(dy) { return dx >= 0 ? 0 : 180 }
        // Text running downward was turned 90 degrees clockwise; turn it 270 more.
        return dy < 0 ? 270 : 90
    }
}
