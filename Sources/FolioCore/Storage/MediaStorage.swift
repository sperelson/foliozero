import Foundation
import GRDB

public enum StorageError: Error, CustomStringConvertible {
    case outsideRoot(String)
    case missingFile(URL)

    public var description: String {
        switch self {
        case .outsideRoot(let path): "Refusing to write outside the media directory: \(path)"
        case .missingFile(let url): "File not found: \(url.path)"
        }
    }
}

/// File layout under `MEDIA_ROOT`: originals, archive PDFs and thumbnails.
public struct MediaStorage: Sendable {
    public let originalsDir: URL
    public let archiveDir: URL
    public let thumbnailDir: URL
    public let emptyTrashDir: URL?
    public let namer: FileNamer

    public init(settings: Settings) {
        originalsDir = settings.originalsDir
        archiveDir = settings.archiveDir
        thumbnailDir = settings.thumbnailDir
        emptyTrashDir = settings.emptyTrashDir
        namer = FileNamer(settings: settings)
    }

    public func originalURL(_ document: Document) -> URL? {
        document.filename.map { originalsDir.appendingPathComponent($0) }
    }

    public func archiveURL(_ document: Document) -> URL? {
        document.archiveFilename.map { archiveDir.appendingPathComponent($0) }
    }

    public func thumbnailURL(documentId: Int) -> URL {
        thumbnailDir.appendingPathComponent(String(format: "%07d.jpg", documentId))
    }

    /// Moves `source` to `relativePath` under `root`, creating folders. Falls back to copy+delete across volumes.
    public func place(_ source: URL, at relativePath: String, root: URL) throws -> URL {
        // Check the components rather than comparing standardized paths: URL
        // standardization strips "/private" only from paths that already exist.
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !components.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }) else {
            throw StorageError.outsideRoot(relativePath)
        }
        let destination = root.appendingPathComponent(relativePath)
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        do {
            try fm.moveItem(at: source, to: destination)
        } catch {
            try fm.copyItem(at: source, to: destination)
            try? fm.removeItem(at: source)
        }
        return destination
    }

    /// Recomputes the stored names of a document from its metadata and moves its files.
    /// Returns the document with updated `filename` / `archiveFilename` (the caller saves it).
    public func applyNaming(to document: Document, in db: Database) throws -> Document {
        var document = document
        let context = try NamingContext.load(for: document, in: db)
        let version = document.rootDocumentId != nil ? document.versionIndex : nil

        let newOriginal = namer.uniqueFilename(for: context, fileExtension: document.fileExtension, version: version, current: document.filename, root: originalsDir)
        if let current = document.filename, current != newOriginal {
            try move(from: current, to: newOriginal, root: originalsDir)
        }
        document.filename = newOriginal

        if let currentArchive = document.archiveFilename {
            let newArchive = namer.uniqueFilename(for: context, fileExtension: ".pdf", version: version, archive: true, current: currentArchive, originalFilename: newOriginal, root: archiveDir)
            if currentArchive != newArchive {
                try move(from: currentArchive, to: newArchive, root: archiveDir)
            }
            document.archiveFilename = newArchive
        }
        return document
    }

    private func move(from: String, to: String, root: URL) throws {
        let source = root.appendingPathComponent(from)
        guard FileManager.default.fileExists(atPath: source.path) else { throw StorageError.missingFile(source) }
        _ = try place(source, at: to, root: root)
        removeEmptyDirectories(from: source.deletingLastPathComponent(), root: root)
    }

    /// Deletes a document's files. With `EMPTY_TRASH_DIR` set, the original is moved there instead.
    public func deleteFiles(of document: Document) {
        let fm = FileManager.default
        if let original = originalURL(document) {
            if let emptyTrashDir, let name = document.filename {
                _ = try? place(original, at: (name as NSString).lastPathComponent, root: emptyTrashDir)
            } else {
                try? fm.removeItem(at: original)
            }
            removeEmptyDirectories(from: original.deletingLastPathComponent(), root: originalsDir)
        }
        if let archive = archiveURL(document) {
            try? fm.removeItem(at: archive)
            removeEmptyDirectories(from: archive.deletingLastPathComponent(), root: archiveDir)
        }
        if let id = document.id {
            try? fm.removeItem(at: thumbnailURL(documentId: id))
        }
    }

    /// Removes empty folders upwards, stopping at `root`.
    public func removeEmptyDirectories(from directory: URL, root: URL) {
        let fm = FileManager.default
        var current = directory.resolvingSymlinksInPath()
        let rootPath = root.resolvingSymlinksInPath().path
        while current.path.hasPrefix(rootPath + "/") {
            guard let contents = try? fm.contentsOfDirectory(atPath: current.path),
                  contents.allSatisfy({ $0 == ".DS_Store" }) else { return }
            try? fm.removeItem(at: current)
            current = current.deletingLastPathComponent()
        }
    }
}

public enum Checksum {
    /// Lowercase hex SHA-256 of a file, streamed in 1 MiB chunks.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256Stream()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(chunk)
        }
        return hasher.finalizeHex()
    }
}

import CryptoKit

struct SHA256Stream {
    private var hasher = SHA256()
    mutating func update(_ data: Data) { hasher.update(data: data) }
    mutating func finalizeHex() -> String {
        hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
