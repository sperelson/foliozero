import CoreGraphics
import Foundation
import Testing
import Vision
@testable import FolioParsing

func containsSampleWords(_ text: String) -> Bool {
    let lower = text.lowercased()
    return lower.contains("invoice") && lower.contains("4711") && lower.contains("payment") && lower.contains("1234")
}

@Suite("OCR engines")
struct OCRTests {
    @Test func visionRecognisesWordsWithBoxes() async throws {
        let engine = VisionOCREngine(languages: ["eng"])
        let lines = try await engine.recognizeLines(in: FixtureFactory.textImage(), orientation: .up)
        let text = ReadingOrder.text(lines)
        #expect(containsSampleWords(text), "got: \(text)")
        let invoice = try #require(lines.first { $0.text.contains("INVOICE") })
        // First line is drawn near the top-left of the image.
        #expect(invoice.boundingBox.minY < 0.15)
        #expect(invoice.boundingBox.minX < 0.15)
        #expect(invoice.confidence > 0.3)
        #expect(ReadingOrder.sorted(lines).first?.text.contains("INVOICE") == true)
    }

    @Test func visionBoxesFollowOrientation() async throws {
        // Pixels rotated 90 degrees clockwise; EXIF-style orientation "left" turns them back.
        let stored = FixtureFactory.rotate(FixtureFactory.textImage(), clockwise: 90)
        let engine = VisionOCREngine(languages: ["en-US"])
        let lines = try await engine.recognizeLines(in: stored, orientation: ImageOrientation(rotation: 270))
        #expect(containsSampleWords(ReadingOrder.text(lines)))
        let invoice = try #require(lines.first { $0.text.contains("INVOICE") })
        #expect(invoice.boundingBox.minY < 0.15, "box \(invoice.boundingBox) should be in upright coordinates")
    }

    @Test(arguments: [90, 180, 270])
    func rotationDetection(degrees: Int) async throws {
        let image = FixtureFactory.rotate(FixtureFactory.textImage(), clockwise: degrees)
        let recognizer = PageRecognizer(engine: VisionOCREngine(), detectRotation: true)
        let result = try await recognizer.recognize(image)
        #expect(result.rotation == (360 - degrees) % 360, "text: \(result.text)")
        #expect(containsSampleWords(result.text), "got: \(result.text)")
        let invoice = try #require(result.lines.first { $0.text.contains("INVOICE") })
        #expect(invoice.boundingBox.minY < 0.15)
    }

    @Test func uprightPageIsNotRotated() async throws {
        let recognizer = PageRecognizer(engine: VisionOCREngine(), detectRotation: true)
        let result = try await recognizer.recognize(FixtureFactory.textImage())
        #expect(result.rotation == 0)
        #expect(result.engine == "vision")
    }

    @Test func textDirectionFromCorners() {
        let size = CGSize(width: 1000, height: 1000)
        func rotation(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat) -> Int {
            VisionOCREngine.textRotation(
                from: NormalizedPoint(x: x0, y: y0), to: NormalizedPoint(x: x1, y: y1), imageSize: size
            )
        }
        #expect(rotation(0.1, 0.9, 0.6, 0.9) == 0)
        #expect(rotation(0.9, 0.9, 0.9, 0.4) == 270)
        #expect(rotation(0.9, 0.1, 0.4, 0.1) == 180)
        #expect(rotation(0.1, 0.1, 0.1, 0.6) == 90)

        func line(_ text: String, _ rotation: Int?) -> OCRLine {
            OCRLine(text: text, boundingBox: CGRect(x: 0, y: 0, width: 0.1, height: 0.1), confidence: 1, textRotation: rotation)
        }
        #expect(PageRecognizer.dominantTextRotation([line("long sideways text", 270), line("ab", 0)]) == 270)
        #expect(PageRecognizer.dominantTextRotation([line("abcd", 90), line("abcd", 0)]) == nil)
        #expect(PageRecognizer.dominantTextRotation([line("abcd", nil)]) == nil)
    }

    @Test func visionLanguageResolution() {
        let english = VisionOCREngine.resolveLanguages(["eng"])
        #expect(english.first?.languageCode?.identifier == "en")
        let german = VisionOCREngine.resolveLanguages(["deu+eng"])
        #expect(german.map { $0.languageCode?.identifier } == ["de", "en"])
        // Klingon is not supported anywhere: automatic detection.
        #expect(VisionOCREngine.resolveLanguages(["tlh"]).isEmpty)
        let chinese = VisionOCREngine.resolveLanguages(["chi_tra"])
        #expect(chinese.first?.script?.identifier == "Hant")
    }

