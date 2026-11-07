import ArgumentParser
import FolioCore
import Foundation
import GRDB

@main
struct FolioZeroCommand: AsyncParsableCommand {
    static let version = FolioApp.version

    static let configuration = CommandConfiguration(
        commandName: "foliozero",
        abstract: "A macOS-native document management server, compatible with the Paperless-ngx API.",
        version: version,
        subcommands: [
            ServeCommand.self,
            ConsumeCommand.self,
            AddURLCommand.self,
            MailCommand.self,
            ListCommand.self,
            ShowCommand.self,
            SearchCommand.self,
            UserCommand.self,
            IndexCommand.self,
            ConfigCommand.self,
            DoctorCommand.self,
            SanityCheckCommand.self,
            RenameCommand.self,
            RetagCommand.self,
            ReprocessCommand.self,
            ThumbnailsCommand.self,
            TrainCommand.self,
            EmptyTrashCommand.self,
            ImportCommand.self,
            ExportCommand.self,
            ServiceCommand.self,
            FrontendCommand.self,
        ]
    )
}

/// Options every command accepts.
struct GlobalOptions: ParsableArguments {
    @Option(name: .long, help: "Data root (default: ~/Library/Application Support/FolioZero or $FOLIOZERO_HOME).")
    var home: String?

    @Option(name: .long, help: "Config file with KEY=VALUE lines (default: <home>/foliozero.conf).")
    var config: String?

    @Option(name: .customLong("set"), help: "Override a setting, e.g. --set OCR_MODE=force. Repeat for several.")
    var overrides: [String] = []

    @Flag(name: .shortAndLong, help: "Log debug output.")
    var verbose = false

    func loadSettings() throws -> Settings {
        var values: [String: String] = [:]
        for item in overrides {
            guard let eq = item.firstIndex(of: "=") else {
                throw ValidationError("--set expects KEY=VALUE, got \(item)")
            }
            let key = item[..<eq].uppercased()
                .replacingOccurrences(of: "FOLIOZERO_", with: "")
                .replacingOccurrences(of: "PAPERLESS_", with: "")
            values[key] = String(item[item.index(after: eq)...])
        }
        if verbose { values["LOGGING_LEVEL"] = "debug" }
        return try SettingsLoader.load(home: home, configFile: config, overrides: values)
    }

    /// Loads settings, sets up logging and opens the app.
    func openApp(logToFile: Bool = false) throws -> FolioApp {
        let settings = try loadSettings()
        FolioLogging.bootstrap(
            level: settings.logLevel,
            file: logToFile ? settings.loggingDir.appendingPathComponent("foliozero.log") : nil,
            maxSize: settings.logRotateMaxSize,
            maxBackups: settings.logRotateMaxBackups
        )
        return try FolioApp.open(settings: settings)
    }
}

// MARK: - Name lookups shared by commands

enum Lookup {
    /// Finds a tag/correspondent/type/path by id or case-insensitive name. With `create`, missing names are created.
    static func resolve<M: MatchingObject>(_ value: String, _ type: M.Type, create: Bool, in db: Database, make: (String) -> M) throws -> Int {
        if let id = Int(value), try M.fetchOne(db, key: id) != nil { return id }
        if let existing = try M.filter(sql: "name = ? COLLATE NOCASE", arguments: [value]).fetchOne(db), let id = existing.id {
            return id
        }
        guard create else {
            throw ValidationError("No \(M.objectType) named \"\(value)\". Use --create to add it.")
        }
        var object = make(value)
        try object.insert(db)
        return object.id!
    }
}

// MARK: - Output helpers

enum Output {
    static func table(_ headers: [String], _ rows: [[String]]) -> String {
        var widths = headers.map(\.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = min(max(widths[index], cell.count), 60)
            }
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { index, cell in
                let clipped = cell.count > widths[index] ? String(cell.prefix(widths[index] - 1)) + "…" : cell
                return clipped.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }
        return ([line(headers), widths.map { String(repeating: "-", count: $0) }.joined(separator: "  ")] + rows.map(line))
            .joined(separator: "\n")
    }

    static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}
