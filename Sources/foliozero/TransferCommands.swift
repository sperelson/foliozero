import ArgumentParser
import FolioCore
import Foundation

struct ImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import a Paperless-ngx export (document_exporter folder or --zip file) or a FolioZero export.",
        discussion: """
            The FolioZero home must be empty: no users, documents or other objects. Users keep their \
            passwords, documents keep their ids, history and permissions. Files are stored under \
            FolioZero's filename format, and the search index is rebuilt. If anything fails, nothing is imported.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Export folder (with manifest.json), or a zip file made with document_exporter --zip.")
    var source: String

    @Option(help: "Passphrase of an export made with --passphrase. Prefer --ask-passphrase; command lines are visible to other processes.")
    var passphrase: String?

    @Flag(help: "Prompt for the export passphrase.")
    var askPassphrase = false

    @Flag(name: .customLong("no-verify-checksums"), help: "Import files that do not match their checksum in the manifest, with a warning.")
    var noVerifyChecksums = false

    func run() async throws {
        let app = try global.openApp()
        var secret = passphrase
        if askPassphrase {
            guard let entered = Prompt.readSecret("Export passphrase: "), !entered.isEmpty else { throw ValidationError("Passphrase must not be empty.") }
            secret = entered
        }
        let url = URL(fileURLWithPath: (source as NSString).expandingTildeInPath)
        let report = try await PaperlessImporter.run(
            app: app, source: url, options: .init(passphrase: secret, verifyChecksums: !noVerifyChecksums),
            progress: { print($0) }
        )
        if let version = report.sourceVersion { print("Export version: \(version)") }
        TransferOutput.print(report, title: "Imported:")
    }
}

struct ExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export documents, files and settings in Paperless-ngx's document_exporter format.",
        discussion: """
            The export can be imported by Paperless-ngx's document_importer (3.4) or by `foliozero import`, \
            for backup and restore. Thumbnails are JPEG files.
            """
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Existing folder to write into.")
    var target: String

    @Flag(name: [.customShort("z"), .long], help: "Write one zip file into the target folder.")
    var zip = false

    @Option(name: [.customLong("zip-name"), .customLong("zn", withSingleDash: true)], help: "Zip file name (default export-YYYY-MM-DD).")
    var zipName: String?

    @Flag(name: [.customLong("no-archive"), .customLong("na", withSingleDash: true)], help: "Leave out archive PDFs.")
    var noArchive = false

    @Flag(name: [.customLong("no-thumbnails"), .customLong("no-thumbnail"), .customLong("nt", withSingleDash: true)], help: "Leave out thumbnails.")
    var noThumbnails = false

    @Flag(name: [.customShort("f"), .customLong("use-filename-format")], help: "Name exported files with FILENAME_FORMAT and storage paths.")
    var useFilenameFormat = false

    @Flag(name: [.customShort("d"), .long], help: "Remove files in the target that are not part of this export (with --zip: everything except the zip).")
    var delete = false

    @Option(help: "Encrypt mail account passwords and tokens with this passphrase. Prefer --ask-passphrase.")
    var passphrase: String?

    @Flag(help: "Prompt for an encryption passphrase.")
    var askPassphrase = false

    func run() async throws {
        let app = try global.openApp()
        var secret = passphrase
        if askPassphrase {
            guard let first = Prompt.readSecret("Export passphrase: "), !first.isEmpty else { throw ValidationError("Passphrase must not be empty.") }
            guard Prompt.readSecret("Export passphrase (again): ") == first else { throw ValidationError("Passphrases do not match.") }
            secret = first
        }
        let url = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
        let options = PaperlessExportOptions(
            zip: zip, zipName: zipName, noArchive: noArchive, noThumbnails: noThumbnails,
            useFilenameFormat: useFilenameFormat, delete: delete, passphrase: secret
        )
        let report = try await PaperlessExporter.run(app: app, target: url, options: options, progress: { print($0) })
        TransferOutput.print(report, title: "Exported:")
        if let path = report.outputPath { print("Export written to \(path)") }
    }
}

enum TransferOutput {
    static func print(_ report: TransferReport, title: String) {
        Swift.print(title)
        Swift.print(Output.table(["Item", "Count"], report.lines.filter { $0.count > 0 }.map { [$0.name, String($0.count)] }))
        if !report.skipped.isEmpty {
            Swift.print("\nSkipped:")
            Swift.print(Output.table(["Item", "Count"], report.skipped.map { [$0.name, String($0.count)] }))
        }
        for message in report.messages { Swift.print(message) }
        if !report.warnings.isEmpty {
            Swift.print("\nWarnings:")
            for warning in report.warnings.prefix(50) { Swift.print("  - \(warning)") }
            if report.warnings.count > 50 { Swift.print("  ... and \(report.warnings.count - 50) more") }
        }
    }
}
