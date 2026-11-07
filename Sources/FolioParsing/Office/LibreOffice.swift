import Foundation

/// LibreOffice `soffice --headless --convert-to pdf`.
public enum LibreOffice {
    public enum ConversionError: Error, Sendable, CustomStringConvertible {
        case failed(String)
        case noOutput

        public var description: String {
            switch self {
            case .failed(let why): "LibreOffice conversion failed: \(why)"
            case .noOutput: "LibreOffice produced no PDF"
            }
        }
    }

    /// Arguments for a headless conversion. A private profile directory lets
    /// several conversions run at once and keeps the user's profile untouched.
    public static func conversionArguments(
        input: URL,
        outputDirectory: URL,
        profileDirectory: URL,
        format: String = "pdf"
    ) -> [String] {
        [
            "--headless",
            "--invisible",
            "--nologo",
            "--nodefault",
            "--nolockcheck",
            "--norestore",
            "--nofirststartwizard",
            "-env:UserInstallation=\(profileDirectory.absoluteURL.absoluteString)",
            "--convert-to", format,
            "--outdir", outputDirectory.path,
            input.path,
        ]
    }

    /// The file LibreOffice writes for `input`: same base name, new extension, in `outputDirectory`.
    public static func expectedOutput(for input: URL, outputDirectory: URL, extension ext: String = "pdf") -> URL {
        outputDirectory.appendingPathComponent(input.deletingPathExtension().lastPathComponent + "." + ext)
    }

    /// Converts `input` to PDF in `workDirectory` and returns the PDF.
    public static func convertToPDF(
        _ input: URL,
        soffice: URL,
        workDirectory: URL,
        timeout: Duration = .seconds(180)
    ) async throws -> URL {
        let fm = FileManager.default
        let outDir = workDirectory.appendingPathComponent("lo-out-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let profile = workDirectory.appendingPathComponent("lo-profile-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: outDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: profile) }

        let result = try await ProcessRunner.run(
            soffice,
            arguments: conversionArguments(input: input, outputDirectory: outDir, profileDirectory: profile),
            environment: ["HOME": workDirectory.path],
            timeout: timeout
        )
        guard result.succeeded else {
            throw ConversionError.failed(result.timedOut ? "timed out" : "exit \(result.exitCode): \(result.errorString.prefix(500))")
        }
        let output = expectedOutput(for: input, outputDirectory: outDir)
        guard fm.fileExists(atPath: output.path) else { throw ConversionError.noOutput }
        return output
    }
}
