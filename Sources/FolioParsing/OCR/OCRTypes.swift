import CoreGraphics
import Foundation
import Logging

/// One recognised line of text.
public struct OCRLine: Sendable, Hashable, Codable {
    public var text: String
    /// Bounding box normalised to the upright page: origin at the top-left
    /// corner, y grows downward, all values in 0...1.
    public var boundingBox: CGRect
    /// Recognition confidence, 0...1.
    public var confidence: Double
    /// Clockwise rotation (0, 90, 180, 270) that would make this line read
    /// left to right. Nil when the engine does not report text direction.
    public var textRotation: Int?

    public init(text: String, boundingBox: CGRect, confidence: Double, textRotation: Int? = nil) {
        self.text = text
        self.boundingBox = boundingBox
        self.confidence = confidence
        self.textRotation = textRotation
    }
}

/// OCR output for one page.
public struct OCRPageResult: Sendable {
    /// Lines in reading order, boxes normalised to the upright page.
    public var lines: [OCRLine]
    /// Page text in reading order (see `ReadingOrder`).
    public var text: String
    /// Clockwise rotation in degrees (0, 90, 180, 270) that was applied on top of
    /// the input orientation to make the text upright. Rotate the archive page by
    /// the same amount.
    public var rotation: Int
    /// Name of the engine that produced the result.
    public var engine: String

    public init(lines: [OCRLine], text: String, rotation: Int, engine: String) {
        self.lines = lines
        self.text = text
        self.rotation = rotation
        self.engine = engine
    }

    public static func empty(engine: String) -> OCRPageResult {
        OCRPageResult(lines: [], text: "", rotation: 0, engine: engine)
    }

    public var meanConfidence: Double {
        lines.isEmpty ? 0 : lines.map(\.confidence).reduce(0, +) / Double(lines.count)
    }
}

/// A text recognition engine.
public protocol OCREngine: Sendable {
    /// "vision" or "tesseract".
    var name: String { get }

    /// True when the engine reads text in any of the four orientations and
    /// reports `OCRLine.textRotation`. Page rotation is then found from the
    /// first pass; otherwise `PageRecognizer` tries all four orientations.
    var detectsTextDirection: Bool { get }

    /// Recognises the lines of text in `image`, displayed with `orientation`.
    /// Boxes are normalised to the oriented (displayed) image, origin top-left.
    func recognizeLines(in image: CGImage, orientation: ImageOrientation) async throws -> [OCRLine]
}

extension OCREngine {
    public var detectsTextDirection: Bool { false }
}

/// Builds the engine selected in `ParseOptions`.
public enum OCREngines {
    static let logger = Logger(label: "foliozero.parsing.ocr")

    /// The configured engine. Falls back to Vision, with a warning, when
    /// Tesseract is selected but not installed.
    public static func make(for options: ParseOptions) -> any OCREngine {
        switch options.ocrEngine {
        case .vision:
            return VisionOCREngine(languages: options.languages)
        case .tesseract:
            if let engine = TesseractOCREngine(languages: options.languages, explicitPath: options.tesseractPath) {
                return engine
            }
            logger.warning("Tesseract not found; using Vision OCR instead")
            return VisionOCREngine(languages: options.languages)
        }
    }
}

/// Language code conversion between Tesseract (ISO 639-2) and BCP-47.
public enum OCRLanguages {
    /// Tesseract traineddata name to BCP-47 tag.
    public static let tesseractToBCP47: [String: String] = [
        "afr": "af", "amh": "am", "ara": "ar", "aze": "az", "bel": "be", "ben": "bn", "bos": "bs",
        "bul": "bg", "cat": "ca", "ces": "cs", "chi_sim": "zh-Hans", "chi_tra": "zh-Hant",
        "cym": "cy", "dan": "da", "deu": "de", "ell": "el", "eng": "en", "est": "et", "eus": "eu",
        "fas": "fa", "fil": "fil", "fin": "fi", "fra": "fr", "gle": "ga", "glg": "gl", "guj": "gu",
        "heb": "he", "hin": "hi", "hrv": "hr", "hun": "hu", "hye": "hy", "ind": "id", "isl": "is",
        "ita": "it", "jpn": "ja", "kan": "kn", "kat": "ka", "kaz": "kk", "khm": "km", "kor": "ko",
        "lao": "lo", "lat": "la", "lav": "lv", "lit": "lt", "ltz": "lb", "mal": "ml", "mar": "mr",
        "mkd": "mk", "mlt": "mt", "mon": "mn", "msa": "ms", "mya": "my", "nep": "ne", "nld": "nl",
        "nor": "nb", "pan": "pa", "pol": "pl", "por": "pt", "ron": "ro", "rus": "ru", "sin": "si",
        "slk": "sk", "slv": "sl", "spa": "es", "sqi": "sq", "srp": "sr", "swa": "sw", "swe": "sv",
        "tam": "ta", "tel": "te", "tgl": "tl", "tha": "th", "tur": "tr", "ukr": "uk", "urd": "ur",
        "uzb": "uz", "vie": "vi", "yid": "yi", "zul": "zu", "xho": "xh", "sot": "st", "tsn": "tn",
    ]

    /// BCP-47 language (with script where it matters) to Tesseract traineddata name.
    public static let bcp47ToTesseract: [String: String] = {
        var map: [String: String] = [:]
        for (tess, bcp) in tesseractToBCP47 { map[bcp] = tess }
        map["no"] = "nor"
        map["nn"] = "nor"
        map["zh"] = "chi_sim"
        map["zh-CN"] = "chi_sim"
        map["zh-TW"] = "chi_tra"
        map["zh-HK"] = "chi_tra"
        return map
    }()

    /// Splits "eng+deu", "en-US, de" and similar into separate codes.
    public static func split(_ languages: [String]) -> [String] {
        languages
            .flatMap { $0.split(whereSeparator: { $0 == "+" || $0 == "," || $0 == " " }) }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// BCP-47 tag for a Tesseract code or a BCP-47 tag (returned unchanged).
    public static func bcp47(for code: String) -> String {
        if let mapped = tesseractToBCP47[code.lowercased()] { return mapped }
        return code.replacingOccurrences(of: "_", with: "-")
    }

    /// Tesseract code for a BCP-47 tag or a Tesseract code (returned unchanged when known).
    public static func tesseract(for code: String) -> String? {
        let lower = code.lowercased()
        if tesseractToBCP47[lower] != nil || lower == "osd" { return lower }
        let normalized = code.replacingOccurrences(of: "_", with: "-")
        if let exact = bcp47ToTesseract[normalized] { return exact }
        let language = Locale.Language(identifier: normalized)
        if let script = language.script?.identifier,
           let languageCode = language.languageCode?.identifier,
           let match = bcp47ToTesseract["\(languageCode)-\(script)"] {
            return match
        }
        if let region = language.region?.identifier, let languageCode = language.languageCode?.identifier,
           let match = bcp47ToTesseract["\(languageCode)-\(region)"] {
            return match
        }
        if let languageCode = language.languageCode?.identifier { return bcp47ToTesseract[languageCode] }
        return nil
    }
}
