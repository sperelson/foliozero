import Foundation
import PDFKit

/// Page-level PDF edits for the API and workflows. Page numbers are 1-based,
/// as in the Paperless-ngx bulk edit API. Every operation writes new files
/// into `outputDirectory` and never modifies its inputs. Encrypted inputs are
/// opened with `passwords`; outputs are never encrypted.
public enum PDFOperations {
    public enum OperationError: Error, Sendable, Equatable, CustomStringConvertible {
        case unreadable(String)
        case locked(String)
        case pageOutOfRange(page: Int, pageCount: Int)
        case noPages
        case invalidRotation(Int)
        case evenHasMorePages(odd: Int, even: Int)
        case writeFailed(String)

        public var description: String {
            switch self {
            case .unreadable(let name): "\(name) is not a readable PDF"
            case .locked(let name): "\(name) is encrypted and no password worked"
            case .pageOutOfRange(let page, let count): "Page \(page) does not exist (the document has \(count) pages)"
            case .noPages: "The result would have no pages"
            case .invalidRotation(let degrees): "Rotation must be a multiple of 90 degrees, not \(degrees)"
            case .evenHasMorePages(let odd, let even):
                "The even-page scan has \(even) pages but the odd-page scan only \(odd); they do not belong to the same double-sided scan"
            case .writeFailed(let name): "Cannot write \(name)"
            }
        }
    }

    /// One page of an edited document.
    public struct PageSpec: Sendable, Hashable {
        /// 1-based page number in the source.
        public var page: Int
        /// Clockwise rotation added to the page, a multiple of 90.
        public var rotation: Int

        public init(page: Int, rotation: Int = 0) {
            self.page = page
            self.rotation = rotation
        }
    }

    /// Rotates `pages` (all pages when nil) clockwise by `degrees`.
    public static func rotate(
        _ file: URL, pages: [Int]? = nil, degrees: Int, outputDirectory: URL, passwords: [String] = []
    ) throws -> URL {
        try validateRotation(degrees)
        let source = try open(file, passwords: passwords)
        let selected = Set(try pages.map { try validate($0, count: source.pageCount) } ?? Array(1...max(1, source.pageCount)))
        let specs = (1...max(1, source.pageCount)).map { PageSpec(page: $0, rotation: selected.contains($0) ? degrees : 0) }
        return try write(specs: specs, from: source, name: file, suffix: "rotated", outputDirectory: outputDirectory)
    }

    /// Removes `pages`.
    public static func deletePages(_ file: URL, pages: [Int], outputDirectory: URL, passwords: [String] = []) throws -> URL {
        let source = try open(file, passwords: passwords)
        let removed = Set(try validate(pages, count: source.pageCount))
        let specs = (1...max(1, source.pageCount)).filter { !removed.contains($0) }.map { PageSpec(page: $0) }
        return try write(specs: specs, from: source, name: file, suffix: "edited", outputDirectory: outputDirectory)
    }

    /// Builds a document from `specs` in order: reorders, duplicates, drops and rotates pages.
    public static func editPages(_ file: URL, specs: [PageSpec], outputDirectory: URL, passwords: [String] = []) throws -> URL {
        for spec in specs { try validateRotation(spec.rotation) }
        let source = try open(file, passwords: passwords)
        _ = try validate(specs.map(\.page), count: source.pageCount)
        return try write(specs: specs, from: source, name: file, suffix: "edited", outputDirectory: outputDirectory)
    }

    /// Puts pages in `order` (1-based page numbers).
    public static func reorder(_ file: URL, order: [Int], outputDirectory: URL, passwords: [String] = []) throws -> URL {
        try editPages(file, specs: order.map { PageSpec(page: $0) }, outputDirectory: outputDirectory, passwords: passwords)
    }

    /// Concatenates `files`. Document information comes from the first file.
    public static func merge(_ files: [URL], outputDirectory: URL, passwords: [String] = []) throws -> URL {
        guard let first = files.first else { throw OperationError.noPages }
        let output = PDFDocument()
        var sources: [PDFDocument] = []
        for file in files {
            let source = try open(file, passwords: passwords)
            sources.append(source)
            for index in 0..<source.pageCount {
                guard let page = source.page(at: index)?.copy() as? PDFPage else { continue }
                output.insert(page, at: output.pageCount)
            }
        }
        output.documentAttributes = sources.first?.documentAttributes
        return try save(output, name: first, suffix: "merged", outputDirectory: outputDirectory, keepAlive: sources)
    }

    /// One new document per group of 1-based page numbers, for example `[[1, 2], [3]]`.
    public static func split(_ file: URL, pageGroups: [[Int]], outputDirectory: URL, passwords: [String] = []) throws -> [URL] {
        let source = try open(file, passwords: passwords)
        var outputs: [URL] = []
        for (index, group) in pageGroups.enumerated() {
            guard !group.isEmpty else { throw OperationError.noPages }
            _ = try validate(group, count: source.pageCount)
            outputs.append(try write(
                specs: group.map { PageSpec(page: $0) }, from: source, name: file,
                suffix: "part\(index + 1)", outputDirectory: outputDirectory
            ))
        }
        return outputs
    }

