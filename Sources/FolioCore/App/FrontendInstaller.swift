import CryptoKit
import FolioParsing
import Foundation

/// Installs the official Paperless-ngx web frontend: the `static` folder of a release.
///
/// The release is downloaded from GitHub on the user's own Mac, so FolioZero never
/// redistributes the GPL-3.0 frontend. The folder goes to `<home>/static`, the default
/// `FRONTEND_DIR`. Every step of every attempt is appended to `logFile`.
public struct FrontendInstaller: Sendable {
    /// One release archive and the SHA-256 that GitHub publishes for it.
    public struct Release: Sendable, Equatable {
        public var version: String
        public var url: URL
        public var sha256: String
        /// Bytes, for messages only.
        public var size: Int

        public init(version: String, url: URL, sha256: String, size: Int) {
            self.version = version
            self.url = url
            self.sha256 = sha256
            self.size = size
        }

        /// The release whose API FolioZero implements.
        public static let paperless342 = Release(
            version: "3.4.2",
            url: URL(string: "https://github.com/paperless-ngx/paperless-ngx/releases/download/v3.4.2/paperless-ngx-v3.4.2.tar.xz")!,
            sha256: "599be82cd8fc184436b757f9b193101fb71a90bf0facf5695dcda43152fffc85",
            size: 332_281_520
        )
    }

    /// Saves the file at `source` to the local file `destination`.
    public typealias Downloader = @Sendable (_ source: URL, _ destination: URL) async throws -> Void

    public enum InstallError: Error, Sendable, CustomStringConvertible {
        case httpStatus(Int)
        case checksumMismatch(expected: String, actual: String)
        case extractFailed(String)
        case notAFrontend

        public var description: String {
            switch self {
            case .httpStatus(let code): "The download failed with HTTP status \(code)"
            case .checksumMismatch(let expected, let actual): "The download has SHA-256 \(actual), expected \(expected)"
            case .extractFailed(let why): "Extracting the static folder failed: \(why)"
            case .notAFrontend: "The release has no static/frontend folder"
            }
        }
    }

    public let settings: Settings
    public let release: Release
    let download: Downloader

    public init(settings: Settings, release: Release = .paperless342, download: @escaping Downloader = FrontendInstaller.urlSessionDownload) {
        self.settings = settings
        self.release = release
        self.download = download
    }

    // MARK: Locations

    /// `<home>/static`: where the installer puts the frontend, and the default `FRONTEND_DIR`.
    public static func defaultDirectory(home: URL) -> URL {
        home.appendingPathComponent("static", isDirectory: true)
    }

    public var directory: URL { Self.defaultDirectory(home: settings.home) }

    /// `<logging dir>/frontend-install.log`.
    public var logFile: URL { settings.loggingDir.appendingPathComponent("frontend-install.log") }

    public var isInstalled: Bool { Self.isFrontend(directory) }

