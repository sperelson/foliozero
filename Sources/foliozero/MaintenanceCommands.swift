import ArgumentParser
import FolioCore
import Foundation

struct SanityCheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "sanity-check", abstract: "Check files, checksums and thumbnails; list orphaned files.")
    @OptionGroup var global: GlobalOptions
    @Flag(help: "Also print informational messages.") var all = false

    func run() async throws {
        let app = try global.openApp()
        let messages = try await DocumentMaintenance.sanityCheck(app: app).filter { all || $0.level != .info }
        if messages.isEmpty {
            print("No issues found.")
            return
        }
        messages.forEach { print($0) }
        if messages.contains(where: { $0.level == .error }) { throw ExitCode(1) }
    }
}

struct RenameCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "rename", abstract: "Move stored files to match FILENAME_FORMAT and storage paths.")
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let app = try global.openApp()
        let moved = try await DocumentMaintenance.renameAll(app: app)
        print("Renamed \(moved) documents.")
    }
}

struct RetagCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "retag", abstract: "Re-run matching rules (and the classifier) on existing documents.")
    @OptionGroup var global: GlobalOptions
    @Flag(name: .shortAndLong, help: "Correspondents.") var correspondents = false
    @Flag(name: .customShort("T"), help: "Tags.") var tags = false
    @Flag(name: .shortAndLong, help: "Document types.") var types = false
    @Flag(name: .shortAndLong, help: "Storage paths.") var storagePaths = false
    @Flag(help: "Replace existing values.") var overwrite = false
    @Flag(help: "Only documents in the inbox.") var inboxOnly = false
    @Flag(help: "With several matches, use the first one.") var useFirst = false

    func run() async throws {
        guard correspondents || tags || types || storagePaths else {
            throw ValidationError("Choose at least one of -c, -T, -t, -s.")
        }
        let app = try global.openApp()
        let changed = try await DocumentMaintenance.retag(app: app, options: .init(
            correspondents: correspondents, documentTypes: types, tags: tags, storagePaths: storagePaths,
            overwrite: overwrite, inboxOnly: inboxOnly, useFirst: useFirst))
        print("Updated \(changed.count) documents\(changed.isEmpty ? "" : ": " + changed.map { "#\($0)" }.joined(separator: ", ")).")
    }
}

struct ReprocessCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "reprocess", abstract: "Parse documents again (text, OCR, archive file, thumbnail).")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Document ids.") var ids: [Int]

    func run() async throws {
        let app = try global.openApp()
        for id in ids {
            do {
                try await DocumentMaintenance.reprocess(app: app, documentId: id)
                print("Reprocessed #\(id).")
            } catch {
                FileHandle.standardError.write(Data("✗ #\(id): \(error)\n".utf8))
            }
        }
    }
}

struct ThumbnailsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "thumbnails", abstract: "Regenerate thumbnails.")
    @OptionGroup var global: GlobalOptions
    @Argument(help: "Document ids (default: all).") var ids: [Int] = []

    func run() async throws {
        let app = try global.openApp()
        let count = try await DocumentMaintenance.regenerateThumbnails(app: app, ids: ids.isEmpty ? nil : ids)
        print("Generated \(count) thumbnails.")
    }
}

struct TrainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "train", abstract: "Train the classifier used by the Auto matching algorithm.")
    @OptionGroup var global: GlobalOptions

    func run() async throws {
        let app = try global.openApp()
        print(try await DocumentClassifier.trainAndSave(app: app))
    }
}

struct EmptyTrashCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "empty-trash", abstract: "Permanently delete documents in the trash.")
    @OptionGroup var global: GlobalOptions
    @Option(help: "Only documents trashed at least this many days ago (default: everything).") var olderThan: Int?

    func run() async throws {
        let app = try global.openApp()
        let count = try await Maintenance.emptyTrash(app: app, olderThan: olderThan)
        print("Deleted \(count) documents.")
    }
}
