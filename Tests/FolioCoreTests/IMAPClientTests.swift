import Foundation
import Network
import Testing
@testable import FolioCore

/// Mutable state of one fake server connection. NWConnection runs every callback on the
/// server's serial queue, so the state is never used from two threads at once.
final class FakeConnectionState: @unchecked Sendable {
    var buffer = Data()
    var literalRemaining = 0
    var current = ""
    var inData = false
    var saslTag: String?
    var failedSaslTag: String?
}

/// A scripted IMAP server on localhost for one client connection.
final class FakeIMAPServer: @unchecked Sendable {
    let listener: NWListener
    private let queue = DispatchQueue(label: "fake-imap")
    private let lock = NSLock()
    private var received: [String] = []
    private var authentications: [String] = []
    let message: Data
    /// Offer SASL-IR, so XOAUTH2 sends its response with the command.
    let saslIR: Bool
    /// The bearer token AUTHENTICATE XOAUTH2 accepts.
    let accessToken: String
    var port: Int { Int(listener.port!.rawValue) }

    init(message: Data, saslIR: Bool = true, accessToken: String = "good-token") throws {
        self.message = message
        self.saslIR = saslIR
        self.accessToken = accessToken
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in if case .ready = state { ready.signal() } }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
    }

    var commands: [String] { lock.withLock { received } }
    /// Decoded XOAUTH2 responses, in order.
    var xoauth2Responses: [String] { lock.withLock { authentications } }

    func stop() { listener.cancel() }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        send(connection, "* OK FakeIMAP ready\r\n")
        let state = FakeConnectionState()

        // Gmail's behaviour: a wrong token gets a continuation with error details, then NO.
        @Sendable func authenticate(tag: String, response: String) {
            let decoded = Data(base64Encoded: response).map { String(decoding: $0, as: UTF8.self) } ?? ""
            lock.withLock { authentications.append(decoded) }
            if decoded.contains("auth=Bearer \(accessToken)" + String(UnicodeScalar(UInt8(1)))) {
                send(connection, "\(tag) OK authenticated\r\n")
            } else {
                state.failedSaslTag = tag
                send(connection, "+ eyJzdGF0dXMiOiI0MDAiLCJzY2hlbWVzIjoiQmVhcmVyIn0=\r\n")
            }
        }

        @Sendable func handle(_ line: String) {
            lock.withLock { received.append(line) }
            if let tag = state.saslTag {
                state.saslTag = nil
                authenticate(tag: tag, response: line)
                return
            }
            if let tag = state.failedSaslTag {
                state.failedSaslTag = nil
                send(connection, "\(tag) NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n")
                return
            }
            let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return }
            let tag = parts[0], command = parts[1].uppercased()
            switch true {
            case command.hasPrefix("CAPABILITY"):
                send(connection, "* CAPABILITY IMAP4rev1 MOVE UIDPLUS AUTH=XOAUTH2\(saslIR ? " SASL-IR" : "")\r\n\(tag) OK done\r\n")
            case command.hasPrefix("AUTHENTICATE XOAUTH2"):
                let initial = parts[1].dropFirst("AUTHENTICATE XOAUTH2".count).trimmingCharacters(in: .whitespaces)
                if initial.isEmpty {
                    state.saslTag = tag
                    send(connection, "+ \r\n")
                } else {
                    authenticate(tag: tag, response: initial)
                }
            case command.hasPrefix("LOGIN"):
                send(connection, line.contains("\"secret\"") ? "\(tag) OK logged in\r\n" : "\(tag) NO [AUTHENTICATIONFAILED] bad\r\n")
            case command.hasPrefix("LIST"):
                send(connection, "* LIST (\\HasNoChildren) \"/\" INBOX\r\n* LIST (\\HasNoChildren) \"/\" \"Paperless/Done\"\r\n* LIST () \"/\" \"&AMQ-rger\"\r\n\(tag) OK\r\n")
            case command.hasPrefix("SELECT"):
                send(connection, command.contains("INBOX") || command.contains("&AMQ-RGER") ? "* 2 EXISTS\r\n\(tag) OK [READ-WRITE]\r\n" : "\(tag) NO no such mailbox\r\n")
            case command.hasPrefix("UID SEARCH"):
                send(connection, "* SEARCH 7 9\r\n\(tag) OK\r\n")
            case command.hasPrefix("UID FETCH"):
                var reply = Data("* 1 FETCH (UID 7 FLAGS (\\Seen $Forwarded) BODY[] {\(message.count)}\r\n".utf8)
                reply.append(message)
                reply.append(Data(")\r\n\(tag) OK\r\n".utf8))
                connection.send(content: reply, completion: .contentProcessed { _ in })
            case command.hasPrefix("LOGOUT"):
                send(connection, "* BYE bye\r\n\(tag) OK\r\n")
            default:
                send(connection, "\(tag) OK\r\n")
            }
        }

        @Sendable func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, done, _ in
                if let data { state.buffer.append(data) }
                while true {
                    if state.literalRemaining > 0 {
                        guard state.buffer.count >= state.literalRemaining else { break }
                        state.current += String(decoding: state.buffer.prefix(state.literalRemaining), as: UTF8.self)
                        state.buffer.removeFirst(state.literalRemaining)
                        state.literalRemaining = 0
                        continue
                    }
                    guard let range = state.buffer.range(of: Data("\r\n".utf8)) else { break }
                    let line = String(decoding: state.buffer[state.buffer.startIndex..<range.lowerBound], as: UTF8.self)
                    state.buffer.removeSubrange(state.buffer.startIndex..<range.upperBound)
                    if let open = line.lastIndex(of: "{"), line.hasSuffix("}"), let n = Int(line[line.index(after: open)..<line.index(before: line.endIndex)]) {
                        state.current += line[..<open]
                        state.literalRemaining = n
                        self.send(connection, "+ go ahead\r\n")
                        continue
                    }
                    handle(state.current + line)
                    state.current = ""
                }
                if !done { receive() }
            }
        }
        receive()
    }

    private func send(_ connection: NWConnection, _ text: String) {
        connection.send(content: Data(text.utf8), completion: .contentProcessed { _ in })
    }
}

