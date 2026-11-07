import Foundation
import Logging

/// Log output: stderr (for the terminal and launchd), plus a size-rotated file
/// `<LOGGING_DIR>/foliozero.log` in server mode.
public enum FolioLogging {
    /// Call once, early. `file` enables the rotating log file.
    public static func bootstrap(level: String, file: URL? = nil, maxSize: Int = 1 << 20, maxBackups: Int = 20) {
        let logLevel = Logger.Level(rawValue: level.lowercased()) ?? (level.lowercased() == "warn" ? .warning : .info)
        let fileWriter = file.map { RotatingFileWriter(url: $0, maxSize: maxSize, maxBackups: maxBackups) }
        LoggingSystem.bootstrap { label in
            var handler = FolioLogHandler(label: label, fileWriter: fileWriter)
            handler.logLevel = logLevel
            return handler
        }
    }
}

struct FolioLogHandler: LogHandler {
    let label: String
    let fileWriter: RotatingFileWriter?
    var logLevel: Logger.Level = .info
    var metadata: Logger.Metadata = [:]

    subscript(metadataKey key: String) -> Logger.Metadata.Value? {
        get { metadata[key] }
        set { metadata[key] = newValue }
    }

    func log(event: LogEvent) {
        let merged = metadata.merging(event.metadata ?? [:]) { _, new in new }
        let meta = merged.isEmpty ? "" : " " + merged.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        let line = "[\(Self.timestamp())] [\(event.level.rawValue.uppercased())] [\(label)] \(event.message)\(meta)\n"
        FileHandle.standardError.write(Data(line.utf8))
        fileWriter?.write(line)
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter.string(from: Date())
    }
}

/// Appends lines to a file, rotating to `.1`, `.2`, ... when it exceeds `maxSize`.
final class RotatingFileWriter: @unchecked Sendable {
    private let url: URL
    private let maxSize: Int
    private let maxBackups: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private var size: Int = 0

    init(url: URL, maxSize: Int, maxBackups: Int) {
        self.url = url
        self.maxSize = max(maxSize, 4096)
        self.maxBackups = max(maxBackups, 0)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        open()
    }

    private func open() {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        size = Int((try? handle?.seekToEnd()) ?? 0)
    }

    func write(_ line: String) {
        lock.withLock {
            let data = Data(line.utf8)
            if size + data.count > maxSize { rotate() }
            try? handle?.write(contentsOf: data)
            size += data.count
        }
    }

    private func rotate() {
        try? handle?.close()
        let fm = FileManager.default
        if maxBackups > 0 {
            try? fm.removeItem(atPath: url.path + ".\(maxBackups)")
            for index in stride(from: maxBackups - 1, through: 1, by: -1) {
                let from = url.path + ".\(index)"
                if fm.fileExists(atPath: from) { try? fm.moveItem(atPath: from, toPath: url.path + ".\(index + 1)") }
            }
            try? fm.moveItem(atPath: url.path, toPath: url.path + ".1")
        } else {
            try? fm.removeItem(at: url)
        }
        open()
    }
}
