import Foundation

public enum IMAPError: Error, CustomStringConvertible, Equatable {
    case connectionClosed
    case timeout
    case protocolError(String)
    case commandFailed(command: String, response: String)
    case authenticationFailed(String)
    case folderNotFound(String, available: [String])

    public var description: String {
        switch self {
        case .connectionClosed: "The mail server closed the connection"
        case .timeout: "The mail server did not answer in time"
        case .protocolError(let detail): "Unexpected IMAP response: \(detail)"
        case let .commandFailed(command, response): "IMAP \(command) failed: \(response)"
        case .authenticationFailed(let response): "Mail login failed: \(response)"
        case let .folderNotFound(folder, available): "Mail folder \"\(folder)\" not found. Folders: \(available.joined(separator: ", "))"
        }
    }
}

/// A small IMAP4rev1 client (RFC 3501) with the commands mail rules need.
/// Uses `URLSessionStreamTask`, which handles implicit TLS and STARTTLS.
public actor IMAPClient {
    public enum Security: Int, Codable, Sendable {
        case none = 1, ssl = 2, starttls = 3
    }

    public struct FetchedMessage: Sendable {
        public var uid: UInt32
        public var flags: [String]
        public var raw: Data
    }

    private let host: String
    private let port: Int
    private let security: Security
    private let timeout: TimeInterval
    private var task: URLSessionStreamTask?
    private let session: URLSession
    private var buffer = Data()
    private var tagCounter = 0
    public private(set) var capabilities: Set<String> = []

    public init(host: String, port: Int, security: Security, timeout: TimeInterval = 30) {
        self.host = host
        self.port = port
        self.security = security
        self.timeout = timeout
        self.session = URLSession(configuration: .ephemeral)
    }

    // MARK: Session

    public func connect() async throws {
        let task = session.streamTask(withHostName: host, port: port)
        self.task = task
        task.resume()
        if security == .ssl { task.startSecureConnection() }
        let greeting = try await readLine()
        guard greeting.hasPrefix("* OK") || greeting.hasPrefix("* PREAUTH") else {
            throw IMAPError.protocolError("greeting: \(greeting)")
        }
        try await refreshCapabilities()
        if security == .starttls {
            guard capabilities.contains("STARTTLS") else { throw IMAPError.protocolError("server does not offer STARTTLS") }
            _ = try await command("STARTTLS")
            task.startSecureConnection()
            try await refreshCapabilities()
        }
    }

    public func login(username: String, password: String) async throws {
        do {
            _ = try await command("LOGIN \(Self.quote(username)) \(Self.quote(password))", redacted: "LOGIN ***")
        } catch IMAPError.commandFailed(_, let response) {
            throw IMAPError.authenticationFailed(response)
        }
        try await refreshCapabilities()
    }

    /// OAuth 2 login (Gmail, Outlook). Sends the initial response with the command when the
    /// server offers SASL-IR, otherwise after the first continuation.
    public func authenticateXOAUTH2(username: String, accessToken: String) async throws {
        let response = Self.xoauth2Response(username: username, accessToken: accessToken)
        tagCounter += 1
        let tag = String(format: "F%03d", tagCounter)
        var sentResponse = capabilities.contains("SASL-IR")
        try await write(Data((sentResponse ? "\(tag) AUTHENTICATE XOAUTH2 \(response)\r\n" : "\(tag) AUTHENTICATE XOAUTH2\r\n").utf8))
        while true {
            let line = try await readResponseLine()
            if line.text.hasPrefix("+") {
                // A continuation after the response carries the error details (Gmail); an empty line ends the exchange.
                try await write(Data(((sentResponse ? "" : response) + "\r\n").utf8))
                sentResponse = true
            } else if line.text.hasPrefix("\(tag) ") {
                let status = String(line.text.dropFirst(tag.count + 1))
                guard status.uppercased().hasPrefix("OK") else { throw IMAPError.authenticationFailed(status) }
                break
            } else if line.text.hasPrefix("* BYE") {
                throw IMAPError.connectionClosed
            }
        }
        try await refreshCapabilities()
    }

    /// The SASL XOAUTH2 initial response: `user=…^Aauth=Bearer …^A^A`, base64 encoded.
    static func xoauth2Response(username: String, accessToken: String) -> String {
        let separator: [UInt8] = [1]
        return Data(Array("user=\(username)".utf8) + separator + Array("auth=Bearer \(accessToken)".utf8) + separator + separator).base64EncodedString()
    }

    public func logout() async {
        _ = try? await command("LOGOUT")
        task?.closeWrite()
        task?.cancel()
        task = nil
        session.invalidateAndCancel()
    }

    private func refreshCapabilities() async throws {
        let response = try await command("CAPABILITY")
        for line in response.untagged where line.text.uppercased().hasPrefix("CAPABILITY ") {
            capabilities = Set(line.text.dropFirst(11).uppercased().split(separator: " ").map(String.init))
        }
    }

    // MARK: Mailboxes

    /// All folder names, decoded from modified UTF-7.
    public func listFolders() async throws -> [String] {
        let response = try await command("LIST \"\" \"*\"")
        return response.untagged.compactMap { line -> String? in
            guard line.text.uppercased().hasPrefix("LIST ") else { return nil }
            if let literal = line.literals.first { return Self.decodeModifiedUTF7(String(decoding: literal, as: UTF8.self)) }
            guard let name = Self.lastAtom(of: line.text) else { return nil }
            return Self.decodeModifiedUTF7(name)
        }
    }

    /// Selects a folder. Throws `folderNotFound` with the available names when it does not exist.
    @discardableResult
    public func select(_ folder: String) async throws -> Int {
        do {
            let response = try await command("SELECT \(Self.quote(Self.encodeModifiedUTF7(folder)))")
            return response.untagged.compactMap { line -> Int? in
                let parts = line.text.split(separator: " ")
                return parts.count == 2 && parts[1].uppercased() == "EXISTS" ? Int(parts[0]) : nil
            }.first ?? 0
        } catch IMAPError.commandFailed {
            throw IMAPError.folderNotFound(folder, available: (try? await listFolders()) ?? [])
        }
    }

    // MARK: Messages

    /// `UID SEARCH` with the given criteria. String arguments are sent as UTF-8 literals.
    public func search(_ criteria: [SearchKey]) async throws -> [UInt32] {
        var parts: [CommandPart] = [.text("UID SEARCH")]
        let needsUTF8 = criteria.contains { $0.argument.map { !$0.allSatisfy(\.isASCII) } ?? false }
        if needsUTF8 { parts.append(.text(" CHARSET UTF-8")) }
        if criteria.isEmpty { parts.append(.text(" ALL")) }
        for key in criteria {
            parts.append(.text(" " + key.keyword))
            if let argument = key.argument {
                if argument.allSatisfy(\.isASCII) && !argument.contains("\"") && !argument.contains("\\") {
                    parts.append(.text(" \"\(argument)\""))
                } else {
                    parts.append(.text(" "))
                    parts.append(.literal(Data(argument.utf8)))
                }
            }
        }
        let response = try await command(parts: parts, display: "UID SEARCH")
        return response.untagged
            .filter { $0.text.uppercased().hasPrefix("SEARCH") }
            .flatMap { $0.text.split(separator: " ").dropFirst().compactMap { UInt32($0) } }
    }

    public func fetch(uid: UInt32) async throws -> FetchedMessage {
        let response = try await command("UID FETCH \(uid) (UID FLAGS BODY.PEEK[])")
        guard let line = response.untagged.first(where: { $0.text.uppercased().contains("FETCH") && !$0.literals.isEmpty }),
              let raw = line.literals.last else {
            throw IMAPError.protocolError("no message body for UID \(uid)")
        }
        return FetchedMessage(uid: uid, flags: Self.flags(in: line.text), raw: raw)
    }

    public func addFlags(_ flags: [String], uid: UInt32) async throws {
        _ = try await command("UID STORE \(uid) +FLAGS (\(flags.joined(separator: " ")))")
    }

    public func delete(uid: UInt32) async throws {
        try await addFlags(["\\Deleted"], uid: uid)
        if capabilities.contains("UIDPLUS") {
            _ = try await command("UID EXPUNGE \(uid)")
        } else {
            _ = try await command("EXPUNGE")
        }
    }

    public func move(uid: UInt32, to folder: String) async throws {
        let target = Self.quote(Self.encodeModifiedUTF7(folder))
        if capabilities.contains("MOVE") {
            _ = try await command("UID MOVE \(uid) \(target)")
        } else {
            _ = try await command("UID COPY \(uid) \(target)")
            try await delete(uid: uid)
        }
    }

    public struct SearchKey: Sendable, Equatable {
        public var keyword: String
        public var argument: String?

        public static let unseen = SearchKey(keyword: "UNSEEN")
        public static let unflagged = SearchKey(keyword: "UNFLAGGED")
        public static func unkeyword(_ k: String) -> SearchKey { SearchKey(keyword: "UNKEYWORD \(k)") }
        public static func since(_ date: Date) -> SearchKey {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "d-MMM-yyyy"
            return SearchKey(keyword: "SINCE \(formatter.string(from: date))")
        }
        public static func from(_ s: String) -> SearchKey { SearchKey(keyword: "FROM", argument: s) }
        public static func to(_ s: String) -> SearchKey { SearchKey(keyword: "TO", argument: s) }
        public static func subject(_ s: String) -> SearchKey { SearchKey(keyword: "SUBJECT", argument: s) }
        public static func body(_ s: String) -> SearchKey { SearchKey(keyword: "BODY", argument: s) }
    }

    // MARK: Protocol

    struct ResponseLine {
        var text: String
        var literals: [Data]
    }

    struct Response {
        var untagged: [ResponseLine]
        var status: String
    }

    enum CommandPart {
        case text(String)
        case literal(Data)
    }

    private func command(_ text: String, redacted: String? = nil) async throws -> Response {
        try await command(parts: [.text(text)], display: redacted ?? text)
    }

    /// Sends a command (waiting for `+` before each literal) and collects its response.
    private func command(parts: [CommandPart], display: String) async throws -> Response {
        tagCounter += 1
        let tag = String(format: "F%03d", tagCounter)
        var pending = Data((tag + " ").utf8)
        for part in parts {
            switch part {
            case .text(let text):
                pending.append(Data(text.utf8))
            case .literal(let data):
                pending.append(Data("{\(data.count)}\r\n".utf8))
                try await write(pending)
                pending = Data()
                let continuation = try await readResponseLine()
                guard continuation.text.hasPrefix("+") else {
                    throw IMAPError.commandFailed(command: display, response: continuation.text)
                }
                pending.append(data)
            }
        }
        pending.append(Data("\r\n".utf8))
        try await write(pending)

        var untagged: [ResponseLine] = []
        while true {
            let line = try await readResponseLine()
            if line.text.hasPrefix("\(tag) ") {
                let status = String(line.text.dropFirst(tag.count + 1))
                guard status.uppercased().hasPrefix("OK") else {
                    throw IMAPError.commandFailed(command: display, response: status)
                }
                return Response(untagged: untagged, status: status)
            }
            if line.text.hasPrefix("* BYE"), !display.hasPrefix("LOGOUT") {
                throw IMAPError.connectionClosed
            }
            if line.text.hasPrefix("* ") {
                untagged.append(ResponseLine(text: String(line.text.dropFirst(2)), literals: line.literals))
            }
        }
    }

    /// One logical response line: text with `{n}` literals spliced out into `literals`.
    private func readResponseLine() async throws -> ResponseLine {
        var text = ""
        var literals: [Data] = []
        while true {
            let line = try await readLine()
            if let open = line.lastIndex(of: "{"), line.hasSuffix("}"),
               let count = Int(line[line.index(after: open)..<line.index(before: line.endIndex)].trimmingCharacters(in: CharacterSet(charactersIn: "+"))) {
                text += line[..<open]
                literals.append(try await readBytes(count))
                text += "{literal}"
                continue
            }
            text += line
            return ResponseLine(text: text, literals: literals)
        }
    }

    private func readLine() async throws -> String {
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(decoding: lineData, as: UTF8.self)
            }
            try await fill()
        }
    }

    private func readBytes(_ count: Int) async throws -> Data {
        while buffer.count < count { try await fill() }
        let data = buffer.prefix(count)
        buffer.removeFirst(count)
        return Data(data)
    }

    private func fill() async throws {
        guard let task else { throw IMAPError.connectionClosed }
        let (data, atEOF) = try await task.readData(ofMinLength: 1, maxLength: 1 << 20, timeout: timeout)
        if let data, !data.isEmpty {
            buffer.append(data)
        } else if atEOF {
            throw IMAPError.connectionClosed
        } else {
            throw IMAPError.timeout
        }
    }

    private func write(_ data: Data) async throws {
        guard let task else { throw IMAPError.connectionClosed }
        try await task.write(data, timeout: timeout)
    }

    // MARK: Helpers

    static func quote(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func flags(in text: String) -> [String] {
        guard let start = text.range(of: "FLAGS (", options: .caseInsensitive),
              let end = text[start.upperBound...].firstIndex(of: ")") else { return [] }
        return text[start.upperBound..<end].split(separator: " ").map(String.init)
    }

    /// The last atom or quoted string of a LIST line.
    static func lastAtom(of text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("\"") {
            var result = ""
            var index = trimmed.index(before: trimmed.endIndex)
            var escaped = false
            while index > trimmed.startIndex {
                index = trimmed.index(before: index)
                let ch = trimmed[index]
                if ch == "\"" && !escaped {
                    return String(result.reversed()).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                }
                escaped = false
                result.append(ch)
            }
            return nil
        }
        return trimmed.split(separator: " ").last.map(String.init)
    }

    /// RFC 3501 modified UTF-7 for folder names.
    static func encodeModifiedUTF7(_ string: String) -> String {
        var result = ""
        var pending: [UInt16] = []
        func flush() {
            guard !pending.isEmpty else { return }
            let bytes = pending.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }
            let base64 = Data(bytes).base64EncodedString().replacingOccurrences(of: "/", with: ",").replacingOccurrences(of: "=", with: "")
            result += "&\(base64)-"
            pending = []
        }
        for unit in string.utf16 {
            if (0x20...0x7E).contains(unit) {
                flush()
                result += unit == 0x26 ? "&-" : String(UnicodeScalar(UInt8(unit)))
            } else {
                pending.append(unit)
            }
        }
        flush()
        return result
    }

    static func decodeModifiedUTF7(_ string: String) -> String {
        var result = ""
        var index = string.startIndex
        while index < string.endIndex {
            let ch = string[index]
            if ch == "&", let end = string[index...].firstIndex(of: "-") {
                let encoded = string[string.index(after: index)..<end]
                if encoded.isEmpty {
                    result += "&"
                } else {
                    var base64 = encoded.replacingOccurrences(of: ",", with: "/")
                    while base64.count % 4 != 0 { base64 += "=" }
                    if let data = Data(base64Encoded: base64) {
                        let units = stride(from: 0, to: data.count - 1, by: 2).map { UInt16(data[data.startIndex + $0]) << 8 | UInt16(data[data.startIndex + $0 + 1]) }
                        result += String(decoding: units, as: UTF16.self)
                    }
                }
                index = string.index(after: end)
            } else {
                result.append(ch)
                index = string.index(after: index)
            }
        }
        return result
    }
}