    /// One new document per page range, for example `[1...2, 3...5]`.
    public static func split(_ file: URL, ranges: [ClosedRange<Int>], outputDirectory: URL, passwords: [String] = []) throws -> [URL] {
        try split(file, pageGroups: ranges.map(Array.init), outputDirectory: outputDirectory, passwords: passwords)
    }

    /// An unencrypted copy of `file`, or nil when no password opens it.
    /// A file that is not encrypted is copied as it is.
    public static func removePassword(_ file: URL, passwords: [String], outputDirectory: URL) throws -> URL? {
        guard let opened = PDFUtilities.open(file, passwords: passwords) else {
            throw OperationError.unreadable(file.lastPathComponent)
        }
        if opened.isLocked { return nil }
        let specs = (0..<opened.document.pageCount).map { PageSpec(page: $0 + 1) }
        return try write(specs: specs, from: opened.document, name: file, suffix: "unlocked", outputDirectory: outputDirectory)
    }

    /// Collates two single-sided scans of a double-sided document, as Paperless-ngx's
    /// double-sided consumption does: the even pages were scanned back to front,
    /// so they are reversed and interleaved after each odd page.
    public static func collateDoubleSided(odd: URL, even: URL, outputDirectory: URL, passwords: [String] = []) throws -> URL {
        let oddDocument = try open(odd, passwords: passwords)
        let evenDocument = try open(even, passwords: passwords)
        let oddCount = oddDocument.pageCount
        let evenCount = evenDocument.pageCount
        guard evenCount <= oddCount else { throw OperationError.evenHasMorePages(odd: oddCount, even: evenCount) }
        let output = PDFDocument()
        for index in 0..<oddCount {
            if let page = oddDocument.page(at: index)?.copy() as? PDFPage {
                output.insert(page, at: output.pageCount)
            }
            if index < evenCount, let page = evenDocument.page(at: evenCount - 1 - index)?.copy() as? PDFPage {
                output.insert(page, at: output.pageCount)
            }
        }
        output.documentAttributes = oddDocument.documentAttributes
        return try save(output, name: odd, suffix: "collated", outputDirectory: outputDirectory, keepAlive: [oddDocument, evenDocument])
    }

    // MARK: Helpers

    static func open(_ file: URL, passwords: [String]) throws -> PDFDocument {
        guard let opened = PDFUtilities.open(file, passwords: passwords) else {
            throw OperationError.unreadable(file.lastPathComponent)
        }
        guard !opened.isLocked else { throw OperationError.locked(file.lastPathComponent) }
        guard opened.document.pageCount > 0 else { throw OperationError.noPages }
        return opened.document
    }

    static func validate(_ page: Int, count: Int) throws -> Int {
        guard (1...count).contains(page) else { throw OperationError.pageOutOfRange(page: page, pageCount: count) }
        return page
    }

    static func validate(_ pages: [Int], count: Int) throws -> [Int] {
        try pages.map { try validate($0, count: count) }
    }

    static func validateRotation(_ degrees: Int) throws {
        guard degrees % 90 == 0 else { throw OperationError.invalidRotation(degrees) }
    }

    static func write(specs: [PageSpec], from source: PDFDocument, name: URL, suffix: String, outputDirectory: URL) throws -> URL {
        guard !specs.isEmpty else { throw OperationError.noPages }
        let output = PDFDocument()
        for spec in specs {
            guard let page = source.page(at: spec.page - 1)?.copy() as? PDFPage else { continue }
            page.rotation = ImageOrientation.normalize(page.rotation + spec.rotation)
            output.insert(page, at: output.pageCount)
        }
        output.documentAttributes = source.documentAttributes
        return try save(output, name: name, suffix: suffix, outputDirectory: outputDirectory, keepAlive: [source])
    }

    /// Writes `document` as `<input name>-<suffix>-<random>.pdf`. `keepAlive`
    /// holds the source documents, whose pages the copies still reference.
    static func save(_ document: PDFDocument, name: URL, suffix: String, outputDirectory: URL, keepAlive: [PDFDocument]) throws -> URL {
        guard document.pageCount > 0 else { throw OperationError.noPages }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let base = name.deletingPathExtension().lastPathComponent
        let url = outputDirectory.appendingPathComponent("\(base)-\(suffix)-\(UUID().uuidString.prefix(8)).pdf")
        let written = withExtendedLifetime(keepAlive) { document.write(to: url) }
        guard written else { throw OperationError.writeFailed(url.lastPathComponent) }
        return url
    }
}
