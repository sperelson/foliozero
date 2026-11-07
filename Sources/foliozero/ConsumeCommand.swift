import ArgumentParser
import FolioCore
import Foundation

struct ConsumeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "consume",
        abstract: "Add files to the archive: detect the type, OCR, classify and store them."
    )

    @OptionGroup var global: GlobalOptions

    @Argument(help: "Files or folders to consume. Folders are read recursively.")
    var paths: [String]

    @Option(help: "Title for the document (single file only).")
    var title: String?

    @Option(name: .customLong("tag"), help: "Tag name or id. Repeat for several tags.")
    var tags: [String] = []

    @Option(help: "Correspondent name or id.")
    var correspondent: String?

    @Option(name: .customLong("type"), help: "Document type name or id.")
    var documentType: String?

    @Option(name: .customLong("storage-path"), help: "Storage path name or id.")
    var storagePath: String?

    @Option(help: "Created date, YYYY-MM-DD.")
    var created: String?

    @Option(help: "Archive serial number (single file only).")
    var asn: Int?

    @Option(help: "Owner username.")
    var owner: String?

    @Flag(help: "Create missing tags, correspondents, types and storage paths.")
    var create = false

    @Flag(help: "Delete the source files after they are consumed.")
    var deleteSource = false

    func validate() throws {
        if created != nil, CalendarDate(iso: created!) == nil { throw ValidationError("--created must be YYYY-MM-DD") }
    }

    func run() async throws {
        let app = try global.openApp()
        let files = try collectFiles(app.settings)
        guard !files.isEmpty else { throw ValidationError("No files to consume.") }
        if files.count > 1, title != nil || asn != nil {
            throw ValidationError("--title and --asn need a single file.")
        }

        let overrides = try await app.database.write { [self] db -> DocumentOverrides in
            var overrides = DocumentOverrides()
            overrides.title = title
            overrides.created = created.flatMap { CalendarDate(iso: $0) }
            overrides.archiveSerialNumber = asn
            overrides.tagIds = try tags.map { try Lookup.resolve($0, Tag.self, create: create, in: db) { Tag(name: $0) } }
            overrides.correspondentId = try correspondent.map { try Lookup.resolve($0, Correspondent.self, create: create, in: db) { Correspondent(name: $0) } }
            overrides.documentTypeId = try documentType.map { try Lookup.resolve($0, DocumentType.self, create: create, in: db) { DocumentType(name: $0) } }
            overrides.storagePathId = try storagePath.map { name in
                try Lookup.resolve(name, StoragePath.self, create: false, in: db) { StoragePath(name: $0, path: $0) }
            }
            if let owner {
                guard let user = try UserStore.user(named: owner, in: db) else { throw ValidationError("No user named \(owner)") }
                overrides.ownerId = user.id
            }
            return overrides
        }

        let consumer = app.consumer()
        var failures = 0
        for file in files {
            let started = Date()
            do {
                let request = ConsumeRequest(file: file, source: .consumeFolder, overrides: overrides, deleteSource: deleteSource)
                let document = try await consumer.consume(request)
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                print("#\(document.id ?? 0)  \(document.title)  (\(document.mimeType), \(document.pageCount.map { "\($0) pages" } ?? "no pages"), \(seconds)s)")
            } catch {
                failures += 1
                FileHandle.standardError.write(Data("✗ \(file.lastPathComponent): \(error)\n".utf8))
            }
        }
        if failures > 0 { throw ExitCode(1) }
    }

    func collectFiles(_ settings: Settings) throws -> [URL] {
        let fm = FileManager.default
        var result: [URL] = []
        for path in paths {
            let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw ValidationError("Not found: \(path)")
            }
            if isDirectory.boolValue {
                let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
                while let item = enumerator?.nextObject() as? URL {
                    if (try? item.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
                       !IgnorePatterns(settings.consumerIgnorePatterns).matches(item.lastPathComponent) {
                        result.append(item)
                    }
                }
            } else {
                result.append(url)
            }
        }
        return result.sorted { $0.path < $1.path }
    }
}
