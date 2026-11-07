import Foundation
import FolioCore
import ZIPFoundation

/// Writes the zip of `/api/documents/bulk_download/` (Paperless-ngx `bulk_download.py` strategies).
enum BulkArchive {
    static func write(entries: [(Document, String?)], to url: URL, content: String, deflate: Bool, followFormatting: Bool,
                      storage: MediaStorage, api: API) throws {
        let archive = try Archive(url: url, accessMode: .create, pathEncoding: nil)
        var used = Set<String>()
        func unique(_ make: (Int) -> String) -> String {
            var counter = 0
            while true {
                let name = make(counter)
                if used.insert(name).inserted { return name }
                counter += 1
            }
        }
        func add(_ file: URL, as entry: String) throws {
            try archive.addEntry(with: entry, fileURL: file, compressionMethod: deflate ? .deflate : .none)
        }
        for (document, correspondent) in entries {
            let original = try api.safeFile(document.filename, root: storage.originalsDir)
            let archived = document.hasArchiveVersion ? try api.safeFile(document.archiveFilename, root: storage.archiveDir) : nil
            func name(archive: Bool, folder: String) -> String {
                if followFormatting, let relative = archive ? document.archiveFilename : document.filename {
                    return unique { counter in folder + withCounter(relative, counter) }
                }
                return unique { counter in folder + API.publicFilename(document, correspondent: correspondent, archive: archive, counter: counter) }
            }
            switch content {
            case "originals":
                try add(original, as: name(archive: false, folder: ""))
            case "both":
                if let archived { try add(archived, as: name(archive: true, folder: "archive/")) }
                try add(original, as: name(archive: false, folder: "originals/"))
            default:
                if let archived { try add(archived, as: name(archive: true, folder: "")) } else { try add(original, as: name(archive: false, folder: "")) }
            }
        }
    }

    /// `a/b.pdf` with counter 1 becomes `a/b_01.pdf`.
    static func withCounter(_ path: String, _ counter: Int) -> String {
        guard counter > 0 else { return path }
        let ext = (path as NSString).pathExtension
        let stem = (path as NSString).deletingPathExtension
        return stem + String(format: "_%02d", counter) + (ext.isEmpty ? "" : "." + ext)
    }
}
