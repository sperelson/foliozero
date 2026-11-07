import Foundation
import Network
import Testing
@testable import FolioCore

/// A scripted SMTP server that records the session.
final class FakeSMTPServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "fake-smtp")
    private let lock = NSLock()
    private var lines: [String] = []
    private var dataBlock = ""
    var port: Int { Int(listener.port!.rawValue) }

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] in self?.serve($0) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    var commands: [String] { lock.withLock { lines } }
    var message: String { lock.withLock { dataBlock } }
    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        @Sendable func send(_ text: String) { connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in }) }
        send("220 fake ESMTP\r\n")
        let state = FakeConnectionState()
        @Sendable func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, _ in
                if let data { state.buffer.append(data) }
                while let range = state.buffer.range(of: Data("\r\n".utf8)) {
                    let line = String(decoding: state.buffer[state.buffer.startIndex..<range.lowerBound], as: UTF8.self)
                    state.buffer.removeSubrange(state.buffer.startIndex..<range.upperBound)
                    if state.inData {
                        if line == "." { state.inData = false; send("250 queued\r\n") } else { self.lock.withLock { self.dataBlock += line + "\n" } }
                        continue
                    }
                    self.lock.withLock { self.lines.append(line) }
                    switch line.prefix(4).uppercased() {
                    case "EHLO": send("250-fake\r\n250-AUTH PLAIN\r\n250 8BITMIME\r\n")
                    case "AUTH": send("235 ok\r\n")
                    case "MAIL", "RCPT": send("250 ok\r\n")
                    case "DATA": state.inData = true; send("354 go\r\n")
                    case "QUIT": send("221 bye\r\n")
                    default: send("500 what\r\n")
                    }
                }
                if !done { receive() }
            }
        }
        receive()
    }
}

@Suite struct SMTPClientTests {
    @Test func sendsMessageWithAttachment() async throws {
        let server = try FakeSMTPServer()
        defer { server.stop() }
        let client = SMTPClient(host: "127.0.0.1", port: server.port, username: "me", password: "pw", useSSL: false, useStartTLS: false, timeout: 5)
        let email = OutgoingEmail(from: "FolioZero <fz@example.com>", to: ["a@example.com", "b@example.com"], subject: "Rechnung für März",
                                  body: "Hello\n.leading dot", attachments: [.init(filename: "doc.pdf", contentType: "application/pdf", data: Data("%PDF".utf8))])
        try await client.send(email)
        let commands = server.commands
        #expect(commands.contains("MAIL FROM:<fz@example.com>"))
        #expect(commands.contains("RCPT TO:<b@example.com>"))
        #expect(commands.contains { $0.hasPrefix("AUTH PLAIN ") })
        let message = server.message
        #expect(message.contains("Subject: =?UTF-8?B?"))
        #expect(message.contains("Content-Disposition: attachment; filename=\"doc.pdf\""))
        #expect(message.contains("multipart/mixed"))
    }

    @Test func addressExtraction() {
        #expect(SMTPClient.address("Name <x@y.z>") == "x@y.z")
        #expect(SMTPClient.address(" x@y.z ") == "x@y.z")
    }
}
