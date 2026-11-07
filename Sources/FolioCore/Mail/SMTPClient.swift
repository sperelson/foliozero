import Foundation

public enum SMTPError: Error, CustomStringConvertible, Equatable {
    case notConfigured
    case unexpectedReply(command: String, reply: String)
    case connectionClosed

    public var description: String {
        switch self {
        case .notConfigured: "Email sending is not configured (set EMAIL_HOST)"
        case let .unexpectedReply(command, reply): "SMTP \(command) failed: \(reply)"
        case .connectionClosed: "The SMTP server closed the connection"
        }
    }
}

/// An outgoing email with optional attachments.
public struct OutgoingEmail: Sendable {
    public struct Attachment: Sendable {
        public var filename: String
        public var contentType: String
        public var data: Data
        public init(filename: String, contentType: String, data: Data) {
            self.filename = filename; self.contentType = contentType; self.data = data
        }
    }

    public var from: String
    public var to: [String]
    public var subject: String
    public var body: String
    public var attachments: [Attachment]

    public init(from: String, to: [String], subject: String, body: String, attachments: [Attachment] = []) {
        self.from = from; self.to = to; self.subject = subject; self.body = body; self.attachments = attachments
    }

    /// RFC 5322 message with MIME parts, CRLF line endings, dot-stuffing not applied.
    public func rfc5322(date: Date = Date(), boundary: String = "FolioZero-\(UUID().uuidString)") -> Data {
        func encodedWord(_ text: String) -> String {
            text.allSatisfy { $0.isASCII && !$0.isNewline } ? text : "=?UTF-8?B?\(Data(text.utf8).base64EncodedString())?="
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var lines = [
            "From: \(from)",
            "To: \(to.joined(separator: ", "))",
            "Subject: \(encodedWord(subject))",
            "Date: \(formatter.string(from: date))",
            "Message-ID: <\(UUID().uuidString)@foliozero>",
            "MIME-Version: 1.0",
        ]
        let text = Data(body.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        if attachments.isEmpty {
            lines += ["Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: base64", "", text]
        } else {
            lines += ["Content-Type: multipart/mixed; boundary=\"\(boundary)\"", "", "--\(boundary)",
                      "Content-Type: text/plain; charset=utf-8", "Content-Transfer-Encoding: base64", "", text]
            for attachment in attachments {
                let name = attachment.filename.replacingOccurrences(of: "\"", with: "")
                let encodedName = name.allSatisfy(\.isASCII) ? "filename=\"\(name)\"" : "filename*=UTF-8''\(name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "attachment")"
                lines += ["--\(boundary)", "Content-Type: \(attachment.contentType)", "Content-Transfer-Encoding: base64",
                          "Content-Disposition: attachment; \(encodedName)", "",
                          attachment.data.base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])]
            }
            lines.append("--\(boundary)--")
        }
        return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
    }
}

/// Sends mail through the server in `EMAIL_HOST` (Django EMAIL_* settings semantics:
/// EMAIL_USE_SSL is implicit TLS, EMAIL_USE_TLS is STARTTLS).
public struct SMTPClient: Sendable {
    public var host: String
    public var port: Int
    public var username: String?
    public var password: String?
    public var useSSL: Bool
    public var useStartTLS: Bool
    public var timeout: TimeInterval

    public init(host: String, port: Int, username: String?, password: String?, useSSL: Bool, useStartTLS: Bool, timeout: TimeInterval = 30) {
        self.host = host; self.port = port; self.username = username; self.password = password
        self.useSSL = useSSL; self.useStartTLS = useStartTLS; self.timeout = timeout
    }

    public init(settings: Settings) throws {
        guard let host = settings.emailHost else { throw SMTPError.notConfigured }
        self.init(host: host, port: settings.emailPort, username: settings.emailHostUser, password: settings.emailHostPassword,
                  useSSL: settings.emailUseSSL, useStartTLS: settings.emailUseTLS)
    }

    public func send(_ email: OutgoingEmail) async throws {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.streamTask(withHostName: host, port: port)
        task.resume()
        if useSSL { task.startSecureConnection() }
        var reader = ReplyReader(task: task, timeout: timeout)

        func expect(_ code: Int, after command: String) async throws {
            let reply = try await reader.read()
            guard reply.code == code else { throw SMTPError.unexpectedReply(command: command, reply: reply.text) }
        }
        func send(_ line: String, expecting code: Int, display: String? = nil) async throws {
            try await task.write(Data((line + "\r\n").utf8), timeout: timeout)
            try await expect(code, after: display ?? line)
        }

        try await expect(220, after: "greeting")
        try await send("EHLO foliozero.local", expecting: 250)
        if useStartTLS && !useSSL {
            try await send("STARTTLS", expecting: 220)
            task.startSecureConnection()
            try await send("EHLO foliozero.local", expecting: 250)
        }
        if let username, let password, !username.isEmpty {
            // AUTH PLAIN: NUL username NUL password (RFC 4616).
            let token = Data([0] + Array(username.utf8) + [0] + Array(password.utf8)).base64EncodedString()
            try await send("AUTH PLAIN \(token)", expecting: 235, display: "AUTH PLAIN ***")
        }
        try await send("MAIL FROM:<\(Self.address(email.from))>", expecting: 250)
        for recipient in email.to {
            try await send("RCPT TO:<\(Self.address(recipient))>", expecting: 250)
        }
        try await send("DATA", expecting: 354)
        // Dot-stuff lines that start with ".".
        var body = String(decoding: email.rfc5322(), as: UTF8.self)
        body = body.replacingOccurrences(of: "\r\n.", with: "\r\n..")
        if body.hasPrefix(".") { body = "." + body }
        try await task.write(Data((body + ".\r\n").utf8), timeout: timeout)
        try await expect(250, after: "DATA")
        try? await task.write(Data("QUIT\r\n".utf8), timeout: timeout)
        task.cancel()
    }

    /// The address part of "Name <addr>".
    static func address(_ value: String) -> String {
        if let open = value.lastIndex(of: "<"), let close = value.lastIndex(of: ">"), open < close {
            return String(value[value.index(after: open)..<close])
        }
        return value.trimmingCharacters(in: .whitespaces)
    }

    struct Reply {
        var code: Int
        var text: String
    }

    /// Reads multi-line SMTP replies ("250-..." continuation, "250 ..." last line).
    struct ReplyReader {
        let task: URLSessionStreamTask
        let timeout: TimeInterval
        var buffer = Data()

        mutating func read() async throws -> Reply {
            var text: [String] = []
            while true {
                let line = try await readLine()
                text.append(line)
                guard line.count >= 3, let code = Int(line.prefix(3)) else { throw SMTPError.unexpectedReply(command: "read", reply: line) }
                if line.count == 3 || line[line.index(line.startIndex, offsetBy: 3)] == " " {
                    return Reply(code: code, text: text.joined(separator: "\n"))
                }
            }
        }

        mutating func readLine() async throws -> String {
            while true {
                if let range = buffer.range(of: Data("\r\n".utf8)) {
                    let line = String(decoding: buffer[buffer.startIndex..<range.lowerBound], as: UTF8.self)
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    return line
                }
                let (data, eof) = try await task.readData(ofMinLength: 1, maxLength: 65536, timeout: timeout)
                if let data, !data.isEmpty { buffer.append(data) } else if eof { throw SMTPError.connectionClosed }
            }
        }
    }
}
