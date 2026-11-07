import ArgumentParser
import FolioCore
import FolioParsing
import Foundation
import GRDB

struct UserCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "user",
        abstract: "Manage users.",
        subcommands: [Create.self, Password.self, Token.self, List.self]
    )

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Create a user. Prompts for the password unless --password is given.")
        @OptionGroup var global: GlobalOptions
        @Argument var username: String
        @Option var email = ""
        @Option(help: "Password. Prefer the interactive prompt; command lines are visible to other processes.")
        var password: String?
        @Flag(help: "Grant all permissions.") var superuser = false

        func run() async throws {
            let app = try global.openApp()
            let secret = try password ?? Prompt.newPassword()
            let user = try await app.database.write { [username, email, superuser] db in
                try UserStore.createUser(username: username, password: secret, email: email, isSuperuser: superuser, in: db)
            }
            print("Created user \(user.username) (id \(user.id ?? 0))\(user.isSuperuser ? " with superuser rights" : "").")
        }
    }

    struct Password: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Set a user's password.")
        @OptionGroup var global: GlobalOptions
        @Argument var username: String

        func run() async throws {
            let app = try global.openApp()
            let secret = try Prompt.newPassword()
            try await app.database.write { [username] db in
                guard let user = try UserStore.user(named: username, in: db) else { throw ValidationError("No user named \(username)") }
                try UserStore.setPassword(userId: user.id!, password: secret, in: db)
            }
            print("Password changed for \(username).")
        }
    }

    struct Token: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print (or with --regenerate, replace) a user's API token.")
        @OptionGroup var global: GlobalOptions
        @Argument var username: String
        @Flag var regenerate = false

        func run() async throws {
            let app = try global.openApp()
            let token = try await app.database.write { [username, regenerate] db in
                guard let user = try UserStore.user(named: username, in: db) else { throw ValidationError("No user named \(username)") }
                return regenerate ? try UserStore.regenerateToken(for: user.id!, in: db) : try UserStore.token(for: user.id!, in: db)
            }
            print(token)
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List users.")
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let app = try global.openApp()
            let users = try await app.database.read { db in try User.order(Column("username")).fetchAll(db) }
            print(Output.table(["ID", "Username", "Email", "Superuser", "Active"], users.map {
                [String($0.id ?? 0), $0.username, $0.email, $0.isSuperuser ? "yes" : "", $0.isActive ? "yes" : "no"]
            }))
        }
    }
}

enum Prompt {
    static func newPassword() throws -> String {
        guard let first = readSecret("Password: "), !first.isEmpty else { throw ValidationError("Password must not be empty.") }
        guard let second = readSecret("Password (again): "), second == first else { throw ValidationError("Passwords do not match.") }
        return first
    }

    static func readSecret(_ prompt: String) -> String? {
        guard let pointer = getpass(prompt) else { return nil }
        return String(cString: pointer)
    }
}

struct IndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Maintain the full-text index.",
        subcommands: [Reindex.self, Optimize.self]
    )

    struct Reindex: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Rebuild the index from the database.")
        @OptionGroup var global: GlobalOptions
        @Flag(inversion: .prefixedNo, help: "Index word stems (English Porter stemmer).") var stemming = true

        func run() async throws {
            let app = try global.openApp()
            let count = try await app.database.write { [stemming] db in
                try SearchIndex.rebuild(in: db, stemming: stemming)
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM documents_fts") ?? 0
            }
            print("Indexed \(count) documents.")
        }
    }

    struct Optimize: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Merge index segments.")
        @OptionGroup var global: GlobalOptions

        func run() async throws {
            let app = try global.openApp()
            try await app.database.write { db in try SearchIndex.optimize(in: db) }
            print("Index optimized.")
        }
    }
}

struct ConfigCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config", abstract: "Show the effective settings and paths.")
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let s = try global.loadSettings()
        let rows: [[String]] = [
            ["Home", s.home.path], ["Data", s.dataDir.path], ["Database", s.databaseFile.path],
            ["Media", s.mediaRoot.path], ["Consume", s.consumptionDir.path], ["Scratch", s.scratchDir.path],
            ["Logs", s.loggingDir.path], ["Listen", "[\(s.bindAddress)]:\(s.port)"], ["Time zone", s.timeZone.identifier],
            ["OCR", "\(s.ocrEngine.rawValue), mode \(s.ocrMode.rawValue), languages \(s.ocrLanguage.joined(separator: "+"))"],
            ["Archive files", s.archiveFileGeneration.rawValue], ["Filename format", s.filenameFormat ?? "(default: id)"],
            ["Date order", s.dateOrder.rawValue],
            ["Remote OCR", RemoteOCRConfig(settings: s).isConfigured ? "\(s.remoteOCREngine ?? ""), mode \(s.remoteOCRMode.rawValue)" : "not set"],
        ]
        print(Output.table(["Setting", "Value"], rows))
        if !s.raw.isEmpty {
            print("\nExplicitly set:")
            for (key, value) in s.raw.sorted(by: { $0.key < $1.key }) {
                // SOCIALACCOUNT_PROVIDERS holds client secrets inside its JSON.
                let hidden = key.contains("PASSWORD") || key.contains("SECRET") || key.hasSuffix("API_KEY")
                    || key == "SOCIALACCOUNT_PROVIDERS"
                let shown = hidden ? "********" : value
                print("  \(key)=\(shown)")
            }
        }
    }
}

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor", abstract: "Check tools, folders and the database.")
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let settings = try global.loadSettings()
        var problems = 0
        func check(_ label: String, _ ok: Bool, _ detail: String) {
            print("\(ok ? "✓" : "✗") \(label): \(detail)")
            if !ok { problems += 1 }
        }
        func optional(_ label: String, _ url: URL?, _ purpose: String) {
            print("\(url != nil ? "✓" : "–") \(label): \(url?.path ?? "not found (\(purpose))")")
        }

        do {
            let app = try FolioApp.open(settings: settings)
            let count = try await app.database.read { db in try Document.fetchCount(db) }
            check("Database", true, "\(settings.databaseFile.path), \(count) documents")
            check("Parsers", true, app.parsers.parsers.map(\.name).joined(separator: ", "))
        } catch {
            check("Database", false, "\(error)")
        }
        for (label, url) in [("Consume folder", settings.consumptionDir), ("Media folder", settings.mediaRoot), ("Scratch folder", settings.scratchDir)] {
            check(label, FileManager.default.isWritableFile(atPath: url.path), url.path)
        }
        optional("Web frontend", FrontendInstaller.frontendDirectory(settings: settings), "run `foliozero frontend install`, or `serve` installs it")
        optional("Tesseract", ToolLocator.find("tesseract", explicitPath: settings.tesseractPath), "needed for OCR_ENGINE=tesseract")
        optional("Ghostscript", ToolLocator.find("gs", explicitPath: settings.ghostscriptPath), "needed for PDF/A output")
        optional("LibreOffice", ToolLocator.find("soffice", explicitPath: settings.libreOfficePath), "improves Office file conversion")
        if problems > 0 { throw ExitCode(1) }
    }
}
