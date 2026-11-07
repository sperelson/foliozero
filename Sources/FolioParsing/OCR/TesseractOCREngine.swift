import CoreGraphics
import Foundation
import Synchronization

/// OCR with the Tesseract CLI: `tesseract <image> stdout -l eng+afr tsv`.
public struct TesseractOCREngine: OCREngine {
    public let name = "tesseract"
    public var executable: URL
    /// Requested languages as Tesseract codes or BCP-47 tags.
    public var languages: [String]
    /// Page segmentation mode (`--psm`). 3 is Tesseract's default (automatic).
    public var pageSegmentationMode: Int
    public var timeout: Duration

    public init(
        executable: URL,
        languages: [String] = ["eng"],
        pageSegmentationMode: Int = 3,
        timeout: Duration = .seconds(180)
    ) {
        self.executable = executable
        self.languages = languages
        self.pageSegmentationMode = pageSegmentationMode
        self.timeout = timeout
    }

    /// Locates `tesseract` (explicit path, PATH, Homebrew). Nil when it is not installed.
    public init?(languages: [String], explicitPath: String? = nil) {
        guard let url = ToolLocator.find("tesseract", explicitPath: explicitPath) else { return nil }
        self.init(executable: url, languages: languages)
    }

    private static let installedCache = Mutex<[String: [String]]>([:])

    /// Languages installed for `executable` (`tesseract --list-langs`), cached per path.
    public static func installedLanguages(executable: URL) async -> [String] {
        if let cached = installedCache.withLock({ $0[executable.path] }) { return cached }
        guard let result = try? await ProcessRunner.run(executable, arguments: ["--list-langs"], timeout: .seconds(30)),
              result.succeeded else { return [] }
        // Older versions print the list on stderr.
        let output = result.outputString + "\n" + result.errorString
        let languages = output
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains(" ") && !$0.contains(":") }
        installedCache.withLock { $0[executable.path] = languages }
        return languages
    }

    /// The `-l` argument: requested languages mapped to Tesseract codes and
    /// limited to installed ones. Falls back to `eng`, then to any installed language.
    public func languageArgument() async -> String {
        let installed = await Self.installedLanguages(executable: executable)
        var codes: [String] = []
        for code in OCRLanguages.split(languages) {
            guard let mapped = OCRLanguages.tesseract(for: code), mapped != "osd" else { continue }
            if (installed.isEmpty || installed.contains(mapped)) && !codes.contains(mapped) { codes.append(mapped) }
        }
        if codes.isEmpty {
            if installed.isEmpty || installed.contains("eng") {
                codes = ["eng"]
            } else if let first = installed.first(where: { $0 != "osd" && $0 != "snum" && $0 != "equ" }) {
                codes = [first]
            } else {
                codes = ["eng"]
            }
        }
        return codes.joined(separator: "+")
    }

    public func recognizeLines(in image: CGImage, orientation: ImageOrientation) async throws -> [OCRLine] {
        let upright: CGImage
        if orientation == .up {
            upright = image
        } else if let rendered = ImageUtilities.renderUpright(image, orientation: orientation, gray: true) {
            upright = rendered
        } else {
            throw ParserError.ocrFailed("Cannot rotate image for Tesseract")
        }
        guard let png = ImageUtilities.pngData(upright) else {
            throw ParserError.ocrFailed("Cannot encode image for Tesseract")
        }

        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("foliozero-tess-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let input = dir.appendingPathComponent("page.png")
        try png.write(to: input)

        let language = await languageArgument()
        let result = try await ProcessRunner.run(
            executable,
            arguments: [input.path, "stdout", "-l", language, "--psm", String(pageSegmentationMode), "--dpi", "300", "tsv"],
            // One thread per page; pages run in parallel instead.
            environment: ["OMP_THREAD_LIMIT": "1"],
            timeout: timeout
        )
        guard result.succeeded else {
            let reason = result.timedOut ? "timed out" : "exit \(result.exitCode): \(result.errorString.prefix(500))"
            throw ParserError.ocrFailed("Tesseract \(reason)")
        }
        return Self.parseTSV(result.outputString, imageSize: CGSize(width: upright.width, height: upright.height))
    }

    /// Builds lines from Tesseract TSV output: words (level 5) grouped by
    /// block, paragraph and line; box is the union of word boxes; confidence is
    /// the mean word confidence scaled to 0...1.
    public static func parseTSV(_ tsv: String, imageSize: CGSize) -> [OCRLine] {
        struct Accumulator {
            var words: [String] = []
            var box: CGRect = .null
            var confidence: Double = 0
        }
        guard imageSize.width > 0, imageSize.height > 0 else { return [] }
        var order: [String] = []
        var lines: [String: Accumulator] = [:]

        for row in tsv.split(whereSeparator: \.isNewline) {
            let fields = row.split(separator: "\t", omittingEmptySubsequences: false)
            guard fields.count >= 12, fields[0] == "5" else { continue }
            let text = fields[11...].joined(separator: "\t").trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty,
                  let left = Double(fields[6]), let top = Double(fields[7]),
                  let width = Double(fields[8]), let height = Double(fields[9]),
                  let confidence = Double(fields[10]), confidence >= 0 else { continue }
            let key = "\(fields[1]).\(fields[2]).\(fields[3]).\(fields[4])"
            if lines[key] == nil { order.append(key) }
            var line = lines[key] ?? Accumulator()
            line.words.append(text)
            line.box = line.box.union(CGRect(x: left, y: top, width: width, height: height))
            line.confidence += confidence
            lines[key] = line
        }

        return order.compactMap { key in
            guard let line = lines[key], !line.box.isNull else { return nil }
            let box = CGRect(
                x: line.box.minX / imageSize.width,
                y: line.box.minY / imageSize.height,
                width: line.box.width / imageSize.width,
                height: line.box.height / imageSize.height
            )
            return OCRLine(
                text: line.words.joined(separator: " "),
                boundingBox: box,
                confidence: line.confidence / Double(line.words.count) / 100
            )
        }
    }
}