@Suite struct IMAPClientTests {
    let message = Data("From: Bank <statements@bank.example>\r\nSubject: Statement\r\n\r\nHello\r\n".utf8)

    @Test func fullSession() async throws {
        let server = try FakeIMAPServer(message: message)
        defer { server.stop() }
        let client = IMAPClient(host: "127.0.0.1", port: server.port, security: .none, timeout: 5)
        try await client.connect()
        try await client.login(username: "me@example.com", password: "secret")
        #expect(await client.capabilities.contains("MOVE"))

        let folders = try await client.listFolders()
        #expect(folders == ["INBOX", "Paperless/Done", "Ärger"])
        #expect(try await client.select("INBOX") == 2)
        #expect(try await client.select("Ärger") == 2)

        let uids = try await client.search([.unseen, .since(Date(timeIntervalSince1970: 0)), .from("bank"), .subject("Kontoauszug für März")])
        #expect(uids == [7, 9])

        let fetched = try await client.fetch(uid: 7)
        #expect(fetched.raw == message)
        #expect(fetched.flags == ["\\Seen", "$Forwarded"])

        try await client.addFlags(["\\Seen"], uid: 7)
        try await client.move(uid: 9, to: "Paperless/Done")
        await client.logout()

        let commands = server.commands
        #expect(commands.contains { $0.contains("UID SEARCH CHARSET UTF-8 UNSEEN SINCE 1-Jan-1970 FROM \"bank\" SUBJECT Kontoauszug für März") })
        #expect(commands.contains { $0.hasSuffix("UID MOVE 9 \"Paperless/Done\"") })
        #expect(commands.contains { $0.hasSuffix("UID STORE 7 +FLAGS (\\Seen)") })
    }

    @Test func loginFailureAndMissingFolder() async throws {
        let server = try FakeIMAPServer(message: message)
        defer { server.stop() }
        let client = IMAPClient(host: "127.0.0.1", port: server.port, security: .none, timeout: 5)
        try await client.connect()
        await #expect(throws: IMAPError.self) { try await client.login(username: "me", password: "wrong") }
        do {
            try await client.select("Nope")
            Issue.record("expected folderNotFound")
        } catch IMAPError.folderNotFound(let name, let available) {
            #expect(name == "Nope")
            #expect(available.contains("INBOX"))
        }
    }

