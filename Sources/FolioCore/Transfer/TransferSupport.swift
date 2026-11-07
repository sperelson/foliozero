import CoreGraphics
import CryptoKit
import FolioParsing
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import ZIPFoundation

public enum TransferError: Error, CustomStringConvertible {
    case notFound(String)
    case notAnExport(String)
    case invalidExport(String)
    case notEmpty(String)
    case missingFile(String)
    case checksumMismatch(documentId: Int, file: String)
    case unsafePath(String)
    case invalidTarget(String)

    public var description: String {
        switch self {
        case .notFound(let path): "That path doesn't exist: \(path)"
        case .notAnExport(let path): "\(path) is not an export: it has no manifest.json (and is not a zip file containing one)"
        case .invalidExport(let reason): "Invalid export: \(reason)"
        case .notEmpty(let detail): "The database is not empty (\(detail)). Import into a new FolioZero home, for example with --home."
        case .missingFile(let detail): "The export is missing a file: \(detail)"
        case .checksumMismatch(let id, let file): "Checksum mismatch for document \(id): \(file). Use --no-verify-checksums to import it anyway."
        case .unsafePath(let path): "Refusing a path outside the export: \(path)"
        case .invalidTarget(let reason): reason
        }
    }
}

/// What an import or export did: rows per table or model, skipped records and warnings.
public struct TransferReport: Sendable, CustomStringConvertible {
    public struct Line: Sendable, Hashable {
        public var name: String
        public var count: Int
    }

    public private(set) var lines: [Line] = []
    public private(set) var skipped: [Line] = []
    public private(set) var warnings: [String] = []
    /// Paperless-ngx version from `metadata.json` / `version.json`.
    public var sourceVersion: String?
    /// Export folder or zip file written.
    public var outputPath: String?
    /// Informational messages (not problems), such as the classifier training result.
    public var messages: [String] = []

    public init() {}

    public func count(_ name: String) -> Int { lines.first { $0.name == name }?.count ?? 0 }
    public func skippedCount(_ name: String) -> Int { skipped.first { $0.name == name }?.count ?? 0 }

    mutating func add(_ name: String, _ n: Int = 1) {
        if let index = lines.firstIndex(where: { $0.name == name }) { lines[index].count += n } else { lines.append(Line(name: name, count: n)) }
    }

    mutating func skip(_ name: String, _ n: Int = 1) {
        if let index = skipped.firstIndex(where: { $0.name == name }) { skipped[index].count += n } else { skipped.append(Line(name: name, count: n)) }
    }

    mutating func warn(_ message: String) {
        warnings.append(message)
    }

    public var description: String {
        var out = lines.filter { $0.count > 0 }.map { "  \($0.name): \($0.count)" }
        if !skipped.isEmpty {
            out.append("Skipped:")
            out += skipped.map { "  \($0.name): \($0.count)" }
        }
        return out.joined(separator: "\n")
    }
}

// MARK: - Manifest records

/// One record of a Django serialisation, as the Paperless-ngx exporter writes them.
public struct ManifestRecord: Codable, Sendable {
    public static let fileNameKey = "__exported_file_name__"
    public static let archiveNameKey = "__exported_archive_name__"
    public static let thumbnailNameKey = "__exported_thumbnail_name__"

    public var model: String
    public var pk: JSONValue
    public var fields: [String: JSONValue]
    public var exportedFileName: String?
    public var exportedArchiveName: String?
    public var exportedThumbnailName: String?

    enum CodingKeys: String, CodingKey {
        case model, pk, fields
        case exportedFileName = "__exported_file_name__"
        case exportedArchiveName = "__exported_archive_name__"
        case exportedThumbnailName = "__exported_thumbnail_name__"
    }

