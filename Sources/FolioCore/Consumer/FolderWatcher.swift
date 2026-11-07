import CoreServices
import Foundation
import GRDB
import Logging

/// Watches the consume folder and hands stable files to the task queue
/// (Paperless-ngx `document_consumer` management command).
///
/// Uses FSEvents, or polling when `CONSUMER_POLLING_INTERVAL` is above zero.
/// A file is consumed once its size and modification time have not changed for
/// `CONSUMER_STABILITY_DELAY` seconds.
public actor FolderWatcher {
    private let app: FolioApp
    private let queue: TaskQueue
    private let consumer: Consumer
    private let root: URL
    private var candidates: [String: (size: Int, modified: Date, stableSince: Date)] = [:]
    private var inFlight: Set<String> = []
    private var stream: FSEventStreamRef?
    private var loop: Task<Void, Never>?
    private let eventBridge: EventBridge

    public init(app: FolioApp, queue: TaskQueue) {
        self.app = app
        self.queue = queue
        self.consumer = app.consumer()
        self.root = app.settings.consumptionDir.resolvingSymlinksInPath()
        self.eventBridge = EventBridge()
    }

    var settings: Settings { app.settings }
    var logger: Logger { app.logger }

    public func start() {
        logger.info("Watching \(root.path) for new documents\(settings.consumerPollingInterval > 0 ? " (polling)" : "")")
        if settings.consumerPollingInterval <= 0 { startFSEvents() }
        let interval = settings.consumerPollingInterval > 0 ? settings.consumerPollingInterval : 1
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.scan()
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    public func stop() {
        loop?.cancel()
        loop = nil
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        stream = nil
    }

    /// FSEvents only wakes the scan loop early; the scan itself is the source of truth.
    private func startFSEvents() {
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(eventBridge).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<EventBridge>.fromOpaque(info).takeUnretainedValue().signal()
        }
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, [root.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        ) else {
            logger.warning("FSEvents unavailable; falling back to a 1 second scan")
            return
        }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue(label: "foliozero.fsevents"))
        FSEventStreamStart(stream)
        self.stream = stream
        eventBridge.onSignal = { [weak self] in
            Task { await self?.scan() }
        }
    }

    /// One pass over the consume folder.
    public func scan() async {
        let now = Date()
        var seen = Set<String>()
        for file in listFiles() {
            let path = file.path
            seen.insert(path)
            guard !inFlight.contains(path),
                  let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                  let size = values.fileSize, let modified = values.contentModificationDate else { continue }
            if let previous = candidates[path], previous.size == size, previous.modified == modified {
                if now.timeIntervalSince(previous.stableSince) >= settings.consumerStabilityDelay {
                    candidates[path] = nil
                    await submit(file)
                }
            } else {
                candidates[path] = (size, modified, now)
            }
        }
        for path in candidates.keys where !seen.contains(path) { candidates[path] = nil }
    }

    private func listFiles() -> [URL] {
        let fm = FileManager.default
        let ignore = IgnorePatterns(settings.consumerIgnorePatterns)
        let ignoreDirs = Set(settings.consumerIgnoreDirs)
        var result: [URL] = []
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey], options: settings.consumerRecursive ? [] : [.skipsSubdirectoryDescendants]) else { return [] }
        while let url = enumerator.nextObject() as? URL {
            let relative = relativePath(url)
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
            if values?.isDirectory == true {
                if ignoreDirs.contains(url.lastPathComponent) || ignore.matches(relative + "/") { enumerator.skipDescendants() }
                continue
            }
            guard values?.isRegularFile == true, !ignore.matches(relative) else { continue }
            result.append(url)
        }
        return result
    }

    private func relativePath(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().path
        let base = root.path.hasSuffix("/") ? root.path : root.path + "/"
        return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : url.lastPathComponent
    }

    private func submit(_ file: URL) async {
        let path = file.path
        inFlight.insert(path)
        do {
            var overrides = DocumentOverrides()
            if settings.consumerSubdirsAsTags {
                overrides.tagIds = try await tagsForFolders(of: file)
            }
            let request = ConsumeRequest(file: file, source: .consumeFolder, overrides: overrides, deleteSource: true)
            let taskId = try await queue.enqueueConsume(request, consumer: consumer)
            logger.info("Queued \(relativePath(file)) as task \(taskId)")
            // Keep the file marked until the task is done, so it is not queued twice.
            Task { [weak self] in
                await self?.release(path, after: taskId)
            }
        } catch {
            inFlight.remove(path)
            logger.error("Could not queue \(file.lastPathComponent): \(error)")
        }
    }

    private func release(_ path: String, after taskId: String) async {
        while true {
            let status = try? await app.database.read { db in
                try String.fetchOne(db, sql: "SELECT status FROM tasks WHERE task_id = ?", arguments: [taskId])
            }
            if status != "pending" && status != "started" { break }
            try? await Task.sleep(for: .seconds(1))
        }
        inFlight.remove(path)
    }

    /// `CONSUMER_SUBDIRS_AS_TAGS`: each folder between the consume folder and the file becomes a tag.
    private func tagsForFolders(of file: URL) async throws -> [Int] {
        let folders = relativePath(file).split(separator: "/").dropLast()
            .map(String.init)
            .filter { $0 != settings.consumerCollateDoubleSidedSubdirName }
        guard !folders.isEmpty else { return [] }
        return try await app.database.write { db in
            try folders.map { name in
                if let existing = try Tag.filter(sql: "name = ? COLLATE NOCASE", arguments: [name]).fetchOne(db) {
                    return existing.id!
                }
                var tag = Tag(name: name)
                try tag.insert(db)
                return tag.id!
            }
        }
    }
}

/// Carries FSEvents callbacks (on a dispatch queue) into the actor.
final class EventBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable () -> Void)?

    var onSignal: (@Sendable () -> Void)? {
        get { lock.withLock { handler } }
        set { lock.withLock { handler = newValue } }
    }

    func signal() { onSignal?() }
}
