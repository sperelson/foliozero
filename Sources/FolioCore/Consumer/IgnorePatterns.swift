import Darwin
import Foundation

/// `CONSUMER_IGNORE_PATTERNS`: shell-style patterns (fnmatch) matched against
/// the file name and against its path relative to the consume folder.
public struct IgnorePatterns: Sendable {
    public var patterns: [String]

    public init(_ patterns: [String]) {
        self.patterns = patterns
    }

    /// - Parameter path: a file name, or a path relative to the consume folder.
    public func matches(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return patterns.contains { pattern in
            fnmatch(pattern, path, 0) == 0 || fnmatch(pattern, name, 0) == 0
        }
    }
}