    /// True when `directory` is a release's static folder (it has `frontend/` inside).
    public static func isFrontend(_ directory: URL) -> Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory.appendingPathComponent("frontend").path, isDirectory: &isDirectory)
        return exists && isDirectory.boolValue
    }

    /// The `FRONTEND_DIR` setting, when set.
    public static func configuredDirectory(settings: Settings) -> URL? {
        guard let raw = settings.raw["FRONTEND_DIR"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
    }

    /// The folder to serve the frontend from: `FRONTEND_DIR` when set, else `<home>/static`.
    /// Nil when that folder holds no frontend.
    public static func frontendDirectory(settings: Settings) -> URL? {
        let directory = configuredDirectory(settings: settings) ?? defaultDirectory(home: settings.home)
        return isFrontend(directory) ? directory : nil
    }

    /// True when `serve` should install the frontend itself: `FRONTEND_DIR` is not set, nothing
    /// is installed yet, and `FRONTEND_AUTO_INSTALL` is not false.
    public static func shouldAutoInstall(settings: Settings) -> Bool {
        let flag = settings.raw["FRONTEND_AUTO_INSTALL"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
        guard !["false", "0", "no", "off", "n", "f"].contains(flag) else { return false }
        return configuredDirectory(settings: settings) == nil && !isFrontend(defaultDirectory(home: settings.home))
    }

    // MARK: Install

    /// Downloads the release, checks its SHA-256, extracts its `static` folder and moves it to
    /// `directory`. Without `force`, an installed frontend is kept. Each step goes to `logFile`
    /// and to `progress`. Returns the installed folder.
    @discardableResult
    public func install(force: Bool = false, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> URL {
        let started = Date()
        func step(_ message: String) {
            appendToLog(message)
            progress(message)
        }
        step("Installing the Paperless-ngx \(release.version) web frontend into \(directory.path)")
        if isInstalled && !force {
            step("Already installed; nothing to do")
            return directory
        }

        let fm = FileManager.default
        try fm.createDirectory(at: settings.home, withIntermediateDirectories: true)
        removeLeftoverWorkFolders()
        let work = settings.home.appendingPathComponent(".frontend-install-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        do {
            let archive = work.appendingPathComponent(release.url.lastPathComponent)
            let megabytes = (release.size + 500_000) / 1_000_000
            step("Downloading \(release.url.absoluteString) (\(megabytes) MB)")
            try await download(release.url, archive)

            step("Checking the SHA-256 checksum")
            let actual = try Self.sha256(of: archive)
            guard actual == release.sha256.lowercased() else {
                throw InstallError.checksumMismatch(expected: release.sha256.lowercased(), actual: actual)
            }

            step("Extracting the static folder")
            let result = try await ProcessRunner.run(
                URL(fileURLWithPath: "/usr/bin/tar"),
                arguments: ["-xJf", archive.path, "-C", work.path, "paperless-ngx/static"],
                timeout: .seconds(900))
            guard result.succeeded else {
                let why = result.timedOut ? "timed out" : result.errorString.trimmingCharacters(in: .whitespacesAndNewlines)
                throw InstallError.extractFailed(why.isEmpty ? "tar exited with status \(result.exitCode)" : why)
            }
            try? fm.removeItem(at: archive)
            let extracted = work.appendingPathComponent("paperless-ngx/static", isDirectory: true)
            guard Self.isFrontend(extracted) else { throw InstallError.notAFrontend }

            // Swap the new folder in; put the previous one back if that fails.
            let previous = work.appendingPathComponent("previous-static", isDirectory: true)
            let hadPrevious = fm.fileExists(atPath: directory.path)
            if hadPrevious { try fm.moveItem(at: directory, to: previous) }
            do {
                try fm.moveItem(at: extracted, to: directory)
            } catch {
                if hadPrevious { try? fm.moveItem(at: previous, to: directory) }
                throw error
            }
            step("Installed in \(directory.path) after \(Int(Date().timeIntervalSince(started).rounded())) s")
            return directory
        } catch {
            step("Failed: \(error)")
            throw error
        }
    }

    /// Work folders of attempts that never finished (the process stopped mid-download).
    func removeLeftoverWorkFolders() {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: settings.home.path)) ?? []
        for name in names where name.hasPrefix(".frontend-install-") {
            try? fm.removeItem(at: settings.home.appendingPathComponent(name))
        }
    }

    func appendToLog(_ message: String) {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = settings.timeZone
        let line = Data("\(formatter.string(from: Date())) \(message)\n".utf8)
        let fm = FileManager.default
        try? fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: logFile.path) { fm.createFile(atPath: logFile.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: logFile) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// Lower-case hex SHA-256 of a file, read in 1 MB chunks.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Downloads with `URLSession.shared`, following GitHub's redirect to its file storage.
    public static let urlSessionDownload: Downloader = { source, destination in
        let (temporary, response) = try await URLSession.shared.download(from: source)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temporary)
            throw InstallError.httpStatus(http.statusCode)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
