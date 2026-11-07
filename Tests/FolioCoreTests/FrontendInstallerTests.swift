import Foundation
import Synchronization
import Testing
@testable import FolioCore

@Suite struct FrontendInstallerTests {
    /// Copies a local archive instead of downloading, and counts the calls.
    final class FakeDownloader: Sendable {
        let calls = Mutex(0)
        var count: Int { calls.withLock { $0 } }

        var download: FrontendInstaller.Downloader {
            { [self] source, destination in
                calls.withLock { $0 += 1 }
                try FileManager.default.copyItem(at: source, to: destination)
            }
        }
    }

    /// An archive shaped like a Paperless-ngx release: `paperless-ngx/static/frontend/...`
    /// next to the Python code, which the installer must leave out.
    func makeRelease(in dir: TempDir) throws -> FrontendInstaller.Release {
        let tree = dir.url.appendingPathComponent("tree", isDirectory: true)
        for (path, text) in [("paperless-ngx/static/frontend/en-US/index.html", "<html></html>"), ("paperless-ngx/src/manage.py", "print()")] {
            let file = tree.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }
        let archive = dir.file("paperless-ngx-v9.9.9.tar.xz")
        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-cJf", archive.path, "-C", tree.path, "paperless-ngx"]
        try tar.run()
        tar.waitUntilExit()
        #expect(tar.terminationStatus == 0)
        return .init(version: "9.9.9", url: archive, sha256: try FrontendInstaller.sha256(of: archive), size: 1_000)
    }

    func settings(_ home: TempDir, _ overrides: [String: String] = [:]) throws -> Settings {
        try SettingsLoader.load(home: home.url.path, environment: [:], overrides: overrides)
    }

    func log(_ installer: FrontendInstaller) -> String {
        (try? String(contentsOf: installer.logFile, encoding: .utf8)) ?? ""
    }

    func workFolders(_ home: TempDir) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: home.url.path)) ?? []).filter { $0.hasPrefix(".frontend-install-") }
    }

    @Test func installsOnlyTheStaticFolderAndLogsEachStep() async throws {
        let source = TempDir(), home = TempDir()
        let fake = FakeDownloader()
        let installer = FrontendInstaller(settings: try settings(home), release: try makeRelease(in: source), download: fake.download)
        #expect(!installer.isInstalled)

        let directory = try await installer.install()
        #expect(directory == home.url.appendingPathComponent("static", isDirectory: true))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("frontend/en-US/index.html").path))
        #expect(!FileManager.default.fileExists(atPath: home.url.appendingPathComponent("paperless-ngx").path))
        #expect(installer.isInstalled)
        #expect(workFolders(home).isEmpty)

        let log = log(installer)
        #expect(installer.logFile.path.hasPrefix(home.url.path))
        for step in ["Installing the Paperless-ngx 9.9.9 web frontend", "Downloading", "Checking the SHA-256 checksum", "Extracting the static folder", "Installed in"] {
            #expect(log.contains(step))
        }
    }

    @Test func wrongChecksumInstallsNothingAndLogsTheFailure() async throws {
        let source = TempDir(), home = TempDir()
        var release = try makeRelease(in: source)
        release.sha256 = String(repeating: "0", count: 64)
        let installer = FrontendInstaller(settings: try settings(home), release: release, download: FakeDownloader().download)

        await #expect(throws: FrontendInstaller.InstallError.self) { try await installer.install() }
        #expect(!installer.isInstalled)
        #expect(workFolders(home).isEmpty)
        #expect(log(installer).contains("Failed: The download has SHA-256"))
    }

    @Test func keepsAnInstalledCopyUnlessForced() async throws {
        let source = TempDir(), home = TempDir()
        let fake = FakeDownloader()
        let installer = FrontendInstaller(settings: try settings(home), release: try makeRelease(in: source), download: fake.download)
        try await installer.install()
        let marker = installer.directory.appendingPathComponent("old.txt")
        try Data().write(to: marker)

        try await installer.install()
        #expect(fake.count == 1)
        #expect(log(installer).contains("Already installed"))

        try await installer.install(force: true)
        #expect(fake.count == 2)
        #expect(installer.isInstalled)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func removesWorkFoldersOfInterruptedAttempts() async throws {
        let source = TempDir(), home = TempDir()
        let leftover = home.url.appendingPathComponent(".frontend-install-old/partial.tar.xz")
        try FileManager.default.createDirectory(at: leftover.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("partial".utf8).write(to: leftover)
        let installer = FrontendInstaller(settings: try settings(home), release: try makeRelease(in: source), download: FakeDownloader().download)
        try await installer.install()
        #expect(workFolders(home).isEmpty)
    }

    @Test func frontendDirectoryAndAutoInstallFollowTheSettings() throws {
        let home = TempDir(), custom = TempDir()
        let installed = home.url.appendingPathComponent("static", isDirectory: true)

        let plain = try settings(home)
        #expect(FrontendInstaller.frontendDirectory(settings: plain) == nil)
        #expect(FrontendInstaller.shouldAutoInstall(settings: plain))
        #expect(!FrontendInstaller.shouldAutoInstall(settings: try settings(home, ["FRONTEND_AUTO_INSTALL": "false"])))

        // FRONTEND_DIR set: never download, even when that folder is empty.
        let configured = try settings(home, ["FRONTEND_DIR": custom.url.path])
        #expect(!FrontendInstaller.shouldAutoInstall(settings: configured))
        #expect(FrontendInstaller.frontendDirectory(settings: configured) == nil)
        try FileManager.default.createDirectory(at: custom.url.appendingPathComponent("frontend"), withIntermediateDirectories: true)
        #expect(FrontendInstaller.frontendDirectory(settings: configured)?.path == custom.url.standardizedFileURL.path)

        // Installed: the default folder is served, and there is nothing to download.
        try FileManager.default.createDirectory(at: installed.appendingPathComponent("frontend"), withIntermediateDirectories: true)
        #expect(FrontendInstaller.frontendDirectory(settings: plain) == installed)
        #expect(!FrontendInstaller.shouldAutoInstall(settings: plain))
    }

    @Test func pinsTheReleaseThatTheAPIReports() {
        let release = FrontendInstaller.Release.paperless342
        #expect(release.version == PaperlessCatalog.version)
        #expect(release.url.absoluteString == "https://github.com/paperless-ngx/paperless-ngx/releases/download/v3.4.2/paperless-ngx-v3.4.2.tar.xz")
        #expect(release.sha256.count == 64)
    }
}