    public init(model: String, pk: JSONValue, fields: [String: JSONValue]) {
        self.model = model
        self.pk = pk
        self.fields = fields
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decode(String.self, forKey: .model).lowercased()
        pk = try c.decodeIfPresent(JSONValue.self, forKey: .pk) ?? .null
        fields = try c.decodeIfPresent([String: JSONValue].self, forKey: .fields) ?? [:]
        exportedFileName = try c.decodeIfPresent(String.self, forKey: .exportedFileName)
        exportedArchiveName = try c.decodeIfPresent(String.self, forKey: .exportedArchiveName)
        exportedThumbnailName = try c.decodeIfPresent(String.self, forKey: .exportedThumbnailName)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(model, forKey: .model)
        try c.encode(pk, forKey: .pk)
        try c.encode(fields, forKey: .fields)
        try c.encodeIfPresent(exportedFileName, forKey: .exportedFileName)
        try c.encodeIfPresent(exportedArchiveName, forKey: .exportedArchiveName)
        try c.encodeIfPresent(exportedThumbnailName, forKey: .exportedThumbnailName)
    }

    var id: Int? { pk.intValue }

    func value(_ key: String) -> JSONValue? {
        guard let value = fields[key], !value.isNull else { return nil }
        return value
    }

    func string(_ key: String) -> String? { value(key)?.stringValue }
    func int(_ key: String) -> Int? { value(key)?.intValue }
    func double(_ key: String) -> Double? { value(key)?.doubleValue }
    func bool(_ key: String) -> Bool? { value(key)?.boolValue }
    func date(_ key: String) -> Date? { string(key).flatMap(DjangoTime.parseDateTime) }

    func list(_ key: String) -> [JSONValue] {
        switch value(key) {
        case .array(let items): items
        case .string(let text):
            // Old Django versions serialised JSON fields as text.
            (try? JSONDecoder().decode([JSONValue].self, from: Data(text.utf8))) ?? []
        default: []
        }
    }

    func intList(_ key: String) -> [Int] { list(key).compactMap(\.intValue) }

    /// A JSON field that may hold a value or (older exports) its JSON text.
    func json(_ key: String) -> JSONValue? {
        guard let value = value(key) else { return nil }
        if case .string(let text) = value, let first = text.first, first == "{" || first == "[",
           let decoded = try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) {
            return decoded
        }
        return value
    }
}

extension JSONValue {
    /// Compact JSON text.
    var manifestJSONText: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    static func manifestValue<T: Encodable>(of value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: JSONEncoder().encode(self))
    }

    var manifestObject: [String: JSONValue]? {
        if case .object(let object) = self { return object }
        return nil
    }
}

// MARK: - Dates

/// Date and time text as Django's JSON encoder writes it.
enum DjangoTime {
    private static let pattern = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:[.,](\d+))?)?)?\s*(Z|[+-]\d{2}(?::?\d{2})?)?$"#
    )

    /// Parses ISO 8601 timestamps (`2024-03-14T10:20:30.123Z`, `...+02:00`, or a bare date).
    /// Times without an offset are UTC.
    static func parseDateTime(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        var components = DateComponents()
        components.year = Int(group(1)!)
        components.month = Int(group(2)!)
        components.day = Int(group(3)!)
        components.hour = group(4).flatMap { Int($0) } ?? 0
        components.minute = group(5).flatMap { Int($0) } ?? 0
        components.second = group(6).flatMap { Int($0) } ?? 0
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard var date = calendar.date(from: components) else { return nil }
        if let fraction = group(7) {
            date += Double("0." + fraction) ?? 0
        }
        if let zone = group(8), zone != "Z" {
            let sign: Double = zone.hasPrefix("-") ? -1 : 1
            let digits = zone.dropFirst().replacingOccurrences(of: ":", with: "")
            let hours = Double(digits.prefix(2)) ?? 0
            let minutes = Double(digits.dropFirst(2)) ?? 0
            date -= sign * (hours * 3600 + minutes * 60)
        }
        return date
    }

    /// A document's `created`: a date, or a timestamp (exports before Paperless-ngx 2.16)
    /// converted to the calendar day in `timeZone`.
    static func parseCalendarDate(_ text: String, timeZone: TimeZone) -> CalendarDate? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= 10 { return CalendarDate(iso: trimmed) }
        return parseDateTime(trimmed).map { CalendarDate($0, in: timeZone) } ?? CalendarDate(iso: trimmed)
    }

    /// `2024-03-14T10:20:30.123Z`, or without the fraction when it is zero (DjangoJSONEncoder).
    static func format(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let rounded = (date.timeIntervalSince1970 * 1000).rounded() / 1000
        let instant = Date(timeIntervalSince1970: rounded)
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: instant)
        let millis = Int((Double(c.nanosecond ?? 0) / 1_000_000).rounded())
        let base = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        return millis > 0 ? base + String(format: ".%03dZ", min(millis, 999)) : base + "Z"
    }
}