    @Test func modifiedUTF7RoundTrip() {
        for name in ["INBOX", "Ärger", "日本語/フォルダ", "A&B", "Paperless/Done"] {
            #expect(IMAPClient.decodeModifiedUTF7(IMAPClient.encodeModifiedUTF7(name)) == name)
        }
        #expect(IMAPClient.encodeModifiedUTF7("A&B") == "A&-B")
        #expect(IMAPClient.encodeModifiedUTF7("Ärger") == "&AMQ-rger")
    }

    // MARK: XOAUTH2

    /// `user=…^Aauth=Bearer …^A^A` with Ctrl-A separators.
    static func xoauth2String(_ user: String, _ token: String) -> String {
        let separator = String(UnicodeScalar(UInt8(1)))
        return "user=\(user)\(separator)auth=Bearer \(token)\(separator)\(separator)"
    }

    @Test func xoauth2ResponseEncoding() {
        let response = IMAPClient.xoauth2Response(username: "me@gmail.com", accessToken: "ya29.token")
        #expect(response == "dXNlcj1tZUBnbWFpbC5jb20BYXV0aD1CZWFyZXIgeWEyOS50b2tlbgEB")
        #expect(Data(base64Encoded: response).map { String(decoding: $0, as: UTF8.self) } == Self.xoauth2String("me@gmail.com", "ya29.token"))
    }

    @Test(arguments: [true, false]) func xoauth2Login(saslIR: Bool) async throws {
        let server = try FakeIMAPServer(message: message, saslIR: saslIR)
        defer { server.stop() }
        let client = IMAPClient(host: "127.0.0.1", port: server.port, security: .none, timeout: 5)
        try await client.connect()
        var config = MailAccount.Config(imapServer: "127.0.0.1", imapPort: server.port, imapSecurity: .none, username: "me@gmail.com", password: "good-token")
        config.isToken = true
        try await client.login(account: config)
        #expect(try await client.select("INBOX") == 2)
        await client.logout()

        #expect(server.xoauth2Responses == [Self.xoauth2String("me@gmail.com", "good-token")])
        let commands = server.commands
        #expect(!commands.contains { $0.contains("LOGIN") })
        let encoded = IMAPClient.xoauth2Response(username: "me@gmail.com", accessToken: "good-token")
        if saslIR {
            #expect(commands.contains { $0.hasSuffix(" AUTHENTICATE XOAUTH2 \(encoded)") })
        } else {
            // Without SASL-IR the response follows the server's continuation on its own line.
            let index = try #require(commands.firstIndex { $0.hasSuffix(" AUTHENTICATE XOAUTH2") })
            #expect(commands[index + 1] == encoded)
        }
    }

    @Test func xoauth2RejectedTokenFailsWithoutHanging() async throws {
        let server = try FakeIMAPServer(message: message)
        defer { server.stop() }
        let client = IMAPClient(host: "127.0.0.1", port: server.port, security: .none, timeout: 5)
        try await client.connect()
        do {
            try await client.authenticateXOAUTH2(username: "me@gmail.com", accessToken: "expired-token")
            Issue.record("expected authenticationFailed")
        } catch IMAPError.authenticationFailed(let response) {
            #expect(response.contains("Invalid credentials"))
            #expect(!response.contains("expired-token"))
        }
        // The client answered the error continuation with an empty line.
        #expect(server.commands.last == "")
        await client.logout()
    }

    @Test func passwordAccountsStillUseLogin() async throws {
        let server = try FakeIMAPServer(message: message)
        defer { server.stop() }
        let client = IMAPClient(host: "127.0.0.1", port: server.port, security: .none, timeout: 5)
        try await client.connect()
        try await client.login(account: MailAccount.Config(imapServer: "127.0.0.1", username: "me", password: "secret"))
        await client.logout()
        #expect(server.commands.contains { $0.contains("LOGIN \"me\" \"secret\"") })
        #expect(server.xoauth2Responses.isEmpty)
    }
}
