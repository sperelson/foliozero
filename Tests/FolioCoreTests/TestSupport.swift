import Foundation
@testable import FolioCore

/// A temporary directory removed when the value is deinitialised.
final class TempDir {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("foliozero-tests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }

    func file(_ name: String) -> URL { url.appendingPathComponent(name) }
}

/// A database in a temporary directory.
func makeTestDatabase() throws -> (FolioDatabase, TempDir) {
    let dir = TempDir()
    let db = try FolioDatabase(url: dir.file("test.sqlite"))
    return (db, dir)
}

extension Document {
    static func fixture(_ title: String, content: String = "", created: CalendarDate = CalendarDate(year: 2024, month: 3, day: 14), checksum: String? = nil, asn: Int? = nil, pageCount: Int? = 1) -> Document {
        Document(
            title: title, content: content, created: created, mimeType: "application/pdf",
            checksum: checksum ?? UUID().uuidString.lowercased(), archiveSerialNumber: asn, pageCount: pageCount
        )
    }
}
