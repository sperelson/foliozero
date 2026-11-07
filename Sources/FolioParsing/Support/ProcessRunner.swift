import Foundation
import Synchronization

/// Output of a finished child process.
public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var standardOutput: Data
    public var standardError: Data
    /// True when the process was killed because it ran longer than the timeout.
    public var timedOut: Bool

    public var succeeded: Bool { exitCode == 0 && !timedOut }
    public var outputString: String { String(decoding: standardOutput, as: UTF8.self) }
    public var errorString: String { String(decoding: standardError, as: UTF8.self) }
}

public enum ProcessRunnerError: Error, Sendable, CustomStringConvertible {
    case launchFailed(String, String)

    public var description: String {
        switch self {
        case .launchFailed(let path, let why): "Cannot launch \(path): \(why)"
        }
    }
}

/// Runs external tools (Tesseract, Ghostscript, LibreOffice) with a timeout.
///
/// Standard output and error go to temporary files, not pipes. A tool that
/// writes a lot of output, or leaves a child process holding the pipe open,
/// therefore cannot block the caller.
public enum ProcessRunner {
    /// Runs `executable` and waits for it to exit.
    ///
    /// - Parameters:
    ///   - environment: Variables merged over the current environment.
    ///   - standardInput: Bytes fed to the process on standard input.
    ///   - timeout: The process gets SIGTERM after this, then SIGKILL 3 seconds later.
    /// - Throws: `ProcessRunnerError.launchFailed` when the process cannot start.
    ///   A non-zero exit or a timeout is reported in the result, not thrown.
    public static func run(
        _ executable: URL,
        arguments: [String],
        environment: [String: String] = [:],
        currentDirectory: URL? = nil,
        standardInput: Data? = nil,
        timeout: Duration = .seconds(300)
    ) async throws -> ProcessResult {
        let fm = FileManager.default
        let ioDir = fm.temporaryDirectory.appendingPathComponent("foliozero-proc-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: ioDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: ioDir) }

        let outURL = ioDir.appendingPathComponent("stdout")
        let errURL = ioDir.appendingPathComponent("stderr")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        defer {
            try? outHandle.close()
            try? errHandle.close()
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        process.standardOutput = outHandle
        process.standardError = errHandle

        var inHandle: FileHandle?
        if let standardInput {
            let inURL = ioDir.appendingPathComponent("stdin")
            try standardInput.write(to: inURL)
            let handle = try FileHandle(forReadingFrom: inURL)
            inHandle = handle
            process.standardInput = handle
        } else {
            process.standardInput = FileHandle.nullDevice
        }
        defer { try? inHandle?.close() }

        let exit = ExitSignal()
        process.terminationHandler = { _ in exit.fire() }
        do {
            try process.run()
        } catch {
            throw ProcessRunnerError.launchFailed(executable.path, error.localizedDescription)
        }

        let timedOut = Flag()
        let watchdog = Task.detached {
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, process.isRunning else { return }
            timedOut.set()
            process.terminate()
            try? await Task.sleep(for: .seconds(3))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }

        await withTaskCancellationHandler {
            await exit.wait()
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
        watchdog.cancel()

        let output = (try? Data(contentsOf: outURL)) ?? Data()
        let errors = (try? Data(contentsOf: errURL)) ?? Data()
        return ProcessResult(
            exitCode: process.terminationStatus,
            standardOutput: output,
            standardError: errors,
            timedOut: timedOut.isSet
        )
    }
}

/// One-shot signal that any number of tasks can await.
final class ExitSignal: Sendable {
    private struct State {
        var fired = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func fire() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.fired = true
            defer { state.waiters = [] }
            return state.waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { state -> Bool in
                if state.fired { return true }
                state.waiters.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}

/// A thread-safe boolean that can only be switched on.
final class Flag: Sendable {
    private let value = Mutex(false)
    func set() { value.withLock { $0 = true } }
    var isSet: Bool { value.withLock { $0 } }
}
