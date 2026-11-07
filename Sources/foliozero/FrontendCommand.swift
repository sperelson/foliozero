import ArgumentParser
import FolioCore
import Foundation

/// The Paperless-ngx web frontend, downloaded from GitHub (FolioZero never ships it).
struct FrontendCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "frontend",
        abstract: "Install the Paperless-ngx web frontend.",
        discussion: """
        `serve` installs the frontend by itself when it is missing. Set FRONTEND_AUTO_INSTALL=false
        to stop that, or FRONTEND_DIR to serve a static folder of your own.
        """,
        subcommands: [Install.self]
    )

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Download the Paperless-ngx \(FrontendInstaller.Release.paperless342.version) release from GitHub and install its static folder in <home>/static."
        )
        @OptionGroup var global: GlobalOptions

        @Flag(help: "Download and install again, replacing the installed copy.")
        var force = false

        func run() async throws {
            let settings = try global.loadSettings()
            try settings.createDirectories()
            let installer = FrontendInstaller(settings: settings)
            if let configured = FrontendInstaller.configuredDirectory(settings: settings) {
                print("Please note: FRONTEND_DIR is set to \(configured.path), so `serve` uses that folder, not this install.")
            }
            if installer.isInstalled && !force {
                print("The web frontend is already installed in \(installer.directory.path). Pass --force to download it again.")
                return
            }
            do {
                try await installer.install(force: force) { print($0) }
            } catch {
                print("The log is in \(installer.logFile.path)")
                throw error
            }
        }
    }
}
