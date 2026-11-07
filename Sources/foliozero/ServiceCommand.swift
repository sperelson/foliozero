import ArgumentParser
import FolioCore
import Foundation

/// launchd integration: run `foliozero serve` as a LaunchAgent (default) or LaunchDaemon.
struct ServiceCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "service",
        abstract: "Install and control FolioZero as a launchd service.",
        discussion: """
        A LaunchAgent (default) runs while you are logged in; on a headless Mac, turn on automatic login
        for this user. Vision, WebKit and QuickLook work best there.
        A LaunchDaemon (--system, needs sudo) starts at boot without a login and runs as --user.
        """,
        subcommands: [Install.self, Uninstall.self, Start.self, Stop.self, Restart.self, Status.self, Logs.self]
    )

    static let label = "com.foliozero.server"

    struct Target: ParsableArguments {
        @Flag(help: "Use the system LaunchDaemon instead of the per-user LaunchAgent.")
        var system = false

        var plistURL: URL {
            system
                ? URL(fileURLWithPath: "/Library/LaunchDaemons/\(ServiceCommand.label).plist")
                : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(ServiceCommand.label).plist")
        }

        var domain: String { system ? "system" : "gui/\(getuid())" }
        var serviceTarget: String { "\(domain)/\(ServiceCommand.label)" }

        func requireRootIfSystem() throws {
            if system && getuid() != 0 {
                throw ValidationError("--system needs root. Run the same command with sudo.")
            }
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write the launchd plist and start the service.")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var target: Target

        @Option(help: "Account the LaunchDaemon runs as (--system only). Default: the user who ran sudo.")
        var user: String?

        @Option(help: "Path of the foliozero binary to run. Default: this binary.")
        var binary: String?

        func run() async throws {
            try target.requireRootIfSystem()
            let settings = try global.loadSettings()
            let executable = try resolveBinary()
            if executable.contains("/.build/") {
                print("Warning: \(executable) is inside a build folder. Copy a release build somewhere stable first, e.g.\n  swift build -c release && sudo cp .build/release/foliozero /usr/local/bin/\nthen pass --binary /usr/local/bin/foliozero.")
            }

            var arguments = [executable, "serve", "--home", settings.home.path]
            if let config = global.config { arguments += ["--config", (config as NSString).expandingTildeInPath] }

            var plist: [String: Any] = [
                "Label": ServiceCommand.label,
                "ProgramArguments": arguments,
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false],
                "ThrottleInterval": 10,
                "ProcessType": "Standard",
                "WorkingDirectory": settings.home.path,
                "StandardOutPath": settings.loggingDir.appendingPathComponent("launchd.out.log").path,
                "StandardErrorPath": settings.loggingDir.appendingPathComponent("launchd.err.log").path,
                "EnvironmentVariables": [
                    "FOLIOZERO_HOME": settings.home.path,
                    "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
                    "LANG": "en_US.UTF-8",
                ],
                // Give running tasks time to finish on stop.
                "ExitTimeOut": 40,
            ]
            if target.system {
                let account = user ?? ProcessInfo.processInfo.environment["SUDO_USER"]
                guard let account, account != "root" else {
                    throw ValidationError("Pass --user <account> for the LaunchDaemon; FolioZero should not run as root.")
                }
                plist["UserName"] = account
                plist["GroupName"] = "staff"
                plist["SessionCreate"] = true
            }

            try settings.createDirectories()
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try FileManager.default.createDirectory(at: target.plistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: target.plistURL, options: .atomic)
            if target.system {
                // launchd requires root:wheel 0644 for daemons.
                try FileManager.default.setAttributes([.posixPermissions: 0o644, .ownerAccountID: 0, .groupOwnerAccountID: 0], ofItemAtPath: target.plistURL.path)
                if let account = plist["UserName"] as? String {
                    _ = try? Launchctl.run("/usr/sbin/chown", ["-R", account, settings.home.path])
                }
            }
            print("Wrote \(target.plistURL.path)")

            _ = try? Launchctl.run("/bin/launchctl", ["bootout", target.serviceTarget])
            let result = try Launchctl.run("/bin/launchctl", ["bootstrap", target.domain, target.plistURL.path])
            guard result.status == 0 else {
                throw ValidationError("launchctl bootstrap failed (\(result.status)): \(result.output)")
            }
            print("Started \(ServiceCommand.label) in \(target.domain). Logs: foliozero service logs\(target.system ? " --system" : "")")
        }

        func resolveBinary() throws -> String {
            if let binary {
                let path = (binary as NSString).expandingTildeInPath
                guard FileManager.default.isExecutableFile(atPath: path) else { throw ValidationError("Not executable: \(path)") }
                return URL(fileURLWithPath: path).standardizedFileURL.path
            }
            guard let path = Bundle.main.executableURL?.resolvingSymlinksInPath().path else {
                throw ValidationError("Cannot find this binary's path; pass --binary.")
            }
            return path
        }
    }

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the service and remove its plist. Data stays.")
        @OptionGroup var target: Target

        func run() async throws {
            try target.requireRootIfSystem()
            _ = try? Launchctl.run("/bin/launchctl", ["bootout", target.serviceTarget])
            if FileManager.default.fileExists(atPath: target.plistURL.path) {
                try FileManager.default.removeItem(at: target.plistURL)
            }
            print("Removed \(ServiceCommand.label). Your documents and settings were not touched.")
        }
    }

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start (load) the service.")
        @OptionGroup var target: Target

        func run() async throws {
            try target.requireRootIfSystem()
            guard FileManager.default.fileExists(atPath: target.plistURL.path) else {
                throw ValidationError("Not installed. Run: foliozero service install\(target.system ? " --system" : "")")
            }
            let result = try Launchctl.run("/bin/launchctl", ["bootstrap", target.domain, target.plistURL.path])
            if result.status != 0 {
                // Already loaded: make sure it runs.
                _ = try Launchctl.run("/bin/launchctl", ["kickstart", target.serviceTarget])
            }
            print("Started.")
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop (unload) the service until the next start or reboot.")
        @OptionGroup var target: Target

        func run() async throws {
            try target.requireRootIfSystem()
            let result = try Launchctl.run("/bin/launchctl", ["bootout", target.serviceTarget])
            print(result.status == 0 ? "Stopped." : "Not running.")
        }
    }

    struct Restart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Restart the running service.")
        @OptionGroup var target: Target

        func run() async throws {
            try target.requireRootIfSystem()
            let result = try Launchctl.run("/bin/launchctl", ["kickstart", "-k", target.serviceTarget])
            guard result.status == 0 else { throw ValidationError("Restart failed: \(result.output)") }
            print("Restarted.")
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show whether the service is loaded and running.")
        @OptionGroup var target: Target

        func run() async throws {
            print("Plist:  \(target.plistURL.path) \(FileManager.default.fileExists(atPath: target.plistURL.path) ? "" : "(not installed)")")
            let result = try Launchctl.run("/bin/launchctl", ["print", target.serviceTarget])
            guard result.status == 0 else {
                print("State:  not loaded")
                throw ExitCode(3)
            }
            let lines = result.output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            for key in ["state", "pid", "last exit code", "runs"] {
                if let line = lines.first(where: { $0.hasPrefix("\(key) =") }) {
                    print("\(key.capitalized.padding(toLength: 7, withPad: " ", startingAt: 0)) \(line.dropFirst(key.count + 3))")
                }
            }
        }
    }

    struct Logs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show the server log.")
        @OptionGroup var global: GlobalOptions
        @Flag(name: .shortAndLong, help: "Keep printing new lines.") var follow = false
        @Option(name: .shortAndLong, help: "Number of lines.") var lines = 100

        func run() async throws {
            let settings = try global.loadSettings()
            let log = settings.loggingDir.appendingPathComponent("foliozero.log")
            guard FileManager.default.fileExists(atPath: log.path) else { throw ValidationError("No log yet at \(log.path)") }
            let tail = Process()
            tail.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
            tail.arguments = (follow ? ["-F"] : []) + ["-n", String(lines), log.path]
            try tail.run()
            tail.waitUntilExit()
        }
    }
}

enum Launchctl {
    struct Result {
        var status: Int32
        var output: String
    }

    static func run(_ tool: String, _ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
