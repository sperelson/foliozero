import CoreGraphics
import Foundation
import Logging
import PDFKit

/// Converts PDFs to PDF/A-2b with Ghostscript.
public enum PDFAConverter {
    static let logger = Logger(label: "foliozero.parsing.pdfa")

    /// Converts `input` to PDF/A-2b at `output`. Returns false (and leaves no
    /// output) when Ghostscript fails, times out, produces an unreadable file, or
    /// loses more than 10 % of the extractable text.
    public static func convert(input: URL, output: URL, ghostscript: URL, timeout: Duration = .seconds(300)) async -> Bool {
        let fm = FileManager.default
        let workDir = output.deletingLastPathComponent()
            .appendingPathComponent(".pdfa-\(UUID().uuidString)", isDirectory: true)
        do {
            try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        } catch {
            return false
        }
        defer { try? fm.removeItem(at: workDir) }

        let icc = workDir.appendingPathComponent("srgb.icc")
        let definition = workDir.appendingPathComponent("pdfa_def.ps")
        guard let iccData = CGColorSpace(name: CGColorSpace.sRGB)?.copyICCData() as Data? else { return false }
        do {
            try iccData.write(to: icc)
            try pdfaDefinition(iccPath: icc.path).write(to: definition, atomically: true, encoding: .utf8)
        } catch {
            return false
        }

        let temporary = workDir.appendingPathComponent("out.pdf")
        let arguments = [
            "-q", "-dBATCH", "-dNOPAUSE", "-dSAFER",
            "--permit-file-read=\(icc.path)",
            "-sDEVICE=pdfwrite",
            "-dPDFA=2",
            "-dPDFACompatibilityPolicy=1",
            "-sColorConversionStrategy=RGB",
            "-dAutoRotatePages=/None",
            "-sOutputFile=\(temporary.path)",
            definition.path,
            input.path,
        ]
        do {
            let result = try await ProcessRunner.run(ghostscript, arguments: arguments, timeout: timeout)
            guard result.succeeded else {
                logger.warning("Ghostscript PDF/A conversion failed: \(result.timedOut ? "timeout" : result.errorString)")
                return false
            }
        } catch {
            logger.warning("Ghostscript could not run: \(error)")
            return false
        }

        guard let original = PDFDocument(url: input), let converted = PDFDocument(url: temporary),
              converted.pageCount == original.pageCount else {
            logger.warning("Ghostscript output is unreadable or has a different page count")
            return false
        }
        // Ghostscript's PDF/A output re-encodes simple TrueType fonts with a CMap that
        // PDFKit cannot read, which makes their text unextractable. Keep the plain PDF then.
        let before = TextNormalizer.nonWhitespaceCount(original.string ?? "")
        let after = TextNormalizer.nonWhitespaceCount(converted.string ?? "")
        if before > 0, Double(after) < Double(before) * 0.9 {
            logger.warning("PDF/A conversion lost text (\(before) -> \(after) characters); keeping the plain PDF")
            return false
        }
        do {
            if fm.fileExists(atPath: output.path) { try fm.removeItem(at: output) }
            try fm.moveItem(at: temporary, to: output)
            return true
        } catch {
            return false
        }
    }

    /// Converts `archive` in place when `options.pdfA` is set and Ghostscript is
    /// installed. Keeps the plain PDF when conversion fails.
    public static func applyIfRequested(to archive: URL, options: ParseOptions) async {
        guard options.pdfA else { return }
        guard let gs = ToolLocator.find("gs", explicitPath: options.ghostscriptPath) else {
            logger.info("PDF/A requested but Ghostscript is not installed; keeping plain PDF")
            return
        }
        let output = archive.deletingLastPathComponent()
            .appendingPathComponent("pdfa-\(UUID().uuidString).pdf")
        if await convert(input: archive, output: output, ghostscript: gs) {
            do {
                _ = try FileManager.default.replaceItemAt(archive, withItemAt: output)
            } catch {
                try? FileManager.default.removeItem(at: output)
            }
        }
    }

    /// pdfmark program that adds an sRGB output intent, as required by PDF/A.
    static func pdfaDefinition(iccPath: String) -> String {
        let escaped = iccPath
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
        return """
        %!
        /ICCProfile (\(escaped)) def
        [/_objdef {icc_PDFA} /type /stream /OBJ pdfmark
        [{icc_PDFA} <</N 3>> /PUT pdfmark
        [{icc_PDFA} ICCProfile (r) file /PUT pdfmark
        [/_objdef {OutputIntent_PDFA} /type /dict /OBJ pdfmark
        [{OutputIntent_PDFA} <<
          /Type /OutputIntent
          /S /GTS_PDFA1
          /DestOutputProfile {icc_PDFA}
          /OutputConditionIdentifier (sRGB)
        >> /PUT pdfmark
        [{Catalog} <</OutputIntents [ {OutputIntent_PDFA} ]>> /PUT pdfmark

        """
    }
}