    @Test func languageCodeMapping() {
        #expect(OCRLanguages.bcp47(for: "afr") == "af")
        #expect(OCRLanguages.bcp47(for: "chi_sim") == "zh-Hans")
        #expect(OCRLanguages.bcp47(for: "en-US") == "en-US")
        #expect(OCRLanguages.tesseract(for: "en-US") == "eng")
        #expect(OCRLanguages.tesseract(for: "de-DE") == "deu")
        #expect(OCRLanguages.tesseract(for: "af") == "afr")
        #expect(OCRLanguages.tesseract(for: "zh-Hant") == "chi_tra")
        #expect(OCRLanguages.tesseract(for: "eng") == "eng")
        #expect(OCRLanguages.split(["eng+afr", "de-DE"]) == ["eng", "afr", "de-DE"])
    }

    @Test(.enabled(if: ToolLocator.find("tesseract") != nil, "tesseract is not installed"))
    func tesseractRecognisesWords() async throws {
        let engine = try #require(TesseractOCREngine(languages: ["en-US", "afr"]))
        // "afr" is dropped when it is not installed.
        let argument = await engine.languageArgument()
        #expect(argument.hasPrefix("eng"))
        let lines = try await engine.recognizeLines(in: FixtureFactory.textImage(), orientation: .up)
        let text = ReadingOrder.text(lines)
        #expect(containsSampleWords(text), "got: \(text)")
        let invoice = try #require(lines.first { $0.text.contains("INVOICE") })
        #expect(invoice.boundingBox.minY < 0.15)
        #expect(invoice.confidence > 0.5)
    }

    @Test(.enabled(if: ToolLocator.find("tesseract") != nil, "tesseract is not installed"))
    func tesseractThroughPDFParser() async throws {
        let dir = try FixtureFactory.makeDirectory()
        let pdf = dir.appendingPathComponent("scan.pdf")
        try FixtureFactory.scannedPDF(images: [FixtureFactory.textImage()], to: pdf)
        let result = try await PDFParser().parse(
            file: pdf, mimeType: "application/pdf",
            options: FixtureFactory.options(dir, engine: .tesseract, languages: ["eng"])
        )
        #expect(containsSampleWords(result.text), "got: \(result.text)")
        #expect(result.archiveFile != nil)
    }

    @Test func tesseractTSVParsing() {
        let tsv = """
        level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext
        1\t1\t0\t0\t0\t0\t0\t0\t1000\t500\t-1\t
        4\t1\t1\t1\t1\t0\t100\t50\t300\t40\t-1\t
        5\t1\t1\t1\t1\t1\t100\t50\t120\t40\t96.5\tHello
        5\t1\t1\t1\t1\t2\t250\t55\t150\t35\t90.5\tworld
        5\t1\t1\t1\t2\t1\t100\t150\t80\t40\t80\tSecond
        5\t1\t1\t1\t2\t2\t200\t150\t80\t40\t-1\t
        """
        let lines = TesseractOCREngine.parseTSV(tsv, imageSize: CGSize(width: 1000, height: 500))
        #expect(lines.count == 2)
        #expect(lines[0].text == "Hello world")
        #expect(abs(lines[0].boundingBox.minX - 0.1) < 0.0001)
        #expect(abs(lines[0].boundingBox.width - 0.3) < 0.0001)
        #expect(abs(lines[0].boundingBox.minY - 0.1) < 0.0001)
        #expect(abs(lines[0].confidence - 0.935) < 0.0001)
        #expect(lines[1].text == "Second")
    }

    @Test func readingOrderGroupsRowsAndParagraphs() {
        func line(_ text: String, _ x: CGFloat, _ y: CGFloat, w: CGFloat = 0.2, h: CGFloat = 0.03) -> OCRLine {
            OCRLine(text: text, boundingBox: CGRect(x: x, y: y, width: w, height: h), confidence: 1)
        }
        let lines = [
            line("Amount", 0.6, 0.101),
            line("Invoice", 0.1, 0.1),
            line("Second", 0.1, 0.14),
            line("Paragraph", 0.1, 0.3),
            line("Right", 0.6, 0.142, h: 0.025),
        ]
        #expect(ReadingOrder.text(lines) == "Invoice Amount\nSecond Right\n\nParagraph")
        #expect(ReadingOrder.text([]) == "")
    }
}
