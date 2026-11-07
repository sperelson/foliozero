import Foundation

/// Finds external command-line tools.
///
/// Search order: the explicit path, `PATH`, `standardDirectories`, then known
/// executables inside app bundles (`knownBundleExecutables`).
public enum ToolLocator {
    /// Directories searched after `PATH`. A launchd job often has a minimal `PATH`,
    /// so Homebrew locations are listed explicitly.
    public static let standardDirectories: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/opt/local/bin",
        "/usr/bin",
        "/bin",
    ]

    /// Executables that live inside app bundles, by tool name.
    public static let knownBundleExecutables: [String: [String]] = [
        "soffice": [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "~/Applications/LibreOffice.app/Contents/MacOS/soffice",
        ],
        "libreoffice": [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "~/Applications/LibreOffice.app/Contents/MacOS/soffice",
        ],
    ]

    /// Returns the URL of an executable tool, or nil when it is not installed.
    ///
    /// - Parameters:
    ///   - name: Tool name, for example "tesseract", "gs" or "soffice".
    ///   - explicitPath: A configured path. When it contains a slash it must point to
    ///     an executable file; otherwise it is treated as another name to search for.
    ///   - additionalPaths: Extra candidate executables, checked after the bundle paths.
    public static func find(_ name: String, explicitPath: String? = nil, additionalPaths: [String] = []) -> URL? {
        let fm = FileManager.default
        func executable(_ path: String) -> URL? {
            let expanded = (path as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: expanded, isDirectory: &isDir), !isDir.boolValue,
                  fm.isExecutableFile(atPath: expanded) else { return nil }
            return URL(fileURLWithPath: expanded)
        }

        var names = [name]
        if let explicitPath, !explicitPath.isEmpty {
            if explicitPath.contains("/") {
                if let url = executable(explicitPath) { return url }
                // A configured but wrong path still falls back to the search below.
            } else {
                names.insert(explicitPath, at: 0)
            }
        }

        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        var seen = Set<String>()
        let dirs = (pathDirs + standardDirectories).filter { seen.insert($0).inserted }

        for candidate in names {
            for dir in dirs {
                if let url = executable((dir as NSString).appendingPathComponent(candidate)) { return url }
            }
        }
        for candidate in names {
            for path in knownBundleExecutables[candidate] ?? [] {
                if let url = executable(path) { return url }
            }
        }
        for path in additionalPaths {
            if let url = executable(path) { return url }
        }
        return nil
    }
}