// MARK: - Paths and files

enum TransferPaths {
    /// `relative` resolved under `root`. Rejects absolute paths and `..`.
    static func resolve(_ relative: String, under root: URL) throws -> URL {
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !relative.isEmpty, !relative.hasPrefix("/"), !components.isEmpty,
              !components.contains(where: { $0 == ".." }) else {
            throw TransferError.unsafePath(relative)
        }
        return components.filter { $0 != "." }.reduce(root) { $0.appendingPathComponent(String($1)) }
    }

    static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Relative paths of all regular files under `root`.
    static func files(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        let rootPath = root.resolvingSymlinksInPath().path
        var result: [String] = []
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = url.resolvingSymlinksInPath().path
            if path.hasPrefix(rootPath + "/") { result.append(String(path.dropFirst(rootPath.count + 1))) }
        }
        return result.sorted()
    }
}

enum TransferChecksum {
    static func md5(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = Insecure.MD5()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Zip

enum TransferZip {
    static func isZip(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        return head[0] == 0x50 && head[1] == 0x4B && (head[2] == 0x03 || head[2] == 0x05) && (head[3] == 0x04 || head[3] == 0x06)
    }

    /// Extracts regular files and folders of `zip` into `directory`. Symlinks are skipped;
    /// entries that would land outside `directory` abort the extraction.
    static func extract(_ zip: URL, to directory: URL) throws {
        let archive: Archive
        do {
            archive = try Archive(url: zip, accessMode: .read, pathEncoding: nil)
        } catch {
            throw TransferError.invalidExport("cannot open zip file \(zip.lastPathComponent): \(error)")
        }
        for entry in archive {
            let destination = try TransferPaths.resolve(entry.path, under: directory)
            switch entry.type {
            case .directory:
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            case .file:
                _ = try archive.extract(entry, to: destination)
            case .symlink:
                continue
            }
        }
    }
}

// MARK: - Thumbnails and metadata

enum TransferImages {
    /// Writes `source` (JPEG, WebP, PNG...) as a JPEG thumbnail into `scratch` and returns it.
    /// JPEG files are returned unchanged. nil when ImageIO cannot read the file.
    static func jpegThumbnail(from source: URL, maxPixels: Int, scratch: URL) throws -> URL? {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil),
              CGImageSourceGetCount(imageSource) > 0 else { return nil }
        if (CGImageSourceGetType(imageSource) as String?) == UTType.jpeg.identifier {
            return source
        }
        guard let image = ThumbnailRenderer.image(fromImageSource: imageSource, index: 0, maxPixels: maxPixels) else { return nil }
        return try ThumbnailRenderer.write(image, to: scratch, fileName: "thumb-\(UUID().uuidString).jpg")
    }

    /// A new thumbnail for a stored file: PDF first page, image, or Quick Look / placeholder.
    static func render(_ file: URL, maxPixels: Int) async -> CGImage {
        if file.pathExtension.lowercased() == "pdf", let image = ThumbnailRenderer.image(fromPDF: file, maxPixels: maxPixels) {
            return image
        }
        if let source = CGImageSourceCreateWithURL(file as CFURL, nil), CGImageSourceGetCount(source) > 0,
           let image = ThumbnailRenderer.image(fromImageSource: source, index: 0, maxPixels: maxPixels) {
            return image
        }
        return await ThumbnailRenderer.genericImage(for: file, maxPixels: maxPixels)
    }

    /// Metadata entries of a PDF or image, like the parsers record at consume time.
    static func metadata(of file: URL, mimeType: String) -> [MetadataEntry]? {
        if mimeType == "application/pdf" {
            guard let opened = PDFUtilities.open(file) else { return nil }
            return PDFMetadata.entries(for: opened.document, isEncrypted: opened.isEncrypted, isLocked: opened.isLocked)
        }
        if mimeType.hasPrefix("image/"), let source = CGImageSourceCreateWithURL(file as CFURL, nil) {
            let count = CGImageSourceGetCount(source)
            guard count > 0, let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
            return ImageMetadata.entries(properties: properties, frameCount: count)
        }
        return nil
    }
}
